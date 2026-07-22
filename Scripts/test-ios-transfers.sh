#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME_SOURCE="$ROOT/Scripts/XcodeSchemes/CatermMobileTests.xcscheme"
SCHEME_DIRECTORY="$ROOT/.swiftpm/xcode/xcshareddata/xcschemes"
DERIVED_DATA="${CATERM_IOS_TEST_DERIVED_DATA:-$ROOT/build/ios-transfer-tests/DerivedData}"

simulator_id="${IOS_SIM:-}"
if [[ -z "$simulator_id" ]]; then
	simulator_id="$(
		xcrun simctl list devices available 2>/dev/null \
			| awk '/iPhone/ && match($0, /[0-9A-F-]{36}/) { print substr($0, RSTART, RLENGTH); exit }'
	)"
fi
if [[ -z "$simulator_id" ]]; then
	echo "No available iPhone Simulator was found." >&2
	exit 1
fi

mkdir -p "$SCHEME_DIRECTORY"
cp "$SCHEME_SOURCE" "$SCHEME_DIRECTORY/CatermMobileTests.xcscheme"
xcrun simctl boot "$simulator_id" 2>/dev/null || true

xcodebuild test -quiet \
	-scheme CatermMobileTests \
	-destination "platform=iOS Simulator,id=$simulator_id" \
	-derivedDataPath "$DERIVED_DATA" \
	-only-testing:CatermMobileTests/MobileFileTransferTests \
	CODE_SIGNING_ALLOWED=NO
