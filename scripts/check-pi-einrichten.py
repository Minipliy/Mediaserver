#!/usr/bin/env python3
"""Spielt scripts/pi-einrichten.sh mit dash in einem Testordner durch.

Systembefehle (apt-get, systemctl, useradd, curl …) sind Attrappen; das Skript
schreibt nur unter einem temporären Ordner (MINIPLY_TEST_ROOT). So lassen sich
Erstinstallation, Update, Schutz einer fremden Einrichtung und Startfehler
prüfen, ohne einen Raspberry Pi zu verändern.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "pi-einrichten.sh"
SHELL = shutil.which("dash") or "/bin/sh"

STUBS = {
    "id": """[ "$1" = "-u" ] && { echo "${STUB_UID:-0}"; exit 0; }
[ -f "$STUB_STATE/user" ] || exit 1""",
    "uname": 'echo "${STUB_ARCH:-aarch64}"',
    "apt-get": 'echo "apt-get $*" >> "$STUB_STATE/calls"',
    "getent": '[ -f "$STUB_STATE/group" ]',
    "groupadd": 'touch "$STUB_STATE/group"; echo "groupadd $*" >> "$STUB_STATE/calls"',
    "useradd": 'touch "$STUB_STATE/user"; echo "useradd $*" >> "$STUB_STATE/calls"',
    "mountpoint": "exit 1",
    "chgrp": 'echo "chgrp $*" >> "$STUB_STATE/calls"',
    "openssl": 'echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"',
    "sleep": "exit 0",
    "systemctl": """echo "systemctl $*" >> "$STUB_STATE/calls"
case "$1" in
    show) echo "${STUB_RESTARTS:-0}" ;;
    is-failed) exit 1 ;;
esac""",
    "curl": """for arg; do
    case "$arg" in
        */healthz)
            n=$(cat "$STUB_STATE/health" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_STATE/health"
            [ "${STUB_HEALTHY_AFTER:-1}" != never ] && [ "$n" -ge "${STUB_HEALTHY_AFTER:-1}" ]; exit ;;
    esac
done
out=""; prev=""
for arg; do [ "$prev" = "-o" ] && out=$arg; prev=$arg; done
echo "download $*" >> "$STUB_STATE/calls"
[ -n "$out" ] && printf 'ELF-fake-binary' > "$out"
exit 0""",
}

checks = failures = 0


def expect(condition, message):
    global checks, failures
    checks += 1
    if not condition:
        failures += 1
    print(("PASS " if condition else "FAIL ") + message)


def run(root, state, stubs, **env):
    environment = {
        "PATH": f"{stubs}:/usr/bin:/bin",
        "HOME": str(state),
        "MINIPLY_TEST_ROOT": str(root),
        "STUB_STATE": str(state),
        **env,
    }
    return subprocess.run([SHELL, str(SCRIPT)], env=environment, capture_output=True, text=True, timeout=30)


def fresh():
    base = Path(tempfile.mkdtemp())
    root, state, stubs = base / "root", base / "state", base / "stubs"
    for d in (root, state, stubs):
        d.mkdir()
    for name, body in STUBS.items():
        path = stubs / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
    return base, root, state, stubs


def main():
    base, root, state, stubs = fresh()
    first = run(root, state, stubs)
    env_file = root / "etc/miniply/server.env"
    unit = root / "etc/systemd/system/miniply.service"
    binary = root / "usr/local/bin/miniply-server"
    expect(first.returncode == 0, "Erstinstallation endet ohne Fehler")
    env_text = env_file.read_text() if env_file.exists() else ""
    expect("MINIPLY_TOKEN=0123456789abcdef" in env_text and "MINIPLY_BIND=127.0.0.1:8080" in env_text
           and "MINIPLY_MEDIA_ROOT=/srv/media" in env_text, "Einstellungen mit Token, lokaler Adresse und Medienordner")
    expect(oct(env_file.stat().st_mode & 0o777) == "0o600", "Die Einstellungsdatei ist nur für root lesbar")
    unit_text = unit.read_text() if unit.exists() else ""
    expect(unit_text.startswith("# Eingerichtet mit scripts/pi-einrichten.sh") and "ExecStart=/usr/local/bin/miniply-server" in unit_text
           and "ReadWritePaths=/var/lib/miniply /srv/media" in unit_text and str(root) not in unit_text,
           "Dienst mit Markierung und echten Pfaden, ohne Testordner")
    expect(binary.exists() and os.access(binary, os.X_OK), "Das Programm liegt ausführbar in /usr/local/bin")
    expect(all((root / "srv/media" / d).is_dir() for d in ("Musik", "Filme", "Serien", "Dokumente")), "Medienordner angelegt")
    calls = (state / "calls").read_text()
    expect("releases/latest/download/miniply-server-aarch64-linux" in calls, "Lädt die Version für 64-Bit-ARM")
    expect("useradd --system" in calls and "groupadd --system media" in calls, "Legt Dienstbenutzer und Gruppe an")
    expect("systemctl enable miniply" in calls and "systemctl restart miniply" in calls, "Aktiviert und startet den Dienst")
    expect("Fertig: Mediaserver läuft." in first.stdout and "0123456789abcdef" in first.stdout, "Zeigt Erfolg und das Token")
    expect("keine eigene Festplatte" in first.stdout, "Weist darauf hin, wenn keine Festplatte eingebunden ist")

    (state / "health").unlink(missing_ok=True)
    env_file.write_text(env_text.replace("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "f" * 64))
    second = run(root, state, stubs)
    expect(second.returncode == 0 and "aktualisiert" in second.stdout, "Ein zweiter Lauf aktualisiert")
    expect("f" * 64 in env_file.read_text() and "f" * 64 in second.stdout, "Ein Update behält das bisherige Token")
    expect(calls.count("useradd") == (state / "calls").read_text().count("useradd"), "Ein Update legt den Benutzer nicht neu an")

    unit.write_text("[Unit]\nDescription=Eigene Einrichtung mit WireGuard\n")
    foreign = run(root, state, stubs)
    expect(foreign.returncode != 0 and "eigene Mediaserver-Einrichtung" in foreign.stderr, "Eine fremde Einrichtung wird abgelehnt")
    expect(unit.read_text().startswith("[Unit]\nDescription=Eigene"), "Die fremde Einrichtung bleibt unverändert")
    unit.unlink()

    (state / "health").unlink(missing_ok=True)
    slow = run(root, state, stubs, STUB_HEALTHY_AFTER="15")
    expect(slow.returncode == 0 and "liest deine Bibliothek ein" in slow.stdout, "Wartet geduldig, während eine große Bibliothek eingelesen wird")

    (state / "health").unlink(missing_ok=True)
    crash = run(root, state, stubs, STUB_HEALTHY_AFTER="never", STUB_RESTARTS="1")
    expect(crash.returncode != 0 and "startet nicht" in crash.stderr, "Ein abstürzender Dienst wird sofort gemeldet")

    (state / "health").unlink(missing_ok=True)
    stuck = run(root, state, stubs, STUB_HEALTHY_AFTER="never", MINIPLY_WAIT_SECONDS="3")
    expect(stuck.returncode != 0 and "nach 3 Sekunden" in stuck.stderr, "Gibt nach der Wartezeit mit Hinweis auf das Protokoll auf")

    old = run(root, state, stubs, STUB_ARCH="armv7l")
    expect(old.returncode != 0 and "64-Bit" in old.stderr, "Ein 32-Bit-System wird mit Erklärung abgelehnt")
    pc = run(root, state, stubs, STUB_ARCH="x86_64")
    expect(pc.returncode == 0 and "miniply-server-x86_64-linux" in (state / "calls").read_text(), "Auf einem PC kommt die x86_64-Version")
    user = run(root, state, stubs, STUB_UID="1000")
    expect(user.returncode != 0 and "sudo" in user.stderr, "Ohne sudo kommt ein verständlicher Hinweis")

    shutil.rmtree(base)
    print(f"{checks - failures}/{checks} Prüfungen für pi-einrichten.sh bestanden ({SHELL})")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
