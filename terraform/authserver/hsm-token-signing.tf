# ── HSM Token Signing Key Provider ────────────────────────────────────────────
#
# Registers the zeta-hsm-token-signing KeyProvider component in the zeta-guard
# realm via the Keycloak Admin REST API.
#
# The keycloak Terraform provider has no native resource for custom KeyProvider
# components, so this uses a script-based approach via terraform_data + local-exec.
#
# Prerequisites:
#   - Keycloak deployed and healthy
#   - hsm-sim or production HSM reachable from authserver pods
#   - HSM_PROXY_ENDPOINT env var set on authserver (Helm: authserver.hsm.enabled)
#   - hsm-token-signing plugin JAR deployed in providers/
#
# Usage:
#   Set hsm_token_signing_enabled = true and hsm_token_signing_key_id in the
#   stage tfvars. Then: make config stage=<env>

# ── Create HSM KeyProvider component ─────────────────────────────────────────

resource "terraform_data" "hsm_token_signing" {
  count = var.hsm_token_signing_enabled ? 1 : 0

  triggers_replace = {
    key_id   = var.hsm_token_signing_key_id
    endpoint = var.hsm_token_signing_endpoint
    priority = var.hsm_token_signing_priority
    realm_id = keycloak_realm.zeta_realm.internal_id # changes on DB wipe → forces re-registration
  }

  # Stored in state, accessible as self.output during destroy
  input = {
    kc_url      = var.keycloak_url
    kc_realm    = keycloak_realm.zeta_realm.realm
    kc_username = var.use_kubernetes ? (var.keycloak_username != "" ? var.keycloak_username : data.kubernetes_secret_v1.keycloak_admin[0].data["username"]) : var.keycloak_username
    kc_password = var.use_kubernetes ? (var.keycloak_password != "" ? var.keycloak_password : data.kubernetes_secret_v1.keycloak_admin[0].data["password"]) : var.keycloak_password
    kc_insecure = var.insecure_tls ? "true" : "false"
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/configure-hsm-token-signing.sh"

    environment = {
      KC_URL   = var.keycloak_url
      KC_REALM = keycloak_realm.zeta_realm.realm
      KC_USERNAME = var.use_kubernetes ? (var.keycloak_username != "" ? var.keycloak_username :
      data.kubernetes_secret_v1.keycloak_admin[0].data["username"]) : var.keycloak_username
      KC_PASSWORD = var.use_kubernetes ? (var.keycloak_password != "" ? var.keycloak_password :
      data.kubernetes_secret_v1.keycloak_admin[0].data["password"]) : var.keycloak_password
      KC_INSECURE  = var.insecure_tls ? "true" : "false"
      HSM_ENDPOINT = var.hsm_token_signing_endpoint
      HSM_KEY_ID   = var.hsm_token_signing_key_id
      HSM_PRIORITY = var.hsm_token_signing_priority
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/scripts/remove-hsm-token-signing.sh"

    environment = {
      KC_URL      = self.output.kc_url
      KC_REALM    = self.output.kc_realm
      KC_USERNAME = self.output.kc_username
      KC_PASSWORD = self.output.kc_password
      KC_INSECURE = self.output.kc_insecure
    }
  }

  depends_on = [keycloak_realm.zeta_realm]
}

# ── Remove software signing keys (optional) ─────────────────────────────────

resource "terraform_data" "hsm_remove_software_keys" {
  count = var.hsm_token_signing_enabled && var.hsm_token_signing_remove_software_keys ? 1 : 0

  triggers_replace = {
    hsm_configured = terraform_data.hsm_token_signing[0].id
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/remove-software-signing-keys.sh"

    environment = {
      KC_URL      = var.keycloak_url
      KC_REALM    = keycloak_realm.zeta_realm.realm
      KC_USERNAME = var.use_kubernetes ? (var.keycloak_username != "" ? var.keycloak_username : data.kubernetes_secret_v1.keycloak_admin[0].data["username"]) : var.keycloak_username
      KC_PASSWORD = var.use_kubernetes ? (var.keycloak_password != "" ? var.keycloak_password : data.kubernetes_secret_v1.keycloak_admin[0].data["password"]) : var.keycloak_password
      KC_INSECURE = var.insecure_tls ? "true" : "false"
    }
  }

  depends_on = [terraform_data.hsm_token_signing]
}

# ── Variables ────────────────────────────────────────────────────────────────

variable "hsm_token_signing_enabled" {
  description = "Register HSM-backed ES256 KeyProvider in the zeta-guard realm"
  type        = bool
  default     = false
}

variable "hsm_token_signing_endpoint" {
  description = "gRPC endpoint of the HSM Proxy (e.g., hsm-sim:50051)"
  type        = string
  default     = ""
}

variable "hsm_token_signing_key_id" {
  description = "Identifier of the signing key in the HSM (e.g., zeta-guard-keycloak-token-es256-v1.p256)"
  type        = string
  default     = ""
}

variable "hsm_token_signing_priority" {
  description = "Provider priority (higher wins). Default 200 beats software keys at 100."
  type        = string
  default     = "200"
}

variable "hsm_token_signing_remove_software_keys" {
  description = "Remove software signing keys (rsa-generated, ecdsa-generated) after HSM key registration"
  type        = bool
  default     = true
}
