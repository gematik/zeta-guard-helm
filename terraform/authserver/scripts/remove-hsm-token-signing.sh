#!/usr/bin/env bash
set -euo pipefail

# Removes the zeta-hsm-token-signing KeyProvider component from a Keycloak realm.
# Called by Terraform (hsm-token-signing.tf) on destroy.
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

PROVIDER_ID="zeta-hsm-token-signing"

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

# ── Find and remove HSM token signing components ────────────────────────────
COMPONENTS=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
  "${KC_URL}/admin/realms/${KC_REALM}/components?type=org.keycloak.keys.KeyProvider")

IDS=$(echo "$COMPONENTS" | jq -r --arg pid "$PROVIDER_ID" '.[] | select(.providerId == $pid) | .id')

REMOVED=0
for ID in $IDS; do
  echo "Removing HSM token signing component: id=${ID}"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -X DELETE \
    "${KC_URL}/admin/realms/${KC_REALM}/components/${ID}"
  REMOVED=$((REMOVED + 1))
done

if [[ $REMOVED -eq 0 ]]; then
  echo "No HSM token signing components found in realm ${KC_REALM}"
else
  echo "Removed ${REMOVED} HSM token signing component(s) from realm ${KC_REALM}"
  echo "Keycloak will auto-generate software signing keys on next token request."
fi
