# ── Optional scopes for already registered clients ───────────────────────────
#
# keycloak_realm_optional_client_scopes.pdp_optional_scopes (scopes.tf) only
# sets the realm defaults, and Keycloak copies those into a client once, when
# the client is created. Without this step a scope added to pdp_scopes (or a
# notification scope) reaches only clients that register afterwards; existing
# DCR clients would need a DB wipe to get it.
#
# The script adds the missing scopes to every client that carries the audience
# scope as an optional scope (= registered through DCR). Additive only, see
# scripts/sync-client-optional-scopes.sh. No destroy step: there is nothing to
# undo, and removing the resource must not strip scopes from clients.
#
# Opt-in (var.sync_existing_client_scopes): the admin API has no filter for
# "clients without scope X", so the script reads every client of the realm. With
# millions of clients one run takes many hours. The script therefore refuses to
# start above var.sync_existing_client_scopes_max_clients (exit status 3).
#
# The keycloak provider has no resource for the optional scopes of clients it
# does not manage, so this uses the script-based approach of vau-db-enc.tf.

resource "terraform_data" "sync_client_optional_scopes" {
  count = var.sync_existing_client_scopes ? 1 : 0

  # No script hash here: a change of the script alone must not rescan all clients.
  triggers_replace = {
    realm_id = keycloak_realm.zeta_realm.internal_id # changes on DB wipe → runs against the new realm
    scopes   = join(" ", sort(keycloak_realm_optional_client_scopes.pdp_optional_scopes.optional_scopes))
    marker   = keycloak_openid_client_scope.zero_audience.name
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/sync-client-optional-scopes.sh"

    environment = {
      KC_URL          = var.keycloak_url
      KC_REALM        = keycloak_realm.zeta_realm.realm
      KC_USERNAME     = var.keycloak_username
      KC_PASSWORD     = var.keycloak_password
      KC_INSECURE     = var.insecure_tls ? "true" : "false"
      KC_MARKER_SCOPE = keycloak_openid_client_scope.zero_audience.name
      KC_SCOPES       = jsonencode(keycloak_realm_optional_client_scopes.pdp_optional_scopes.optional_scopes)
      KC_MAX_CLIENTS  = tostring(var.sync_existing_client_scopes_max_clients)
    }
  }

  depends_on = [keycloak_realm_optional_client_scopes.pdp_optional_scopes]
}
