#!/usr/bin/env bash
set -euo pipefail

# dev-run-app.sh — wrap the signed dev binary in a minimal Caterm.app
# bundle and launch it.
#
# Why this exists:
#   `make run` launches `.build/debug/caterm` directly. That binary is
#   codesigned and has entitlements, but it has no Info.plist and no
#   CFBundleIdentifier — i.e. no bundle identity. Several Apple frameworks
#   refuse to operate without a bundle identity and raise an *uncatchable*
#   Obj-C NSException when called:
#
#       UNUserNotificationCenter.current()  →  bundleProxyForCurrentProcess is nil
#       NSWorkspace.frontmostApplication.bundleIdentifier  →  nil
#       LSCopyApplicationURLsForBundleIdentifier            →  empty
#
#   Hardened Runtime + AMFI on Apple Silicon also gate certain entitlements
#   on a real .app structure. So when the dev needs to test anything that
#   touches UserNotifications, NSUserActivity, App Groups handoff, etc. —
#   running the bare binary will crash on first use.
#
#   This script assembles the smallest possible .app shell around the
#   already-signed binaries from `make sign` and re-seals the bundle, then
#   launches it via `open`. The bundle identifier is stable so Keychain
#   ACLs and Launch Services state survive between runs.
#
# Required env:
#   CATERM_DEV_IDENTITY  — signing identity (same one `make run` uses).

: "${CATERM_DEV_IDENTITY:?CATERM_DEV_IDENTITY env var required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.build/debug"
APP="$BIN_DIR/Caterm.app"
# Default bundle id matches the profile's App ID (9VM4RM39R3.com.caterm.app).
# AMFI rejects launch when CFBundleIdentifier does not match the profile's
# application-identifier. Override only if you have a separate dev profile.
APP_BUNDLE_ID="${CATERM_DEV_BUNDLE_ID:-com.caterm.app}"

# Optional Mac App Development provisioning profile. Required for AMFI to
# accept restricted entitlements like `aps-environment` (Push Notifications)
# and `keychain-access-groups`. Prefer the gitignored sign/ dir (same place
# the Distribution profile lives); fall back to the legacy ~/Downloads path.
if [[ -z "${CATERM_DEV_PROFILE:-}" ]]; then
    if [[ -f "$ROOT/sign/Caterm_Mac_Dev_Apple_Dev.provisionprofile" ]]; then
        CATERM_DEV_PROFILE="$ROOT/sign/Caterm_Mac_Dev_Apple_Dev.provisionprofile"
    else
        CATERM_DEV_PROFILE="$HOME/Downloads/Caterm_Mac_Dev_Apple_Dev.provisionprofile"
    fi
fi
ENTITLEMENTS="$BIN_DIR/Caterm.dev.entitlements"

if [[ ! -x "$BIN_DIR/caterm" || ! -x "$BIN_DIR/caterm-askpass" ]]; then
    echo "Error: signed binaries not found in $BIN_DIR. Run \`make sign\` first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the bundle layout.
# ---------------------------------------------------------------------------
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy the already-signed binaries. Their inner signatures (with hardened
# runtime + the right entitlements) are preserved when we seal the outer
# bundle without `--deep`.
cp "$BIN_DIR/caterm" "$APP/Contents/MacOS/caterm"
cp "$BIN_DIR/caterm-askpass" "$APP/Contents/MacOS/caterm-askpass"

# Carry over GhosttyKit if Caterm uses it as a runtime-loaded resource.
# (Static-linked .a inside the xcframework needs no runtime copy.)

# Pick an icon if one is checked in (optional).
# Strip xattrs after copy: icon generators (Image2Icon, etc.) routinely leave
# com.apple.FinderInfo / ResourceFork / quarantine, which codesign rejects with
# "resource fork, Finder information, or similar detritus not allowed".
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    xattr -c "$APP/Contents/Resources/AppIcon.icns"
fi

# Dev builds tolerate a missing/empty public key (|| true): the updater
# still launches; "Check for Updates" just can't verify until keys exist.
# dist-package.sh enforces a non-empty key (hard error) for releases.
SPARKLE_PUB_KEY="$(tr -d '[:space:]' < "$ROOT/Scripts/sparkle_public_key.txt" 2>/dev/null || true)"
SPARKLE_FEED_URL="https://github.com/ZingerLittleBee/Caterm/releases/latest/download/appcast.xml"

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
    <string>Caterm (dev)</string>
    <key>CFBundleExecutable</key>
    <string>caterm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0-dev</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUB_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
EOF

# ---------------------------------------------------------------------------
# Embed the Mac App Development provisioning profile so AMFI can validate
# restricted entitlements (aps-environment, keychain-access-groups) at exec
# time. Without this, the kernel SIGKILLs the process with "no matching
# profile" — see docs/macos-dev-signing.md "Embedding the profile".
# ---------------------------------------------------------------------------
if [[ -f "$CATERM_DEV_PROFILE" ]]; then
    echo "==> Embedding profile from $CATERM_DEV_PROFILE"
    cp "$CATERM_DEV_PROFILE" "$APP/Contents/embedded.provisionprofile"
else
    echo "Warning: provisioning profile not found at $CATERM_DEV_PROFILE — APS / KAG entitlements will be rejected by AMFI" >&2
fi

# ---------------------------------------------------------------------------
# Re-sign the bundle. The inner binaries were signed by dev-codesign.sh with
# the correct entitlements; we don't want to re-sign them and lose those
# entitlements, so we omit --deep and let codesign just produce the bundle
# seal that references the existing inner signatures.
#
# Pass --entitlements explicitly (Pitfall 5 in docs/macos-dev-signing.md):
# without it, the outer codesign re-signs the main executable with empty
# entitlements, which then fails to register for remote notifications and
# crashes inside CKContainer init.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Embed + sign Sparkle.framework, and add the Frameworks rpath.
#
# `caterm` links Sparkle via @rpath; the bundled app must carry the
# framework at Contents/Frameworks and an @executable_path/../Frameworks
# rpath or it won't launch. Sign the framework inside-out with the dev
# identity BEFORE the non-deep outer seal (which re-signs only the main
# executable). No --timestamp for dev (offline-friendly).
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source "$ROOT/Scripts/lib-sparkle.sh"
SPARKLE_FW="$(find_sparkle_framework "$ROOT")"
echo "==> Embedding Sparkle.framework from $SPARKLE_FW"
mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

EMBEDDED_FW="$APP/Contents/Frameworks/Sparkle.framework"
dev_sign_one() {
    codesign --force --options runtime --sign "$CATERM_DEV_IDENTITY" "$1"
}
echo "==> Signing Sparkle nested components (inside-out, dev identity)"
while IFS= read -r xpc; do
    [[ -n "$xpc" ]] && dev_sign_one "$xpc"
done < <(find "$EMBEDDED_FW" -name '*.xpc' -type d)
[[ -e "$EMBEDDED_FW/Versions/Current/Autoupdate" ]] \
    && dev_sign_one "$EMBEDDED_FW/Versions/Current/Autoupdate"
if [[ ! -e "$EMBEDDED_FW/Versions/Current/Updater.app" ]]; then
    echo "Error: Sparkle Updater.app missing in $EMBEDDED_FW — embed/layout broken." >&2
    exit 1
fi
dev_sign_one "$EMBEDDED_FW/Versions/Current/Updater.app"
dev_sign_one "$EMBEDDED_FW"

MAIN_EXE="$APP/Contents/MacOS/caterm"
if otool -l "$MAIN_EXE" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks'; then
    echo "==> Frameworks rpath already present on caterm"
else
    echo "==> Adding @executable_path/../Frameworks rpath to caterm"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MAIN_EXE"
fi

echo "==> Signing $APP"
ENT_ARGS=()
if [[ -f "$ENTITLEMENTS" ]]; then
    ENT_ARGS=(--entitlements "$ENTITLEMENTS")
fi
codesign --force --options runtime \
    --sign "$CATERM_DEV_IDENTITY" \
    "${ENT_ARGS[@]}" \
    "$APP"

codesign -dvv "$APP" 2>&1 | grep -E "TeamIdentifier|Authority|Identifier" || true

# ---------------------------------------------------------------------------
# Launch via Launch Services so macOS treats the process as a real .app
# and frameworks like UserNotifications resolve a bundle identity.
# ---------------------------------------------------------------------------
echo "==> Launching $APP"
OPEN_ENV_ARGS=()
if [[ -n "${CATERM_DEV_OPEN_ENV:-}" ]]; then
    for env_pair in $CATERM_DEV_OPEN_ENV; do
        OPEN_ENV_ARGS+=(--env "$env_pair")
    done
fi
open "${OPEN_ENV_ARGS[@]}" "$APP"
echo "Logs: tail -f \$TMPDIR/caterm-dev.log  # if you set CFBundleDocumentTypes/log redirect"
echo "Force quit if needed: pkill -f Caterm.app/Contents/MacOS/caterm"
