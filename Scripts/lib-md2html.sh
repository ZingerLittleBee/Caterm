# lib-md2html.sh — sourced helper.
#
#   caterm_md_to_html MARKDOWN_PATH
#       Convert the CHANGELOG subset we actually emit (### headings,
#       "- " bullets, blank-line-separated paragraphs) to a minimal,
#       self-contained HTML document on stdout. HTML-escapes & < > so
#       release notes render correctly inside Sparkle's WebKit view.

caterm_md_to_html() {
    local src="$1"
    printf '%s\n' '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>'
    awk '
        function esc(s) {
            gsub(/&/, "\\&amp;", s)
            gsub(/</, "\\&lt;", s)
            gsub(/>/, "\\&gt;", s)
            return s
        }
        function closelist() { if (inlist) { print "</ul>"; inlist=0 } }
        function closepara() { if (inpara) { print parabuf "</p>"; inpara=0; parabuf="" } }
        /^### / {
            closelist(); closepara()
            print "<h3>" esc(substr($0, 5)) "</h3>"
            next
        }
        /^[[:space:]]*-[[:space:]]+/ {
            closepara()
            if (!inlist) { print "<ul>"; inlist=1 }
            line=$0
            sub(/^[[:space:]]*-[[:space:]]+/, "", line)
            print "<li>" esc(line) "</li>"
            next
        }
        /^[[:space:]]*$/ {
            closelist(); closepara()
            next
        }
        {
            closelist()
            if (!inpara) { inpara=1; parabuf="<p>" esc($0) }
            else { parabuf=parabuf " " esc($0) }
            next
        }
        END { closelist(); closepara() }
    ' "$src"
    printf '%s\n' '</body></html>'
}
