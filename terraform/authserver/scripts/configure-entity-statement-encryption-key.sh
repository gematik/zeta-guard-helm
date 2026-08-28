#!/usr/bin/env bash
set -euo pipefail

# Registers the ecdh-generated (ECDH-ES) entity-statement encryption KeyProvider
# in a Keycloak realm. Script-based (like configure-hsm-token-signing.sh)
# because the keycloak provider v5.8.0 has no native resource for this type.
# Required env: KC_URL, KC_REALM, KC_USERNAME, KC_PASSWORD.
# Optional: KC_INSECURE ("true" skips TLS verify), KEY_PRIORITY (default 100).

CURL_OPTS=(-s -f --retry 3 --retry-delay 2)
if [[ "${KC_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

PRIORITY="${KEY_PRIORITY:-100}"
PROVIDER_ID="ecdh-generated"
COMPONENT_NAME="ecdh-generated"

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

  echo "Updating existing entity-statement encryption key component ${COMPONENT_ID} in realm ${KC_REALM}"
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
        \"ecdhAlgorithm\": [\"ECDH-ES\"]
      }
    }"
else
  # Create new component
  echo "Creating entity-statement encryption key component in realm ${KC_REALM}"

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
        \"ecdhAlgorithm\": [\"ECDH-ES\"]
      }
    }"
fi

echo "Entity-statement encryption key (ecdh-generated) configured in realm ${KC_REALM} (priority=${PRIORITY})"
