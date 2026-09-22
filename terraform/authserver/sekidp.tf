# ── ZETA mobile client registration via SekIDP broker ─────────────────────────
# Headless mobile onboarding: custom IdP plugin (zeta-sekidp-oidc) brokers login
# to gematik's SekIDP via OIDC-Federation (through Fedmaster); the zeta-mobile
# browser flow forces mobile DCR clients there, zeta-mobile-first-login skips the
# profile-review page, and two scopes down-scope tokens until email binding (F1).
# Mirrors keycloak-zeta's zeta-guard-realm.json + 13-15-*.sh as Terraform.
# Activate: set enable_sekidp=true + sekidp_fedmaster_url in tfvars, make config.

# ── Entity-statement signing key (ecdsa-generated, P-256) ────────────────────
# Typed resource (provider supports this key type natively). The custom
# SekIDPEntityStatementProvider plugin looks it up by name.

resource "keycloak_realm_keystore_ecdsa_generated" "entity_statement_sig" {
  count              = var.enable_sekidp ? 1 : 0
  realm_id           = keycloak_realm.zeta_realm.id
  name               = "ecdsa-generated"
  elliptic_curve_key = "P-256"
  # Must outrank token-encryption.tf's ES256 key (priority 100): at equal
  # priority Keycloak's active-key lookup and the plugin's by-name lookup can
  # pick different keys, so the statement is signed with a key absent from its
  # own jwks and gsi-server rejects it ("Key not found in jwks").
  priority = 200
  enabled  = true
  active   = true
}

# ── Sync the entity-statement signing key's public half to gsi-fedmaster ────
# The key's material only exists after `make config` creates the component, so
# its pubkey/kid aren't known ahead of time. Read them via the Admin REST API
# into a Secret gsi-fedmaster mounts at /public-keys, then restart it to pick up
# the key. See docs/how-to_guides/How_to_configure_sekidp.md.

data "external" "entity_statement_pubkey" {
  count   = var.enable_sekidp ? 1 : 0
  program = ["${path.module}/scripts/fetch-entity-statement-pubkey.sh"]
  # No credentials in the query — it's stored in tfstate and echoed in plans.
  # The program re-reads admin creds at runtime (kc-admin-credentials.sh) from
  # kc_admin_secret in kc_namespace.
  query = {
    kc_url          = var.keycloak_url
    kc_realm        = keycloak_realm.zeta_realm.realm
    kc_insecure     = var.insecure_tls ? "true" : "false"
    kc_namespace    = var.keycloak_namespace
    kc_admin_secret = var.keycloak_admin_secret

    key_provider_id = keycloak_realm_keystore_ecdsa_generated.entity_statement_sig[0].id
  }
}

# ── Entity-statement encryption key (ecdh-generated, ECDH-ES) ────────────────
# No typed Terraform resource for this key-provider type (provider v5.8.0), so
# use the script-based Admin REST API workaround (terraform_data + local-exec),
# as in hsm-token-signing.tf.

resource "terraform_data" "entity_statement_enc_key" {
  count = var.enable_sekidp ? 1 : 0

  triggers_replace = {
    realm_id    = keycloak_realm.zeta_realm.internal_id # changes on DB wipe → forces re-registration
    script_hash = filesha256("${path.module}/scripts/configure-entity-statement-encryption-key.sh")
  }

  # Stored in state (self.output during destroy). Deliberately holds NO
  # credentials — anything here is cleartext in tfstate/plans. The destroy
  # script re-reads admin creds at runtime (kc-admin-credentials.sh).
  input = {
    kc_url          = var.keycloak_url
    kc_realm        = keycloak_realm.zeta_realm.realm
    kc_insecure     = var.insecure_tls ? "true" : "false"
    kc_namespace    = var.keycloak_namespace
    kc_admin_secret = var.keycloak_admin_secret
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/configure-entity-statement-encryption-key.sh"

    environment = {
      KC_URL      = var.keycloak_url
      KC_REALM    = keycloak_realm.zeta_realm.realm
      KC_USERNAME = var.keycloak_username
      KC_PASSWORD = var.keycloak_password
      KC_INSECURE = var.insecure_tls ? "true" : "false"
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/scripts/remove-entity-statement-encryption-key.sh"

    # Only non-sensitive values from self.output — the script resolves the
    # admin credentials itself from KC_ADMIN_SECRET in KC_NAMESPACE.
    # try() tolerates state written by the older shape (kc_username/kc_password
    # instead of kc_namespace/kc_admin_secret): during a replace the destroy
    # provisioner reads self from the *pre-existing* state, so both shapes must
    # resolve. kc-admin-credentials.sh accepts whichever pair is non-empty.
    environment = {
      KC_URL          = self.output.kc_url
      KC_REALM        = self.output.kc_realm
      KC_INSECURE     = self.output.kc_insecure
      KC_NAMESPACE    = try(self.output.kc_namespace, "")
      KC_ADMIN_SECRET = try(self.output.kc_admin_secret, "")
      KC_USERNAME     = try(self.output.kc_username, "")
      KC_PASSWORD     = try(self.output.kc_password, "")
    }
  }

  depends_on = [keycloak_realm.zeta_realm]
}

# ── Disable VERIFY_PROFILE required action ───────────────────────────────────
# Lets the headless first-broker-login flow skip the profile-review page.
# CAVEAT: realm-wide — disables profile verification for ALL zeta-guard logins.
# CAVEAT: it's a built-in action; if apply errors "already exists", import first:
#   terraform import 'keycloak_required_action.verify_profile_disabled[0]' zeta-guard/VERIFY_PROFILE

resource "keycloak_required_action" "verify_profile_disabled" {
  count          = var.enable_sekidp ? 1 : 0
  realm_id       = keycloak_realm.zeta_realm.id
  alias          = "VERIFY_PROFILE"
  name           = "Verify Profile"
  enabled        = false
  default_action = false
  priority       = 90
}

# ── Headless first-broker-login flow (idp-create-user-if-unique only) ───────
# Only "Create User If Unique", no review-profile step — otherwise the
# VERIFY_PROFILE page blocks the headless mobile flow.

resource "keycloak_authentication_flow" "zeta_mobile_first_login" {
  count       = var.enable_sekidp ? 1 : 0
  realm_id    = keycloak_realm.zeta_realm.realm
  alias       = "zeta-mobile-first-login"
  description = "ZETA mobile headless first broker login (only Create User If Unique)"
  provider_id = "basic-flow"
}

resource "keycloak_authentication_execution" "zeta_mobile_first_login" {
  count             = var.enable_sekidp ? 1 : 0
  realm_id          = keycloak_realm.zeta_realm.realm
  parent_flow_alias = keycloak_authentication_flow.zeta_mobile_first_login[0].alias
  authenticator     = "idp-create-user-if-unique"
  requirement       = "REQUIRED"
}

# ── zeta-sekidp-oidc identity provider ───────────────────────────────────────
# Custom SPI (not built-in "oidc") brokering login to SekIDP via OIDC-Federation
# through Fedmaster. No client_secret: client_id is this realm's own issuer URL,
# matching the authserver entry in sekidp.fedmaster.relyingPartyConfigs.

resource "keycloak_oidc_identity_provider" "zeta_sekidp_oidc" {
  count        = var.enable_sekidp ? 1 : 0
  realm        = keycloak_realm.zeta_realm.realm
  alias        = "zeta-sekidp-oidc"
  display_name = "ZETA SekIDP (GesundheitsID)"
  provider_id  = "zeta-sekidp-oidc"
  enabled      = true
  client_id    = "${var.keycloak_url}/realms/zeta-guard"

  # Required by the resource schema but unused by SekIDPIdentityProvider: it
  # resolves endpoints via Fedmaster and authenticates via the OIDC-Federation
  # entity-statement chain, not a client secret.
  authorization_url = ""
  token_url         = ""
  client_secret     = ""

  hide_on_login_page            = true
  trust_email                   = false
  store_token                   = false
  add_read_token_role_on_create = false
  authenticate_by_default       = false
  link_only                     = false
  backchannel_supported         = false
  disable_user_info             = true
  validate_signature            = false
  sync_mode                     = "IMPORT"
  default_scopes                = "urn:telematik:display_name urn:telematik:versicherter openid"
  first_broker_login_flow_alias = keycloak_authentication_flow.zeta_mobile_first_login[0].alias

  extra_config = {
    updateProfileFirstLoginMode = "off"
    fedmasterUrl                = var.sekidp_fedmaster_url
    acrValues                   = "gematik-ehealth-loa-high"
    pkceEnabled                 = "true"
    pkceMethod                  = "S256"
    disableNonce                = "false"
  }

  depends_on = [
    keycloak_realm.zeta_realm,
    keycloak_authentication_execution.zeta_mobile_first_login
  ]
}

# ── zeta-mobile browser flow (Identity Provider Redirector) ─────────────────
# Assigned to mobile clients during DCR as a browserFlow override
# (ZetaGuardClientRegistrationPolicy), enforcing the SekIDP redirect server-side.

resource "keycloak_authentication_flow" "zeta_mobile" {
  count       = var.enable_sekidp ? 1 : 0
  realm_id    = keycloak_realm.zeta_realm.realm
  alias       = "zeta-mobile"
  description = "ZETA mobile: enforced redirect to the SekIDP (no login screen)"
  provider_id = "basic-flow"
}

resource "keycloak_authentication_execution" "zeta_mobile" {
  count             = var.enable_sekidp ? 1 : 0
  realm_id          = keycloak_realm.zeta_realm.realm
  parent_flow_alias = keycloak_authentication_flow.zeta_mobile[0].alias
  authenticator     = "identity-provider-redirector"
  requirement       = "REQUIRED"
}

resource "keycloak_authentication_execution_config" "zeta_mobile" {
  count        = var.enable_sekidp ? 1 : 0
  realm_id     = keycloak_realm.zeta_realm.realm
  execution_id = keycloak_authentication_execution.zeta_mobile[0].id
  alias        = "zeta-mobile-redirector"
  config = {
    defaultProvider = keycloak_oidc_identity_provider.zeta_sekidp_oidc[0].alias
  }
}
