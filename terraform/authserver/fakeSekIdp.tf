
resource "keycloak_realm" "fake_sekidp_realm" {
  count                       = var.use_fake_sekidp_testrealm ? 1 : 0
  realm                       = "fake-sekidp"
  display_name                = "Fake sekIdp"
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

####### Start HTTP Basic Auth Flow

resource "keycloak_authentication_flow" "http_basic_auth" {
  count       = var.use_fake_sekidp_testrealm ? 1 : 0
  realm_id    = keycloak_realm.fake_sekidp_realm[0].realm
  alias       = "HTTP Basic Auth Flow"
  description = "Single-step HTTP Basic Authentication flow"
  provider_id = "basic-flow"
}

resource "keycloak_authentication_execution" "http_basic_auth" {
  count             = var.use_fake_sekidp_testrealm ? 1 : 0
  realm_id          = keycloak_realm.fake_sekidp_realm[0].realm
  parent_flow_alias = keycloak_authentication_flow.http_basic_auth[0].alias
  authenticator     = "http-basic-authenticator"
  requirement       = "REQUIRED"
}

resource "keycloak_authentication_bindings" "browser" {
  count        = var.use_fake_sekidp_testrealm ? 1 : 0
  realm_id     = keycloak_realm.fake_sekidp_realm[0].realm
  browser_flow = keycloak_authentication_flow.http_basic_auth[0].alias
}

####### End HTTP Basic Auth Flow

resource "keycloak_openid_client" "fake_sekidp_client" {
  count                 = var.use_fake_sekidp_testrealm ? 1 : 0
  realm_id              = keycloak_realm.fake_sekidp_realm[0].realm
  access_type           = "CONFIDENTIAL"
  client_id             = "fake_sekidp_client"
  standard_flow_enabled = true
  valid_redirect_uris   = ["*"]
}

resource "keycloak_user" "sekidp_dummy_user" {
  count      = var.use_fake_sekidp_testrealm ? 1 : 0
  realm_id   = keycloak_realm.fake_sekidp_realm[0].realm
  username   = "dummy"
  email      = "dummy@localhost"
  first_name = "Dummy"
  last_name  = "Dummy"
  initial_password {
    value     = var.dummy_user_for_fake_sekidp_password
    temporary = false
  }
}

resource "keycloak_oidc_identity_provider" "fake_sekidp_identity_provider" {
  count              = var.use_fake_sekidp_testrealm ? 1 : 0
  alias              = "fake_sekidp"
  authorization_url  = "${var.keycloak_url}/realms/${keycloak_realm.fake_sekidp_realm[0].realm}/protocol/openid-connect/auth"
  token_url          = "${var.keycloak_url}/realms/${keycloak_realm.fake_sekidp_realm[0].realm}/protocol/openid-connect/token"
  logout_url         = "${var.keycloak_url}/realms/${keycloak_realm.fake_sekidp_realm[0].realm}/protocol/openid-connect/logout"
  user_info_url      = "${var.keycloak_url}/realms/${keycloak_realm.fake_sekidp_realm[0].realm}/protocol/openid-connect/userinfo"
  issuer             = "${var.keycloak_url}/realms/${keycloak_realm.fake_sekidp_realm[0].realm}"
  jwks_url           = "${var.keycloak_url}/realms/${keycloak_realm.fake_sekidp_realm[0].realm}/protocol/openid-connect/certs"
  validate_signature = true

  client_id     = keycloak_openid_client.fake_sekidp_client[0].client_id
  client_secret = keycloak_openid_client.fake_sekidp_client[0].client_secret
  realm         = keycloak_realm.zeta_realm.realm
}

####### Start IdP Redirect Flow
resource "keycloak_authentication_flow" "idp_redirect" {
  count       = var.use_fake_sekidp_testrealm ? 1 : 0
  realm_id    = keycloak_realm.zeta_realm.realm
  alias       = "IDP Redirect Flow"
  description = "Single-step IDP redirect flow defaulting to sekidp"
  provider_id = "basic-flow"
}

resource "keycloak_authentication_execution" "idp_redirect" {
  count             = var.use_fake_sekidp_testrealm ? 1 : 0
  realm_id          = keycloak_realm.zeta_realm.realm
  parent_flow_alias = keycloak_authentication_flow.idp_redirect[0].alias
  authenticator     = "identity-provider-redirector"
  requirement       = "REQUIRED"
}

resource "keycloak_authentication_execution_config" "idp_redirect" {
  count        = var.use_fake_sekidp_testrealm ? 1 : 0
  realm_id     = keycloak_realm.zeta_realm.realm
  execution_id = keycloak_authentication_execution.idp_redirect[0].id
  alias        = "sekidp-redirect-config"
  config = {
    defaultProvider = keycloak_oidc_identity_provider.fake_sekidp_identity_provider[0].alias
  }
}
####### End IdP Redirect Flow

resource "keycloak_openid_client" "dummy_client_for_sekidp_testing" {
  count                     = var.use_fake_sekidp_testrealm ? 1 : 0
  realm_id                  = keycloak_realm.zeta_realm.realm
  access_type               = "CONFIDENTIAL"
  client_id                 = "dummy_client_for_sekidp_testing"
  standard_flow_enabled     = true
  require_dpop_bound_tokens = false
  valid_redirect_uris       = ["*"]
  client_secret             = var.dummy_client_for_fake_sekidp_clientsecret
  authentication_flow_binding_overrides {
    browser_id = keycloak_authentication_flow.idp_redirect[0].id
  }
}
