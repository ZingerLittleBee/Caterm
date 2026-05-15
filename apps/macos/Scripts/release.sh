#!/usr/bin/env bash
set -euo pipefail

# release.sh — one-command Distribution release pipeline.
#
# Orchestrates the full chain that was previously a manual sequence of
# env-var-laden invocations:
#
#   swift build -c release
#     → dev-codesign.sh --profile distribution   (sign inner binaries)
#       → dist-package.sh                         (assemble + re-seal + notarize + staple .app)
#         → build-dmg.sh                          (wrap + sign + notarize + staple .dmg)
#           → Gatekeeper assessment               (spctl + stapler validate)
#
# Defaults are tuned for the Caterm release identity so the common case is
# just `make release`. Everything is overridable via env.
#
# Identity / profile resolution (priority high → low):
#   CATERM_DIST_IDENTITY      env / arg
#                             else: the sole "Developer ID Application" in the
#                             login keychain (errors if 0 or >1 match)
#   CATERM_DIST_PROFILE_PATH  env / arg
#                             else first existing of:
#                               $ROOT/Caterm_Developer_ID.provisionprofile
#                               ~/Downloads/Caterm_Developer_ID.provisionprofile
#
# Notarization:
#   CATERM_NOTARY_PROFILE     keychain profile name for notarytool
#                             (default: caterm). One-time bootstrap (the
#                             app-specific password is read interactively —
#                             never store secrets in this repo):
#                               xcrun notarytool store-credentials caterm \
#                                   --apple-id <appleid-email> \
#                                   --team-id 9VM4RM39R3
#   --skip-notary             produce a signed-but-unnotarized .app/.dmg
#                             (valid for the two-Mac smoke on your own Macs;
#                             NOT for public distribution — Gatekeeper on
#                             other machines will block it).
#
# Output:
#   --skip-dmg                stop after the .app (no disk image)
#
# Versioning:
#   CATERM_DIST_VERSION       CFBundleShortVersionString (default: 1.0.0)
#   CATERM_DIST_BUILD         CFBundleVersion            (default: 1)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/Scripts"

SKIP_NOTARY=0
SKIP_DMG=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notary) SKIP_NOTARY=1; shift ;;
        --skip-dmg)    SKIP_DMG=1; shift ;;
        -h|--help)
            sed -n '3,55p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--skip-notary] [--skip-dmg]" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve signing identity.
# ---------------------------------------------------------------------------
if [[ -z "${CATERM_DIST_IDENTITY:-}" ]]; then
    # bash 3.2 (system bash) has no `mapfile`; fill the array by hand.
    _ids=()
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && _ids+=("$_line")
    done < <(
        security find-identity -v -p codesigning 2>/dev/null \
            | grep "Developer ID Application" \
            | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/' \
            | sort -u
    )
    if [[ ${#_ids[@]} -eq 0 ]]; then
        echo "Error: no \"Developer ID Application\" identity in the login keychain." >&2
        echo "Set CATERM_DIST_IDENTITY=... explicitly, or import the cert." >&2
        exit 1
    fi
    if [[ ${#_ids[@]} -gt 1 ]]; then
        echo "Error: multiple Developer ID Application identities found:" >&2
        printf '  %s\n' "${_ids[@]}" >&2
        echo "Disambiguate by setting CATERM_DIST_IDENTITY=... (CN or SHA-1)." >&2
        exit 1
    fi
    CATERM_DIST_IDENTITY="${_ids[0]}"
fi
export CATERM_DIST_IDENTITY

# ---------------------------------------------------------------------------
# Resolve provisioning profile.
# ---------------------------------------------------------------------------
if [[ -z "${CATERM_DIST_PROFILE_PATH:-}" ]]; then
    for _cand in \
        "$ROOT/Caterm_Developer_ID.provisionprofile" \
        "$HOME/Downloads/Caterm_Developer_ID.provisionprofile"; do
        if [[ -f "$_cand" ]]; then
            CATERM_DIST_PROFILE_PATH="$_cand"
            break
        fi
    done
fi
if [[ -z "${CATERM_DIST_PROFILE_PATH:-}" || ! -f "$CATERM_DIST_PROFILE_PATH" ]]; then
    echo "Error: Distribution provisioning profile not found." >&2
    echo "Set CATERM_DIST_PROFILE_PATH=/path/to/Caterm_Developer_ID.provisionprofile" >&2
    exit 1
fi
export CATERM_DIST_PROFILE_PATH

# ---------------------------------------------------------------------------
# Resolve / gate notary credentials.
# ---------------------------------------------------------------------------
NOTARY_PROFILE="${CATERM_NOTARY_PROFILE:-caterm}"
if [[ "$SKIP_NOTARY" -eq 1 ]]; then
    unset CATERM_NOTARY_PROFILE || true
    echo "==> --skip-notary: building signed but UNNOTARIZED artifacts."
    echo "    Valid for the two-Mac smoke on your own Macs only."
else
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
            >/dev/null 2>&1; then
        cat >&2 <<EOF
Error: notarytool keychain profile "$NOTARY_PROFILE" not found.

One-time bootstrap (the app-specific password is prompted securely; it is
NOT stored in this repo):

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id <your-apple-id-email> \\
      --team-id 9VM4RM39R3

Generate an app-specific password at https://account.apple.com → Sign-In
and Security → App-Specific Passwords.

Then re-run \`make release\`. To skip notarization (smoke build only):
  make release ARGS=--skip-notary
EOF
        exit 1
    fi
    export CATERM_NOTARY_PROFILE="$NOTARY_PROFILE"
fi

VERSION="${CATERM_DIST_VERSION:-1.0.0}"
export CATERM_DIST_VERSION="$VERSION"
export CATERM_DIST_BUILD="${CATERM_DIST_BUILD:-1}"

echo "============================================================"
echo " Caterm release pipeline"
echo "   version   : $VERSION (build $CATERM_DIST_BUILD)"
echo "   identity  : $CATERM_DIST_IDENTITY"
echo "   profile   : $CATERM_DIST_PROFILE_PATH"
echo "   notarize  : $([[ "$SKIP_NOTARY" -eq 1 ]] && echo 'NO (--skip-notary)' || echo "yes ($NOTARY_PROFILE)")"
echo "   dmg       : $([[ "$SKIP_DMG" -eq 1 ]] && echo 'NO (--skip-dmg)' || echo 'yes')"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Release build.
# ---------------------------------------------------------------------------
echo "==> [1/4] swift build -c release"
( cd "$ROOT" && swift build -c release )

# ---------------------------------------------------------------------------
# 2. Sign inner binaries with the distribution profile/entitlements.
# ---------------------------------------------------------------------------
echo "==> [2/4] dev-codesign.sh --profile distribution"
bash "$SCRIPTS/dev-codesign.sh" --profile distribution

# ---------------------------------------------------------------------------
# 3. Assemble + re-seal + (notarize + staple) the .app.
# ---------------------------------------------------------------------------
echo "==> [3/4] dist-package.sh"
bash "$SCRIPTS/dist-package.sh"

APP="$ROOT/.build/release/Caterm.app"

# ---------------------------------------------------------------------------
# 4. DMG (optional) + Gatekeeper assessment.
# ---------------------------------------------------------------------------
if [[ "$SKIP_DMG" -eq 1 ]]; then
    echo "==> [4/4] --skip-dmg: skipping disk image"
else
    echo "==> [4/4] build-dmg.sh"
    bash "$SCRIPTS/build-dmg.sh"
fi

echo "==> Gatekeeper assessment"
if [[ "$SKIP_NOTARY" -eq 1 ]]; then
    echo "    (skipped: --skip-notary builds are not stapled; spctl would"
    echo "     reject them off the build machine by design)"
else
    spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/    /' || {
        echo "FAIL: Gatekeeper rejected $APP" >&2
        exit 1
    }
    xcrun stapler validate "$APP" | sed 's/^/    /'
    DMG="$ROOT/.build/release/Caterm-${VERSION}.dmg"
    if [[ -f "$DMG" ]]; then
        xcrun stapler validate "$DMG" | sed 's/^/    /'
    fi
fi

echo
echo "============================================================"
echo " Release artifacts:"
echo "   $APP"
[[ "$SKIP_DMG" -eq 0 && -f "$ROOT/.build/release/Caterm-${VERSION}.dmg" ]] \
    && echo "   $ROOT/.build/release/Caterm-${VERSION}.dmg"
echo
echo " Next: two-Mac smoke per Manual/pre-ship-two-mac-smoke.md,"
echo "       then tag v${VERSION}."
echo "============================================================"
