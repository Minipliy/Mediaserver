#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ ! -f .env ]; then
    umask 077
    token=$(openssl rand -hex 32)
    printf 'MINIPLY_TOKEN=%s\nMINIPLY_MEDIA_ROOT=./media\nMINIPLY_DATABASE=./build/dev.sqlite\nMINIPLY_BIND=127.0.0.1:8080\n' "$token" > .env
fi
set -a
. ./.env
set +a
mkdir -p media build
printf '%s\n' 'Development server: http://localhost:8080' 'Local token: open the ignored .env file. Do not commit it.'
exec cargo run --locked --manifest-path server/Cargo.toml
