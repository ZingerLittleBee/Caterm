#!/usr/bin/env bash
set -euo pipefail

# build-dmg.sh — wrap a Distribution-signed (and ideally already-stapled)
# Caterm.app in a UDZO-compressed disk image for end-user distribution.
#
# Stage layout: Caterm.app + a /Applications symlink, the conventional
# drag-to-install UX users expect on macOS.
#
# Optional env:
#   CATERM_DIST_VERSION    same default as dist-package.sh (1.0.0); used to
#                          name the output as Caterm-<version>.dmg.
#   CATERM_DIST_IDENTITY   if set, codesign the .dmg itself with the same
#                          Developer ID identity used for the .app. Signing
#                          the dmg is OPTIONAL but recommended — Gatekeeper
#                          treats a signed dmg as more trustworthy on first
#                          mount.
#   CATERM_NOTARY_PROFILE  if set, notarize + staple the dmg. Independent of
#                          whether the .app inside has already been stapled
#                          (you should staple both: the inner .app for users
#                          who copy it out, and the dmg itself for the mount
#                          trust prompt).
#
# Pre-conditions:
#   .build/release/Caterm.app exists, signed by dist-package.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.build/release"
APP="$BIN_DIR/Caterm.app"
APP_VERSION="${CATERM_DIST_VERSION:-1.0.0}"

if [[ ! -d "$APP" ]]; then
    echo "Error: $APP not found. Run \`make dist\` first." >&2
    exit 1
fi

DMG_NAME="Caterm-${APP_VERSION}.dmg"
DMG_PATH="$BIN_DIR/$DMG_NAME"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/Caterm.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "Caterm" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [[ -n "${CATERM_DIST_IDENTITY:-}" ]]; then
    echo "==> Signing dmg"
    codesign --force --sign "$CATERM_DIST_IDENTITY" "$DMG_PATH"
fi

if [[ -n "${CATERM_NOTARY_PROFILE:-}" ]]; then
    echo "==> Submitting dmg to notary"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$CATERM_NOTARY_PROFILE" \
        --wait

    echo "==> Stapling dmg"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

echo
echo "DMG: $DMG_PATH"
