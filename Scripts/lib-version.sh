# lib-version.sh — sourced helpers. No side effects on source.
#
#   caterm_changelog_version [CHANGELOG_PATH]
#       Echo the first `## [X.Y.Z]` release version, skipping
#       `## [Unreleased]`. Mirrors publish-release.sh's existing grep.
#
#   caterm_build_number X.Y.Z
#       Echo a strictly-monotonic CFBundleVersion = X*10000 + Y*100 + Z.
#       Each segment must be < 100; otherwise error to stderr + return 1.

caterm_changelog_version() {
    local changelog="${1:-CHANGELOG.md}"
    local v
    v="$(grep -m1 -E '^## \[[0-9]' "$changelog" \
        | sed -E 's/^## \[([^]]+)\].*/\1/')"
    if [[ -z "$v" ]]; then
        echo "lib-version: no '## [X.Y.Z]' release entry in $changelog" >&2
        return 1
    fi
    printf '%s' "$v"
}

caterm_build_number() {
    local semver="$1"
    if [[ ! "$semver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "lib-version: not a X.Y.Z version: '$semver'" >&2
        return 1
    fi
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"
    local seg
    for seg in "$major" "$minor" "$patch"; do
        if (( seg >= 100 )); then
            echo "lib-version: version segment >=100 ('$semver') breaks the build-number scheme" >&2
            return 1
        fi
    done
    printf '%s' "$(( major * 10000 + minor * 100 + patch ))"
}
