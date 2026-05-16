#!/usr/bin/env bash
# Builds Sources/SettingsStore/Resources/themes.json from the Ghostty submodule.
# Discovers themes from a fixed candidate root list (§3.4 of spec); falls back
# to vendored 9-favorites set if no root contains parseable themes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$ROOT/Sources/SettingsStore/Resources/themes.json"
FALLBACK_DIR="$ROOT/Sources/SettingsStore/Resources/fallback-themes"

CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in --check-only) CHECK_ONLY=1 ;; esac
done

CANDIDATES=(
    "$ROOT/Vendor/ghostty/zig-out/share/ghostty/themes"
    "$ROOT/Vendor/ghostty/zig-out/themes"
    "$ROOT/Vendor/ghostty/src/config/themes"
    "$ROOT/Vendor/ghostty/pkg/iterm2-themes/themes"
)

CHOSEN=""
for c in "${CANDIDATES[@]}"; do
    if [ -d "$c" ] && find "$c" -maxdepth 2 -type f -name "*" -exec grep -l "^palette" {} \; | grep -q .; then
        CHOSEN="$c"
        break
    fi
done

if [ -z "$CHOSEN" ]; then
    echo "[build-theme-catalog] no candidate root with parseable themes; using fallback at $FALLBACK_DIR" >&2
    CHOSEN="$FALLBACK_DIR"
    if [ ! -d "$CHOSEN" ]; then
        echo "[build-theme-catalog] fallback dir missing; emitting empty catalog" >&2
        if [ "$CHECK_ONLY" -eq 0 ]; then echo "[]" > "$OUT"; fi
        exit 0
    fi
fi

echo "[build-theme-catalog] using $CHOSEN" >&2

python3 - "$CHOSEN" "$OUT" "$CHECK_ONLY" <<'PY'
import json, os, re, sys
src, out, check_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
themes = []
for name in sorted(os.listdir(src)):
    path = os.path.join(src, name)
    if not os.path.isfile(path):
        continue
    palette = [None] * 16
    bg = fg = cur = sel = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"^\s*palette\s*=\s*(\d+)\s*=\s*(#?[0-9a-fA-F]{6})", line)
                if m:
                    idx = int(m.group(1))
                    if 0 <= idx < 16:
                        palette[idx] = m.group(2) if m.group(2).startswith("#") else "#" + m.group(2)
                    continue
                m = re.match(r"^\s*background\s*=\s*(.+?)\s*$", line)
                if m: bg = m.group(1).strip().strip('"'); continue
                m = re.match(r"^\s*foreground\s*=\s*(.+?)\s*$", line)
                if m: fg = m.group(1).strip().strip('"'); continue
                m = re.match(r"^\s*cursor-color\s*=\s*(.+?)\s*$", line)
                if m: cur = m.group(1).strip().strip('"'); continue
                m = re.match(r"^\s*selection-background\s*=\s*(.+?)\s*$", line)
                if m: sel = m.group(1).strip().strip('"'); continue
    except Exception as e:
        print(f"[build-theme-catalog] skip {name}: {e}", file=sys.stderr)
        continue
    if any(p is None for p in palette) or bg is None or fg is None:
        continue
    themes.append({
        "name": name,
        "palette": palette,
        "background": bg,
        "foreground": fg,
        "cursorColor": cur,
        "selectionBackground": sel,
    })

if not themes:
    print(f"[build-theme-catalog] no parseable themes in {src}", file=sys.stderr)
    if not check_only:
        with open(out, "w") as f: f.write("[]\n")
    sys.exit(0)

print(f"[build-theme-catalog] discovered {len(themes)} themes", file=sys.stderr)
if check_only:
    sys.exit(0)

with open(out, "w", encoding="utf-8") as f:
    json.dump(themes, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"[build-theme-catalog] wrote {out}", file=sys.stderr)
PY
