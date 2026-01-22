resource "terraform_data" "max_user_clients_policy" {
  triggers_replace = {
    namespace = var.keycloak_namespace
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KEYCLOAK_PASSWORD = var.keycloak_password
    }

    command = <<-EOT
      set -euo pipefail

      PASSWORD="$KEYCLOAK_PASSWORD"
      if [ -z "$PASSWORD" ]; then
        SECRET_NAME="authserver-admin"
        SECRET_B64=$(kubectl -n ${var.keycloak_namespace} get secret "$SECRET_NAME" -o jsonpath='{.data.password}' 2>/dev/null || true)

        if [ -z "$SECRET_B64" ]; then
          echo "Unable to fetch Keycloak admin secret '$SECRET_NAME' in namespace '${var.keycloak_namespace}'" >&2
          exit 1
        fi

        if ! PASSWORD=$(printf '%s' "$SECRET_B64" | base64 --decode 2>/dev/null); then
          echo "Failed to decode Keycloak admin password from secret '$SECRET_NAME'" >&2
          exit 1
        fi
      fi

      POD=$(kubectl -n ${var.keycloak_namespace} get pods -l app=authserver -o jsonpath='{.items[0].metadata.name}')

      echo "Applying Max Clients Limit Policy for realm zeta-guard..."

      kubectl -n ${var.keycloak_namespace} exec $POD -- /opt/keycloak/bin/kcadm.sh config credentials \
        --server http://localhost:8080/auth \
        --realm master \
        --user admin \
        --password "$PASSWORD"

      POLICY_NAME="𝛇-Guard user clients limit"
      PROVIDER_ID="zeta-client-registration-policy"
      POLICY_ID=$(kubectl -n ${var.keycloak_namespace} exec $POD -- /opt/keycloak/bin/kcadm.sh get components -r zeta-guard \
        | jq -r ".[] | select(.providerId==\"$PROVIDER_ID\" and .name==\"$POLICY_NAME\") | .id")

      if [ -n "$POLICY_ID" ]; then
        echo "Policy exists (ID $POLICY_ID), updating"
        kubectl -n ${var.keycloak_namespace} exec $POD -- /opt/keycloak/bin/kcadm.sh update components/$POLICY_ID -r zeta-guard \
          -s name="$POLICY_NAME" \
          -s providerId="$PROVIDER_ID" \
          -s subType="anonymous" \
          -s providerType="org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy"
      else
        echo "Policy does not exist, creating"
        kubectl -n ${var.keycloak_namespace} exec $POD -- /opt/keycloak/bin/kcadm.sh create components -r zeta-guard \
          -s name="$POLICY_NAME" \
          -s providerId="$PROVIDER_ID" \
          -s subType="anonymous" \
          -s providerType="org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy"
      fi

      echo "Max Clients Limit Policy applied successfully."
    EOT
  }

  depends_on = [
    keycloak_realm.zeta_realm,
    data.external.delete_policies
  ]
}
