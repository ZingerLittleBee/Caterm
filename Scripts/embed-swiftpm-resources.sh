#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <SwiftPM binary directory> <app resource directory>" >&2
    exit 64
fi

BIN_DIR="$1"
DESTINATION="$2"

shopt -s nullglob
RESOURCE_BUNDLES=("$BIN_DIR"/*.bundle)
shopt -u nullglob

if [[ "${#RESOURCE_BUNDLES[@]}" -eq 0 ]]; then
    echo "Error: no SwiftPM resource bundles found in $BIN_DIR" >&2
    exit 1
fi

mkdir -p "$DESTINATION"
for bundle in "${RESOURCE_BUNDLES[@]}"; do
    name="$(basename "$bundle")"
    echo "==> Embedding SwiftPM resource bundle $name"
    /usr/bin/ditto "$bundle" "$DESTINATION/$name"
done
