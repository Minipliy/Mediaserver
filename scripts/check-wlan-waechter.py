#!/usr/bin/env python3
"""Prüft deploy/wlan-waechter.sh mit Ersatz für ping, ip und die Netzwerkbefehle."""
import os
import stat
import subprocess
import tempfile
from pathlib import Path

skript = Path(__file__).resolve().parent.parent / "deploy/wlan-waechter.sh"
ROUTER, VPS = "192.168.0.1", "10.77.0.1"


def ausfuehrbar(pfad, inhalt):
    pfad.write_text(inhalt)
    pfad.chmod(pfad.stat().st_mode | stat.S_IXUSR)


with tempfile.TemporaryDirectory() as tmp:
    ordner = Path(tmp)
    stubs, erreichbar, route, protokoll, kaputt = (
        ordner / "stubs", ordner / "erreichbar", ordner / "route", ordner / "protokoll", ordner / "kaputt")
    stubs.mkdir()
    ausfuehrbar(stubs / "ping", f'#!/bin/sh\nfor a; do z=$a; done\ngrep -qx "$z" "{erreichbar}"\n')
    ausfuehrbar(stubs / "ip", f'#!/bin/sh\ncase "$*" in *default*) cat "{route}";; *) echo "ip $*";; esac\n')
    ausfuehrbar(stubs / "timeout", '#!/bin/sh\nshift\nexec "$@"\n')
    for befehl in ("systemctl", "networkctl", "modprobe"):
        ausfuehrbar(stubs / befehl, f'#!/bin/sh\necho "{befehl} $*" >> "{protokoll}"\n'
                                    f'[ "{befehl}" != modprobe ] || [ ! -e "{kaputt}" ]\n')
    ausfuehrbar(stubs / "wpa_cli", '#!/bin/sh\necho wpa_state=SCANNING\n')
    sparen, iw_protokoll = ordner / "sparen", ordner / "iw"
    ausfuehrbar(stubs / "iw", f'#!/bin/sh\ncase "$*" in *get*) echo "Power save: $(cat "{sparen}")";;'
                              f' *) echo "iw $*" >> "{iw_protokoll}"; echo off > "{sparen}";; esac\n')
    sparen.write_text("off")
    ausfuehrbar(stubs / "dmesg", '#!/bin/sh\necho "brcmfmac: Testzeile"\n')
    umgebung = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", WLAN_ZUSTAND=str(ordner / "zustand"))

    def lauf(*antworten, mit_route=True):
        erreichbar.write_text("".join(z + "\n" for z in antworten))
        route.write_text(f"default via {ROUTER} dev wlan0 proto dhcp\n" if mit_route else "")
        protokoll.write_text("")
        ergebnis = subprocess.run(["sh", str(skript)], env=umgebung, capture_output=True, text=True)
        assert ergebnis.returncode == 0, ergebnis
        return protokoll.read_text().splitlines(), ergebnis.stdout

    def nichts_tun(*antworten, **mehr):
        aufrufe, _ = lauf(*antworten, **mehr)
        assert aufrufe == [], aufrufe

    zaehler = ordner / "zustand/fehlversuche"
    NEU = ["systemctl restart netplan-wpa-wlan0.service", "networkctl reconfigure wlan0"]
    TREIBER = ["modprobe -r brcmfmac_wcc brcmfmac", "modprobe brcmfmac"] + NEU

    # Alles in Ordnung: nichts passiert, nichts wird gezählt.
    nichts_tun(ROUTER, VPS)
    assert not zaehler.exists()
    # Router ignoriert Pings, aber der VPS antwortet: Das WLAN bleibt in Ruhe.
    for _ in range(8):
        nichts_tun(VPS)
    assert not zaehler.exists()
    # Kurzer Aussetzer: Zähler geht zurück, ohne Eingriff, aber mit Meldung im Journal.
    nichts_tun()
    nichts_tun()
    aufrufe, text = lauf(ROUTER)
    assert aufrufe == [] and "wieder da" in text and not zaehler.exists(), text

    # Adresse verloren wie beim echten Ausfall: im dritten Versuch neu verbinden, Zustand im Journal.
    nichts_tun(mit_route=False)
    nichts_tun(mit_route=False)
    aufrufe, text = lauf(mit_route=False)
    assert aufrufe == NEU, aufrufe
    assert "wpa_state=SCANNING" in text and "brcmfmac: Testzeile" in text, text
    # Danach kein Eingriff bis zum Treiber im sechsten Versuch, dann alle zehn Versuche.
    nichts_tun(mit_route=False)
    nichts_tun(mit_route=False)
    aufrufe, _ = lauf(mit_route=False)
    assert aufrufe == TREIBER, aufrufe
    for _ in range(9):
        nichts_tun(mit_route=False)
    aufrufe, _ = lauf(mit_route=False)
    assert aufrufe == TREIBER, aufrufe
    # Wieder da: Meldung und Neubeginn der Zählung.
    aufrufe, text = lauf(ROUTER)
    assert aufrufe == [] and "wieder da" in text and not zaehler.exists(), text

    # Treiber lässt sich nicht entladen: klare Meldung, die Zählung läuft weiter.
    kaputt.touch()
    zaehler.write_text("5")
    aufrufe, text = lauf()
    assert aufrufe == ["modprobe -r brcmfmac_wcc brcmfmac"] and "Neustart des Pi" in text, (aufrufe, text)
    assert zaehler.read_text().strip() == "6"

    # Energiesparen an (nach Neustart oder Treiber-Neuladen): wird ausgeschaltet, sonst nichts.
    kaputt.unlink()
    sparen.write_text("on")
    aufrufe, text = lauf(ROUTER)
    assert iw_protokoll.read_text().splitlines() == ["iw dev wlan0 set power_save off"], iw_protokoll.read_text()
    assert "Energiesparen" in text
    lauf(ROUTER)
    assert len(iw_protokoll.read_text().splitlines()) == 1, "Nur wenn es an ist"

print("WLAN-Wächter ist in Ordnung")
