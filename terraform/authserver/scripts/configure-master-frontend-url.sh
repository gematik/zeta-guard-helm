#!/usr/bin/env bash
set -euo pipefail

# Pins the master realm's frontend URL to the dedicated admin hostname.
#
# Why: with authserver.adminHostname set, the chart denies /auth/realms/master on
# the public hostname (see charts/zeta-guard/templates/pep/_pep-nginx-conf.tpl).
# The Admin Console is an OIDC client of the master realm and derives its
# authServerUrl from that realm's frontend URL, which by default follows
# Keycloak's --hostname, i.e. the public hostname. Without this pin the console's
# login redirect lands on the blocked path and the browser login breaks; the
# admin REST API (admin-cli against the admin hostname) is unaffected either way.
#
# Only the master realm is touched. The zeta-guard realm keeps the public issuer
# every access token carries.
#
# Script-based because keycloak/keycloak 5.9.0 has no resource for a single realm
# attribute. The only candidate, keycloak_realm, manages the whole realm: 20 of its
# attributes are optional-without-computed, so an apply resets every one the config
# leaves out — among them default_signature_algorithm, which remove-rsa-keys.sh sets
# to ES256 on this very realm, plus ssl_required, password_policy, revoke_refresh_token
# and `enabled` itself. Its six nested blocks (security_defenses, otp_policy,
# web_authn_*, smtp_server, internationalization) fall back to provider defaults the
# same way. Reproducing the master realm's full state in HCL, and keeping it in step
# with every provider release, is a far larger liability than this script.
#
# Required env: KC_URL, KC_FRONTEND_URL.
# Optional: KC_INSECURE ("true" skips TLS verify).
# Admin creds resolved by kc-admin-credentials.sh — never passed via tfstate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kc-admin-credentials.sh
source "${SCRIPT_DIR}/kc-admin-credentials.sh"
resolve_kc_credentials

: "${KC_URL:?KC_URL is required}"
: "${KC_FRONTEND_URL:?KC_FRONTEND_URL is required}"

CURL_OPTS=(-s -f --retry 3 --retry-delay 2)
if [[ "${KC_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

# ── Get admin token ──────────────────────────────────────────────────────────
TOKEN_RESPONSE=$(curl "${CURL_OPTS[@]}" -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  --data-urlencode "username=${KC_USERNAME}" \
  --data-urlencode "password=${KC_PASSWORD}" 2>&1) || {
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

# ── Skip when already pinned ─────────────────────────────────────────────────
CURRENT=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" "${KC_URL}/admin/realms/master" \
  | jq -r '.attributes.frontendUrl // ""')

if [[ "$CURRENT" == "$KC_FRONTEND_URL" ]]; then
  echo "master realm frontendUrl already set to ${KC_FRONTEND_URL}"
  exit 0
fi

# ── Pin it ───────────────────────────────────────────────────────────────────
# A realm update merges the attributes it carries; sending only frontendUrl
# leaves every other master-realm attribute untouched.
curl "${CURL_OPTS[@]}" -X PUT "${KC_URL}/admin/realms/master" \
  "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  --data "$(jq -n --arg url "$KC_FRONTEND_URL" \
    '{realm: "master", attributes: {frontendUrl: $url}}')"

echo "master realm frontendUrl set to ${KC_FRONTEND_URL} (was \"${CURRENT}\")"
