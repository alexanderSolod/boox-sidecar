#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
suite=all
gui=false
while (( $# )); do
    case "$1" in
        --suite) suite="${2:?Supply all, browser, mac, or android}"; shift 2 ;;
        --gui) gui=true; shift ;;
        *) echo "Usage: $0 [--suite all|browser|mac|android] [--gui]" >&2; exit 2 ;;
    esac
done
case "$suite" in all|browser|mac|android) ;; *) echo "Unknown suite: $suite" >&2; exit 2 ;; esac
if $gui && [[ "$suite" != all && "$suite" != mac ]]; then
    echo '--gui requires the mac or all suite.' >&2; exit 2
fi
for script in scripts/*.sh android/build.sh android/tests/*.sh; do bash -n "$script"; done
if [[ "$suite" == all || "$suite" == browser ]]; then
    node --check viewer/app.js
    node --test viewer/app.test.js
fi
if [[ "$suite" == all || "$suite" == mac ]]; then
    [[ "$(uname -s)" == Darwin ]] || { echo 'Mac checks require macOS 15+ and Swift Command Line Tools.' >&2; exit 1; }
    sh macos/Tests/run-helper-tests.sh
    ./scripts/build-mac.sh
    if $gui; then python3 tests/smoke_host.py
    else echo 'SKIP: GUI host smoke (run with --gui in a macOS desktop session).'; fi
fi
if [[ "$suite" == all || "$suite" == android ]]; then
    sh android/tests/run-native-client-tests.sh
    sh android/build.sh :app:lintDebug
fi
echo "PASS: requested $suite checks"
