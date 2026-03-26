
data "external" "manage_policies" {
  count = var.skip_external_resources ? 0 : 1

  program = [
    "/bin/bash",
    "scripts/managePolicies.sh"
  ]

  query = {
    namespace = var.keycloak_namespace
    password  = var.keycloak_password

    delete_policies = jsonencode([
      "Trusted Hosts",
      "Max Clients Limit",
      "Consent Required"
    ])

    policy_name_add = "𝛇-Guard user clients limit"
    provider_id_add = "zeta-client-registration-policy"
  }

  depends_on = [keycloak_realm.zeta_realm]
}
