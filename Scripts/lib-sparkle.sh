# lib-sparkle.sh — sourced helper. Locates SwiftPM-fetched Sparkle
# artifacts. Sparkle is a binary target: paths under .build are NOT
# stable across SwiftPM/config versions, so we search + assert
# uniqueness instead of hardcoding. No side effects on source.
#
#   find_sparkle_framework ROOT
#       Echo the absolute path of the single Sparkle.framework under
#       ROOT/.build/artifacts. Error + return 1 if zero or multiple are
#       found, or if it lacks the host architecture.
#
#   find_sparkle_tool ROOT TOOLNAME
#       Echo the absolute path of a Sparkle CLI tool (generate_appcast,
#       generate_keys, sign_update). Error + return 1 if not found.

find_sparkle_framework() {
    local root="$1"
    # Use the canonical xcframework artifact slice SPM downloads
    # (universal, Sparkle-signed, config-independent). Build-output
    # copies under .build/<triple>/<config>/ are intentionally excluded
    # — they vary by arch/config and are not the artifact of record.
    local matches
    # Drop any Sparkle.framework nested inside another (defensive).
    matches="$(find "$root/.build/artifacts" \
        -path '*/Sparkle.xcframework/macos*/Sparkle.framework' -type d 2>/dev/null \
        | grep -v '/Sparkle.framework/.*Sparkle.framework' || true)"
    local count
    count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$count" -eq 0 ]]; then
        echo "lib-sparkle: Sparkle.xcframework macOS slice not found under $root/.build/artifacts (run 'swift build' first)" >&2
        return 1
    fi
    if [[ "$count" -ne 1 ]]; then
        echo "lib-sparkle: expected exactly one Sparkle.xcframework macOS slice, found $count:" >&2
        printf '%s\n' "$matches" >&2
        return 1
    fi
    local fw
    fw="$(printf '%s\n' "$matches" | sed '/^$/d' | head -1)"
    local binary=""
    local candidate
    for candidate in "$fw/Versions/Current/Sparkle" "$fw/Sparkle"; do
        if [[ -f "$candidate" || -L "$candidate" ]]; then binary="$candidate"; break; fi
    done
    if [[ -z "$binary" ]]; then
        echo "lib-sparkle: cannot locate the Sparkle binary inside $fw" >&2
        return 1
    fi
    local arch
    arch="$(uname -m)"
    if ! lipo -info "$binary" 2>/dev/null | grep -q "$arch" \
       && ! file "$binary" 2>/dev/null | grep -q "$arch"; then
        echo "lib-sparkle: $fw does not contain host arch $arch" >&2
        return 1
    fi
    printf '%s' "$fw"
}

find_sparkle_tool() {
    local root="$1" tool="$2"
    local matches
    matches="$(find "$root/.build" -name "$tool" -type f -perm +111 2>/dev/null || true)"
    local hit
    # All Sparkle CLI tools live in one artifact bin/ dir; first match is canonical.
    hit="$(printf '%s\n' "$matches" | sed '/^$/d' | head -1)"
    if [[ -z "$hit" ]]; then
        echo "lib-sparkle: tool '$tool' not found under $root/.build." >&2
        echo "             It ships in the Sparkle SPM artifact; run 'swift build' first," >&2
        echo "             or download Sparkle's release tools bundle." >&2
        return 1
    fi
    printf '%s' "$hit"
}
