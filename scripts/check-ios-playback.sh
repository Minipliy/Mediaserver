#!/bin/sh
# Compile the real player into an isolated simulator app and test async transitions.
# Uses an existing booted iOS simulator. To select one explicitly, set
# MINIPLY_TEST_SIMULATOR_UUID=<booted simulator UUID>. No simulator is created.
# The fixture media, app, sandbox and random-scope defaults are removed afterward.
# Optional: MINIPLY_PLAYBACK_FIXTURES=/absolute/directory adds real prepared copies
# named prepared-video.mp4 and prepared-audio.m4a to the playback checks.
set -eu
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Darwin ]; then
    echo "Playback regression tests require macOS and Xcode." >&2
    exit 1
fi

playback_simulator=${MINIPLY_TEST_SIMULATOR_UUID:-}
if [ -z "$playback_simulator" ]; then
    playback_simulator=$(xcrun simctl list devices booted --json | python3 -c '
import json,sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" in runtime:
        for device in devices:
            if device["state"] == "Booted" and device.get("isAvailable", True):
                print(device["udid"])
                sys.exit(0)
sys.exit(1)
') || {
        echo "Boot an existing iOS simulator or set MINIPLY_TEST_SIMULATOR_UUID to a booted simulator." >&2
        exit 1
    }
fi

playback_work=$(mktemp -d "${TMPDIR:-/tmp}/miniply-playback.XXXXXX")
playback_app="$playback_work/PlaybackTests.app"
playback_bundle="net.miniply.PlaybackRegressionTests.p$$"
playback_installed=false
cleanup() {
    if [ "$playback_installed" = true ]; then
        xcrun simctl terminate "$playback_simulator" "$playback_bundle" >/dev/null 2>&1 || true
        xcrun simctl uninstall "$playback_simulator" "$playback_bundle" >/dev/null 2>&1 || true
    fi
    rm -rf "$playback_work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$playback_app"
python3 - "$playback_app" "$playback_bundle" <<'PY'
import plistlib, sys, wave
from pathlib import Path
app = Path(sys.argv[1])
with (app / "Info.plist").open("wb") as stream:
    plistlib.dump({
        "CFBundleIdentifier": sys.argv[2],
        "CFBundleExecutable": "PlaybackTests",
        "CFBundleName": "PlaybackTests",
        "CFBundlePackageType": "APPL",
        "MinimumOSVersion": "17.0",
        "UILaunchScreen": {},
    }, stream)
with wave.open(str(app / "sample.wav"), "wb") as audio:
    audio.setnchannels(1)
    audio.setsampwidth(2)
    audio.setframerate(22050)
    audio.writeframes(b"\0" * (22050 * 2 * 2))
(app / "unplayable.wav").write_bytes(b"invalid audio fixture")
PY

afconvert "$playback_app/sample.wav" "$playback_app/sample.aiff" -f AIFF -d BEI16
afconvert "$playback_app/sample.wav" "$playback_app/sample.caf" -f caff -d LEI16
afconvert "$playback_app/sample.wav" "$playback_app/aac.m4a" -f m4af -d aac
afconvert "$playback_app/sample.wav" "$playback_app/alac.m4a" -f m4af -d alac
afconvert "$playback_app/sample.wav" "$playback_app/sample.flac" -f flac -d flac
swift ios/Tests/CreatePlaybackFixtures.swift "$playback_app"
if [ -n "${MINIPLY_PLAYBACK_FIXTURES:-}" ]; then
    case "$MINIPLY_PLAYBACK_FIXTURES" in
        /*) ;;
        *) echo "MINIPLY_PLAYBACK_FIXTURES must be an absolute directory." >&2; exit 1 ;;
    esac
    cp "$MINIPLY_PLAYBACK_FIXTURES/prepared-video.mp4" "$playback_app/prepared-video.mp4"
    cp "$MINIPLY_PLAYBACK_FIXTURES/prepared-audio.m4a" "$playback_app/prepared-audio.m4a"
fi

playback_arch=$(uname -m)
# The simulator uses arm64 on Apple Silicon even when this shell runs in Rosetta.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then playback_arch=arm64; fi
xcrun --sdk iphonesimulator swiftc -D DEBUG -swift-version 5 \
    -target "$playback_arch-apple-ios17.0-simulator" \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    ios/Miniply/Models.swift ios/Miniply/API.swift ios/Miniply/Personal.swift ios/Miniply/PlayerModel.swift ios/Miniply/StreamCache.swift \
    ios/Tests/PlaybackRegression.swift -o "$playback_app/PlaybackTests"
codesign --sign - "$playback_app"
xcrun simctl install "$playback_simulator" "$playback_app"
playback_installed=true
xcrun simctl launch "$playback_simulator" "$playback_bundle"
playback_data=$(xcrun simctl get_app_container "$playback_simulator" "$playback_bundle" data)
playback_result="$playback_data/Documents/results.txt"
playback_attempt=0
while [ ! -f "$playback_result" ] && [ "$playback_attempt" -lt 300 ]; do
    sleep 0.2
    playback_attempt=$((playback_attempt + 1))
done
if [ ! -f "$playback_result" ]; then
    echo "Playback regression app did not report results within 60 seconds." >&2
    exit 1
fi
cat "$playback_result"
python3 - "$playback_result" <<'PYTHON'
from pathlib import Path
import sys
results = Path(sys.argv[1]).read_text().splitlines()
sys.exit(0 if results and all(line.startswith("PASS ") for line in results) else 1)
PYTHON
