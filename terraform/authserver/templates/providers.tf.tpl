{{KUBERNETES_PROVIDER_BLOCK}}

provider "keycloak" {
  tls_insecure_skip_verify = var.insecure_tls
  url                      = var.keycloak_url
  realm                    = "master"
  client_id                = "admin-cli"
  client_secret            = ""
  username = var.use_kubernetes ? (
    var.keycloak_username != "" ? var.keycloak_username : data.kubernetes_secret_v1.keycloak_admin[0].data["username"]
  ) : var.keycloak_username
  password = var.use_kubernetes ? (
    var.keycloak_password != "" ? var.keycloak_password : data.kubernetes_secret_v1.keycloak_admin[0].data["password"]
  ) : var.keycloak_password
}

check "local_credentials_provided" {
  assert {
    condition     = var.use_kubernetes || (var.keycloak_username != "" && var.keycloak_password != "")
    error_message = "keycloak_username and keycloak_password must be set when use_kubernetes = false."
  }
}
