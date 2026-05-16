#!/usr/bin/env bash
set -euo pipefail

PROFILE=""
IDENTITY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="${2:-}"
            shift 2
            ;;
        --identity)
            IDENTITY="${2:-}"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: profile-identity-preflight.sh --profile <profile> [--identity <identity>]

Verifies that a Developer ID signing identity is one of the certificates
embedded in a Distribution provisioning profile.

When --identity is omitted, prints the matching local Developer ID SHA-1.
When --identity is supplied, exits 0 only if that identity matches the profile.
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$PROFILE" ]]; then
    echo "Error: --profile is required." >&2
    exit 1
fi
if [[ ! -f "$PROFILE" ]]; then
    echo "Error: provisioning profile not found at $PROFILE." >&2
    exit 1
fi

normalize_fingerprint() {
    tr '[:lower:]' '[:upper:]' | tr -d ':' | awk '{ gsub(/[[:space:]]/, ""); if (length($0) > 0) print }'
}

profile_fingerprints() {
    local profile="$1"
    local tmpdir profile_plist cert_dir
    tmpdir="$(mktemp -d)"
    profile_plist="$tmpdir/profile.plist"
    cert_dir="$tmpdir/certs"
    mkdir -p "$cert_dir"

    if ! security cms -D -i "$profile" > "$profile_plist"; then
        rm -rf "$tmpdir"
        echo "Error: failed to decode provisioning profile: $profile" >&2
        exit 1
    fi

    if ! python3 - "$profile_plist" "$cert_dir" <<'PY'
import pathlib
import plistlib
import sys

profile_path = pathlib.Path(sys.argv[1])
cert_dir = pathlib.Path(sys.argv[2])

with profile_path.open("rb") as handle:
    profile = plistlib.load(handle)

certificates = profile.get("DeveloperCertificates", [])
if not certificates:
    raise SystemExit("profile has no DeveloperCertificates")

for index, certificate in enumerate(certificates):
    (cert_dir / f"cert-{index}.der").write_bytes(certificate)
PY
    then
        rm -rf "$tmpdir"
        echo "Error: profile has no readable DeveloperCertificates." >&2
        exit 1
    fi

    for cert in "$cert_dir"/*.der; do
        openssl x509 -inform DER -in "$cert" -noout -fingerprint -sha1 \
            | sed -nE 's/^sha1 Fingerprint=//p' \
            | normalize_fingerprint
    done | sort -u

    rm -rf "$tmpdir"
}

developer_id_identities() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '
            /Developer ID Application/ {
                prefix = $1
                name = $2
                sub(/^[[:space:]]*[0-9]+\) /, "", prefix)
                gsub(/[[:space:]]/, "", prefix)
                print toupper(prefix) "\t" name
            }
        ' \
        | sort -u
}

identity_fingerprints() {
    local identity="$1"
    if [[ "$identity" =~ ^[A-Fa-f0-9:]{40,59}$ ]]; then
        local normalized
        normalized="$(printf '%s\n' "$identity" | normalize_fingerprint)"
        developer_id_identities | awk -F'\t' -v fp="$normalized" '$1 == fp { print $1 }'
        return
    fi

    developer_id_identities \
        | awk -F'\t' -v name="$identity" '$2 == name { print $1 }'
}

fingerprint_is_in_profile() {
    local needle="$1"
    local fp
    shift
    for fp in "$@"; do
        [[ "$fp" == "$needle" ]] && return 0
    done
    return 1
}

mapfile_fallback() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && printf '%s\0' "$line"
    done
}

profile_entries=()
while IFS= read -r -d '' fp; do
    profile_entries+=("$fp")
done < <(profile_fingerprints "$PROFILE" | mapfile_fallback)

if [[ ${#profile_entries[@]} -eq 0 ]]; then
    echo "Error: no Developer ID certificates found in profile $PROFILE." >&2
    exit 1
fi

if [[ -n "$IDENTITY" ]]; then
    identity_entries=()
    while IFS= read -r -d '' fp; do
        identity_entries+=("$fp")
    done < <(identity_fingerprints "$IDENTITY" | mapfile_fallback)

    if [[ ${#identity_entries[@]} -eq 0 ]]; then
        echo "Error: Developer ID identity not found in keychain: $IDENTITY" >&2
        exit 1
    fi

    for fp in "${identity_entries[@]}"; do
        if fingerprint_is_in_profile "$fp" "${profile_entries[@]}"; then
            printf '%s\n' "$fp"
            exit 0
        fi
    done

    echo "Error: Developer ID identity does not match the provisioning profile." >&2
    echo "  identity : $IDENTITY" >&2
    echo "  identity SHA-1(s): ${identity_entries[*]}" >&2
    echo "  profile  SHA-1(s): ${profile_entries[*]}" >&2
    echo "Download a Developer ID profile generated for this certificate, or sign with the matching certificate." >&2
    exit 1
fi

matches=()
while IFS=$'\t' read -r fp name; do
    if fingerprint_is_in_profile "$fp" "${profile_entries[@]}"; then
        matches+=("$fp")
    fi
done < <(developer_id_identities)

if [[ ${#matches[@]} -eq 0 ]]; then
    echo "Error: no local Developer ID Application identity matches the provisioning profile." >&2
    echo "  profile SHA-1(s): ${profile_entries[*]}" >&2
    echo "Import the matching Developer ID certificate/private key, or regenerate the profile for an installed certificate." >&2
    exit 1
fi

printf '%s\n' "${matches[0]}"
