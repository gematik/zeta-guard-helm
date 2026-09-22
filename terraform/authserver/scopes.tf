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
}

# Resource-server (Fachdienst) audience — matches pepproxy.nginxConf.requiredAudience
# per stage, the audience the PEP enforces for Fachdienst-proxied routes.
resource "keycloak_openid_audience_protocol_mapper" "pdp_audience_mapper" {
  realm_id                 = keycloak_realm.zeta_realm.id
  client_scope_id          = keycloak_openid_client_scope.zero_audience.id
  name                     = "audience-mapper"
  included_custom_audience = local.guard_public_url
}

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
# Assigned as DEFAULT scopes to mobile clients during DCR by
# ZetaGuardClientRegistrationPolicy (not optional scopes), so stationary
# clients are unaffected.

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
