#!/bin/bash
# Deterministic signed-Simulator proof for offline Host persistence and the
# shared Host synchronization boundary. No CloudKit account is required.
set -euo pipefail

cd "$(dirname "$0")/.."
SIM="${IOS_SIM:?set IOS_SIM to a booted simulator UDID}"
BUNDLE_ID="app.caterm.mobile"
CACHED_NAME="Offline Cached"
REMOTE_NAME="Boundary Remote"

IDB() {
  python3 -c "import asyncio; asyncio.set_event_loop(asyncio.new_event_loop()); import sys; sys.argv=['idb']+sys.argv[1:]; from idb.cli.main import main; main()" "$@"
}

wait_for_accessibility_text() {
  local expected="$1"
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    if IDB ui describe-all --udid "$SIM" 2>/dev/null | grep -Fq "$expected"; then
      return
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  echo "[ios-host-sync] accessibility text not found: $expected" >&2
  exit 1
}

echo "[ios-host-sync] connect idb"
pkill -f "idb_companion --udid $SIM" 2>/dev/null || true
idb_companion --udid "$SIM" --grpc-port 10882 \
  >/tmp/caterm-ios-host-sync-idb.log 2>&1 &
sleep 4
IDB connect localhost 10882 >/dev/null 2>&1 || true

echo "[ios-host-sync] build and install signed app"
APP="$(bash Scripts/build-ios-app.sh | tail -1)"
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"

echo "[ios-host-sync] seed cached Host while offline"
SIMCTL_CHILD_CATERM_SIM_CACHED_HOST_NAME="$CACHED_NAME" \
  SIMCTL_CHILD_CATERM_SIM_CACHED_HOST_ADDRESS="offline.example.com" \
  xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
wait_for_accessibility_text "$CACHED_NAME"
xcrun simctl terminate "$SIM" "$BUNDLE_ID"

echo "[ios-host-sync] relaunch offline without seed input"
xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
wait_for_accessibility_text "$CACHED_NAME"
xcrun simctl terminate "$SIM" "$BUNDLE_ID"

echo "[ios-host-sync] run deterministic shared sync boundary"
SIMCTL_CHILD_CATERM_SIM_SYNC_REMOTE_HOST_NAME="$REMOTE_NAME" \
  SIMCTL_CHILD_CATERM_SIM_SYNC_REMOTE_HOST_ADDRESS="fixture.example.com" \
  SIMCTL_CHILD_CATERM_SIM_SYNC_REMOTE_HOST_USER="fixture" \
  xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
wait_for_accessibility_text "$REMOTE_NAME"
wait_for_accessibility_text "$CACHED_NAME"

DATA_CONTAINER="$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)"
HOSTS_FILE="$DATA_CONTAINER/Library/Application Support/Caterm/hosts.json"
if ! grep -Fq 'simulator-local-' "$HOSTS_FILE"; then
  echo "[ios-host-sync] local Host was not acknowledged by the sync boundary" >&2
  exit 1
fi

echo "[ios-host-sync] PASS: offline relaunch, remote pull, and local push acknowledged"
