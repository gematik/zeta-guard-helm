#!/usr/bin/env bash
set -euo pipefail

# input from terraform external data source
input=$(cat)
namespace=$(echo "$input" | jq -r '.namespace')
password=$(echo "$input" | jq -r '.password // ""')
policie_names_delete=$(echo "$input" | jq -r '.delete_policies | fromjson')
policy_name_add=$(echo "$input" | jq -r '.policy_name_add')
provider_id_add=$(echo "$input" | jq -r '.provider_id_add')

results="{}"

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

# Wait for keycloak container to be ready
timeout=60
interval=2
elapsed=0
while true; do
  # determine the pod
  POD=$(kubectl -n "$namespace" get pods \
    -l app.kubernetes.io/name=authserver \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$POD" ]; then
    status=$(kubectl -n "$namespace" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="keycloak")].ready}')
    if [ "$status" = "true" ]; then
      break
    fi
  fi
  sleep $interval
  elapsed=$((elapsed + interval))
  if [ $elapsed -ge $timeout ]; then
    >&2 echo "Timeout: Keycloak-Container in pod '$POD' is not ready."
    kubectl -n "$namespace" describe pod "$POD"
    exit 1
  fi
done

# set keycloak credentials
kubectl -n "$namespace" exec "$POD" -- sh -c '
  export HOME=/tmp
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth \
    --realm master \
    --user admin \
    --password "'"$password"'" \
'

## delete policies ##
# iterate over all policies and delete them if they exist
policy_count_delete=$(echo "$policie_names_delete" | jq length)
for (( i=0; i<policy_count_delete; i++ )); do
  policy_name_delete=$(echo "$policie_names_delete" | jq -r ".[$i]")
  set +e
  # fetch policy by name
  POLICY_JSON_DELETE=$(kubectl -n "$namespace" exec "$POD" -- sh -c '
    export HOME=/tmp
    /opt/keycloak/bin/kcadm.sh \
      get components -r zeta-guard -F id,name -q name="'"$policy_name_delete"'"
  ' 2>/dev/null)
  STATUS=$?
  set -e

  if [ $STATUS -ne 0 ] || [ -z "$POLICY_JSON_DELETE" ] || [ "$POLICY_JSON_DELETE" = "[]" ] || [ "$POLICY_JSON_DELETE" = "null" ]; then
    result="No policy found, skipping."
  else
    POLICY_ID_DELETE=$(echo "$POLICY_JSON_DELETE" | jq -r '.[0].id')
    if [ -n "$POLICY_ID_DELETE" ] && [ "$POLICY_ID_DELETE" != "null" ]; then
      kubectl -n "$namespace" exec "$POD" -- sh -c '
        export HOME=/tmp
        /opt/keycloak/bin/kcadm.sh \
          delete components/"'"$POLICY_ID_DELETE"'" -r zeta-guard
      '
      result="Policy deleted successfully."
    else
      result="No policy found, skipping."
    fi
  fi

  results=$(echo "$results" | jq --arg key "$policy_name_delete" --arg val "$result" '. + {($key): $val}')
done

## add policy
# check existing policy
set +e
# fetch policy by name
POLICY_JSON_ADD=$(kubectl -n "$namespace" exec "$POD" -- sh -c "
  export HOME=/tmp
  /opt/keycloak/bin/kcadm.sh get components -r zeta-guard -F id,name -q name=\"$policy_name_add\" || echo '[]'
")
POLICY_JSON_ADD=$(echo "$POLICY_JSON_ADD" | jq -c '.')
if [ "$(echo "$POLICY_JSON_ADD" | jq length)" -gt 0 ]; then
  result="Policy found, skipping."
else
  kubectl -n "$namespace" exec "$POD" -- sh -c '
    export HOME=/tmp
    /opt/keycloak/bin/kcadm.sh \
      create components -r zeta-guard \
      -s name="'"$policy_name_add"'" \
      -s providerId="'"$provider_id_add"'" \
      -s subType="anonymous" \
      -s providerType="org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy"
  '
  result="Policy created successfully."
fi

results=$(echo "$results" | jq --arg key "$policy_name_add" --arg val "$result" '. + {($key): $val}')

## return the results as json
jq -n --argjson flat "$results" '$flat'
exit 0
