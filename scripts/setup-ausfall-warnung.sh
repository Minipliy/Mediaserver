#!/bin/sh
# Richtet die Ausfall-Warnung auf dem Pi und dem VPS ein. Vom Mac aus starten; fragt einmal
# nach dem Passwort des Pi. Mitteilungen kommen direkt über Apples Push-Dienst in die
# Mediaserver-App (Einstellungen → „Bei Ausfall benachrichtigen"), ohne fremden Dienst.
#
# Braucht einen Push-Schlüssel von Apple (einmalig): developer.apple.com → Certificates,
# Identifiers & Profiles → Keys → „+" → „Apple Push Notifications service (APNs)" → Download.
# Aufruf: sh scripts/setup-ausfall-warnung.sh ~/Downloads/AuthKey_ABCDE12345.p8
set -eu
cd "$(dirname "$0")/.."

schluessel=${1:-}
if [ ! -f "$schluessel" ]; then
    echo "Aufruf: sh scripts/setup-ausfall-warnung.sh /Pfad/zu/AuthKey_XXXXXXXXXX.p8" >&2
    exit 1
fi
kennung=${2:-$(basename "$schluessel" | sed -n 's/^AuthKey_\([A-Z0-9]\{10\}\)\.p8$/\1/p')}
if [ -z "$kennung" ]; then
    echo "Die Schlüssel-ID (10 Zeichen) steht im Dateinamen AuthKey_….p8; als zweites Argument angeben." >&2
    exit 1
fi
openssl pkey -in "$schluessel" -noout 2>/dev/null || { echo "$schluessel ist kein gültiger Schlüssel." >&2; exit 1; }
team=${MINIPLY_APPLE_TEAM:-$(cat "$HOME/.config/miniply/apple-team" 2>/dev/null || true)}
[ -n "$team" ] || { echo "Keine Apple-Team-ID: MINIPLY_APPLE_TEAM setzen oder in ~/.config/miniply/apple-team eintragen." >&2; exit 1; }
vps=${MINIPLY_VPS:-$(cat "$HOME/.config/miniply/vps" 2>/dev/null || true)}
[ -n "$vps" ] || { echo "Kein VPS angegeben: MINIPLY_VPS=benutzer@adresse setzen oder die Zeile in ~/.config/miniply/vps eintragen." >&2; exit 1; }
geraete=http://10.77.0.2:8080/v1/push/devices
arbeit=$(mktemp -d)
trap 'rm -rf "$arbeit"' EXIT

umgebung() { # name ziele
    printf 'NAME="%s"\nZIELE="%s"\nGERAETE_URL=%s\nAPNS_KEY_ID=%s\nAPNS_TEAM_ID=%s\nAPNS_TOPIC=net.miniply.ios\n' \
        "$1" "$2" "$geraete" "$kennung" "$team" > "$arbeit/ausfall.env"
}

# Installiert alles aus /tmp; $1 ist „sudo" oder leer, $2 ein Zusatz vor dem Start.
installieren='
    install -d -m 0755 /usr/local/lib/miniply /etc/miniply
    install -m 0755 /tmp/ausfall-waechter.py /usr/local/lib/miniply/
    install -m 0644 /tmp/miniply-ausfall.service /tmp/miniply-ausfall.timer /etc/systemd/system/
    install -m 0600 /tmp/ausfall.env /etc/miniply/ausfall.env
    install -m 0600 /tmp/apns.p8 /etc/miniply/apns.p8
    rm -f /tmp/ausfall-waechter.py /tmp/miniply-ausfall.service /tmp/miniply-ausfall.timer /tmp/ausfall.env /tmp/apns.p8
    rm -f /usr/local/lib/miniply/ausfall-waechter.sh
    ZUSATZ
    systemctl daemon-reload
    systemctl enable --now miniply-ausfall.timer
    systemctl start miniply-ausfall.service
    systemd-run --quiet --wait --pipe -p DynamicUser=yes -p StateDirectory=miniply-ausfall \
        -p EnvironmentFile=/etc/miniply/ausfall.env -p LoadCredential=apns.p8:/etc/miniply/apns.p8 \
        /usr/bin/python3 /usr/local/lib/miniply/ausfall-waechter.py --test-mitteilung
    systemctl is-active miniply-ausfall.timer
'

hochladen() { # ziel
    scp -q deploy/ausfall-waechter.py deploy/miniply-ausfall.service deploy/miniply-ausfall.timer \
        "$arbeit/ausfall.env" "$1:/tmp/"
    scp -q "$schluessel" "$1:/tmp/apns.p8"
}

# Pi: der Zugangsschlüssel des Servers kommt aus server.env dazu und geht einmal an den VPS.
umgebung "Raspberry Pi" "https://media.minipliy.net/healthz https://hyse.minipliy.net/"
hochladen pi
zusatz='grep "^MINIPLY_TOKEN=" /etc/miniply/server.env >> /etc/miniply/ausfall.env
    rm -f /tmp/miniply-zugang
    (umask 077; grep "^MINIPLY_TOKEN=" /etc/miniply/server.env > /tmp/miniply-zugang)
    chown "$SUDO_USER" /tmp/miniply-zugang'
ssh -t pi "sudo sh -eu -c '$(printf '%s' "$installieren" | sed "s|ZUSATZ|$(printf '%s' "$zusatz" | tr '\n' ';')|")'"
scp -q pi:/tmp/miniply-zugang "$arbeit/zugang"
ssh pi 'rm -f /tmp/miniply-zugang'

# VPS: prüft den Pi durch den Tunnel und meldet auch, wenn der Pi ganz weg ist.
umgebung "VPS" "http://10.77.0.2:8080/healthz"
cat "$arbeit/zugang" >> "$arbeit/ausfall.env"
hochladen "$vps"
ssh -t "$vps" "sh -eu -c '$(printf '%s' "$installieren" | sed 's|ZUSATZ|true|')'"

rm -f build/ausfall-thema.local
echo
echo "Eingerichtet. In der Mediaserver-App unter Einstellungen „Bei Ausfall benachrichtigen\" einschalten."
