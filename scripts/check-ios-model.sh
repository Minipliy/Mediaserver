#!/bin/sh
# Exercise the real AppModel on macOS with deterministic API/Keychain/download
# doubles. Test scopes are random and removed afterward; no real credentials,
# simulator, server or download files are used.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo 'AppModel regression checks require macOS and Xcode.' >&2
    exit 1
fi
model_work=$(mktemp -d "${TMPDIR:-/tmp}/miniply-model.XXXXXX")
trap 'rm -rf "$model_work"' EXIT
trap 'exit 1' HUP INT TERM
xcrun swiftc -swift-version 5 -parse-as-library \
    ios/Miniply/Models.swift ios/Miniply/AppModel.swift \
    ios/Tests/AppModelRegression.swift -o "$model_work/AppModelRegression"
python3 - "$model_work/AppModelRegression" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run([sys.argv[1]], timeout=30)
except subprocess.TimeoutExpired:
    print("AppModel regression checks did not finish within 30 seconds.", file=sys.stderr)
    sys.exit(1)
sys.exit(result.returncode)
PY
