#!/usr/bin/env bash
set -euo pipefail

# publish-release.sh — tag + GitHub release + artifact upload.
#
# Runs AFTER `make release` has produced a signed + notarized + stapled
# .app and .dmg. This script:
#
#   1. Hard-gates on Gatekeeper: refuses to publish unless both the .app
#      and .dmg are `spctl`-accepted AND `stapler`-validated. Shipping a
#      build that fails Gatekeeper is worse than not shipping.
#   2. Extracts the matching section from CHANGELOG.md as release notes.
#   3. Requires a clean tree whose HEAD is already pushed to origin (the
#      tag must point at a commit reviewers can see).
#   4. ditto-zips the .app (preserving the stapled ticket).
#   5. Generates + verifies the Sparkle appcast (EdDSA-signed).
#   6. Creates + pushes an annotated tag v<version> — only after every
#      artifact gate above has passed (no orphan tags on a failed gate).
#   7. `gh release create` with the notes, uploading the .dmg, .app zip,
#      appcast.xml, and notes HTML.
#
# Usage:
#   Scripts/publish-release.sh [<version>]   (default: latest CHANGELOG entry)
#   --draft        REJECTED — incompatible with the Sparkle latest-release feed
#   --dry-run      print every action, mutate nothing

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$ROOT"
BIN_DIR="$ROOT/.build/release"
CHANGELOG="$ROOT/CHANGELOG.md"

DRAFT=0
DRY_RUN=0
VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --draft)   DRAFT=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '3,24p' "$0"; exit 0 ;;
        -*) echo "Unknown flag: $1" >&2; exit 1 ;;
        *)  VERSION="$1"; shift ;;
    esac
done

if [[ "$DRAFT" -eq 1 ]]; then
    echo "Error: --draft is incompatible with Sparkle auto-update." >&2
    echo "       The feed URL resolves via releases/latest/download/appcast.xml," >&2
    echo "       which ignores drafts/prereleases. Publish non-draft or skip publish." >&2
    exit 1
fi

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Version: arg, else the first `## [x.y.z]` heading in the CHANGELOG.
# ---------------------------------------------------------------------------
if [[ -z "$VERSION" ]]; then
    VERSION="$(grep -m1 -E '^## \[[0-9]' "$CHANGELOG" \
        | sed -E 's/^## \[([^]]+)\].*/\1/')"
fi
if [[ -z "$VERSION" ]]; then
    echo "Error: could not determine version (pass it explicitly)." >&2
    exit 1
fi
TAG="v$VERSION"
APP="$BIN_DIR/Caterm.app"
DMG="$BIN_DIR/Caterm-${VERSION}.dmg"
APP_ZIP="$BIN_DIR/Caterm-${VERSION}-app.zip"
STAGE_DIR="$BIN_DIR/appcast-stage"
APP_ZIP_NAME="Caterm-${VERSION}-app.zip"
NOTES_HTML="$STAGE_DIR/Caterm-${VERSION}-app.html"
APPCAST="$STAGE_DIR/appcast.xml"

echo "============================================================"
echo " Publish: $TAG"
echo "   app : $APP"
echo "   dmg : $DMG"
echo "   mode: $([[ $DRAFT -eq 1 ]] && echo draft || echo public)$([[ $DRY_RUN -eq 1 ]] && echo ' (dry-run)')"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Gatekeeper hard gate — never publish a build that won't open.
# ---------------------------------------------------------------------------
[[ -d "$APP" ]] || { echo "Error: $APP missing. Run \`make release\` first." >&2; exit 1; }
[[ -f "$DMG" ]] || { echo "Error: $DMG missing. Run \`make release\` first." >&2; exit 1; }

echo "==> Verifying notarization + stapling"
spctl -a -t exec   "$APP" 2>/dev/null || { echo "FAIL: .app not Gatekeeper-accepted" >&2; exit 1; }
spctl -a -t install "$DMG" 2>/dev/null || { echo "FAIL: .dmg not Gatekeeper-accepted" >&2; exit 1; }
xcrun stapler validate "$APP" >/dev/null 2>&1 || { echo "FAIL: .app not stapled" >&2; exit 1; }
xcrun stapler validate "$DMG" >/dev/null 2>&1 || { echo "FAIL: .dmg not stapled" >&2; exit 1; }
echo "    OK — both artifacts notarized + stapled"

# ---------------------------------------------------------------------------
# 2. CHANGELOG section.
# ---------------------------------------------------------------------------
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"; [[ -n "${STAGE_DIR:-}" ]] && rm -rf "$STAGE_DIR"' EXIT
awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" {f=1; next}
    f && /^## \[/ {exit}
    f {print}
' "$CHANGELOG" | sed -E '/^\['"$VERSION"'\]:/d' \
    | sed -e 's/^[[:space:]]*$//' > "$NOTES_FILE"
# Trim leading/trailing blank lines.
sed -i '' -e '/./,$!d' "$NOTES_FILE" 2>/dev/null || true
if [[ ! -s "$NOTES_FILE" ]]; then
    echo "Error: no CHANGELOG section for $VERSION." >&2
    exit 1
fi
echo "==> Release notes (from CHANGELOG):"
sed 's/^/    | /' "$NOTES_FILE" | head -12
echo "    | ..."

# ---------------------------------------------------------------------------
# 3. Git preconditions: clean tree, HEAD pushed, tag/release absent.
# ---------------------------------------------------------------------------
cd "$REPO_ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: working tree not clean. Commit or stash first." >&2
    git status --porcelain >&2
    exit 1
fi
git fetch --quiet origin
if ! git merge-base --is-ancestor HEAD origin/main; then
    echo "Error: HEAD is not pushed to origin/main. Push first so the tag" >&2
    echo "       points at a commit on the remote." >&2
    exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Error: tag $TAG already exists locally." >&2
    exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Error: GitHub release $TAG already exists." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Zip the .app (ditto preserves the stapled notarization ticket).
# ---------------------------------------------------------------------------
echo "==> Zipping .app"
run rm -f "$APP_ZIP"
run /usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"

# ---------------------------------------------------------------------------
# 5. Sparkle appcast.
#
# generate_appcast takes an "update archives folder" — it must contain
# ONLY the update zip (+ same-basename notes file), never $BIN_DIR which
# also holds the .dmg, Caterm.app, and SwiftPM build artifacts.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source "$ROOT/Scripts/lib-sparkle.sh"
# shellcheck disable=SC1091
source "$ROOT/Scripts/lib-md2html.sh"

echo "==> Verifying embedded Sparkle.framework signature (publish gate)"
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE_IN_APP" ]] || { echo "FAIL: $SPARKLE_IN_APP missing — rebuild with updated dist-package.sh" >&2; exit 1; }
codesign --verify --deep --strict "$SPARKLE_IN_APP" 2>/dev/null \
    || { echo "FAIL: embedded Sparkle.framework signature invalid" >&2; exit 1; }

# Key-pair gate: the appcast is signed with the Keychain private key,
# but clients verify with the public key baked into Info.plist
# (Scripts/sparkle_public_key.txt). A mismatch publishes a release that
# bricks auto-update for everyone with no rollback. Fail before the tag.
GEN_KEYS="$(find_sparkle_tool "$ROOT" generate_keys)" || exit 1
KEYCHAIN_PUB="$("$GEN_KEYS" -p 2>/dev/null | tr -d '[:space:]')"
COMMITTED_PUB="$(tr -d '[:space:]' < "$ROOT/Scripts/sparkle_public_key.txt")"
if [[ -z "$COMMITTED_PUB" ]]; then
    echo "FAIL: Scripts/sparkle_public_key.txt is empty." >&2
    exit 1
fi
if [[ -z "$KEYCHAIN_PUB" ]]; then
    echo "FAIL: no Sparkle private key in the login Keychain (run generate_keys)." >&2
    exit 1
fi
if [[ "$KEYCHAIN_PUB" != "$COMMITTED_PUB" ]]; then
    echo "FAIL: Sparkle key mismatch — the Keychain private key does NOT match" >&2
    echo "      Scripts/sparkle_public_key.txt. Signing now would ship an" >&2
    echo "      appcast no installed client can verify. Aborting before tag." >&2
    exit 1
fi
echo "==> Sparkle key-pair OK (Keychain private key matches committed public key)"

echo "==> Staging appcast inputs"
run rm -rf "$STAGE_DIR"
run mkdir -p "$STAGE_DIR"
run cp "$APP_ZIP" "$STAGE_DIR/$APP_ZIP_NAME"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] caterm_md_to_html $NOTES_FILE > $NOTES_HTML"
else
    caterm_md_to_html "$NOTES_FILE" > "$NOTES_HTML"
fi

GEN_APPCAST="$(find_sparkle_tool "$ROOT" generate_appcast)" || exit 1
echo "==> generate_appcast ($GEN_APPCAST)"
run "$GEN_APPCAST" "$STAGE_DIR"

if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ -f "$APPCAST" ]] || { echo "FAIL: generate_appcast did not produce $APPCAST" >&2; exit 1; }
    grep -q "sparkle:edSignature" "$APPCAST" \
        || { echo "FAIL: appcast.xml has no EdDSA signature (is the private key in the Keychain?)" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# 6. Tag + push.
# ---------------------------------------------------------------------------
echo "==> Tagging $TAG at $(git rev-parse --short HEAD)"
run git tag -a "$TAG" -m "Caterm $VERSION"
run git push origin "$TAG"

# ---------------------------------------------------------------------------
# 7. GitHub release + assets.
# ---------------------------------------------------------------------------
GH_ARGS=(release create "$TAG"
    --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)"
    --title "Caterm $VERSION"
    --notes-file "$NOTES_FILE"
    --target "$(git rev-parse HEAD)")
# Unreachable: --draft is rejected at startup (Sparkle latest-release feed).
[[ "$DRAFT" -eq 1 ]] && GH_ARGS+=(--draft)

echo "==> Creating GitHub release"
run gh "${GH_ARGS[@]}" "$DMG" "$APP_ZIP" "$APPCAST" "$NOTES_HTML"

echo
echo "============================================================"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo " dry-run complete — nothing was created."
else
    echo " Released $TAG"
    gh release view "$TAG" --json url -q .url 2>/dev/null || true
fi
echo "============================================================"
