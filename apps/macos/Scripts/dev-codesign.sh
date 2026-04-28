#!/usr/bin/env bash
set -euo pipefail

# dev-codesign.sh — sign caterm + caterm-askpass with the user's Apple Dev
# Identity so Keychain access group ACL works between processes during
# development.
#
# Required env:
#   CATERM_DEV_IDENTITY  — name of the codesign identity in login keychain
#                         (e.g. "Apple Development: Your Name (TEAMID)")
#
# This script extracts the TeamIdentifier (OU) from the chosen identity's
# certificate and substitutes $(TeamIdentifierPrefix) in the entitlements
# files before signing. codesign itself does NOT expand that placeholder
# (only Xcode does), so without this substitution the binary would carry
# a literal "$(TeamIdentifierPrefix)caterm.shared" access group that the
# kernel rejects.

: "${CATERM_DEV_IDENTITY:?CATERM_DEV_IDENTITY env var required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.build/debug"

# Extract the TeamIdentifier (OU field) from the certificate.
TEAM_ID="$(security find-certificate -c "$CATERM_DEV_IDENTITY" -p \
    | openssl x509 -noout -subject \
    | sed -nE 's/.*OU=([A-Z0-9]+).*/\1/p')"

if [[ -z "$TEAM_ID" ]]; then
    echo "Failed to extract TeamIdentifier from identity: $CATERM_DEV_IDENTITY" >&2
    exit 1
fi

echo "Using TeamIdentifier: $TEAM_ID"

# Create a temp directory for substituted entitlements.
TMPDIR_ENT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ENT"' EXIT

substitute_entitlements() {
    local src="$1"
    local dst="$2"
    sed -e "s/\$(TeamIdentifierPrefix)/${TEAM_ID}./g" "$src" > "$dst"
}

substitute_entitlements "$ROOT/Resources/Caterm.entitlements" \
    "$TMPDIR_ENT/Caterm.entitlements"
substitute_entitlements "$ROOT/Resources/CatermAskpass.entitlements" \
    "$TMPDIR_ENT/CatermAskpass.entitlements"

# Dev-only: when CATERM_DEV_LOGIN_KEYCHAIN=1 (default in this dev workflow),
# strip the `keychain-access-groups` entitlement before signing. AMFI on
# Apple Silicon macOS rejects that restricted entitlement without an
# embedded development provisioning profile (kills the process at exec
# with SIGKILL / exit 137). For dev we fall back to the login-keychain
# path which works with no provisioning profile. See
# Manual/end-to-end-smoke.md for the full rationale.
DEV_LOGIN_KEYCHAIN="${CATERM_DEV_LOGIN_KEYCHAIN:-1}"
if [[ "$DEV_LOGIN_KEYCHAIN" == "1" ]]; then
    echo "Dev mode: stripping keychain-access-groups (login-keychain path)"
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" \
        "$TMPDIR_ENT/Caterm.entitlements" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" \
        "$TMPDIR_ENT/CatermAskpass.entitlements" 2>/dev/null || true
fi

codesign --force --options runtime \
    --sign "$CATERM_DEV_IDENTITY" \
    --entitlements "$TMPDIR_ENT/Caterm.entitlements" \
    "$BIN_DIR/caterm"

codesign --force --options runtime \
    --sign "$CATERM_DEV_IDENTITY" \
    --entitlements "$TMPDIR_ENT/CatermAskpass.entitlements" \
    "$BIN_DIR/caterm-askpass"

echo "Signed both binaries with $CATERM_DEV_IDENTITY (team $TEAM_ID)"
codesign -dvv "$BIN_DIR/caterm" 2>&1 | grep -E "TeamIdentifier|Authority"
codesign -dvv "$BIN_DIR/caterm-askpass" 2>&1 | grep -E "TeamIdentifier|Authority"

# Print the resolved access group so the caller knows what to pass to
# CATERM_ACCESS_GROUP at runtime.
echo
echo "Access group: ${TEAM_ID}.caterm.shared"
