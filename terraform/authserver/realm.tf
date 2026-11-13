resource "keycloak_realm" "zeta_realm" {
  realm                       = "zeta-guard"
  display_name                = "ζ Guard"
  enabled                     = true
  default_signature_algorithm = "ES256"
  login_with_email_allowed    = true
  revoke_refresh_token        = true
  refresh_token_max_reuse     = 0

  # Must outlive the policy's refresh-token TTL — see variables.tf.
  sso_session_idle_timeout = var.sso_session_idle_timeout
  sso_session_max_lifespan = var.sso_session_max_lifespan

  attributes = {
    webauthn_passwordless_require_resident_key          = "NOT_SPECIFIED"
    webauthn_passwordless_user_verification_requirement = "NOT_SPECIFIED"
    # Always created disabled — the effective value of var.use_vau_db_enc is
    # applied as the very last step by terraform_data.vau_db_enc (vau-db-enc.tf),
    # after every other realm resource exists. Client-side encryption must not
    # be active while the realm is still being configured.
    "spree.config.realm.enabled" = "false"
    # TTL in seconds of the request_uri of the outer PAR (only the SekIDP flow uses PAR).
    parRequestUriLifespan = "5"
  }

  lifecycle {
    # Managed by terraform_data.vau_db_enc, not by this resource.
    ignore_changes = [attributes["spree.config.realm.enabled"]]

    precondition {
      condition     = var.smtp_host == "" || (var.smtp_from != "" && can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.smtp_from)))
      error_message = "smtp_from must be a syntactically valid email address whenever smtp_host is set."
    }
  }

  # Email-binding OTP delivery (F1) — see docs/how-to_guides/How_to_configure_mailcatcher.md.
  # Omitted entirely when smtp_host is unset, matching today's no-SMTP-configured behavior.
  dynamic "smtp_server" {
    for_each = var.smtp_host != "" ? [1] : []
    content {
      host     = var.smtp_host
      port     = var.smtp_port
      from     = var.smtp_from
      starttls = var.smtp_starttls
      ssl      = var.smtp_ssl
      dynamic "auth" {
        for_each = var.smtp_auth_username != "" ? [1] : []
        content {
          username = var.smtp_auth_username
          password = var.smtp_auth_password
        }
      }
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

  # Authorization code flow only: rejects implicit and hybrid requests (also via PAR), even for clients registered
  # with response_type "token". auto-configure switches the implicit flow off at registration instead of rejecting it,
  # and must be set explicitly (Keycloak fails on a missing value).
  executor {
    name = "reject-implicit-grant"

    configuration = {
      auto-configure = "true"
    }
  }

  depends_on = [
    keycloak_realm.zeta_realm
  ]
}

# The fake sekIdP test realm is gone, and with it the second, mutually
# exclusive policy that exempted authorization_code clients from the DPoP
# binding. The remaining policy applies to any client, so it no longer needs a
# count — this keeps stages that ran without the test realm from recreating it.
# Can be dropped one release after the teardown.
moved {
  from = keycloak_realm_client_policy_profile_policy.zeta_client_policy_prod[0]
  to   = keycloak_realm_client_policy_profile_policy.zeta_client_policy
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

# Rejects an outer PAR that lacks a SekIDP flow parameter (SekIDP clients only).
resource "keycloak_realm_client_policy_profile" "zeta_outer_par_validation" {
  count       = var.enable_sekidp ? 1 : 0
  name        = "zeta-outer-par-validation"
  realm_id    = keycloak_realm.zeta_realm.id
  description = "Outer PAR must carry all SekIDP flow parameters."

  executor {
    name = "zeta-outer-par"
  }

  # Profiles and policies are written as one list per realm; serialize them to avoid lost updates.
  depends_on = [
    keycloak_realm.zeta_realm,
    keycloak_realm_client_policy_profile.zeta_client_policy_profile,
  ]
}

resource "keycloak_realm_client_policy_profile_policy" "zeta_outer_par_validation" {
  count       = var.enable_sekidp ? 1 : 0
  name        = "zeta-outer-par-validation"
  realm_id    = keycloak_realm.zeta_realm.id
  description = "Applies to clients with mandatory PAR (set for SekIDP clients at registration)."
  profiles = [
    keycloak_realm_client_policy_profile.zeta_outer_par_validation[0].name
  ]

  condition {
    name = "client-attributes"
    configuration = {
      is-negative-logic = false
      attributes        = jsonencode([{ key = "require.pushed.authorization.requests", value = "true" }])
    }
  }

  depends_on = [
    keycloak_realm.zeta_realm,
    keycloak_realm_client_policy_profile.zeta_outer_par_validation,
    keycloak_realm_client_policy_profile_policy.zeta_client_policy,
  ]
}
