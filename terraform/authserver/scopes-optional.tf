resource "keycloak_openid_client_scope" "zero_audience" {
  realm_id               = keycloak_realm.zeta_realm.id
  name                   = "zero:audience"
  description            = "Zero Trust scope for audience mapper"
  include_in_token_scope = true
}

resource "keycloak_openid_audience_protocol_mapper" "pdp_audience_mapper" {
  realm_id                 = keycloak_realm.zeta_realm.id
  client_scope_id          = keycloak_openid_client_scope.zero_audience.id
  name                     = "audience-mapper"
  included_custom_audience = replace(var.keycloak_url, "/auth", "")
}

resource "keycloak_openid_client_scope" "zero_register" {
  realm_id               = keycloak_realm.zeta_realm.id
  name                   = "zero:register"
  description            = "Zero Trust scope for service registration"
  include_in_token_scope = true
}

resource "keycloak_openid_client_scope" "zero_manage" {
  realm_id               = keycloak_realm.zeta_realm.id
  name                   = "zero:manage"
  description            = "Zero Trust scope for policy and trust management"
  include_in_token_scope = true
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
    [
      keycloak_openid_client_scope.zero_audience.name,
      keycloak_openid_client_scope.zero_register.name,
      keycloak_openid_client_scope.zero_manage.name
    ],
    [for scope in keycloak_openid_client_scope.pdp_scopes : scope.name]
  )

  depends_on = [
    keycloak_openid_client_scope.zero_audience,
    keycloak_openid_client_scope.zero_register,
    keycloak_openid_client_scope.zero_manage,
    keycloak_openid_client_scope.pdp_scopes
  ]
}
