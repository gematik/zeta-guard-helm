resource "keycloak_realm" "zeta_realm" {
  realm                       = var.realm_name
  display_name                = var.realm_display_name
  enabled                     = true
  default_signature_algorithm = "ES256"
  login_with_email_allowed    = true
  revoke_refresh_token        = true
  refresh_token_max_reuse     = 0

  attributes = {
    webauthn_passwordless_require_resident_key          = "NOT_SPECIFIED"
    webauthn_passwordless_user_verification_requirement = "NOT_SPECIFIED"
  }
}

resource "keycloak_realm_client_policy_profile" "zeta_client_policy_profile" {
  name        = "zeta_client_policy_profile"
  realm_id    = keycloak_realm.zeta_realm.id
  description = "Profile for ZETA Clients"

  executor {
    name = "dpop-bind-enforcer"

    configuration = {
      auto-configure = "true"
    }
  }

  depends_on = [
    keycloak_realm.zeta_realm
  ]
}

resource "keycloak_realm_client_policy_profile_policy" "zeta_client_policy" {
  name        = "zeta_client_policy"
  realm_id    = keycloak_realm.zeta_realm.id
  description = "ZETA Client Policy"
  profiles = [
    keycloak_realm_client_policy_profile.zeta_client_policy_profile.name
  ]

  condition {
    name = "any-client"
  }

  depends_on = [
    keycloak_realm.zeta_realm,
    keycloak_realm_client_policy_profile.zeta_client_policy_profile
  ]
}
