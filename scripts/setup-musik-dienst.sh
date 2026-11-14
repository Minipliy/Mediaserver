#!/bin/sh
# Richtet auf dem Raspberry Pi das Laden von Musik über die App ein. Vom Mac aus
# starten, nach scripts/update-pi.sh. yt-dlp und Deno halten sich danach selbst aktuell:
# täglich und sobald kein Song mehr geladen werden kann.
set -eu
cd "$(dirname "$0")/.."

scp scripts/musik-suchen.py deploy/miniply-music.service deploy/miniply-music-update.service \
    deploy/miniply-music-update.path deploy/miniply-music-update.timer \
    deploy/musik-werkzeuge-aktualisieren.sh pi:/tmp/
ssh -t pi 'sudo sh -eu -c "
    install -d -m 0755 /usr/local/lib/miniply /usr/local/lib/miniply/tools
    install -m 0755 /tmp/musik-suchen.py /tmp/musik-werkzeuge-aktualisieren.sh /usr/local/lib/miniply/
    install -m 0644 /tmp/miniply-music.service /tmp/miniply-music-update.service \
        /tmp/miniply-music-update.path /tmp/miniply-music-update.timer /etc/systemd/system/
    rm -f /tmp/musik-suchen.py /tmp/musik-werkzeuge-aktualisieren.sh /tmp/miniply-music.service \
        /tmp/miniply-music-update.service /tmp/miniply-music-update.path /tmp/miniply-music-update.timer
    install -d -o miniply -g media -m 0750 /var/lib/miniply/music-jobs /var/lib/miniply/music-jobs/.home
    systemctl daemon-reload
    systemctl start miniply-music-update.service
    systemctl enable miniply-music miniply-music-update.path miniply-music-update.timer
    systemctl restart miniply-music
    systemctl start miniply-music-update.path miniply-music-update.timer
    sleep 3
    systemctl is-active miniply-music miniply-music-update.path miniply-music-update.timer
    sudo -u miniply env PATH=/usr/local/lib/miniply/tools:/usr/bin:/bin HOME=/var/lib/miniply/music-jobs/.home \
        yt-dlp --version
    echo Der Musik-Dienst ist eingerichtet.
"'
