#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

GHOSTTY_DIR="$ROOT/Vendor/ghostty"
OUT_DIR="$ROOT/Frameworks"
XCFRAMEWORK="$OUT_DIR/GhosttyKit.xcframework"

if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "Error: $GHOSTTY_DIR not found. Did you init submodules?"
    exit 1
fi

# Ghostty v1.3.1 requires exactly Zig 0.15.2. We install it via brew as
# zig@0.15 (keg-only) so it doesn't conflict with whatever zig is on PATH.
ZIG_BIN="${ZIG_BIN:-/opt/homebrew/opt/zig@0.15/bin/zig}"
if [ ! -x "$ZIG_BIN" ]; then
    echo "Error: $ZIG_BIN not found. Install with: brew install zig@0.15"
    exit 1
fi

echo "==> Building libghostty with $($ZIG_BIN version) (this can take 5-10 minutes first time)"
cd "$GHOSTTY_DIR"

# Ghostty's `install` step (triggered by emit-xcframework) chains through to
# `xcodebuild` to also build the full Ghostty.app bundle, which depends on
# Sparkle and other things we don't need. The xcframework itself is produced
# *before* that step, so we tolerate a non-zero exit code as long as the
# xcframework appears at the expected output path.
SRC="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
rm -rf "$SRC"

set +e
"$ZIG_BIN" build -Demit-xcframework=true -Doptimize=ReleaseFast
ZIG_RC=$?
set -e

if [ ! -d "$SRC" ]; then
    echo "Error: zig build exited with $ZIG_RC and no xcframework was produced at $SRC."
    exit "$ZIG_RC"
fi

if [ "$ZIG_RC" -ne 0 ]; then
    echo "==> zig build returned $ZIG_RC after producing xcframework (downstream app-bundle step failed). Continuing — we only need the xcframework."
fi

mkdir -p "$OUT_DIR"
rm -rf "$XCFRAMEWORK"
cp -R "$SRC" "$XCFRAMEWORK"

# SwiftPM rejects static libraries that don't follow the `lib<name>.a`
# convention. Ghostty's macOS slice ships as `ghostty-internal.a`, which we
# rename in-place along with its Info.plist references. iOS slices are
# already prefixed (`libghostty-internal-fat.a`) and need no change.
MACOS_DIR="$XCFRAMEWORK/macos-arm64_x86_64"
if [ -f "$MACOS_DIR/ghostty-internal.a" ]; then
    mv "$MACOS_DIR/ghostty-internal.a" "$MACOS_DIR/libghostty-internal.a"
    /usr/bin/plutil -replace 'AvailableLibraries.0.BinaryPath' -string 'libghostty-internal.a' "$XCFRAMEWORK/Info.plist"
    /usr/bin/plutil -replace 'AvailableLibraries.0.LibraryPath' -string 'libghostty-internal.a' "$XCFRAMEWORK/Info.plist"
fi

echo "==> $XCFRAMEWORK ready"
