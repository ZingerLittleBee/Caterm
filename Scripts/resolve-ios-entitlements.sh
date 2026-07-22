#!/bin/bash
# Resolve device entitlements from a decoded provisioning profile and reject
# profiles that do not authorize Caterm's exact bundle and shared capabilities.
set -euo pipefail

PROFILE_PLIST="${1:?decoded profile plist required}"
TEMPLATE="${2:?entitlements template required}"
OUTPUT="${3:?resolved entitlements output required}"
TEAM_ID="${4:?team identifier required}"
BUNDLE_ID="${5:?bundle identifier required}"
PB=/usr/libexec/PlistBuddy
EXPECTED_APP_ID="$TEAM_ID.$BUNDLE_ID"
EXPECTED_KEYCHAIN_GROUP="$TEAM_ID.caterm.shared"
EXPECTED_CONTAINER="iCloud.com.caterm.app"

profile_value() {
  "$PB" -c "Print :Entitlements:$1" "$PROFILE_PLIST" 2>/dev/null
}

require_equal() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(profile_value "$key" || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "[ios] provisioning profile $key mismatch: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

require_array_value() {
  local key="$1"
  local expected="$2"
  local index=0
  local actual
  while actual="$(profile_value "$key:$index" 2>/dev/null)"; do
    if [[ "$actual" == "$expected" ]]; then
      return
    fi
    index=$((index + 1))
  done
  echo "[ios] provisioning profile $key does not authorize '$expected'" >&2
  exit 1
}

require_equal "application-identifier" "$EXPECTED_APP_ID"
require_equal "com.apple.developer.team-identifier" "$TEAM_ID"
require_equal "com.apple.developer.ubiquity-kvstore-identifier" "$EXPECTED_APP_ID"
require_array_value "keychain-access-groups" "$EXPECTED_KEYCHAIN_GROUP"
require_array_value "com.apple.developer.icloud-container-identifiers" "$EXPECTED_CONTAINER"
require_array_value "com.apple.developer.icloud-services" "CloudKit"

APS_ENVIRONMENT="$(profile_value "aps-environment" || true)"
if [[ "$APS_ENVIRONMENT" != "development" && "$APS_ENVIRONMENT" != "production" ]]; then
  echo "[ios] provisioning profile has invalid aps-environment '$APS_ENVIRONMENT'" >&2
  exit 1
fi

CLOUDKIT_ENVIRONMENT="$(profile_value "com.apple.developer.icloud-container-environment" || true)"
if [[ -n "$CLOUDKIT_ENVIRONMENT" \
  && "$CLOUDKIT_ENVIRONMENT" != "Development" \
  && "$CLOUDKIT_ENVIRONMENT" != "Production" ]]; then
  echo "[ios] provisioning profile has invalid CloudKit environment '$CLOUDKIT_ENVIRONMENT'" >&2
  exit 1
fi

cp "$TEMPLATE" "$OUTPUT"
"$PB" -c "Set :application-identifier $EXPECTED_APP_ID" "$OUTPUT"
"$PB" -c "Set :aps-environment $APS_ENVIRONMENT" "$OUTPUT"
"$PB" -c \
  "Set :com.apple.developer.ubiquity-kvstore-identifier $EXPECTED_APP_ID" \
  "$OUTPUT"
"$PB" -c "Set :keychain-access-groups:0 $EXPECTED_KEYCHAIN_GROUP" "$OUTPUT"
if [[ -n "$CLOUDKIT_ENVIRONMENT" ]]; then
  "$PB" -c "Delete :com.apple.developer.icloud-container-environment" \
    "$OUTPUT" >/dev/null 2>&1 || true
  "$PB" -c \
    "Add :com.apple.developer.icloud-container-environment string $CLOUDKIT_ENVIRONMENT" \
    "$OUTPUT"
fi
