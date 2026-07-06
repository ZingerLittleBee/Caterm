#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PROCESS_PATTERN="Caterm.app/Contents/MacOS/caterm"

cd "$ROOT"

cleanup() {
    make kill >/dev/null 2>&1 || true
}

terminate() {
    cleanup
    exit 143
}

trap cleanup EXIT
trap terminate INT TERM

cleanup
make run-app

pid=""
for _ in {1..100}; do
    pid="$(pgrep -f "$APP_PROCESS_PATTERN" | tr '\n' ' ' || true)"
    if [[ -n "${pid// }" ]]; then
        break
    fi
    sleep 0.1
done

if [[ -z "${pid// }" ]]; then
    echo "Caterm.app did not stay running after launch." >&2
    exit 1
fi

echo "Caterm running (pid(s): $pid). Waiting for changes..."
while pgrep -f "$APP_PROCESS_PATTERN" >/dev/null; do
    sleep 1
done

echo "Caterm exited."
