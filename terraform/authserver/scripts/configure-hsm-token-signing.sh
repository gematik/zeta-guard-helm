#!/usr/bin/env bash
set -euo pipefail

# Registers the zeta-hsm-token-signing KeyProvider component in a Keycloak realm.
# Called by Terraform (hsm-token-signing.tf) or standalone.
#
# Required environment variables:
#   KC_URL       — Keycloak base URL (e.g., https://zeta-cd.example.com/auth)
#   KC_REALM     — Target realm (e.g., zeta-guard)
#   KC_USERNAME  — Admin username
#   KC_PASSWORD  — Admin password
#   HSM_ENDPOINT — gRPC address of the HSM Proxy (e.g., hsm-sim:50051)
#   HSM_KEY_ID   — Key identifier in the HSM
#
# Optional:
#   KC_INSECURE  — "true" to skip TLS verification (default: false)
#   HSM_PRIORITY — Provider priority (default: 200)

CURL_OPTS=(-s -f --retry 3 --retry-delay 2)
if [[ "${KC_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

PRIORITY="${HSM_PRIORITY:-200}"
PROVIDER_ID="zeta-hsm-token-signing"
COMPONENT_NAME="hsm-token-signing"

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

# ── Check if component already exists ────────────────────────────────────────
EXISTING=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
  "${KC_URL}/admin/realms/${KC_REALM}/components?type=org.keycloak.keys.KeyProvider" \
  | jq --arg pid "$PROVIDER_ID" '[.[] | select(.providerId == $pid)] | length')

if [[ "$EXISTING" -gt 0 ]]; then
  # Update existing component
  COMPONENT_ID=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    "${KC_URL}/admin/realms/${KC_REALM}/components?type=org.keycloak.keys.KeyProvider" \
    | jq -r --arg pid "$PROVIDER_ID" '[.[] | select(.providerId == $pid)] | first | .id')

  echo "Updating existing HSM token signing component ${COMPONENT_ID} in realm ${KC_REALM}"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -X PUT \
    -H "Content-Type: application/json" \
    "${KC_URL}/admin/realms/${KC_REALM}/components/${COMPONENT_ID}" \
    -d "{
      \"id\": \"${COMPONENT_ID}\",
      \"name\": \"${COMPONENT_NAME}\",
      \"providerId\": \"${PROVIDER_ID}\",
      \"providerType\": \"org.keycloak.keys.KeyProvider\",
      \"config\": {
        \"priority\": [\"${PRIORITY}\"],
        \"endpoint\": [\"${HSM_ENDPOINT}\"],
        \"keyId\": [\"${HSM_KEY_ID}\"]
      }
    }"
else
  # Create new component
  echo "Creating HSM token signing component in realm ${KC_REALM}"

  # Get realm ID (parentId for the component)
  REALM_ID=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    "${KC_URL}/admin/realms/${KC_REALM}" \
    | jq -r '.id')

  curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -X POST \
    -H "Content-Type: application/json" \
    "${KC_URL}/admin/realms/${KC_REALM}/components" \
    -d "{
      \"name\": \"${COMPONENT_NAME}\",
      \"providerId\": \"${PROVIDER_ID}\",
      \"providerType\": \"org.keycloak.keys.KeyProvider\",
      \"parentId\": \"${REALM_ID}\",
      \"config\": {
        \"priority\": [\"${PRIORITY}\"],
        \"endpoint\": [\"${HSM_ENDPOINT}\"],
        \"keyId\": [\"${HSM_KEY_ID}\"]
      }
    }"
fi

echo "HSM token signing configured in realm ${KC_REALM} (endpoint=${HSM_ENDPOINT}, keyId=${HSM_KEY_ID}, priority=${PRIORITY})"
