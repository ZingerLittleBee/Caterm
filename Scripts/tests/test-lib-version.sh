#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib-version.sh"

fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc (expected '$expected', got '$actual')"
        fail=1
    fi
}

tmp="$(mktemp)"
cat > "$tmp" <<'EOF'
# Changelog
## [Unreleased]
## [1.1.0] - 2026-05-17
notes
## [1.0.0] - 2026-01-01
EOF

check "version skips [Unreleased]" "1.1.0" "$(caterm_changelog_version "$tmp")"
check "build number 1.1.0"  "10100" "$(caterm_build_number 1.1.0)"
check "build number 1.2.3"  "10203" "$(caterm_build_number 1.2.3)"
check "build number 0.9.0"  "900"   "$(caterm_build_number 0.9.0)"
check "build number 1.10.2" "11002" "$(caterm_build_number 1.10.2)"

if caterm_build_number 1.100.0 2>/dev/null; then
    echo "FAIL - segment >=100 must error"; fail=1
else
    echo "ok   - segment >=100 errors"
fi

rm -f "$tmp"
exit "$fail"
