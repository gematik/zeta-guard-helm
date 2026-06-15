resource "keycloak_realm_keystore_ecdsa_generated" "es256" {
  realm_id           = keycloak_realm.zeta_realm.id
  name               = "ES256-generated-key"
  elliptic_curve_key = "P-256"
  priority           = 100
  enabled            = true
  active             = true
}

resource "terraform_data" "remove_rsa_keys" {
  triggers_replace = {
    realm_id    = keycloak_realm.zeta_realm.internal_id
    realms      = "${keycloak_realm.zeta_realm.realm} master"
    script_hash = filesha256("${path.module}/scripts/remove-rsa-keys.sh")
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/remove-rsa-keys.sh"

    environment = {
      KC_URL    = var.keycloak_url
      KC_REALMS = "${keycloak_realm.zeta_realm.realm} master"
      KC_USERNAME = var.use_kubernetes ? (var.keycloak_username != "" ? var.keycloak_username :
      data.kubernetes_secret_v1.keycloak_admin[0].data["username"]) : var.keycloak_username
      KC_PASSWORD = var.use_kubernetes ? (var.keycloak_password != "" ? var.keycloak_password :
      data.kubernetes_secret_v1.keycloak_admin[0].data["password"]) : var.keycloak_password
      KC_INSECURE = var.insecure_tls ? "true" : "false"
    }
  }

  depends_on = [keycloak_realm.zeta_realm]
}
