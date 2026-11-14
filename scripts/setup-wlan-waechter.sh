#!/bin/sh
# Richtet auf dem Raspberry Pi den WLAN-Wächter ein. Vom Mac aus starten.
# Fällt das WLAN aus, verbindet er es neu, und er hält das Energiesparen des WLAN-Chips aus
# (installiert dafür das kleine Paket iw). Protokoll: journalctl -u miniply-wlan-waechter
set -eu
cd "$(dirname "$0")/.."

scp deploy/wlan-waechter.sh deploy/miniply-wlan-waechter.service deploy/miniply-wlan-waechter.timer pi:/tmp/
ssh -t pi 'sudo sh -eu -c "
    command -v iw >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q iw
    install -d -m 0755 /usr/local/lib/miniply
    install -m 0755 /tmp/wlan-waechter.sh /usr/local/lib/miniply/
    install -m 0644 /tmp/miniply-wlan-waechter.service /tmp/miniply-wlan-waechter.timer /etc/systemd/system/
    rm -f /tmp/wlan-waechter.sh /tmp/miniply-wlan-waechter.service /tmp/miniply-wlan-waechter.timer
    systemctl daemon-reload
    systemctl start miniply-wlan-waechter.service
    systemctl enable --now miniply-wlan-waechter.timer
    systemctl is-active miniply-wlan-waechter.timer
    echo Der WLAN-Wächter ist eingerichtet.
"'
