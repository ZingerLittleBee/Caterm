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
#
# CATERM_DEV_IDENTITY may be either:
#   - a Common Name like "Apple Development: Bee Zinger (4GH398M5WH)"
#   - a 40-char SHA-1 fingerprint (preferred — disambiguates when multiple
#     certs share the same CN, which Apple's auto-renewal flow can produce)
if [[ "$CATERM_DEV_IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    # SHA-1 lookup: dump all certs matching the dev CN, find the one whose
    # SHA-1 fingerprint matches CATERM_DEV_IDENTITY, parse OU from its subject.
    TEAM_ID="$(security find-certificate -a -p 2>/dev/null \
        | awk 'BEGIN{RS="-----BEGIN CERTIFICATE-----"} NR>1{print "-----BEGIN CERTIFICATE-----" $0 ORS}' \
        | python3 -c "
import sys, re, subprocess
target = '$CATERM_DEV_IDENTITY'.upper().replace(':', '')
blocks = sys.stdin.read().split('-----END CERTIFICATE-----')
for raw in blocks:
    s = raw.strip()
    if not s: continue
    pem = s + '\n-----END CERTIFICATE-----\n'
    try:
        fp = subprocess.run(['openssl','x509','-noout','-fingerprint','-sha1'],
                            input=pem, capture_output=True, text=True, check=True).stdout
        sha1 = fp.split('=',1)[1].strip().replace(':','')
        if sha1.upper() != target: continue
        sub = subprocess.run(['openssl','x509','-noout','-subject'],
                             input=pem, capture_output=True, text=True, check=True).stdout
        m = re.search(r'OU=([A-Z0-9]+)', sub)
        if m: print(m.group(1)); break
    except Exception: pass
")"
else
    TEAM_ID="$(security find-certificate -c "$CATERM_DEV_IDENTITY" -p \
        | openssl x509 -noout -subject \
        | sed -nE 's/.*OU=([A-Z0-9]+).*/\1/p')"
fi

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

# Pitfall 6 (docs/macos-dev-signing.md): Xcode auto-injects application-
# identifier + team-identifier into embedded entitlements. Raw codesign
# does not. AMFI then fails to match restricted entitlements (aps-
# environment, keychain-access-groups) against the profile, even when
# the profile is embedded. Inject them here.
APP_ID="${CATERM_DEV_APP_ID:-com.caterm.app}"
inject_app_identifier() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${TEAM_ID}.${APP_ID}" "$plist"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string ${TEAM_ID}" "$plist"
}
inject_app_identifier "$TMPDIR_ENT/Caterm.entitlements"
inject_app_identifier "$TMPDIR_ENT/CatermAskpass.entitlements"

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

# Persist the substituted entitlements next to the binary so the bundle
# wrapper (dev-run-app.sh) can reuse the *exact same* file when sealing
# Caterm.app — avoiding Pitfall 5 (outer codesign w/o --entitlements
# clearing the main executable's entitlements).
cp "$TMPDIR_ENT/Caterm.entitlements" "$BIN_DIR/Caterm.dev.entitlements"

echo "Signed both binaries with $CATERM_DEV_IDENTITY (team $TEAM_ID)"
codesign -dvv "$BIN_DIR/caterm" 2>&1 | grep -E "TeamIdentifier|Authority"
codesign -dvv "$BIN_DIR/caterm-askpass" 2>&1 | grep -E "TeamIdentifier|Authority"

# Print the resolved access group so the caller knows what to pass to
# CATERM_ACCESS_GROUP at runtime.
echo
echo "Access group: ${TEAM_ID}.caterm.shared"
