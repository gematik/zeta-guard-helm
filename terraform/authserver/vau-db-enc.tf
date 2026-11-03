# ── VAU DB client-side encryption switch ─────────────────────────────────────
#
# Sets the realm attribute "spree.config.realm.enabled" as the LAST step of the
# authserver configuration.
#
# Why a separate resource instead of the attribute on keycloak_realm.zeta_realm:
# the realm is the root of the dependency graph — everything else references
# realm_id, so its attributes are always written first. The realm is therefore
# created with the flag disabled (see realm.tf) and switched to its effective
# value here, once scopes, policies, identity providers and key providers are
# in place.
#
# The keycloak provider has no resource for a single realm attribute, so this
# uses the script-based approach already used for the HSM/key-provider steps.

resource "terraform_data" "vau_db_enc" {
  triggers_replace = {
    enabled     = tostring(var.use_vau_db_enc)
    realm_id    = keycloak_realm.zeta_realm.internal_id # changes on DB wipe → forces re-apply
    script_hash = filesha256("${path.module}/scripts/set-vau-db-enc.sh")
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/set-vau-db-enc.sh"

    environment = {
      KC_URL         = var.keycloak_url
      KC_REALM       = keycloak_realm.zeta_realm.realm
      KC_USERNAME    = var.keycloak_username
      KC_PASSWORD    = var.keycloak_password
      KC_INSECURE    = var.insecure_tls ? "true" : "false"
      VAU_DB_ENABLED = tostring(var.use_vau_db_enc)
    }
  }

  # Explicit edges to every other resource of the zeta-guard realm — without
  # them Terraform would only order this after the realm itself and could run it
  # concurrently with (or before) the remaining configuration.
  depends_on = [
    # realm.tf
    keycloak_realm.zeta_realm,
    keycloak_realm_client_policy_profile.zeta_client_policy_profile,
    keycloak_realm_client_policy_profile_policy.zeta_client_policy,
    keycloak_realm_client_policy_profile.zeta_outer_par_validation,
    keycloak_realm_client_policy_profile_policy.zeta_outer_par_validation,
    # scopes.tf
    keycloak_openid_client_scope.zero_audience,
    keycloak_openid_client_scope.pdp_scopes,
    keycloak_openid_audience_protocol_mapper.pdp_audience_mapper,
    keycloak_generic_protocol_mapper.zeta_guard_mapper,
    keycloak_realm_optional_client_scopes.pdp_optional_scopes,
    # policies.tf
    data.external.manage_policies,
    # identity-providers.tf
    keycloak_oidc_identity_provider.smc_b,
    # token-encryption.tf
    keycloak_realm_keystore_ecdsa_generated.es256,
    terraform_data.remove_rsa_keys,
    # hsm-token-signing.tf
    terraform_data.hsm_token_signing,
    terraform_data.hsm_remove_software_keys,
  ]
}
