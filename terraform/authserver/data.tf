data "kubernetes_secret" "keycloak_admin" {
  metadata {
    name      = "authserver-admin"
    namespace = var.keycloak_namespace
  }
}
