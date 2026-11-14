#!/bin/sh
# Einmalig vom Mac aus starten (fragt ein letztes Mal nach dem Passwort des Pi).
# Danach spielt scripts/update-pi.sh neue Versionen ohne Passwort ein. Erlaubt ist dafür
# nur deploy/miniply-aktualisieren: Server und Skripte ersetzen und neu starten, sonst nichts.
# Rückgängig: ssh -t pi sudo rm /etc/sudoers.d/miniply-aktualisieren
set -eu
cd "$(dirname "$0")/.."

scp deploy/miniply-aktualisieren deploy/miniply-aktualisieren.sudoers pi:/tmp/
ssh -t pi 'sudo sh -eu -c "
    install -m 0755 -o root -g root /tmp/miniply-aktualisieren /usr/local/sbin/miniply-aktualisieren
    visudo -cqf /tmp/miniply-aktualisieren.sudoers
    install -m 0440 -o root -g root /tmp/miniply-aktualisieren.sudoers /etc/sudoers.d/miniply-aktualisieren
    rm -f /tmp/miniply-aktualisieren /tmp/miniply-aktualisieren.sudoers
    visudo -cq
"'
if ssh pi 'sudo -n -l /usr/local/sbin/miniply-aktualisieren' >/dev/null 2>&1; then
    echo "Eingerichtet: scripts/update-pi.sh braucht kein Passwort mehr."
else
    echo "Die Regel greift nicht. Mit visudo -c auf dem Pi prüfen." >&2
    exit 1
fi
