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
# Local release environment:
#   sign/env.sh                 optional gitignored environment file loaded
#                               before resolving identities, profiles,
#                               notarization, and version settings. Supports
#                               POSIX `export NAME=value` and fish
#                               `set -x NAME value` syntax.
#
# Identity / profile resolution (priority high → low):
#   CATERM_DIST_IDENTITY      env / arg
#                             else: the local "Developer ID Application"
#                             identity whose SHA-1 appears in the provisioning
#                             profile
#   CATERM_DIST_PROFILE_PATH  env / arg
#                             else first existing of:
#                               $ROOT/sign/Caterm_Developer_ID.provisionprofile
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
#                                   --team-id <your-team-id>
#   CATERM_NOTARY_APPLE_ID    Apple ID for direct notarytool auth. Falls back
#   CATERM_NOTARY_PASSWORD    to APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID
#   CATERM_NOTARY_TEAM_ID     when those are loaded from sign/env.sh.
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
RELEASE_ENV="$ROOT/sign/env.sh"

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

unquote_env_value() {
    local value
    value="$(trim "$1")"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

load_release_env() {
    local env_file="$1"
    local line name value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

        if [[ "$line" =~ ^set[[:space:]]+-e[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
            unset "${BASH_REMATCH[1]}" || true
            continue
        elif [[ "$line" =~ ^set[[:space:]]+-(x|gx)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+(.+)$ ]]; then
            name="${BASH_REMATCH[2]}"
            value="$(unquote_env_value "${BASH_REMATCH[3]}")"
        elif [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            value="$(unquote_env_value "${BASH_REMATCH[2]}")"
        elif [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            value="$(unquote_env_value "${BASH_REMATCH[2]}")"
        else
            echo "Warning: skipping unsupported line in $env_file" >&2
            continue
        fi

        export "$name=$value"
    done < "$env_file"
}

if [[ -f "$RELEASE_ENV" ]]; then
    echo "==> Loading release environment from $RELEASE_ENV"
    load_release_env "$RELEASE_ENV"
fi

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
# Resolve provisioning profile.
# ---------------------------------------------------------------------------
if [[ -z "${CATERM_DIST_PROFILE_PATH:-}" ]]; then
    for _cand in \
        "$ROOT/sign/Caterm_Developer_ID.provisionprofile" \
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
# Resolve / validate signing identity.
#
# AMFI requires the binary's signing certificate to be one of the profile's
# DeveloperCertificates. Notarization can still succeed when these disagree,
# but launchd rejects the app with POSIX 163 / "Security policy issue".
# ---------------------------------------------------------------------------
if [[ -z "${CATERM_DIST_IDENTITY:-}" ]]; then
    CATERM_DIST_IDENTITY="$(bash "$SCRIPTS/profile-identity-preflight.sh" \
        --profile "$CATERM_DIST_PROFILE_PATH")"
else
    bash "$SCRIPTS/profile-identity-preflight.sh" \
        --profile "$CATERM_DIST_PROFILE_PATH" \
        --identity "$CATERM_DIST_IDENTITY" \
        >/dev/null
fi
export CATERM_DIST_IDENTITY

# ---------------------------------------------------------------------------
# Resolve / gate notary credentials.
# ---------------------------------------------------------------------------
if [[ -z "${CATERM_NOTARY_APPLE_ID:-}" && -n "${APPLE_ID:-}" ]]; then
    CATERM_NOTARY_APPLE_ID="$APPLE_ID"
fi
if [[ -z "${CATERM_NOTARY_APPLE_ID:-}" && -n "${APPLE_EMAIL:-}" ]]; then
    CATERM_NOTARY_APPLE_ID="$APPLE_EMAIL"
fi
if [[ -z "${CATERM_NOTARY_PASSWORD:-}" && -n "${APPLE_PASSWORD:-}" ]]; then
    CATERM_NOTARY_PASSWORD="$APPLE_PASSWORD"
fi
if [[ -z "${CATERM_NOTARY_TEAM_ID:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    CATERM_NOTARY_TEAM_ID="$APPLE_TEAM_ID"
fi

HAS_DIRECT_NOTARY=0
if [[ -n "${CATERM_NOTARY_APPLE_ID:-}" \
      && -n "${CATERM_NOTARY_PASSWORD:-}" \
      && -n "${CATERM_NOTARY_TEAM_ID:-}" ]]; then
    HAS_DIRECT_NOTARY=1
fi

NOTARY_PROFILE="${CATERM_NOTARY_PROFILE:-}"
if [[ -z "$NOTARY_PROFILE" && "$HAS_DIRECT_NOTARY" -eq 0 ]]; then
    NOTARY_PROFILE="caterm"
fi

if [[ "$SKIP_NOTARY" -eq 1 ]]; then
    unset CATERM_NOTARY_PROFILE || true
    echo "==> --skip-notary: building signed but UNNOTARIZED artifacts."
    echo "    Valid for the two-Mac smoke on your own Macs only."
else
    if [[ -n "$NOTARY_PROFILE" ]]; then
        if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
                >/dev/null 2>&1; then
            cat >&2 <<EOF
Error: notarytool keychain profile "$NOTARY_PROFILE" not found.

One-time bootstrap (the app-specific password is prompted securely; it is
NOT stored in this repo):

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id <your-apple-id-email> \\
      --team-id <your-team-id>

Generate an app-specific password at https://account.apple.com → Sign-In
and Security → App-Specific Passwords.

Alternatively, put direct credentials in sign/env.sh:

  set -x APPLE_ID <your-apple-id-email>
  set -x APPLE_PASSWORD <app-specific-password>
  set -x APPLE_TEAM_ID <your-team-id>

Then re-run \`make release\`. To skip notarization (smoke build only):
  make release ARGS=--skip-notary
EOF
            exit 1
        fi
        export CATERM_NOTARY_PROFILE="$NOTARY_PROFILE"
        NOTARY_DISPLAY="yes ($NOTARY_PROFILE)"
    elif [[ "$HAS_DIRECT_NOTARY" -eq 1 ]]; then
        if ! xcrun notarytool history \
                --apple-id "$CATERM_NOTARY_APPLE_ID" \
                --password "$CATERM_NOTARY_PASSWORD" \
                --team-id "$CATERM_NOTARY_TEAM_ID" \
                >/dev/null 2>&1; then
            echo "Error: direct notarytool credentials from sign/env.sh were rejected." >&2
            echo "Check APPLE_ID, APPLE_PASSWORD, and APPLE_TEAM_ID." >&2
            exit 1
        fi
        export CATERM_NOTARY_APPLE_ID
        export CATERM_NOTARY_PASSWORD
        export CATERM_NOTARY_TEAM_ID
        unset CATERM_NOTARY_PROFILE || true
        NOTARY_DISPLAY="yes (direct credentials)"
    else
        cat >&2 <<EOF
Error: notarization credentials are incomplete.

One-time bootstrap (the app-specific password is prompted securely; it is
NOT stored in this repo):

  xcrun notarytool store-credentials caterm \\
      --apple-id <your-apple-id-email> \\
      --team-id <your-team-id>

Generate an app-specific password at https://account.apple.com → Sign-In
and Security → App-Specific Passwords.

Then re-run \`make release\`. To skip notarization (smoke build only):
  make release ARGS=--skip-notary
EOF
        exit 1
    fi
fi

# Version/build are derived from CHANGELOG.md (single source of truth).
# Sparkle compares CFBundleVersion; a constant build number means
# auto-update never detects a new release.
# shellcheck disable=SC1091
source "$SCRIPTS/lib-version.sh"
VERSION="${CATERM_DIST_VERSION:-$(caterm_changelog_version "$ROOT/CHANGELOG.md")}"
export CATERM_DIST_VERSION="$VERSION"
export CATERM_DIST_BUILD="${CATERM_DIST_BUILD:-$(caterm_build_number "$VERSION")}"

echo "============================================================"
echo " Caterm release pipeline"
echo "   version   : $VERSION (build $CATERM_DIST_BUILD)"
echo "   identity  : $CATERM_DIST_IDENTITY"
echo "   profile   : $CATERM_DIST_PROFILE_PATH"
echo "   notarize  : $([[ "$SKIP_NOTARY" -eq 1 ]] && echo 'NO (--skip-notary)' || echo "$NOTARY_DISPLAY")"
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
