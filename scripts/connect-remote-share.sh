#!/bin/sh
# Run on the Mac AFTER the Pi, WireGuard and Samba are configured.
set -eu
saved=$(cat "$HOME/.config/miniply/vps" 2>/dev/null || true)
VPS_HOST=${MINIPLY_VPS_HOST:-${saved#*@}}
VPS_USER=${MINIPLY_VPS_USER:-${saved%@*}}
[ -n "$VPS_HOST" ] && [ -n "$VPS_USER" ] || { echo "Kein VPS angegeben: MINIPLY_VPS_HOST und MINIPLY_VPS_USER setzen oder benutzer@adresse in ~/.config/miniply/vps eintragen." >&2; exit 1; }
LOCAL_PORT=${MINIPLY_SMB_PORT:-1445}
case "$LOCAL_PORT" in ''|*[!0-9]*) printf '%s\n' 'Port must be numeric.' >&2; exit 1;; esac
if [ "$LOCAL_PORT" -lt 1024 ] || [ "$LOCAL_PORT" -gt 65535 ]; then
    printf '%s\n' 'Choose an unprivileged local port from 1024 to 65535.' >&2; exit 1
fi
if [ "$(uname -s)" != Darwin ]; then printf '%s\n' 'Run this script on your Mac.' >&2; exit 1; fi
if nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null; then
    printf 'Local port %s is already in use. Set MINIPLY_SMB_PORT to another port.\n' "$LOCAL_PORT" >&2
    exit 1
fi
ssh -N -T -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -L "127.0.0.1:$LOCAL_PORT:10.77.0.2:445" "$VPS_USER@$VPS_HOST" &
tunnel_pid=$!
cleanup() { kill "$tunnel_pid" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
attempt=0
while ! nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null; do
    if ! kill -0 "$tunnel_pid" 2>/dev/null; then wait "$tunnel_pid"; exit 1; fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 15 ]; then printf '%s\n' 'SSH tunnel did not become ready.' >&2; exit 1; fi
    sleep 1
done
printf '%s\n' 'Finder opens the media share. Log in as mediashare with your Samba password.' \
    'Keep this terminal open. Eject Medien in Finder BEFORE pressing Ctrl+C.'
open "smb://mediashare@127.0.0.1:$LOCAL_PORT/Medien"
wait "$tunnel_pid"
