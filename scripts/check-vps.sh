#!/bin/sh
# Read-only baseline checks. Does not change configuration or restart anything.
set -eu
printf '%s\n' 'Hyse (expected: 200 after login redirect):'
if ! hyse_status=$(curl --silent --show-error --location --output /dev/null \
    --max-time 20 --write-out '%{http_code}' https://hyse.minipliy.net); then
    printf '%s\n' 'Hyse check failed: HTTP request could not be completed.' >&2
    exit 1
fi
if [ "$hyse_status" != 200 ]; then
    printf 'Hyse check failed: expected final HTTP 200, received HTTP %s.\n' "$hyse_status" >&2
    exit 1
fi
printf 'HTTP %s\n' "$hyse_status"
printf '%s\n' 'Root domain (expected: app directory, no redirect):'
if ! root_result=$(curl --silent --show-error --output /dev/null \
    --max-time 20 --write-out '%{http_code} %{redirect_url}' https://minipliy.net); then
    printf '%s\n' 'Root domain check failed: HTTP request could not be completed.' >&2
    exit 1
fi
if [ "$root_result" != '200 ' ]; then
    printf 'Root domain check failed: expected HTTP 200 without redirect, received "%s".\n' "$root_result" >&2
    exit 1
fi
printf 'HTTP %s\n' "$root_result"
vps=${MINIPLY_VPS:-$(cat "$HOME/.config/miniply/vps" 2>/dev/null || true)}
[ -n "$vps" ] || { echo "Kein VPS angegeben: MINIPLY_VPS=benutzer@adresse setzen oder die Zeile in ~/.config/miniply/vps eintragen." >&2; exit 1; }
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$vps" '
sha256sum /etc/caddy/Caddyfile
systemctl show caddy -p ActiveState -p MainPID -p ActiveEnterTimestamp
'
printf '%s\n' 'VPS baseline checks passed.'
