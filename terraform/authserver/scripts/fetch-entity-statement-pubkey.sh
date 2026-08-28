#!/usr/bin/env bash
set -euo pipefail

# Terraform `data "external"` program: reads a realm KeyProvider's public key +
# kid from Keycloak's Admin REST API; emits {pubkey_pem, kid} JSON on stdout.
# Query (stdin JSON): kc_url, kc_realm, kc_insecure, kc_namespace,
# kc_admin_secret, key_provider_id.
# Admin creds resolved by kc-admin-credentials.sh, not passed in the query, so
# they never land in tfstate or the plan output.

QUERY=$(cat)

KC_URL=$(echo "$QUERY" | jq -r '.kc_url')
KC_REALM=$(echo "$QUERY" | jq -r '.kc_realm')
KC_INSECURE=$(echo "$QUERY" | jq -r '.kc_insecure')
KC_NAMESPACE=$(echo "$QUERY" | jq -r '.kc_namespace')
KC_ADMIN_SECRET=$(echo "$QUERY" | jq -r '.kc_admin_secret')
KEY_PROVIDER_ID=$(echo "$QUERY" | jq -r '.key_provider_id')

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kc-admin-credentials.sh
source "${SCRIPT_DIR}/kc-admin-credentials.sh"
resolve_kc_credentials

CURL_OPTS=(-s -f --retry 3 --retry-delay 2)
if [[ "${KC_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

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

# ── Find the key entry for this component ────────────────────────────────────
KEYS_RESPONSE=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
  "${KC_URL}/admin/realms/${KC_REALM}/keys")

KEY_ENTRY=$(echo "$KEYS_RESPONSE" | jq -c --arg pid "$KEY_PROVIDER_ID" '.keys[] | select(.providerId == $pid)')

if [[ -z "$KEY_ENTRY" ]]; then
  echo "ERROR: No key entry found for providerId ${KEY_PROVIDER_ID} in realm ${KC_REALM}." >&2
  echo "${KEYS_RESPONSE}" >&2
  exit 1
fi

KID=$(echo "$KEY_ENTRY" | jq -r '.kid')
PUBLIC_KEY_B64=$(echo "$KEY_ENTRY" | jq -r '.publicKey')

if [[ -z "$KID" || "$KID" == "null" || -z "$PUBLIC_KEY_B64" || "$PUBLIC_KEY_B64" == "null" ]]; then
  echo "ERROR: Key entry for providerId ${KEY_PROVIDER_ID} has no kid/publicKey (not active yet?)." >&2
  echo "${KEY_ENTRY}" >&2
  exit 1
fi

# ── Wrap the base64 DER SubjectPublicKeyInfo in PEM armor ────────────────────
# .publicKey is already base64 DER SubjectPublicKeyInfo; just re-wrap at 64
# chars/line. Avoids openssl, which the CI runner image doesn't ship.
PUBKEY_PEM=$(printf '%s\n%s\n%s\n' \
  "-----BEGIN PUBLIC KEY-----" \
  "$(echo "$PUBLIC_KEY_B64" | fold -w 64)" \
  "-----END PUBLIC KEY-----")

jq -n --arg pubkey_pem "$PUBKEY_PEM" --arg kid "$KID" \
  '{pubkey_pem: $pubkey_pem, kid: $kid}'
