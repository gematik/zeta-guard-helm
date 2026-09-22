#!/usr/bin/env bash
set -euo pipefail

POLICY_NAME_ADD="𝛇-Guard user clients limit"
REALM="zeta-guard"

# Query (stdin JSON): kc_url, kc_insecure, kc_namespace, kc_admin_secret,
# delete_policies, provider_id_add.
# Admin creds are deliberately NOT part of the query — it is stored in tfstate
# and echoed in plan output. They are resolved at runtime by
# kc-admin-credentials.sh instead.
QUERY=$(cat)
KC_URL=$(echo "$QUERY" | jq -r '.kc_url')
KC_INSECURE=$(echo "$QUERY" | jq -r '.kc_insecure // "false"')
KC_NAMESPACE=$(echo "$QUERY" | jq -r '.kc_namespace // ""')
KC_ADMIN_SECRET=$(echo "$QUERY" | jq -r '.kc_admin_secret // ""')
policy_names_delete=$(echo "$QUERY" | jq -r '.delete_policies | fromjson')
provider_id_add=$(echo "$QUERY" | jq -r '.provider_id_add')

results="{}"

# check required tools
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    >&2 echo "ERROR: '$cmd' is required but not found in PATH."
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kc-admin-credentials.sh
source "${SCRIPT_DIR}/kc-admin-credentials.sh"
resolve_kc_credentials

# curl options
CURL_OPTS=("-s" "-f" "--retry" "3" "--retry-delay" "2")
if [ "$KC_INSECURE" = "true" ]; then
  CURL_OPTS+=("-k")
fi

# authenticate against Keycloak and obtain access token
TOKEN_RESPONSE=$(curl "${CURL_OPTS[@]}" \
  -X POST \
  -d "client_id=admin-cli" \
  --data-urlencode "username=$KC_USERNAME" \
  --data-urlencode "password=$KC_PASSWORD" \
  -d "grant_type=password" \
  "$KC_URL/realms/master/protocol/openid-connect/token" 2>&1) || {
    >&2 echo "ERROR: Failed to authenticate against Keycloak at $KC_URL"
    >&2 echo "$TOKEN_RESPONSE"
    exit 1
  }

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
  >&2 echo "ERROR: Failed to obtain access token from Keycloak."
  >&2 echo "$TOKEN_RESPONSE"
  exit 1
fi

# helper: GET components by name
get_component_by_name() {
  local name="$1"
  curl "${CURL_OPTS[@]}" \
    --oauth2-bearer "$ACCESS_TOKEN" \
    "$KC_URL/admin/realms/$REALM/components?name=$(jq -rn --arg n "$name" '$n|@uri')&type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy" \
    2>/dev/null || echo '[]'
}

# delete policies
policy_count_delete=$(echo "$policy_names_delete" | jq length)
for (( i=0; i<policy_count_delete; i++ )); do
  policy_name_delete=$(echo "$policy_names_delete" | jq -r ".[$i]")

  POLICY_JSON_DELETE=$(get_component_by_name "$policy_name_delete")

  if [ -z "$POLICY_JSON_DELETE" ] || [ "$POLICY_JSON_DELETE" = "[]" ] || [ "$POLICY_JSON_DELETE" = "null" ]; then
    result="No policy found, skipping."
  else
    POLICY_ID_DELETE=$(echo "$POLICY_JSON_DELETE" | jq -r '.[0].id')
    if [ -n "$POLICY_ID_DELETE" ] && [ "$POLICY_ID_DELETE" != "null" ]; then
      curl "${CURL_OPTS[@]}" \
        -X DELETE \
        --oauth2-bearer "$ACCESS_TOKEN" \
        "$KC_URL/admin/realms/$REALM/components/$POLICY_ID_DELETE" 2>/dev/null
      result="Policy deleted successfully."
    else
      result="No policy found, skipping."
    fi
  fi
  results=$(echo "$results" | jq --arg key "$policy_name_delete" --arg val "$result" '. + {($key): $val}')
done

# add policy
POLICY_JSON_ADD=$(get_component_by_name "$POLICY_NAME_ADD")
if [ "$(echo "$POLICY_JSON_ADD" | jq length)" -gt 0 ]; then
  result="Policy found, skipping."
else
  CREATE_PAYLOAD=$(jq -n \
    --arg name "$POLICY_NAME_ADD" \
    --arg providerId "$provider_id_add" \
    '{
      name: $name,
      providerId: $providerId,
      providerType: "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy",
      subType: "anonymous"
    }')

  curl "${CURL_OPTS[@]}" \
    -X POST \
    --oauth2-bearer "$ACCESS_TOKEN" \
    --json "$CREATE_PAYLOAD" \
    "$KC_URL/admin/realms/$REALM/components" 2>/dev/null
  result="Policy created successfully."
fi

results=$(echo "$results" | jq --arg key "$POLICY_NAME_ADD" --arg val "$result" '. + {($key): $val}')

# return results
jq -n --argjson flat "$results" '$flat'
exit 0
