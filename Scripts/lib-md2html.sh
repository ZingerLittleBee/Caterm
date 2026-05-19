# lib-md2html.sh — sourced helper.
#
#   caterm_md_to_html MARKDOWN_PATH
#       Convert the CHANGELOG subset we actually emit (### headings,
#       "- " bullets that may wrap onto indented continuation lines,
#       blank-line-separated paragraphs) to a minimal, self-contained
#       HTML document on stdout. HTML-escapes & < > so release notes
#       render correctly inside Sparkle's WebKit view.

caterm_md_to_html() {
    local src="$1"
    if [[ ! -f "$src" ]]; then
        echo "caterm_md_to_html: not found: $src" >&2
        return 1
    fi
    printf '%s\n' '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>'
    awk '
        function esc(s) {
            gsub(/&/, "\\&amp;", s)
            gsub(/</, "\\&lt;", s)
            gsub(/>/, "\\&gt;", s)
            return s
        }
        function flushli() {
            if (initem) { print "<li>" libuf "</li>"; initem=0; libuf="" }
        }
        function closelist() {
            if (inlist) { flushli(); print "</ul>"; inlist=0 }
        }
        function flushpara() {
            if (inpara) { print "<p>" parabuf "</p>"; inpara=0; parabuf="" }
        }
        /^### / {
            closelist(); flushpara()
            print "<h3>" esc(substr($0, 5)) "</h3>"
            next
        }
        /^[[:space:]]*-[[:space:]]+/ {
            flushpara()
            if (!inlist) { print "<ul>"; inlist=1 }
            flushli()
            line=$0
            sub(/^[[:space:]]*-[[:space:]]+/, "", line)
            initem=1; libuf=esc(line)
            next
        }
        /^[[:space:]]*$/ {
            closelist(); flushpara()
            next
        }
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (inlist && initem) {
                libuf = libuf " " esc(line)
            } else {
                closelist()
                if (!inpara) { inpara=1; parabuf=esc(line) }
                else { parabuf = parabuf " " esc(line) }
            }
            next
        }
        END { closelist(); flushpara() }
    ' "$src" || return 1
    printf '%s\n' '</body></html>'
}
