#!/bin/sh
# Opens the web player at https://media.minipliy.net/ : the VPS forwards / and
# /web/ to the Pi as well, not only the API. Run on the Mac after
#   sh scripts/update-pi.sh
# (the Pi has to know /web/ first). Takes the media.minipliy.net block from
# deploy/websites.Caddyfile, keeps a copy of the old file, checks the new one
# and goes back to the old one when the check fails.
set -eu
cd "$(dirname "$0")/.."
vps=${MINIPLY_VPS:-$(cat "$HOME/.config/miniply/vps" 2>/dev/null || true)}
[ -n "$vps" ] || { echo "Kein VPS angegeben: MINIPLY_VPS=benutzer@adresse setzen oder die Zeile in ~/.config/miniply/vps eintragen." >&2; exit 1; }
block=$(mktemp)
trap 'rm -f "$block"' EXIT
sed -n '/^media.minipliy.net {/,/^}/p' deploy/websites.Caddyfile > "$block"
grep -q '/web/\*' "$block" || { echo "Der Abschnitt für media.minipliy.net fehlt in deploy/websites.Caddyfile." >&2; exit 1; }
scp -q "$block" "$vps:/tmp/media-block.caddy"
ssh "$vps" 'set -eu
f=/etc/caddy/sites/mediaserver.caddy
copy=/var/backups/mediaserver-web/mediaserver.caddy.before-webplayer-$(date +%Y%m%d%H%M%S)
mkdir -p /var/backups/mediaserver-web
cp "$f" "$copy"
python3 - "$f" <<EOF
import sys
path = sys.argv[1]
text = open(path).read()
new = open("/tmp/media-block.caddy").read().rstrip("\n")
start = text.index("media.minipliy.net {")
depth = 0
for position in range(start, len(text)):
    if text[position] == "{":
        depth += 1
    elif text[position] == "}":
        depth -= 1
        if depth == 0:
            end = position + 1
            break
open(path, "w").write(text[:start] + new + text[end:])
EOF
rm -f /tmp/media-block.caddy
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    systemctl reload caddy
    echo "Caddy neu geladen. Alte Fassung: $copy"
else
    cp "$copy" "$f"
    echo "Die neue Fassung war fehlerhaft; die alte ist wieder aktiv." >&2
    exit 1
fi'
sleep 2
for address in https://media.minipliy.net/web/ https://minipliy.net/ https://mediaserver.minipliy.net/ https://hyse.minipliy.net/de/; do
    printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "$address")" "$address"
done
echo
echo "Fertig. Der Web-Player: https://media.minipliy.net/ (Anmeldung mit dem Token aus der App)."
