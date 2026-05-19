#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib-md2html.sh"

fail=0
md="$(mktemp)"; html="$(mktemp)"
cat > "$md" <<'EOF'
### iOS app (new)

- First bullet with <angle> & ampersand
- Second bullet

A trailing paragraph.
EOF

caterm_md_to_html "$md" > "$html"

grep -q "<!DOCTYPE html>" "$html"            || { echo "FAIL - no doctype"; fail=1; }
grep -q "<h3>iOS app (new)</h3>" "$html"     || { echo "FAIL - h3 not converted"; fail=1; }
grep -q "<ul>" "$html"                       || { echo "FAIL - no <ul>"; fail=1; }
grep -q "<li>First bullet with &lt;angle&gt; &amp; ampersand</li>" "$html" \
                                             || { echo "FAIL - bullet/escaping wrong"; fail=1; }
grep -q "<p>A trailing paragraph.</p>" "$html" || { echo "FAIL - paragraph not wrapped"; fail=1; }
[[ "$fail" -eq 0 ]] && echo "ok - md2html"

rm -f "$md" "$html"
exit "$fail"
