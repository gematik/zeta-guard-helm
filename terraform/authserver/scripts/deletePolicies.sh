#!/usr/bin/env bash
set -euo pipefail

# input from terraform external data source
input=$(cat)
namespace=$(echo "$input" | jq -r '.namespace')
policy_names=$(echo "$input" | jq -r '.policy_names | fromjson')
password=$(echo "$input" | jq -r '.password // ""')

if [ -z "$password" ]; then
  secret_name="authserver-admin"
  secret_b64=$(kubectl -n "$namespace" get secret "$secret_name" -o jsonpath='{.data.password}' 2>/dev/null || true)

  if [ -z "$secret_b64" ]; then
    >&2 echo "Unable to read password from Keycloak secret '$secret_name' in namespace '$namespace'."
    exit 1
  fi

  if ! password=$(printf '%s' "$secret_b64" | base64 --decode 2>/dev/null); then
    >&2 echo "Failed to decode password from Keycloak secret '$secret_name'."
    exit 1
  fi
fi
# determine the pod
POD=$(kubectl -n "$namespace" get pods -l app=authserver -o jsonpath='{.items[0].metadata.name}')

# set keycloak credentials
kubectl -n "$namespace" exec "$POD" -- /opt/keycloak/bin/kcadm.sh \
  config credentials \
  --server http://localhost:8080/auth \
  --realm master \
  --user admin \
  --password "$password"

results="{}"

# iterate over all policies and delete them if they exist
policy_count=$(echo "$policy_names" | jq length)
for (( i=0; i<policy_count; i++ )); do
  policy_name=$(echo "$policy_names" | jq -r ".[$i]")
  set +e
  # fetch policy by name
  POLICY_JSON=$(kubectl -n "$namespace" exec "$POD" -- /opt/keycloak/bin/kcadm.sh \
    get components -r zeta-guard -F id,name -q name="$policy_name" 2>/dev/null)
  STATUS=$?
  set -e

  if [ $STATUS -ne 0 ] || [ -z "$POLICY_JSON" ] || [ "$POLICY_JSON" = "[]" ] || [ "$POLICY_JSON" = "null" ]; then
    result="No $policy_name Policy found, skipping."
  else
    POLICY_ID=$(echo "$POLICY_JSON" | jq -r '.[0].id')
    if [ -n "$POLICY_ID" ] && [ "$POLICY_ID" != "null" ]; then
      kubectl -n "$namespace" exec "$POD" -- /opt/keycloak/bin/kcadm.sh \
        delete components/"$POLICY_ID" -r zeta-guard
      result="$policy_name Policy deleted successfully."
    else
      result="No $policy_name Policy found, skipping."
    fi
  fi

  results=$(echo "$results" | jq --arg key "$policy_name" --arg val "$result" '. + {($key): $val}')
done

## return the results as json
jq -n --argjson flat "$results" '$flat'
exit 0
