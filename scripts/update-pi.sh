#!/bin/sh
# Bring the Raspberry Pi to this checkout's server: run on the Mac after
#   PATH="$PWD/build/cross-tools/bin:$PATH" cargo zigbuild --release \
#       --manifest-path server/Cargo.toml --target aarch64-unknown-linux-musl
# Uses the ssh host "pi". Keeps the previous program in /var/backups/miniply and
# goes back to it by itself when the new one does not answer. Configuration,
# database and media stay untouched; the database only gains new tables.
set -eu
cd "$(dirname "$0")/.."

binary=server/target/aarch64-unknown-linux-musl/release/miniply-server
if [ ! -x "$binary" ]; then
    echo "$binary fehlt. Zuerst bauen, siehe Kopf dieser Datei." >&2
    exit 1
fi

# Ohne Passwort, wenn scripts/setup-ohne-passwort.sh einmal gelaufen ist.
if ssh pi 'sudo -n -l /usr/local/sbin/miniply-aktualisieren' >/dev/null 2>&1; then
    ssh pi 'rm -rf ~/miniply-neu && mkdir -m 0700 ~/miniply-neu'
    scp "$binary" scripts/prepare-media.py scripts/prepare-hls.py scripts/musik-suchen.py pi:miniply-neu/
    ssh pi 'sudo -n /usr/local/sbin/miniply-aktualisieren; status=$?; rm -rf ~/miniply-neu; exit $status'
    exit $?
fi
echo "Tipp: Nach einmal sh scripts/setup-ohne-passwort.sh fragt dieses Skript nicht mehr nach dem Passwort."

scp "$binary" scripts/prepare-media.py scripts/prepare-hls.py scripts/musik-suchen.py deploy/miniply-hls.service pi:/tmp/
ssh -t pi 'sudo sh -eu -c "
    test \"\$(uname -m)\" = aarch64 || { echo \"Kein 64-Bit-ARM-System: \$(uname -m)\" >&2; exit 1; }
    install -d -m 0700 /var/backups/miniply
    cp -p /usr/local/bin/miniply-server /var/backups/miniply/miniply-server.previous
    install -m 0755 /tmp/miniply-server /usr/local/bin/miniply-server.next
    mv /usr/local/bin/miniply-server.next /usr/local/bin/miniply-server
    install -d -m 0755 /usr/local/lib/miniply
    install -m 0755 /tmp/prepare-media.py /tmp/prepare-hls.py /tmp/musik-suchen.py /usr/local/lib/miniply/
    rm -f /tmp/miniply-server /tmp/prepare-media.py /tmp/prepare-hls.py /tmp/musik-suchen.py
    systemctl restart miniply
    systemctl try-restart miniply-music || true
    answered=no
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        sleep 2
        if curl -fsS -m 3 http://10.77.0.2:8080/healthz >/dev/null 2>&1; then answered=yes; break; fi
    done
    if [ \"\$answered\" = no ]; then
        echo \"Der neue Server antwortet nicht. Das vorherige Programm wird zurückgespielt.\" >&2
        journalctl -u miniply -n 30 --no-pager >&2
        install -m 0755 /var/backups/miniply/miniply-server.previous /usr/local/bin/miniply-server.next
        mv /usr/local/bin/miniply-server.next /usr/local/bin/miniply-server
        systemctl restart miniply
        exit 1
    fi
    echo \"Der neue Server läuft.\"
"'
