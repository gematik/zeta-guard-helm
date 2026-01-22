data "external" "delete_policies" {
  count = var.skip_external_resources ? 0 : 1

  program = [
    "/bin/bash",
    "scripts/deletePolicies.sh"
  ]

  query = {
    namespace    = var.keycloak_namespace
    password     = var.keycloak_password
    policy_names = jsonencode(["Trusted Hosts", "Max Clients Limit", "Consent Required"])
  }

  depends_on = [
    keycloak_realm.zeta_realm
  ]
}
