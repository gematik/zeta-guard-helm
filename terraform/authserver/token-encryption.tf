resource "keycloak_realm_keystore_rsa_generated" "rsa" {
  realm_id = keycloak_realm.zeta_realm.id
  name     = "rsa-generated-key"
  enabled  = false
  active   = false
}

resource "keycloak_realm_keystore_ecdsa_generated" "es256" {
  realm_id           = keycloak_realm.zeta_realm.id
  name               = "ES256-generated-key"
  elliptic_curve_key = "P-256"
  priority           = 100
  enabled            = true
  active             = true
}
