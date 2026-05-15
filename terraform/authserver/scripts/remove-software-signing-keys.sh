#!/usr/bin/env bash
set -euo pipefail

# Removes software signing key providers (rsa-generated, ecdsa-generated) from a realm.
# Called by Terraform (hsm-token-signing.tf) after HSM key registration.
#
# Required environment variables:
#   KC_URL       — Keycloak base URL
#   KC_REALM     — Target realm
#   KC_USERNAME  — Admin username
#   KC_PASSWORD  — Admin password
#
# Optional:
#   KC_INSECURE  — "true" to skip TLS verification

CURL_OPTS=(-s -f --retry 3 --retry-delay 2)
if [[ "${KC_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

SOFTWARE_PROVIDER_IDS=("rsa-generated" "ecdsa-generated")

# ── Get admin token ──────────────────────────────────────────────────────────
TOKEN_RESPONSE=$(curl "${CURL_OPTS[@]}" -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=${KC_USERNAME}" \
  -d "password=${KC_PASSWORD}" 2>&1) || {
    echo "ERROR: Failed to authenticate against Keycloak at ${KC_URL}" >&2
    echo "${TOKEN_RESPONSE}" >&2
    exit 1
  }

TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Failed to obtain access token from Keycloak." >&2
  echo "${TOKEN_RESPONSE}" >&2
  exit 1
fi

AUTH=(-H "Authorization: Bearer ${TOKEN}")

# ── Find and remove software signing keys ────────────────────────────────────
COMPONENTS=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
  "${KC_URL}/admin/realms/${KC_REALM}/components?type=org.keycloak.keys.KeyProvider")

REMOVED=0
for PID in "${SOFTWARE_PROVIDER_IDS[@]}"; do
  IDS=$(echo "$COMPONENTS" | jq -r --arg pid "$PID" '.[] | select(.providerId == $pid) | select(.config.keyUse == null or (.config.keyUse | first) != "enc") | .id')

  for ID in $IDS; do
    echo "Removing software signing key: providerId=${PID}, id=${ID}"
    curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
      -X DELETE \
      "${KC_URL}/admin/realms/${KC_REALM}/components/${ID}"
    REMOVED=$((REMOVED + 1))
  done
done

if [[ $REMOVED -eq 0 ]]; then
  echo "No software signing keys found in realm ${KC_REALM}"
else
  echo "Removed ${REMOVED} software signing key(s) from realm ${KC_REALM}"
fi
