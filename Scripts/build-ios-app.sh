#!/bin/bash
# Build the iOS/iPadOS app via SwiftPM (NOT Xcode's SwiftPM integration,
# which is broken for swift-nio's C targets on Xcode 26.5's
# iphonesimulator SDK) and hand-wrap the executable into a runnable
# Caterm.app for the iOS Simulator. Mirrors the macOS Scripts/dev-run-app.sh
# philosophy: SwiftPM builds, we assemble the bundle.
#
# Output: build/ios/Caterm.app  (also echoed as the last line)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TRIPLE="arm64-apple-ios17.0-simulator"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CONFIG="${CATERM_IOS_CONFIG:-debug}"
BUNDLE_ID="app.caterm.mobile"
APP_NAME="Caterm"
OUT="$ROOT/build/ios/$APP_NAME.app"

SWIFT_FLAGS=(
  --product CatermMobileApp
  -c "$CONFIG"
  --sdk "$SDK"
  -Xswiftc -target -Xswiftc "$TRIPLE"
  -Xcc -target -Xcc "$TRIPLE"
  -Xcc -isysroot -Xcc "$SDK"
)

echo "[ios] swift build CatermMobileApp ($TRIPLE)…" >&2
swift build "${SWIFT_FLAGS[@]}" >&2
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/CatermMobileApp"
test -x "$BIN" || { echo "[ios] built binary not found at $BIN" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BIN" "$OUT/$APP_NAME"

# Concrete Info.plist (no xcodebuild variable substitution available).
PL="$OUT/Info.plist"
cp "$ROOT/App/iOS/Info.plist" "$PL"
PB() { /usr/libexec/PlistBuddy -c "$1" "$PL" >/dev/null 2>&1 || true; }
PB "Set :CFBundleExecutable $APP_NAME"
PB "Set :CFBundleIdentifier $BUNDLE_ID"
PB "Set :CFBundleName $APP_NAME"
PB "Set :CFBundlePackageType APPL"
PB "Delete :CFBundleSupportedPlatforms"
PB "Add :CFBundleSupportedPlatforms array"
PB "Add :CFBundleSupportedPlatforms:0 string iPhoneSimulator"
PB "Set :MinimumOSVersion 17.0"
PB "Delete :UIDeviceFamily"
PB "Add :UIDeviceFamily array"
PB "Add :UIDeviceFamily:0 integer 1"
PB "Add :UIDeviceFamily:1 integer 2"
PB "Set :DTPlatformName iphonesimulator"
PB "Set :DTSDKName iphonesimulator26.5"

echo "[ios] assembled $OUT" >&2
echo "$OUT"
