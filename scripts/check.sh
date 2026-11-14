#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
for script in scripts/*.sh; do sh -n "$script"; done
python3 scripts/check-vps-regression.py
python3 scripts/check-untertitel.py
python3 scripts/check-musik-update.py
python3 scripts/check-wlan-waechter.py
python3 scripts/check-ausfall-waechter.py
if [ "${MINIPLY_FORMAT_TESTS:-0}" = 1 ]; then
    python3 scripts/check-media-formats.py
    python3 scripts/check-hls.py
fi
cargo fmt --manifest-path server/Cargo.toml -- --check
cargo test --manifest-path server/Cargo.toml --locked
cargo clippy --manifest-path server/Cargo.toml --locked --all-targets -- -D warnings
if [ "$(uname -s)" = Darwin ] && command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild -quiet -project ios/Mediaserver.xcodeproj -scheme Mediaserver \
        -configuration Debug -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO build
    # Without a German table iOS shows the English one, also on a German iPhone.
    test -s build/ios/Build/Products/Debug-iphonesimulator/Mediaserver.app/de.lproj/Localizable.strings
    scripts/check-ios-model.sh
    scripts/check-ios-api.sh
    if [ "${MINIPLY_SIMULATOR_TESTS:-0}" = 1 ]; then
        scripts/check-ios-playback.sh
        scripts/check-ios-downloads.sh
    fi
fi
if command -v caddy >/dev/null 2>&1; then
    caddy validate --config deploy/Caddyfile.example --adapter caddyfile
fi
