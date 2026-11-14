#!/bin/sh
# Bring the Genius token from ~/.config/miniply/genius.env to the Raspberry Pi.
# The server finds songs and albums through the official API with it.
set -eu
scp -q "$HOME/.config/miniply/genius.env" pi:/tmp/miniply-genius.env
ssh -t pi 'sudo sh -eu -c "
    sed -i /^MINIPLY_GENIUS_TOKEN=/d /etc/miniply/server.env
    cat /tmp/miniply-genius.env >> /etc/miniply/server.env
    rm -f /tmp/miniply-genius.env
    systemctl restart miniply
    echo Das Genius-Token ist eingerichtet.
"'
