#!/bin/bash
# Build the iOS/iPadOS app via SwiftPM (NOT Xcode's SwiftPM integration,
# which is broken for swift-nio's C targets on Xcode 26.5's
# iphonesimulator SDK) and hand-wrap the executable into a runnable
# Caterm.app for the iOS Simulator or a provisioned iOS device. Mirrors the
# macOS Scripts/dev-run-app.sh philosophy: SwiftPM builds, we assemble and
# sign the bundle.
#
# Output: build/ios/Caterm.app  (also echoed as the last line)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK_NAME="${CATERM_IOS_SDK:-iphonesimulator}"
case "$SDK_NAME" in
  iphonesimulator)
    TRIPLE="${CATERM_IOS_TRIPLE:-arm64-apple-ios17.0-simulator}"
    PLATFORM="iPhoneSimulator"
    ;;
  iphoneos)
    TRIPLE="${CATERM_IOS_TRIPLE:-arm64-apple-ios17.0}"
    PLATFORM="iPhoneOS"
    ;;
  *)
    echo "[ios] unsupported CATERM_IOS_SDK: $SDK_NAME" >&2
    exit 1
    ;;
esac
SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk "$SDK_NAME" --show-sdk-version)"
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

# iOS app resources live at the bundle root, which is also where SwiftPM's
# generated Bundle.module accessor looks for sibling resource bundles.
bash "$ROOT/Scripts/embed-swiftpm-resources.sh" "$BIN_DIR" "$OUT"

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
PB "Add :CFBundleSupportedPlatforms:0 string $PLATFORM"
PB "Set :MinimumOSVersion 17.0"
PB "Delete :UIDeviceFamily"
PB "Add :UIDeviceFamily array"
PB "Add :UIDeviceFamily:0 integer 1"
PB "Add :UIDeviceFamily:1 integer 2"
PB "Set :DTPlatformName $SDK_NAME"
PB "Set :DTSDKName ${SDK_NAME}${SDK_VERSION}"

if [[ "$SDK_NAME" == "iphonesimulator" ]]; then
  codesign --force --sign - "$OUT"
else
  PROFILE="${CATERM_IOS_PROVISIONING_PROFILE:-}"
  IDENTITY="${CATERM_IOS_SIGNING_IDENTITY:-}"
  TEAM_ID="${CATERM_IOS_TEAM_ID:-}"
  if [[ -z "$PROFILE" || -z "$IDENTITY" || -z "$TEAM_ID" ]]; then
    echo "[ios] device builds require CATERM_IOS_PROVISIONING_PROFILE," >&2
    echo "[ios] CATERM_IOS_SIGNING_IDENTITY, and CATERM_IOS_TEAM_ID" >&2
    exit 1
  fi
  test -f "$PROFILE" || {
    echo "[ios] provisioning profile not found: $PROFILE" >&2
    exit 1
  }
  cp "$PROFILE" "$OUT/embedded.mobileprovision"
  PROFILE_PLIST="$ROOT/build/ios/CatermMobile.profile.plist"
  security cms -D -i "$PROFILE" >"$PROFILE_PLIST"
  ENTITLEMENTS="$ROOT/build/ios/CatermMobile.resolved.entitlements"
  bash "$ROOT/Scripts/resolve-ios-entitlements.sh" \
    "$PROFILE_PLIST" \
    "$ROOT/Resources/CatermMobile.entitlements" \
    "$ENTITLEMENTS" \
    "$TEAM_ID" \
    "$BUNDLE_ID"
  PB "Add :CatermKeychainAccessGroup string $TEAM_ID.caterm.shared"
  /usr/libexec/PlistBuddy -c "Set :CatermCloudKitEnabled true" "$PL"
  codesign --force --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --generate-entitlement-der "$OUT"
fi

codesign --verify --deep --strict "$OUT"

echo "[ios] assembled $OUT" >&2
echo "$OUT"
