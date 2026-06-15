#!/usr/bin/env bash
set -euo pipefail

# Enforces ECC-only signing keys in one or more realms so that the JWKS endpoints
# (/auth/realms/<realm>/protocol/openid-connect/certs) contain only ECC keys.
#
# For each realm the script:
#   1. ensures an ES256 (ecdsa, P-256) key provider exists,
#   2. sets defaultSignatureAlgorithm = ES256,
#   3. re-authenticates, and
#   4. removes all RSA key providers (any providerId starting with "rsa").
#
# Why steps 1-3 are required (not just deletion):
#   - Keycloak immediately recreates "rsa-generated" in any realm whose
#     defaultSignatureAlgorithm is RS256 (e.g. the master realm), because the
#     realm needs an active signing key for that algorithm. Switching the realm
#     to ES256 (with an ES256 key present) stops the recreation.
#   - The admin access token is always issued by the master realm. Deleting the
#     master realm's active RS256 signing key invalidates the current token, so
#     we must re-authenticate (after switching master to ES256) before deleting.
#
# Required environment variables:
#   KC_URL       — Keycloak base URL (e.g. https://host/auth)
#   KC_REALMS    — Space-separated list of target realms (e.g. "zeta-guard master")
#   KC_USERNAME  — Admin username
#   KC_PASSWORD  — Admin password
#
# Optional:
#   KC_INSECURE  — "true" to skip TLS verification

CURL_OPTS=(-s --retry 3 --retry-delay 2)
if [[ "${KC_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

TOKEN=""

# ── Obtain an admin access token ──────────────────────────────────────────────
authenticate() {
  local response
  response=$(curl "${CURL_OPTS[@]}" -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=${KC_USERNAME}" \
    -d "password=${KC_PASSWORD}" 2>&1) || {
      echo "ERROR: Failed to authenticate against Keycloak at ${KC_URL}" >&2
      echo "${response}" >&2
      exit 1
    }

  TOKEN=$(echo "$response" | jq -r '.access_token')
  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "ERROR: Failed to obtain access token from Keycloak." >&2
    echo "${response}" >&2
    exit 1
  fi
}

# ── Ensure an ES256 (ecdsa P-256) key provider exists in the realm ────────────
ensure_es256_key() {
  local realm="$1"

  local components
  components=$(curl "${CURL_OPTS[@]}" -H "Authorization: Bearer ${TOKEN}" \
    "${KC_URL}/admin/realms/${realm}/components?type=org.keycloak.keys.KeyProvider")

  if echo "$components" | jq -e '.[] | select(.providerId == "ecdsa-generated")' >/dev/null; then
    echo "ES256 key provider already present in realm ${realm}"
    return
  fi

  # parentId of a realm-level component is the realm's internal id
  local realm_id
  realm_id=$(curl "${CURL_OPTS[@]}" -H "Authorization: Bearer ${TOKEN}" \
    "${KC_URL}/admin/realms/${realm}" | jq -r '.id')

  echo "Creating ES256 key provider in realm ${realm}"
  local code
  code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -X POST "${KC_URL}/admin/realms/${realm}/components" \
    -d "{
      \"name\": \"ES256-generated-key\",
      \"providerId\": \"ecdsa-generated\",
      \"providerType\": \"org.keycloak.keys.KeyProvider\",
      \"parentId\": \"${realm_id}\",
      \"config\": {
        \"priority\": [\"100\"],
        \"ecdsaEllipticCurveKey\": [\"P-256\"],
        \"active\": [\"true\"],
        \"enabled\": [\"true\"]
      }
    }")
  if [[ "$code" != "201" ]]; then
    echo "ERROR: Failed to create ES256 key provider in realm ${realm} (HTTP ${code})" >&2
    exit 1
  fi
}

# ── Ensure defaultSignatureAlgorithm = ES256 for the realm ────────────────────
ensure_default_sig_es256() {
  local realm="$1"

  local current
  current=$(curl "${CURL_OPTS[@]}" -H "Authorization: Bearer ${TOKEN}" \
    "${KC_URL}/admin/realms/${realm}" | jq -r '.defaultSignatureAlgorithm')

  if [[ "$current" == "ES256" ]]; then
    echo "defaultSignatureAlgorithm already ES256 in realm ${realm}"
    return
  fi

  echo "Setting defaultSignatureAlgorithm=ES256 in realm ${realm} (was ${current})"
  local tmp
  tmp=$(mktemp)
  curl "${CURL_OPTS[@]}" -H "Authorization: Bearer ${TOKEN}" "${KC_URL}/admin/realms/${realm}" \
    | jq '.defaultSignatureAlgorithm = "ES256"' > "$tmp"

  local code
  code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -X PUT "${KC_URL}/admin/realms/${realm}" -d @"$tmp")
  rm -f "$tmp"

  if [[ "$code" != "204" ]]; then
    echo "ERROR: Failed to set defaultSignatureAlgorithm in realm ${realm} (HTTP ${code})" >&2
    exit 1
  fi
}

# ── Delete all RSA key providers in the realm ─────────────────────────────────
remove_rsa_keys() {
  local realm="$1"

  local components
  components=$(curl "${CURL_OPTS[@]}" -H "Authorization: Bearer ${TOKEN}" \
    "${KC_URL}/admin/realms/${realm}/components?type=org.keycloak.keys.KeyProvider")

  local ids
  ids=$(echo "$components" | jq -r '.[] | select(.providerId | startswith("rsa")) | .id')

  local removed=0
  for id in $ids; do
    local provider_id
    provider_id=$(echo "$components" | jq -r --arg id "$id" '.[] | select(.id == $id) | .providerId')
    echo "Removing RSA key provider: realm=${realm}, providerId=${provider_id}, id=${id}"

    local code
    code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${TOKEN}" -X DELETE \
      "${KC_URL}/admin/realms/${realm}/components/${id}")

    # A 401 means the token was invalidated by deleting an active signing key —
    # re-authenticate and retry once.
    if [[ "$code" == "401" ]]; then
      authenticate
      code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${TOKEN}" -X DELETE \
        "${KC_URL}/admin/realms/${realm}/components/${id}")
    fi

    if [[ "$code" != "204" ]]; then
      echo "ERROR: Failed to delete key provider ${id} in realm ${realm} (HTTP ${code})" >&2
      exit 1
    fi
    removed=$((removed + 1))
  done

  if [[ $removed -eq 0 ]]; then
    echo "No RSA key providers found in realm ${realm}"
  else
    echo "Removed ${removed} RSA key provider(s) from realm ${realm}"
  fi
}

# ── Process all target realms ─────────────────────────────────────────────────
authenticate

for REALM in ${KC_REALMS}; do
  echo "── Enforcing ECC-only keys in realm: ${REALM} ──"
  ensure_es256_key "$REALM"
  ensure_default_sig_es256 "$REALM"
  authenticate    # token may have been signed by a now-changed realm key
  remove_rsa_keys "$REALM"
done
