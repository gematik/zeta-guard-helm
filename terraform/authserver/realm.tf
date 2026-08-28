resource "keycloak_realm" "zeta_realm" {
  realm                       = "zeta-guard"
  display_name                = "ζ Guard"
  enabled                     = true
  default_signature_algorithm = "ES256"
  login_with_email_allowed    = true
  revoke_refresh_token        = true
  refresh_token_max_reuse     = 0

  attributes = {
    webauthn_passwordless_require_resident_key          = "NOT_SPECIFIED"
    webauthn_passwordless_user_verification_requirement = "NOT_SPECIFIED"
    # Always created disabled — the effective value of var.use_vau_db_enc is
    # applied as the very last step by terraform_data.vau_db_enc (vau-db-enc.tf),
    # after every other realm resource exists. Client-side encryption must not
    # be active while the realm is still being configured.
    "spree.config.realm.enabled" = "false"
  }

  lifecycle {
    # Managed by terraform_data.vau_db_enc, not by this resource.
    ignore_changes = [attributes["spree.config.realm.enabled"]]
  }

  # Email-binding OTP delivery (F1) — see docs/how-to_guides/How_to_configure_mailcatcher.md.
  # Omitted entirely when smtp_host is unset, matching today's no-SMTP-configured behavior.
  dynamic "smtp_server" {
    for_each = var.smtp_host != "" ? [1] : []
    content {
      host = var.smtp_host
      port = var.smtp_port
      from = var.smtp_from
    }
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

resource "keycloak_realm_client_policy_profile_policy" "zeta_client_policy_prod" {
  // use this when use_fake_sekidp_testrealm = false
  count       = var.use_fake_sekidp_testrealm ? 0 : 1
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

resource "keycloak_realm_client_policy_profile_policy" "zeta_client_policy_testonly" {
  // use this when use_fake_sekidp_testrealm = true
  count       = var.use_fake_sekidp_testrealm ? 1 : 0
  name        = "zeta_client_policy_testonly"
  realm_id    = keycloak_realm.zeta_realm.id
  description = "ZETA Client Policy"
  profiles = [
    keycloak_realm_client_policy_profile.zeta_client_policy_profile.name
  ]

  condition {
    name = "grant-type"
    configuration = {
      "is-negative-logic" = "true"
      "grant_types"       = jsonencode(["authorization_code"])
    }
  }

  depends_on = [
    keycloak_realm.zeta_realm,
    keycloak_realm_client_policy_profile.zeta_client_policy_profile
  ]
}
