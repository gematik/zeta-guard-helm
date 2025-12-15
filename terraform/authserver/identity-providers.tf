resource "keycloak_oidc_identity_provider" "smc_b" {
  realm        = keycloak_realm.zeta_realm.realm
  alias        = "zeta-smc-b-oidc"
  display_name = "SMC-B ID provider"
  provider_id  = "zeta-smc-b-oidc"
  enabled      = true

  client_id                               = "smc-b-client"
  client_secret                           = var.smc_b_client_secret
  authorization_url                       = "${var.keycloak_url}/realms/zeta-guard/protocol/openid-connect/auth"
  token_url                               = "${var.keycloak_url}/realms/zeta-guard/protocol/openid-connect/token"
  accepts_prompt_none_forward_from_client = false
  disable_user_info                       = false
  store_token                             = false

  backchannel_supported = false
  validate_signature    = false
  sync_mode             = "LEGACY"

  extra_config = {
    clientAuthMethod            = "client_secret_post"
    clientAssertionSigningAlg   = "ES256"
    requiresShortStateParameter = "false"
    sendIdTokenOnLogout         = "true"
  }

  depends_on = [keycloak_realm.zeta_realm]
}
