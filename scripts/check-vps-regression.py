#!/usr/bin/env python3
"""Exercise the VPS checker with local command stubs; no network access."""

import os
from pathlib import Path
import subprocess
import tempfile


def main():
    checker = Path(__file__).resolve().with_name("check-vps.sh")
    with tempfile.TemporaryDirectory(prefix="miniply-vps-check-") as temporary:
        directory = Path(temporary)
        curl = directory / "curl"
        curl.write_text("""#!/bin/sh
set -eu
endpoint=
follow=0
format=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --location) follow=1 ;;
        --write-out) shift; format=$1 ;;
        https://hyse.minipliy.net) endpoint=hyse ;;
        https://minipliy.net) endpoint=root ;;
    esac
    shift
done
printf 'curl %s\\n' "$endpoint" >> "$STUB_CALLS"
case "$endpoint" in
    hyse)
        [ "$follow" = 1 ] || exit 90
        [ "$format" = '%{http_code}' ] || exit 93
        [ "$STUB_HYSE_EXIT" = 0 ] || exit "$STUB_HYSE_EXIT"
        printf '%s' "$STUB_HYSE_STATUS" ;;
    root)
        [ "$follow" = 0 ] || exit 91
        [ "$format" = '%{http_code} %{redirect_url}' ] || exit 94
        [ "$STUB_ROOT_EXIT" = 0 ] || exit "$STUB_ROOT_EXIT"
        printf '%s %s' "$STUB_ROOT_STATUS" "$STUB_ROOT_REDIRECT" ;;
    *) exit 92 ;;
esac
""")
        ssh = directory / "ssh"
        ssh.write_text('#!/bin/sh\nprintf "ssh\\n" >> "$STUB_CALLS"\n')
        curl.chmod(0o700)
        ssh.chmod(0o700)
        defaults = {
            "STUB_HYSE_STATUS": "200", "STUB_ROOT_STATUS": "200",
            "STUB_ROOT_REDIRECT": "",
            "STUB_HYSE_EXIT": "0", "STUB_ROOT_EXIT": "0",
        }
        cases = [
            ("expected baseline", {}, 0, "VPS baseline checks passed.", ["curl hyse", "curl root", "ssh"]),
            ("root status 301", {"STUB_ROOT_STATUS": "301"}, 1, "Root domain check failed", ["curl hyse", "curl root"]),
            ("root status 302", {"STUB_ROOT_STATUS": "302"}, 1, "Root domain check failed", ["curl hyse", "curl root"]),
            ("wrong redirect", {"STUB_ROOT_REDIRECT": "https://other.invalid/"}, 1, "Root domain check failed", ["curl hyse", "curl root"]),

            ("Hyse final 302", {"STUB_HYSE_STATUS": "302"}, 1, "expected final HTTP 200", ["curl hyse"]),
            ("Hyse final 503", {"STUB_HYSE_STATUS": "503"}, 1, "expected final HTTP 200", ["curl hyse"]),
            ("Hyse transport failure", {"STUB_HYSE_EXIT": "7"}, 1, "Hyse check failed: HTTP request", ["curl hyse"]),
            ("root transport failure", {"STUB_ROOT_EXIT": "7"}, 1, "Root domain check failed: HTTP request", ["curl hyse", "curl root"]),
        ]
        for name, changes, expected_code, diagnostic, expected_calls in cases:
            calls = directory / "calls.txt"
            calls.write_text("")
            # Only the stubs are in PATH. Unexpected external commands cannot
            # resolve to real curl/ssh or other network clients on this machine.
            environment = {**os.environ, **defaults, **changes,
                           "PATH": str(directory), "STUB_CALLS": str(calls),
                           "MINIPLY_VPS": "root@203.0.113.10"}
            result = subprocess.run(["/bin/sh", str(checker)], env=environment,
                                    capture_output=True, text=True, timeout=5)
            if (result.returncode != expected_code
                    or diagnostic not in result.stdout + result.stderr
                    or calls.read_text().splitlines() != expected_calls):
                raise SystemExit(f"FAIL {name}: exit={result.returncode}\n{result.stdout}{result.stderr}")
            print(f"PASS {name}")


if __name__ == "__main__":
    main()
