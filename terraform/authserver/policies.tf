
data "external" "manage_policies" {
  count = var.skip_external_resources ? 0 : 1

  program = [
    "/usr/bin/env",
    "bash",
    "scripts/managePolicies.sh"
  ]

  # No credentials in the query — it's stored in tfstate and echoed in plans.
  # The program re-reads admin creds at runtime (kc-admin-credentials.sh) from
  # kc_admin_secret in kc_namespace, or from TF_VAR_keycloak_* in local mode.
  query = {
    kc_url          = var.keycloak_url
    kc_insecure     = tostring(var.insecure_tls)
    kc_namespace    = var.keycloak_namespace
    kc_admin_secret = var.keycloak_admin_secret

    delete_policies = jsonencode([
      "Trusted Hosts",
      "Max Clients Limit",
      "Consent Required"
    ])

    provider_id_add = "zeta-client-registration-policy"
  }

  depends_on = [keycloak_realm.zeta_realm]
}
