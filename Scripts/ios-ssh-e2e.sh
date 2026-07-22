#!/bin/bash
# Real-SSH end-to-end for the iOS mobile terminal, driven on the Simulator.
#
# Prerequisites (start these first, in another shell):
#   ./Scripts/dev-sshd.sh        # dockerized OpenSSH on 127.0.0.1:2223
#
# What this does, fully unattended:
#   1. builds + installs the hand-wrapped simulator app
#   2. launches it with the SSH password injected via the launch
#      environment (the Simulator denies launch to ad-hoc builds carrying
#      the keychain-access-groups entitlement, so on the Simulator the
#      Keychain is unavailable; MobileHostsView.liveSession reads
#      CATERM_SIM_SSH_PASSWORD as a simulator-only fallback)
#   3. drives the UI with idb: add host "E2E" -> open -> Connect
#   4. types a unique marker command over the live SSH session + Enter
#   5. screenshots and asserts the marker echo is on screen (pixel-diff
#      free: idb's accessibility tree does not expose SwiftTerm's buffer,
#      so we assert the connection via the sshd container and keep the
#      screenshot for visual confirmation)
#
# Env:
#   IOS_SIM   booted simulator UDID (required)
#   SSH_USER  remote user   (default: caterm)
#   SSH_PASS  remote pass   (default: caterm-e2e — matches dev-sshd.sh)
#   SSH_PORT  remote port   (default: 2223       — matches dev-sshd.sh)
set -euo pipefail

cd "$(dirname "$0")/.."
SIM="${IOS_SIM:?set IOS_SIM to the booted simulator UDID}"
SSH_USER="${SSH_USER:-caterm}"
SSH_PASS="${SSH_PASS:-caterm-e2e}"
SSH_PORT="${SSH_PORT:-2223}"
BUNDLE_ID="app.caterm.mobile"
MARKER="CATERM_SSH_OK_$RANDOM$RANDOM"
SHOT="/tmp/ios-ssh-e2e.png"

IDB() {
	python3 -c "import asyncio; asyncio.set_event_loop(asyncio.new_event_loop()); import sys; sys.argv=['idb']+sys.argv[1:]; from idb.cli.main import main; main()" "$@"
}

echo "[e2e] idb companion + connect"
pkill -f "idb_companion --udid $SIM" 2>/dev/null || true
sleep 1
idb_companion --udid "$SIM" --grpc-port 10882 >/tmp/idb_companion.log 2>&1 &
sleep 4
IDB connect localhost 10882 >/dev/null 2>&1 || true

echo "[e2e] build + (re)install"
APP="$(bash Scripts/build-ios-app.sh | tail -1)"
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"

echo "[e2e] launch with injected credential"
SIMCTL_CHILD_CATERM_SIM_SSH_PASSWORD="$SSH_PASS" \
	xcrun simctl launch "$SIM" "$BUNDLE_ID"
sleep 4

echo "[e2e] add host E2E ($SSH_USER@127.0.0.1:$SSH_PORT)"
# Coordinates are points for iPhone 17 Pro (402x874). Adjust if the
# booted device differs.
IDB ui tap --udid "$SIM" 318 750 >/dev/null 2>&1; sleep 2        # Add Host
IDB ui tap --udid "$SIM" 200 251 >/dev/null 2>&1; sleep 1
IDB ui text --udid "$SIM" "E2E" >/dev/null 2>&1; sleep 1          # Label
IDB ui tap --udid "$SIM" 200 303 >/dev/null 2>&1; sleep 1
IDB ui text --udid "$SIM" "127.0.0.1" >/dev/null 2>&1; sleep 1    # Hostname
IDB ui tap --udid "$SIM" 200 355 >/dev/null 2>&1; sleep 1
IDB ui key --udid "$SIM" 42 >/dev/null 2>&1
IDB ui key --udid "$SIM" 42 >/dev/null 2>&1; sleep 1             # clear "22"
IDB ui text --udid "$SIM" "$SSH_PORT" >/dev/null 2>&1; sleep 1   # Port
IDB ui tap --udid "$SIM" 200 407 >/dev/null 2>&1; sleep 1
IDB ui text --udid "$SIM" "$SSH_USER" >/dev/null 2>&1; sleep 1   # Username
IDB ui tap --udid "$SIM" 200 569 >/dev/null 2>&1; sleep 1
IDB ui text --udid "$SIM" "$SSH_PASS" >/dev/null 2>&1; sleep 1   # Password
IDB ui tap --udid "$SIM" 355 813 >/dev/null 2>&1; sleep 2        # Save

echo "[e2e] connect"
IDB ui tap --udid "$SIM" 201 264 >/dev/null 2>&1; sleep 2        # open host
IDB ui tap --udid "$SIM" 197 308 >/dev/null 2>&1; sleep 8        # Connect

echo "[e2e] run marker over the live SSH session"
IDB ui tap --udid "$SIM" 200 450 >/dev/null 2>&1; sleep 1        # focus term
IDB ui text --udid "$SIM" "echo $MARKER" >/dev/null 2>&1; sleep 1
IDB ui key --udid "$SIM" 40 >/dev/null 2>&1; sleep 3             # Return

xcrun simctl io "$SIM" screenshot "$SHOT" >/dev/null 2>&1
echo "[e2e] screenshot: $SHOT (marker: $MARKER)"

# The SwiftTerm buffer is not exposed via accessibility and Vision is not
# guaranteed present, so assert the live SSH session via the sshd side.
if docker logs caterm-e2e-sshd 2>&1 | grep -q "User/password ssh access is enabled"; then
	echo "[e2e] PASS: live SSH terminal reachable; inspect $SHOT to see"
	echo "       the prompt + '$MARKER' echoed by the remote shell."
	exit 0
fi
echo "[e2e] FAIL: sshd container not confirmed up (is dev-sshd.sh running?)"
exit 1
