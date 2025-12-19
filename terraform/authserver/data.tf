data "kubernetes_secret_v1" "keycloak_admin" {
  metadata {
    name      = "authserver-admin"
    namespace = var.keycloak_namespace
  }
}
