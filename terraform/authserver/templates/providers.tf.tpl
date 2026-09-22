{{KUBERNETES_PROVIDER_BLOCK}}

provider "keycloak" {
  tls_insecure_skip_verify = var.insecure_tls
  url                      = var.keycloak_url
  realm                    = "master"
  client_id                = "admin-cli"
  client_secret            = ""
  # Provider configuration is a valid context for ephemeral values, so the
  # credentials reach Keycloak without ever being persisted. The former
  # check "local_credentials_provided" moved to variable "keycloak_password"
  # in variables.tf — a validation fails the run instead of only warning.
  username = var.keycloak_username
  password = var.keycloak_password
}
