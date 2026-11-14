#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Darwin ] || ! command -v xcrun >/dev/null 2>&1; then
    echo "iOS download regression checks require macOS and Xcode." >&2
    exit 2
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/miniply-download-regression.XXXXXX")
bundle_id="net.miniply.DownloadRegression.p$$"
installed_by_check=0
simulator_id=
cleanup() {
    if [ "$installed_by_check" -eq 1 ] && [ -n "$simulator_id" ]; then
        xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
        xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

xcrun simctl list devices available -j > "$work_dir/devices.json"
simulator_id=$(python3 - "$work_dir/devices.json" <<'PY'
import json
import os
import sys

with open(sys.argv[1]) as source:
    devices = [device for runtime, entries in json.load(source)["devices"].items()
               if ".iOS-" in runtime for device in entries]
requested = os.environ.get("MINIPLY_TEST_SIMULATOR_UUID")
selected = next((device for device in devices
                 if device["state"] == "Booted" and (not requested or device["udid"] == requested)), None)
if selected is None:
    print("No booted iOS simulator matches MINIPLY_TEST_SIMULATOR_UUID. Boot an existing simulator before running this check."
          if requested else "No iOS simulator is booted. Boot an existing simulator before running this check.", file=sys.stderr)
    sys.exit(2)
print(selected["udid"])
PY
)

sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
architecture=$(uname -m)
app_dir="$work_dir/DownloadRegression.app"
mkdir -p "$app_dir"
python3 - "$app_dir/Info.plist" "$bundle_id" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as target:
    plistlib.dump({
        "CFBundleIdentifier": sys.argv[2], "CFBundleExecutable": "DownloadRegression",
        "CFBundleName": "Miniply Download Regression", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "17.0", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "UIDeviceFamily": [1, 2], "UILaunchScreen": {},
    }, target)
PY

xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library \
    -sdk "$sdk_path" -target "$architecture-apple-ios17.0-simulator" \
    -module-name DownloadRegression -framework Foundation -framework UIKit \
    ios/Miniply/Models.swift ios/Miniply/DownloadManager.swift ios/Tests/DownloadRegression.swift \
    -o "$app_dir/DownloadRegression"
codesign --force --sign - "$app_dir" >/dev/null 2>&1

if ! xcrun simctl get_app_container "$simulator_id" "$bundle_id" app >/dev/null 2>&1; then
    installed_by_check=1
fi
xcrun simctl install "$simulator_id" "$app_dir"
python3 - "$simulator_id" "$bundle_id" <<'PY'
import os
import subprocess
import sys

try:
    result = subprocess.run(
        ["xcrun", "simctl", "launch", "--terminate-running-process", "--console", sys.argv[1], sys.argv[2]],
        env={**os.environ, "SIMCTL_CHILD_OS_ACTIVITY_MODE": "disable"},
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60,
    )
except subprocess.TimeoutExpired as error:
    if error.stdout:
        print(error.stdout.decode() if isinstance(error.stdout, bytes) else error.stdout, end="")
    print("Download regression app did not finish within 60 seconds.", file=sys.stderr)
    sys.exit(1)
print(result.stdout, end="")
if result.returncode or "MINIPLY_DOWNLOAD_REGRESSION_PASS" not in result.stdout.splitlines():
    sys.exit(1)
PY
