#!/usr/bin/env bash
set -euo pipefail

# Removes the ecdh-generated (ECDH-ES) entity-statement encryption KeyProvider
# from a Keycloak realm. Called by Terraform (sekidp.tf) on destroy.
# Required env: KC_URL, KC_REALM. Optional: KC_INSECURE ("true" skips TLS verify).
# Admin creds resolved by kc-admin-credentials.sh — never passed via tfstate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kc-admin-credentials.sh
source "${SCRIPT_DIR}/kc-admin-credentials.sh"
resolve_kc_credentials

CURL_OPTS=(-s -f --retry 3 --retry-delay 2)
if [[ "${KC_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

PROVIDER_ID="ecdh-generated"

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

# ── Find and remove entity-statement encryption key components ─────────────
COMPONENTS=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
  "${KC_URL}/admin/realms/${KC_REALM}/components?type=org.keycloak.keys.KeyProvider")

IDS=$(echo "$COMPONENTS" | jq -r --arg pid "$PROVIDER_ID" '.[] | select(.providerId == $pid) | .id')

REMOVED=0
for ID in $IDS; do
  echo "Removing entity-statement encryption key component: id=${ID}"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -X DELETE \
    "${KC_URL}/admin/realms/${KC_REALM}/components/${ID}"
  REMOVED=$((REMOVED + 1))
done

if [[ $REMOVED -eq 0 ]]; then
  echo "No entity-statement encryption key components found in realm ${KC_REALM}"
else
  echo "Removed ${REMOVED} entity-statement encryption key component(s) from realm ${KC_REALM}"
fi
