#!/usr/bin/env bash
set -euo pipefail

# dev-codesign.sh — sign caterm + caterm-askpass binaries.
#
# Two profiles are supported via `--profile dev|distribution` (default: dev).
#
#   dev          — debug build, dev identity, Caterm.entitlements, login-keychain
#                  fallback (strips keychain-access-groups so AMFI doesn't kill
#                  unprofiled binaries during dev).
#   distribution — release build, distribution identity, Caterm.distribution
#                  .entitlements (production APS + Production CloudKit env).
#                  Keychain access group is preserved; the distribution build
#                  embeds a Distribution provisioning profile in dist-package.sh
#                  so AMFI accepts the restricted entitlement.
#
# Required env (depending on profile):
#   dev:          CATERM_DEV_IDENTITY  — Apple Development cert (CN or SHA-1)
#   distribution: CATERM_DIST_IDENTITY — Developer ID / Mac App Distribution
#
# This script extracts the TeamIdentifier (OU) from the chosen identity's
# certificate and substitutes $(TeamIdentifierPrefix) in the entitlements
# files before signing. codesign itself does NOT expand that placeholder
# (only Xcode does), so without this substitution the binary would carry
# a literal "$(TeamIdentifierPrefix)caterm.shared" access group that the
# kernel rejects.

PROFILE="dev"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="${2:-}"
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#*=}"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--profile dev|distribution]" >&2
            exit 1
            ;;
    esac
done

case "$PROFILE" in
    dev|distribution) ;;
    *)
        echo "Invalid profile: $PROFILE (expected: dev | distribution)" >&2
        exit 1
        ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "$PROFILE" == "distribution" ]]; then
    : "${CATERM_DIST_IDENTITY:?CATERM_DIST_IDENTITY env var required for --profile distribution}"
    IDENTITY="$CATERM_DIST_IDENTITY"
    BIN_DIR="$ROOT/.build/release"
    MAIN_ENTITLEMENTS_SRC="$ROOT/Resources/Caterm.distribution.entitlements"
    HELPER_ENTITLEMENTS_SRC="$ROOT/Resources/CatermAskpass.entitlements"
    MAIN_ENT_OUT_NAME="Caterm.distribution.entitlements"
    HELPER_ENT_OUT_NAME="CatermAskpass.distribution.entitlements"
else
    : "${CATERM_DEV_IDENTITY:?CATERM_DEV_IDENTITY env var required}"
    IDENTITY="$CATERM_DEV_IDENTITY"
    BIN_DIR="$ROOT/.build/debug"
    MAIN_ENTITLEMENTS_SRC="$ROOT/Resources/Caterm.entitlements"
    HELPER_ENTITLEMENTS_SRC="$ROOT/Resources/CatermAskpass.entitlements"
    MAIN_ENT_OUT_NAME="Caterm.dev.entitlements"
    HELPER_ENT_OUT_NAME="CatermAskpass.dev.entitlements"
fi

# Extract the TeamIdentifier (OU field) from the certificate.
#
# IDENTITY may be either:
#   - a Common Name like "Apple Development: Bee Zinger (4GH398M5WH)"
#   - a 40-char SHA-1 fingerprint (preferred — disambiguates when multiple
#     certs share the same CN, which Apple's auto-renewal flow can produce)
if [[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    # SHA-1 lookup: dump all certs, find the one whose SHA-1 matches, parse OU.
    TEAM_ID="$(security find-certificate -a -p 2>/dev/null \
        | awk 'BEGIN{RS="-----BEGIN CERTIFICATE-----"} NR>1{print "-----BEGIN CERTIFICATE-----" $0 ORS}' \
        | python3 -c "
import sys, re, subprocess
target = '$IDENTITY'.upper().replace(':', '')
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
    TEAM_ID="$(security find-certificate -c "$IDENTITY" -p \
        | openssl x509 -noout -subject \
        | sed -nE 's/.*OU=([A-Z0-9]+).*/\1/p')"
fi

if [[ -z "$TEAM_ID" ]]; then
    echo "Failed to extract TeamIdentifier from identity: $IDENTITY" >&2
    exit 1
fi

echo "Profile: $PROFILE"
echo "Identity: $IDENTITY"
echo "TeamIdentifier: $TEAM_ID"
echo "Binary directory: $BIN_DIR"

if [[ ! -x "$BIN_DIR/caterm" || ! -x "$BIN_DIR/caterm-askpass" ]]; then
    echo "Error: signed binaries not found in $BIN_DIR." >&2
    if [[ "$PROFILE" == "distribution" ]]; then
        echo "Run \`swift build -c release\` first." >&2
    else
        echo "Run \`swift build\` first." >&2
    fi
    exit 1
fi

# Create a temp directory for substituted entitlements.
TMPDIR_ENT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ENT"' EXIT

substitute_entitlements() {
    local src="$1"
    local dst="$2"
    sed -e "s/\$(TeamIdentifierPrefix)/${TEAM_ID}./g" "$src" > "$dst"
}

substitute_entitlements "$MAIN_ENTITLEMENTS_SRC" \
    "$TMPDIR_ENT/Caterm.entitlements"
substitute_entitlements "$HELPER_ENTITLEMENTS_SRC" \
    "$TMPDIR_ENT/CatermAskpass.entitlements"

# Pitfall 6 (docs/macos-dev-signing.md): Xcode auto-injects application-
# identifier + team-identifier into embedded entitlements. Raw codesign
# does not. AMFI then fails to match restricted entitlements (aps-
# environment, keychain-access-groups) against the profile, even when
# the profile is embedded. Inject them here.
APP_ID="${CATERM_APP_ID:-${CATERM_DEV_APP_ID:-com.caterm.app}}"
inject_app_identifier() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${TEAM_ID}.${APP_ID}" "$plist"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string ${TEAM_ID}" "$plist"
}
inject_app_identifier "$TMPDIR_ENT/Caterm.entitlements"
inject_app_identifier "$TMPDIR_ENT/CatermAskpass.entitlements"

if [[ "$PROFILE" == "dev" ]]; then
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
fi

# Askpass entitlement isolation (BOTH dev and distribution).
#
# /usr/bin/ssh exec's caterm-askpass as a plain nested binary. AMFI SIGKILLs
# it before main() if it carries restricted app/team identity entitlements
# (application-identifier, team-identifier, aps-environment, etc.). The
# helper only needs `keychain-access-groups` (when in production / KAG path)
# to share keychain items with the main app. Strip everything else.
echo "Stripping app/team identity from askpass entitlements"
/usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" \
    "$TMPDIR_ENT/CatermAskpass.entitlements" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" \
    "$TMPDIR_ENT/CatermAskpass.entitlements" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.aps-environment" \
    "$TMPDIR_ENT/CatermAskpass.entitlements" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-container-environment" \
    "$TMPDIR_ENT/CatermAskpass.entitlements" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-services" \
    "$TMPDIR_ENT/CatermAskpass.entitlements" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-container-identifiers" \
    "$TMPDIR_ENT/CatermAskpass.entitlements" 2>/dev/null || true

codesign --force --options runtime \
    --sign "$IDENTITY" \
    --entitlements "$TMPDIR_ENT/Caterm.entitlements" \
    "$BIN_DIR/caterm"

codesign --force --options runtime \
    --sign "$IDENTITY" \
    --entitlements "$TMPDIR_ENT/CatermAskpass.entitlements" \
    "$BIN_DIR/caterm-askpass"

# Persist the substituted entitlements next to the binary so the bundle
# wrapper (dev-run-app.sh / dist-package.sh) can reuse the *exact same* file
# when sealing Caterm.app — avoiding Pitfall 5 (outer codesign w/o
# --entitlements clearing the main executable's entitlements).
cp "$TMPDIR_ENT/Caterm.entitlements" "$BIN_DIR/$MAIN_ENT_OUT_NAME"
cp "$TMPDIR_ENT/CatermAskpass.entitlements" "$BIN_DIR/$HELPER_ENT_OUT_NAME"

echo "Signed both binaries with $IDENTITY (team $TEAM_ID)"
codesign -dvv "$BIN_DIR/caterm" 2>&1 | grep -E "TeamIdentifier|Authority"
codesign -dvv "$BIN_DIR/caterm-askpass" 2>&1 | grep -E "TeamIdentifier|Authority"

echo
echo "Access group: ${TEAM_ID}.caterm.shared"
echo "Persisted entitlements:"
echo "  $BIN_DIR/$MAIN_ENT_OUT_NAME"
echo "  $BIN_DIR/$HELPER_ENT_OUT_NAME"
