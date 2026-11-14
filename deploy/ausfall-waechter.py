#!/usr/bin/env python3
"""Meldet einen Ausfall per Push-Mitteilung an die Mediaserver-App, ohne fremden Dienst.

Läuft alle 5 Minuten auf dem Pi (prüft den Weg über den VPS) und auf dem VPS (prüft den Pi
durch den Tunnel). Antwortet eine Adresse zweimal hintereinander nicht (also nach etwa
10 Minuten), geht über Apples Push-Dienst eine Mitteilung an jedes iPhone, das in der App
„Bei Ausfall benachrichtigen" eingeschaltet hat, und noch eine, wenn sie wieder antwortet.
Die Push-Adressen holt es vom Server und behält eine Kopie für die Zeit, in der der Pi weg ist.

Einrichten: scripts/setup-ausfall-warnung.sh. Protokoll: journalctl -u miniply-ausfall
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ZUSTAND = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/miniply-ausfall"))
NAME = os.environ.get("NAME") or os.uname().nodename
GERAETE = ZUSTAND / "geraete.json"
APPLE = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}


def curl(url, *optionen, kopfzeilen=(), daten=None):
    """Geheimnisse (Kopfzeilen) gehen über stdin an curl, nicht in die Prozessliste."""
    konfiguration = "".join(f'header = "{k}"\n' for k in kopfzeilen)
    befehl = ["curl", "-s", "-m", "15", "-K", "-", *optionen]
    if daten is not None:
        befehl += ["--data-binary", daten]
    ergebnis = subprocess.run([*befehl, url], input=konfiguration, capture_output=True, text=True)
    return ergebnis.stdout


def geraete_aktualisieren():
    url, schluessel = os.environ.get("GERAETE_URL"), os.environ.get("MINIPLY_TOKEN")
    if url and schluessel:
        antwort = curl(url, "-f", kopfzeilen=[f"Authorization: Bearer {schluessel}"])
        try:
            liste = json.loads(antwort)
            if isinstance(liste, list):
                vorlaeufig = GERAETE.with_suffix(".neu")
                vorlaeufig.write_text(json.dumps(liste))
                vorlaeufig.replace(GERAETE)
        except ValueError:
            pass  # Pi nicht erreichbar: die letzte Kopie gilt weiter.
    try:
        return json.loads(GERAETE.read_text())
    except (OSError, ValueError):
        return []


def roh_signatur(der):
    """ECDSA-Signatur von openssl (DER) in die 64 Bytes r‖s, die JWT erwartet."""
    if der[0] != 0x30:
        raise ValueError("keine DER-Signatur")
    stelle, teile = 2 if der[1] < 0x80 else 3, []
    for _ in range(2):
        if der[stelle] != 0x02:
            raise ValueError("keine DER-Signatur")
        laenge = der[stelle + 1]
        zahl = der[stelle + 2 : stelle + 2 + laenge].lstrip(b"\0")
        teile.append(zahl.rjust(32, b"\0"))
        stelle += 2 + laenge
    return b"".join(teile)


def b64(daten):
    return base64.urlsafe_b64encode(daten).rstrip(b"=").decode()


def apple_schluessel():
    ordner = os.environ.get("CREDENTIALS_DIRECTORY")
    datei = Path(ordner, "apns.p8") if ordner else Path(os.environ.get("APNS_KEY_FILE", "/etc/miniply/apns.p8"))
    kennung, team = os.environ.get("APNS_KEY_ID"), os.environ.get("APNS_TEAM_ID")
    if not (kennung and team and datei.is_file()):
        return None
    kopf = b64(json.dumps({"alg": "ES256", "kid": kennung}).encode())
    inhalt = b64(json.dumps({"iss": team, "iat": int(time.time())}).encode())
    signiert = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(datei)],
                              input=f"{kopf}.{inhalt}".encode(), capture_output=True)
    if signiert.returncode != 0:
        print("Push-Schlüssel ließ sich nicht verwenden:", signiert.stderr.decode().strip())
        return None
    return f"{kopf}.{inhalt}.{b64(roh_signatur(signiert.stdout))}"


def melden(titel, text, geraete):
    if not geraete:
        print(f"Keine Mitteilung möglich, kein iPhone angemeldet: {titel}")
        return
    jwt = apple_schluessel()
    if not jwt:
        print(f"Keine Mitteilung möglich, Push-Schlüssel fehlt: {titel}")
        return
    nachricht = json.dumps({"aps": {"alert": {"title": titel, "body": text}, "sound": "default"}})
    for geraet in geraete:
        adresse, umgebung = str(geraet.get("token", "")), APPLE.get(geraet.get("environment"))
        if not (re.fullmatch(r"[0-9a-f]{32,200}", adresse) and umgebung):
            continue
        code = curl(f"{umgebung}/3/device/{adresse}", "--http2", "-o", "/dev/null", "-w", "%{http_code}",
                    kopfzeilen=[f"authorization: bearer {jwt}",
                                f"apns-topic: {os.environ.get('APNS_TOPIC', 'net.miniply.ios')}",
                                "apns-push-type: alert", "apns-priority: 10"],
                    daten=nachricht)
        if code != "200":
            print(f"Apple nahm die Mitteilung für …{adresse[-6:]} nicht an (HTTP {code or 'keine Antwort'}).")


def main():
    ZUSTAND.mkdir(parents=True, exist_ok=True)
    geraete = geraete_aktualisieren()
    for ziel in os.environ.get("ZIELE", "").split():
        datei = ZUSTAND / re.sub(r"[^A-Za-z0-9]", "_", ziel)
        try:
            bisher = int(datei.read_text())
        except (OSError, ValueError):
            bisher = 0
        code = curl(ziel, "-o", "/dev/null", "-w", "%{http_code}") or "000"
        if code[0] in "23" or code == "401":
            if bisher >= 2:
                print(f"{ziel} ist wieder erreichbar.")
                melden("Wieder erreichbar", f"{ziel} antwortet wieder (geprüft von {NAME}).", geraete)
            datei.write_text("0")
        else:
            datei.write_text(str(bisher + 1))
            print(f"{ziel} antwortet nicht (HTTP {code}), Fehlversuch {bisher + 1}.")
            if bisher + 1 == 2:
                melden("Nicht erreichbar",
                       f"{ziel} antwortet seit etwa 10 Minuten nicht (HTTP {code}, geprüft von {NAME}).", geraete)


if __name__ == "__main__":
    if sys.argv[1:] == ["--test-mitteilung"]:
        ZUSTAND.mkdir(parents=True, exist_ok=True)
        melden("Ausfall-Warnung eingerichtet", f"{NAME} prüft jetzt alle 5 Minuten.", geraete_aktualisieren())
    else:
        main()
