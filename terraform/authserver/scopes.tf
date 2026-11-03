# Guard's own public base URL — falls back to the admin keycloak_url when no
# separate public audience is configured (stages where both hostnames match).
locals {
  guard_public_url = var.audience != "" ? var.audience : trimsuffix(var.keycloak_url, "/auth")

  # The names live here rather than in the resource's own for_each: `terraform
  # import` evaluates resources absent from the state as unknown, so a for_each
  # keyed on keycloak_openid_client_scope.notification_scopes aborts the whole
  # run with "Invalid for_each argument" before importing anything. See
  # docs/how-to_guides/How_to_upgrade_ZETA_Guard.md.
  # A_29974: notification.history.read exists only when history is enabled, so
  # tokens can't carry it (PEP /history/* then 403s). Must track
  # notificationService.historyEnabled.
  notification_scope_names = toset(concat([
    "notification.pusher.read",
    "notification.pusher.write",
    "notification.channel.read",
    "notification.channel.write",
  ], var.notification_history_enabled ? ["notification.history.read"] : []))
}

resource "keycloak_openid_client_scope" "zero_audience" {
  realm_id               = keycloak_realm.zeta_realm.id
  name                   = var.audience_scope_name
  description            = "Zero Trust scope for audience mapper"
  include_in_token_scope = true

  lifecycle {
    precondition {
      condition     = !contains(var.pdp_scopes, var.audience_scope_name)
      error_message = "audience_scope_name must not also appear in pdp_scopes; both resources would try to create the same Keycloak client scope."
    }
  }
}

# Resource-server (Fachdienst) audience — matches pepproxy.nginxConf.requiredAudience
# per stage, the audience the PEP enforces for Fachdienst-proxied routes.
resource "keycloak_openid_audience_protocol_mapper" "pdp_audience_mapper" {
  realm_id                 = keycloak_realm.zeta_realm.id
  client_scope_id          = keycloak_openid_client_scope.zero_audience.id
  name                     = "audience-mapper"
  included_custom_audience = local.guard_public_url
}

# introspection.token.claim / userinfo.token.claim are stated explicitly in both
# mappers below, although Keycloak stores nothing for them by default. Keycloak
# returns the *effective* values on read: with the keys absent,
# OIDCAttributeMapperHelper.includeInIntrospection/includeInUserInfo fall back to
# access.token.claim / id.token.claim, both "true" here. So every refresh read
# them as "true", planned to remove them, the apply removed them from storage,
# and the next read reported them again — a diff that never converged, on every
# stage. Stating them matches what Keycloak already applies, so nothing changes
# at runtime. The keycloak_openid_audience_protocol_mapper resources are typed
# and manage no free-form config map, so they were never affected.
resource "keycloak_generic_protocol_mapper" "zeta_guard_mapper" {
  realm_id        = keycloak_realm.zeta_realm.id
  client_scope_id = keycloak_openid_client_scope.zero_audience.id
  name            = "zeta-guard-mapper"
  protocol        = "openid-connect"
  protocol_mapper = "zeta-guard-accesstoken-mapper"
  config = {
    "access.tokenResponse.claim" = "true"
    "access.token.claim"         = "true"
    "id.token.claim"             = "true"
    # Both stated on purpose — see the note above this resource.
    "introspection.token.claim" = "true"
    "userinfo.token.claim"      = "true"
  }
}

resource "keycloak_generic_protocol_mapper" "zeta_guard_mapper_notification" {
  for_each        = local.notification_scope_names
  realm_id        = keycloak_realm.zeta_realm.id
  client_scope_id = keycloak_openid_client_scope.notification_scopes[each.key].id
  name            = "zeta-guard-mapper"
  protocol        = "openid-connect"
  protocol_mapper = "zeta-guard-accesstoken-mapper"
  config = {
    "access.tokenResponse.claim" = "true"
    "access.token.claim"         = "true"
    "id.token.claim"             = "true"
    # Both stated on purpose — see the note above this resource.
    "introspection.token.claim" = "true"
    "userinfo.token.claim"      = "true"
  }
}

resource "keycloak_openid_client_scope" "notification_scopes" {
  for_each               = local.notification_scope_names
  realm_id               = keycloak_realm.zeta_realm.id
  name                   = each.key
  description            = "A_29979: Notification Service scope '${each.key}'"
  include_in_token_scope = true
}

# Notification Service audience (A_29979) — Guard's public base URL + NS path
# prefix (pepproxy.wellKnownBase + notificationService.wellKnownResourceSuffix).
resource "keycloak_openid_audience_protocol_mapper" "notification_service_audience_mapper" {
  for_each                 = local.notification_scope_names
  realm_id                 = keycloak_realm.zeta_realm.id
  client_scope_id          = keycloak_openid_client_scope.notification_scopes[each.key].id
  name                     = "notification-service-audience-mapper"
  included_custom_audience = "${local.guard_public_url}${var.notification_service_resource_suffix}"
}

resource "keycloak_openid_client_scope" "pdp_scopes" {
  for_each               = toset(var.pdp_scopes)
  realm_id               = keycloak_realm.zeta_realm.id
  name                   = each.key
  description            = "Additional PDP scope '${each.key}'"
  include_in_token_scope = true
}

resource "keycloak_realm_optional_client_scopes" "pdp_optional_scopes" {
  realm_id = keycloak_realm.zeta_realm.id

  optional_scopes = concat(
    [keycloak_openid_client_scope.zero_audience.name],
    [for scope in keycloak_openid_client_scope.notification_scopes : scope.name],
    [for scope in keycloak_openid_client_scope.pdp_scopes : scope.name]
  )

  depends_on = [
    keycloak_openid_client_scope.zero_audience,
    keycloak_openid_client_scope.notification_scopes,
    keycloak_openid_client_scope.pdp_scopes
  ]
}

# ── Email-binding client scopes ──────────────────────────────────────────────
# Scopes the reduced token is down-scoped to while email binding (F1) is
# incomplete: zeta:email-binding (register email), zeta:email-verify (OTP).
# Assigned as OPTIONAL client scopes to mobile clients during DCR by
# ZetaGuardClientRegistrationPolicy.

resource "keycloak_openid_client_scope" "zeta_email_binding" {
  realm_id               = keycloak_realm.zeta_realm.id
  name                   = "zeta:email-binding"
  description            = "ZETA reduced scope for registering a new user email (I3)"
  include_in_token_scope = true
}

resource "keycloak_openid_client_scope" "zeta_email_verify" {
  realm_id               = keycloak_realm.zeta_realm.id
  name                   = "zeta:email-verify"
  description            = "ZETA reduced scope for resending/verifying the email OTP (I3)"
  include_in_token_scope = true
}

# The reduced binding token carries zeta:email-verify in both of its states (collect_email and
# verify_otp). With the Guard audience and the claim mapper on this scope the token passes the PEP
# like a regular access token, so the bind-email endpoints can be served behind the PEP as well.
# Same pattern as zeta:client-management below.
resource "keycloak_openid_audience_protocol_mapper" "zeta_email_verify_audience_mapper" {
  realm_id                 = keycloak_realm.zeta_realm.id
  client_scope_id          = keycloak_openid_client_scope.zeta_email_verify.id
  name                     = "audience-mapper"
  included_custom_audience = local.guard_public_url
}

resource "keycloak_generic_protocol_mapper" "zeta_guard_mapper_email_verify" {
  realm_id        = keycloak_realm.zeta_realm.id
  client_scope_id = keycloak_openid_client_scope.zeta_email_verify.id
  name            = "zeta-guard-mapper"
  protocol        = "openid-connect"
  protocol_mapper = "zeta-guard-accesstoken-mapper"
  config = {
    "access.tokenResponse.claim" = "true"
    "access.token.claim"         = "true"
    "id.token.claim"             = "true"
    # Both stated on purpose — see the note above zeta_guard_mapper.
    "introspection.token.claim" = "true"
    "userinfo.token.claim"      = "true"
  }
}

# ── Client-management client scope ───────────────────────────────────────────
# Authorizes the PEP-protected endpoints a mobile client uses to list/delete the
# clients of its identity and to change the identity's email. Assigned as an
# OPTIONAL client scope to mobile clients during DCR by
# ZetaGuardClientRegistrationPolicy — deliberately not a realm default, so
# stationary (SMC-B) clients never carry it.
# Carries its own copy of the claim mapper and the Guard audience (same pattern
# as the notification scopes), so the token satisfies the PEP whether or not
# audience_scope_name is requested alongside it.

resource "keycloak_openid_client_scope" "zeta_client_management" {
  realm_id               = keycloak_realm.zeta_realm.id
  name                   = "zeta:client-management"
  description            = "ZETA scope for managing the clients and email of the caller's identity"
  include_in_token_scope = true
}

resource "keycloak_openid_audience_protocol_mapper" "zeta_client_management_audience_mapper" {
  realm_id                 = keycloak_realm.zeta_realm.id
  client_scope_id          = keycloak_openid_client_scope.zeta_client_management.id
  name                     = "audience-mapper"
  included_custom_audience = local.guard_public_url
}

resource "keycloak_generic_protocol_mapper" "zeta_guard_mapper_client_management" {
  realm_id        = keycloak_realm.zeta_realm.id
  client_scope_id = keycloak_openid_client_scope.zeta_client_management.id
  name            = "zeta-guard-mapper"
  protocol        = "openid-connect"
  protocol_mapper = "zeta-guard-accesstoken-mapper"
  config = {
    "access.tokenResponse.claim" = "true"
    "access.token.claim"         = "true"
    "id.token.claim"             = "true"
    # Both stated on purpose — see the note above zeta_guard_mapper.
    "introspection.token.claim" = "true"
    "userinfo.token.claim"      = "true"
  }
}
