#!/usr/bin/env bash
set -euo pipefail

# Sets the realm attribute "spree.config.realm.enabled", which switches VAU DB
# client-side encryption on or off for the realm.
#
# Run as the last step of `make config` (see vau-db-enc.tf): the realm is always
# created with the flag disabled, so encryption only becomes active once the
# realm is fully configured.
#
# The attribute is merged into the existing realm representation — all other
# realm settings are preserved.
#
# Required environment variables:
#   KC_URL         — Keycloak base URL (e.g. https://host/auth)
#   KC_REALM       — Target realm (e.g. zeta-guard)
#   KC_USERNAME    — Admin username
#   KC_PASSWORD    — Admin password
#   VAU_DB_ENABLED — "true" or "false"
#
# Optional:
#   KC_INSECURE    — "true" to skip TLS verification

# --fail-with-body: non-2xx exits non-zero (so the `||` handlers below fire) but
# keeps the response body for diagnostics — plain -f would discard it.
CURL_OPTS=(-sS --fail-with-body --retry 3 --retry-delay 2)
if [[ "${KC_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

ATTRIBUTE="spree.config.realm.enabled"

case "${VAU_DB_ENABLED:-}" in
  true | false) ;;
  *)
    echo "ERROR: VAU_DB_ENABLED must be 'true' or 'false' (got '${VAU_DB_ENABLED:-}')" >&2
    exit 1
    ;;
esac

# ── Obtain an admin access token ──────────────────────────────────────────────
response=$(curl "${CURL_OPTS[@]}" -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  --data-urlencode "username=${KC_USERNAME}" \
  --data-urlencode "password=${KC_PASSWORD}") || {
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

# ── Read current realm representation ────────────────────────────────────────
realm_json=$(curl "${CURL_OPTS[@]}" -H "Authorization: Bearer ${TOKEN}" \
  "${KC_URL}/admin/realms/${KC_REALM}") || {
    echo "ERROR: Failed to read realm ${KC_REALM} from ${KC_URL}" >&2
    echo "${realm_json}" >&2
    exit 1
  }

current=$(echo "$realm_json" | jq -r --arg a "$ATTRIBUTE" '.attributes[$a] // "unset"')

if [[ "$current" == "${VAU_DB_ENABLED}" ]]; then
  echo "${ATTRIBUTE} already '${VAU_DB_ENABLED}' in realm ${KC_REALM}"
  exit 0
fi

# ── Merge the attribute and write the realm back ─────────────────────────────
echo "Setting ${ATTRIBUTE}=${VAU_DB_ENABLED} in realm ${KC_REALM} (was ${current})"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

echo "$realm_json" \
  | jq --arg a "$ATTRIBUTE" --arg v "${VAU_DB_ENABLED}" '.attributes[$a] = $v' > "$tmp"

# `|| true`: --fail-with-body makes curl exit non-zero on a non-2xx response, which
# under `set -e` would abort before the status check below can report the code.
code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -X PUT "${KC_URL}/admin/realms/${KC_REALM}" -d @"$tmp") || true

if [[ "$code" != "204" ]]; then
  echo "ERROR: Failed to set ${ATTRIBUTE} in realm ${KC_REALM} (HTTP ${code})" >&2
  exit 1
fi

echo "${ATTRIBUTE}=${VAU_DB_ENABLED} applied to realm ${KC_REALM}"
