
data "external" "manage_policies" {
  count = var.skip_external_resources ? 0 : 1

  program = [
    "/usr/bin/env",
    "bash",
    "scripts/managePolicies.sh"
  ]

  query = {
    keycloak_url = var.keycloak_url
    insecure_tls = tostring(var.insecure_tls)
    username = var.use_kubernetes ? (
      var.keycloak_username != "" ? var.keycloak_username : data.kubernetes_secret_v1.keycloak_admin[0].data["username"]
    ) : var.keycloak_username
    password = var.keycloak_password != "" ? var.keycloak_password : (
      var.use_kubernetes ? data.kubernetes_secret_v1.keycloak_admin[0].data["password"] : ""
    )

    delete_policies = jsonencode([
      "Trusted Hosts",
      "Max Clients Limit",
      "Consent Required"
    ])

    provider_id_add = "zeta-client-registration-policy"
  }

  depends_on = [keycloak_realm.zeta_realm]
}
