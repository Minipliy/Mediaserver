#!/bin/sh
# Real API requests intercepted in process; no network or credentials required.
set -eu
cd "$(dirname "$0")/.."
api_work=$(mktemp -d "${TMPDIR:-/tmp}/miniply-api.XXXXXX")
trap 'rm -rf "$api_work"' EXIT
trap 'exit 1' HUP INT TERM
xcrun swiftc -swift-version 5 -parse-as-library \
    ios/Miniply/Models.swift ios/Miniply/API.swift ios/Tests/APIRegression.swift \
    -o "$api_work/APIRegression"
python3 - "$api_work/APIRegression" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1]], timeout=15)
except subprocess.TimeoutExpired:
    sys.exit("API regression checks did not finish within 15 seconds.")
sys.exit(result.returncode)
PY
