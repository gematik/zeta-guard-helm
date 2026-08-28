#!/usr/bin/env bash
set -euo pipefail

POLICY_NAME_ADD="𝛇-Guard user clients limit"
REALM="zeta-guard"

# input from terraform external data source
input=$(cat)
keycloak_url=$(echo "$input" | jq -r '.keycloak_url')
insecure_tls=$(echo "$input" | jq -r '.insecure_tls // "false"')
username=$(echo "$input" | jq -r '.username // "admin"')
password=$(echo "$input" | jq -r '.password // ""')
policy_names_delete=$(echo "$input" | jq -r '.delete_policies | fromjson')
provider_id_add=$(echo "$input" | jq -r '.provider_id_add')

results="{}"

# curl options
CURL_OPTS=("-s" "-f" "--retry" "3" "--retry-delay" "2")
if [ "$insecure_tls" = "true" ]; then
  CURL_OPTS+=("-k")
fi

# check required tools
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    >&2 echo "ERROR: '$cmd' is required but not found in PATH."
    exit 1
  fi
done

# get password
if [ -z "$password" ]; then
  if [ -n "${KEYCLOAK_PASSWORD:-}" ]; then
    password="$KEYCLOAK_PASSWORD"
  else
    >&2 echo "No password provided! Set via tfvars, input, or KEYCLOAK_PASSWORD env."
    exit 1
  fi
fi

# authenticate against Keycloak and obtain access token
TOKEN_RESPONSE=$(curl "${CURL_OPTS[@]}" \
  -X POST \
  -d "client_id=admin-cli" \
  --data-urlencode "username=$username" \
  --data-urlencode "password=$password" \
  -d "grant_type=password" \
  "$keycloak_url/realms/master/protocol/openid-connect/token" 2>&1) || {
    >&2 echo "ERROR: Failed to authenticate against Keycloak at $keycloak_url"
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
    "$keycloak_url/admin/realms/$REALM/components?name=$(jq -rn --arg n "$name" '$n|@uri')&type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy" \
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
        "$keycloak_url/admin/realms/$REALM/components/$POLICY_ID_DELETE" 2>/dev/null
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
    "$keycloak_url/admin/realms/$REALM/components" 2>/dev/null
  result="Policy created successfully."
fi

results=$(echo "$results" | jq --arg key "$POLICY_NAME_ADD" --arg val "$result" '. + {($key): $val}')

# return results
jq -n --argjson flat "$results" '$flat'
exit 0
