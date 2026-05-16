#!/usr/bin/env bash
set -euo pipefail

# dist-package.sh — Distribution analog of dev-run-app.sh.
#
# Assembles a Distribution-signed Caterm.app bundle from the release-config
# binaries that dev-codesign.sh --profile distribution has already signed,
# embeds the Distribution provisioning profile, and re-seals the bundle in
# two passes (Pitfall 5: outer codesign without --entitlements clears the
# inner exe's entitlements).
#
# Required env:
#   CATERM_DIST_IDENTITY      — Developer ID Application or Mac App
#                               Distribution cert (CN or SHA-1)
#   CATERM_DIST_PROFILE_PATH  — path to the Distribution .provisionprofile
#                               (App ID configured with aps-environment=
#                               production and icloud-container-environment=
#                               Production on the Apple developer portal)
#
# Optional env:
#   CATERM_APP_ID             — bundle id (default: com.caterm.app)
#   CATERM_DIST_VERSION       — CFBundleShortVersionString (default: 1.0.0)
#   CATERM_DIST_BUILD         — CFBundleVersion (default: 1)
#   CATERM_NOTARY_PROFILE     — keychain profile for `notarytool`. When set,
#                               this script ditto-zips the .app, submits to
#                               Apple notary service (synchronous --wait),
#                               then staples the ticket back into the .app.
#                               Create with:
#                                 xcrun notarytool store-credentials <profile> \
#                                     --apple-id <email> --team-id <TEAMID> \
#                                     --password <app-specific-password>
#                               Leave unset to skip — the bundle is still
#                               valid for local install.
#
# Pre-conditions:
#   `swift build -c release` completed, and dev-codesign.sh --profile
#   distribution has signed the inner binaries AND emitted the substituted
#   entitlements files.

: "${CATERM_DIST_IDENTITY:?CATERM_DIST_IDENTITY env var required}"
: "${CATERM_DIST_PROFILE_PATH:?CATERM_DIST_PROFILE_PATH env var required (path to Distribution .provisionprofile)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.build/release"
APP="$BIN_DIR/Caterm.app"
APP_BUNDLE_ID="${CATERM_APP_ID:-com.caterm.app}"
APP_VERSION="${CATERM_DIST_VERSION:-1.0.0}"
APP_BUILD="${CATERM_DIST_BUILD:-1}"

MAIN_ENT="$BIN_DIR/Caterm.distribution.entitlements"
HELPER_ENT="$BIN_DIR/CatermAskpass.distribution.entitlements"

# ---------------------------------------------------------------------------
# Pre-flight: enforce that dev-codesign.sh --profile distribution ran first.
# ---------------------------------------------------------------------------

if [[ ! -x "$BIN_DIR/caterm" || ! -x "$BIN_DIR/caterm-askpass" ]]; then
    echo "Error: signed release binaries not found in $BIN_DIR." >&2
    echo "Run \`swift build -c release && Scripts/dev-codesign.sh --profile distribution\` first." >&2
    exit 1
fi

if [[ ! -f "$MAIN_ENT" ]]; then
    echo "Error: $MAIN_ENT missing." >&2
    echo "dev-codesign.sh --profile distribution must persist this file." >&2
    exit 1
fi

if [[ ! -f "$HELPER_ENT" ]]; then
    echo "Error: $HELPER_ENT missing." >&2
    echo "dev-codesign.sh --profile distribution must persist this file." >&2
    exit 1
fi

if [[ ! -f "$CATERM_DIST_PROFILE_PATH" ]]; then
    echo "Error: provisioning profile not found at $CATERM_DIST_PROFILE_PATH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Assemble the bundle.
# ---------------------------------------------------------------------------
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_DIR/caterm" "$APP/Contents/MacOS/caterm"
cp "$BIN_DIR/caterm-askpass" "$APP/Contents/MacOS/caterm-askpass"

# Strip xattrs after copy: icon generators (Image2Icon, etc.) routinely leave
# com.apple.FinderInfo / ResourceFork / quarantine, which codesign rejects with
# "resource fork, Finder information, or similar detritus not allowed".
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    xattr -c "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Caterm</string>
    <key>CFBundleDisplayName</key>
    <string>Caterm</string>
    <key>CFBundleExecutable</key>
    <string>caterm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

# ---------------------------------------------------------------------------
# Embed the Distribution provisioning profile.
# ---------------------------------------------------------------------------
echo "==> Embedding profile from $CATERM_DIST_PROFILE_PATH"
cp "$CATERM_DIST_PROFILE_PATH" "$APP/Contents/embedded.provisionprofile"

# ---------------------------------------------------------------------------
# Two-pass re-seal — see plan-e Task 3.0 Step 3.
#
# Pass 1: re-sign the helper with its own entitlements (askpass keeps only
#         keychain-access-groups; never inherits APS / CloudKit env / app
#         identity, which would AMFI-kill it on exec).
# Pass 2: outer-bundle seal with the main exe's distribution entitlements.
#         This re-signs the main caterm binary with the right entitlements
#         (Pitfall 5 applies here: omitting --entitlements clears them).
#
# We do NOT use --deep — the bundle seal references the inner signatures
# we just produced.
# ---------------------------------------------------------------------------
echo "==> Re-sealing askpass helper"
codesign --force \
    --sign "$CATERM_DIST_IDENTITY" \
    --entitlements "$HELPER_ENT" \
    --options runtime \
    "$APP/Contents/MacOS/caterm-askpass"

echo "==> Re-sealing bundle"
codesign --force \
    --sign "$CATERM_DIST_IDENTITY" \
    --entitlements "$MAIN_ENT" \
    --options runtime \
    "$APP"

# ---------------------------------------------------------------------------
# Three-way verification — see plan-e Task 3.0 Step 5.
# ---------------------------------------------------------------------------
echo "==> Verifying signatures"
MAIN="$APP/Contents/MacOS/caterm"
HELPER="$APP/Contents/MacOS/caterm-askpass"

# --xml is required: modern macOS `codesign -d --entitlements -` defaults to a
# structured text dump ([Dict]/[Key]/[String]), not XML, so the
# <string>production</string> greps below would false-negative without it.
bundle_ents=$(codesign -d --entitlements - --xml "$APP" 2>&1)
main_ents=$(codesign -d --entitlements - --xml "$MAIN" 2>&1)
helper_ents=$(codesign -d --entitlements - --xml "$HELPER" 2>&1)

# Bundle + main: production APS + Production CK env (positive checks).
echo "$bundle_ents" | grep -q "<string>production</string>" \
    || { echo "FAIL: bundle missing aps-environment=production" >&2; exit 1; }
echo "$bundle_ents" | grep -q "<string>Production</string>" \
    || { echo "FAIL: bundle missing icloud-container-environment=Production" >&2; exit 1; }
echo "$main_ents"   | grep -q "<string>production</string>" \
    || { echo "FAIL: main exe missing aps-environment=production" >&2; exit 1; }
echo "$main_ents"   | grep -q "<string>Production</string>" \
    || { echo "FAIL: main exe missing icloud-container-environment=Production" >&2; exit 1; }

# Askpass: keychain-access-groups MUST be present.
echo "$helper_ents" | grep -q "keychain-access-groups" \
    || { echo "FAIL: askpass missing keychain-access-groups" >&2; exit 1; }

# Askpass: app/team identity entitlements MUST NOT leak in.
# AMFI SIGKILLs the helper at exec if any of these appear.
if echo "$helper_ents" | grep -Eq \
    "aps-environment|icloud-container-environment|application-identifier|com\.apple\.developer\.team-identifier"; then
    echo "FAIL: askpass has restricted app/team identity entitlements (AMFI will SIGKILL it)" >&2
    echo "$helper_ents" >&2
    exit 1
fi

echo "==> Verification OK"

# ---------------------------------------------------------------------------
# Optional: notarize + staple.
#
# `notarytool submit` accepts .zip / .pkg / .dmg, NOT a raw .app bundle, so
# we ditto-zip first (ditto preserves resource forks + xattrs better than
# `zip`, which Apple's docs explicitly recommend). After Apple issues a
# ticket, `stapler staple` writes it into the .app's Contents/CodeResources
# so Gatekeeper can validate offline.
# ---------------------------------------------------------------------------
if [[ -n "${CATERM_NOTARY_PROFILE:-}" ]]; then
    NOTARY_ZIP="$BIN_DIR/Caterm.notarize.zip"
    rm -f "$NOTARY_ZIP"

    echo "==> Zipping for notary submission"
    /usr/bin/ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"

    echo "==> Submitting to Apple notary service (this can take a few minutes)"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$CATERM_NOTARY_PROFILE" \
        --wait

    rm -f "$NOTARY_ZIP"

    echo "==> Stapling ticket"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    echo "==> Notarization OK"
fi

echo
echo "Bundle: $APP"
echo
if [[ -z "${CATERM_NOTARY_PROFILE:-}" ]]; then
    echo "Next steps:"
    echo "  1. Notarize (set CATERM_NOTARY_PROFILE and re-run, or run manually):"
    echo "       xcrun notarytool submit --keychain-profile <profile> $APP"
    echo "  2. Staple after notarization succeeds:"
    echo "       xcrun stapler staple $APP"
    echo "  3. Run two-Mac smoke per Manual/pre-ship-two-mac-smoke.md"
else
    echo "Next steps:"
    echo "  1. Optionally wrap in a DMG: Scripts/build-dmg.sh"
    echo "  2. Run two-Mac smoke per Manual/pre-ship-two-mac-smoke.md"
fi
