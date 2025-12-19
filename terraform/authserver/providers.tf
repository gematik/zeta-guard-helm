provider "kubernetes" {
  config_path = pathexpand(var.config_path)
}

provider "keycloak" {
  tls_insecure_skip_verify = var.insecure_tls
  url                      = var.keycloak_url
  realm                    = "master"
  client_id                = "admin-cli"
  client_secret            = ""
  username                 = data.kubernetes_secret_v1.keycloak_admin.data["username"]
  password                 = var.keycloak_password != "" ? var.keycloak_password : data.kubernetes_secret_v1.keycloak_admin.data["password"]
}
