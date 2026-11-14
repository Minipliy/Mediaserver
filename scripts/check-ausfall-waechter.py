#!/usr/bin/env python3
"""Prüft deploy/ausfall-waechter.py mit einem Ersatz für curl (Prüfungen, Server, Apple)."""
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

skript = Path(__file__).resolve().parent.parent / "deploy/ausfall-waechter.py"
spec = importlib.util.spec_from_file_location("waechter", skript)
waechter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(waechter)

# DER-Signaturen mit und ohne führende Null werden zu je 32 Bytes r und s.
r, s = b"\x01" * 32, b"\x80" + b"\x02" * 31
der = b"\x30\x45\x02\x20" + r + b"\x02\x21\x00" + s
assert waechter.roh_signatur(der) == r + s
assert waechter.roh_signatur(b"\x30\x26\x02\x01\x05\x02\x21\x00" + s) == b"\0" * 31 + b"\x05" + s

with tempfile.TemporaryDirectory() as tmp:
    ordner = Path(tmp)
    stubs, antwort, geraete, protokoll = ordner / "stubs", ordner / "antwort", ordner / "geraete", ordner / "apple"
    stubs.mkdir()
    curl = stubs / "curl"
    curl.write_text(f'''#!/bin/sh
konfiguration=$(cat)
for url; do :; done
case "$url" in
  *push.apple.com*) echo "$url $(printf '%s' "$konfiguration" | tr '\\n' ' ') $*" >> "{protokoll}"; printf 200;;
  */v1/push/devices) case "$konfiguration" in *"Bearer geheim"*) cat "{geraete}";; *) exit 22;; esac;;
  *) printf '%s' "$(cat "{antwort}")";;
esac
''')
    openssl = stubs / "openssl"
    openssl.write_text(f'#!/bin/sh\ncat > /dev/null\nprintf "{"".join(f"\\\\{b:03o}" for b in der)}"\n')
    for stub in (curl, openssl):
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    schluessel = ordner / "apns.p8"
    schluessel.write_text("Schlüssel")
    token = "ab" * 32
    geraete.write_text(json.dumps([{"token": token, "environment": "production"},
                                   {"token": "kaputt", "environment": "production"}]))
    umgebung = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", STATE_DIRECTORY=str(ordner / "zustand"),
                    NAME="Pi", ZIELE="https://media.example/healthz", GERAETE_URL="http://pi/v1/push/devices",
                    MINIPLY_TOKEN="geheim", APNS_KEY_FILE=str(schluessel), APNS_KEY_ID="ABCDE12345",
                    APNS_TEAM_ID="TEAM123456")

    def lauf(code):
        antwort.write_text(code)
        ergebnis = subprocess.run([sys.executable, str(skript)], env=umgebung, capture_output=True, text=True)
        assert ergebnis.returncode == 0, ergebnis
        return protokoll.read_text().splitlines() if protokoll.exists() else []

    assert lauf("200") == []
    assert lauf("502") == [], "Ein einzelner Aussetzer meldet nichts"
    geraete.write_text("Pi ist weg")  # Ab jetzt gilt die gespeicherte Kopie der Geräteliste.
    gemeldet = lauf("000")
    assert len(gemeldet) == 1, gemeldet
    assert f"https://api.push.apple.com/3/device/{token}" in gemeldet[0]
    assert "authorization: bearer " in gemeldet[0] and "apns-topic: net.miniply.ios" in gemeldet[0]
    assert "Nicht erreichbar" in gemeldet[0] and "--http2" in gemeldet[0]
    assert "geheim" not in gemeldet[0]
    assert len(lauf("000")) == 1, "Nur einmal pro Ausfall"
    gemeldet = lauf("302")
    assert len(gemeldet) == 2 and "Wieder erreichbar" in gemeldet[1], gemeldet
    assert len(lauf("200")) == 2

    # Die JWT-Signatur ist r‖s in Base64url.
    jwt = gemeldet[1].split("authorization: bearer ")[1].split('"')[0]
    kopf, _, signatur = jwt.split(".")
    assert json.loads(waechter.base64.urlsafe_b64decode(kopf + "==")) == {"alg": "ES256", "kid": "ABCDE12345"}
    assert waechter.base64.urlsafe_b64decode(signatur + "==") == r + s

print("Ausfall-Wächter ist in Ordnung")
