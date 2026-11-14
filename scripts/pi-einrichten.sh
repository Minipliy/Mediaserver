#!/bin/sh
# Richtet Mediaserver auf einem Raspberry Pi (Raspberry Pi OS 64-Bit) oder
# einem anderen Debian-/Ubuntu-Rechner ein. Auf dem Pi ausführen:
#
#   curl -fsSL https://raw.githubusercontent.com/Minipliy/Mediaserver/main/scripts/pi-einrichten.sh | sudo sh
#
# Noch einmal ausgeführt, holt es die neueste Version und behält Token und
# Einstellungen. Medien liegen in /srv/media, die Datenbank in /var/lib/miniply.
# Der Server hört nur auf dem Pi selbst (127.0.0.1:8080); von außen erreichbar
# wird er über Tailscale, siehe docs/ANLEITUNG.md.
set -eu

REPO=${MINIPLY_REPO:-Minipliy/Mediaserver}
MEDIA=/srv/media
ENV_FILE=/etc/miniply/server.env

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\nFehler: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Bitte mit sudo starten (siehe Befehl oben in der Anleitung)."
command -v systemctl >/dev/null 2>&1 || fail "Dieses System hat kein systemd. Nimm Raspberry Pi OS (64-bit)."
case "$(uname -m)" in
    aarch64|arm64) arch=aarch64 ;;
    x86_64|amd64) arch=x86_64 ;;
    *) fail "Nur 64-Bit-Systeme werden unterstützt (gefunden: $(uname -m)). Installiere Raspberry Pi OS (64-bit) neu." ;;
esac

# Eine von Hand eingerichtete Installation (zum Beispiel mit WireGuard und VPS
# nach docs/SETUP.md) nicht überschreiben.
MARKER="# Eingerichtet mit scripts/pi-einrichten.sh"
if [ -f /etc/systemd/system/miniply.service ] && ! grep -qF "$MARKER" /etc/systemd/system/miniply.service; then
    fail "Hier läuft schon eine eigene Mediaserver-Einrichtung. Dieses Skript ändert sie nicht; aktualisiere sie wie bisher (z. B. mit scripts/update-pi.sh)."
fi

say "1/5 Benötigte Programme installieren (ffmpeg für Vorschaubilder und Lautstärke) …"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q ffmpeg curl ca-certificates openssl

say "2/5 Neueste Mediaserver-Version herunterladen …"
download=$(mktemp)
trap 'rm -f "$download"' EXIT
curl -fL --retry 3 --progress-bar -o "$download" \
    "https://github.com/$REPO/releases/latest/download/miniply-server-$arch-linux" \
    || fail "Download fehlgeschlagen. Ist der Pi mit dem Internet verbunden?"
[ -s "$download" ] || fail "Die heruntergeladene Datei ist leer."
updating=false
[ -f /usr/local/bin/miniply-server ] && updating=true
install -m 0755 "$download" /usr/local/bin/miniply-server

say "3/5 Benutzer und Medienordner anlegen …"
getent group media >/dev/null || groupadd --system media
id miniply >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /var/lib/miniply \
    --shell /usr/sbin/nologin --gid media miniply
mkdir -p "$MEDIA/Musik" "$MEDIA/Filme" "$MEDIA/Serien" "$MEDIA/Dokumente"
if ! mountpoint -q "$MEDIA"; then
    printf '%s\n' "Hinweis: Unter $MEDIA ist keine eigene Festplatte eingebunden. Deine Medien landen" \
        "dann auf der SD-Karte. Für eine Festplatte siehe Schritt 4 der Anleitung."
fi
# Der Dienst darf lesen und (für Hochladen und Löschen in der App) schreiben;
# neue Ordner erben die Gruppe.
chgrp -R media "$MEDIA"
chmod -R g+rwX "$MEDIA"
find "$MEDIA" -type d -exec chmod g+s {} +

say "4/5 Einstellungen und Dienst einrichten …"
mkdir -p /etc/miniply
if [ ! -f "$ENV_FILE" ]; then
    token=$(openssl rand -hex 32)
    umask 077
    cat > "$ENV_FILE" <<CONF
# Mediaserver-Einstellungen. Nach einer Änderung: sudo systemctl restart miniply
# Das Token ist dein Passwort für App und Browser. Nicht weitergeben.
MINIPLY_TOKEN=$token
MINIPLY_MEDIA_ROOT=$MEDIA
MINIPLY_DATABASE=/var/lib/miniply/miniply.sqlite
MINIPLY_BIND=127.0.0.1:8080
MINIPLY_SCAN_SECONDS=60
# Beschreibungen, Cover und Folgentitel aus dem Internet (iTunes, Wikipedia,
# TVmaze). Dabei gehen nur Namen wie „Album“ oder „Serie“ hinaus. 0 = aus.
MINIPLY_ONLINE_METADATA=1
# Hochladen und Löschen aus App und Browser. Gelöschtes bleibt 14 Tage in
# $MEDIA/.miniply-papierkorb. 0 = aus.
MINIPLY_UPLOADS=1
MINIPLY_DELETES=1
MINIPLY_THUMBNAILS=1
RUST_LOG=miniply_server=info
CONF
    umask 022
fi
chmod 600 "$ENV_FILE"
cat > /etc/systemd/system/miniply.service <<UNIT
$MARKER
[Unit]
Description=Mediaserver
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$MEDIA

[Service]
Type=simple
User=miniply
Group=media
EnvironmentFile=$ENV_FILE
ExecStart=/usr/local/bin/miniply-server
WorkingDirectory=/var/lib/miniply
StateDirectory=miniply
StateDirectoryMode=0750
UMask=0007
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=/var/lib/miniply $MEDIA

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable miniply >/dev/null 2>&1
systemctl restart miniply

say "5/5 Prüfen, ob der Server antwortet …"
ok=false
for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then ok=true; break; fi
    sleep 1
done
$ok || fail "Der Server startet nicht. Details: sudo journalctl -u miniply -n 50"

token=$(sed -n 's/^MINIPLY_TOKEN=//p' "$ENV_FILE")
if $updating; then
    say "Fertig: Mediaserver ist aktualisiert und läuft."
else
    say "Fertig: Mediaserver läuft."
fi
cat <<DONE

Dein Token (dein Passwort für App und Browser, nur für dich):

    $token

Du findest es jederzeit wieder mit:  sudo cat $ENV_FILE

Weiter geht es in der Anleitung mit Schritt 6 (Tailscale), damit App und
Browser den Server sicher erreichen.
DONE
