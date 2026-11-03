variable "insecure_tls" {
  description = "Optional skipping tls verification"
  type        = bool
  default     = false
}

variable "skip_external_resources" {
  description = "Optional skipping external scripts that would otherwise run on tf plan"
  type        = bool
  default     = false
}

variable "use_kubernetes" {
  description = "Whether to use Kubernetes backend and fetch credentials from cluster secrets"
  type        = bool
  default     = true
}

# Only "" as a default — the namespace matters in Kubernetes mode alone (the
# cluster lookup the helper scripts fall back to). Terraform itself no longer
# reads anything from the namespace. Declaring it unconditionally required made
# `use_kubernetes = false` fail at variable parsing, before any count = 0 gate
# could take effect. The state backend takes its own namespace from
# environments/<stage>.backend.hcl, not from this variable.
variable "keycloak_namespace" {
  description = "Namespace where Keycloak is deployed. Required when use_kubernetes = true; unused in local mode."
  type        = string
  default     = ""

  validation {
    condition     = var.keycloak_namespace == "" || can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.keycloak_namespace))
    error_message = "keycloak_namespace must be a valid Kubernetes namespace name."
  }

  validation {
    condition     = !var.use_kubernetes || var.keycloak_namespace != ""
    error_message = "keycloak_namespace must be set when use_kubernetes = true."
  }
}

# ephemeral (Terraform >= 1.10; the module requires >= 1.11, see
# templates/main.tf.tpl) keeps the admin credentials out of tfstate and
# out of `-out` plan files. It also makes the leak that motivated this
# impossible to reintroduce: Terraform rejects any reference from a persisted
# context — a data source query, a terraform_data `input` — with "Invalid use of
# ephemeral value". Provider configuration and provisioner environments remain
# valid contexts, which is all this module needs.
#
# These are the ONLY source of the admin credentials. Terraform deliberately
# does not read the authserver-admin Secret itself: data source results are
# persisted, so that read put the password in cleartext into the state. Use
# scripts/kc-admin-env.sh to fill these from the Secret (or from anywhere else)
# before running terraform. Because they are ephemeral, every invocation needs
# them again — a saved plan does not carry them.
variable "keycloak_username" {
  description = "Keycloak admin username. Required. Fill from the authserver-admin Secret via scripts/kc-admin-env.sh, or set TF_VAR_keycloak_username directly."
  type        = string
  default     = ""
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = var.keycloak_username != ""
    error_message = "keycloak_username must be set. Source terraform/authserver/scripts/kc-admin-env.sh <namespace>, or export TF_VAR_keycloak_username."
  }
}

variable "keycloak_password" {
  description = "Keycloak admin password. Required. Fill from the authserver-admin Secret via scripts/kc-admin-env.sh, or set TF_VAR_keycloak_password directly."
  type        = string
  default     = ""
  sensitive   = true
  ephemeral   = true

  # Replaces the former check "local_credentials_provided" in providers.tf.tpl:
  # a validation fails the run, whereas a check block only warns. It lives here
  # rather than in the Makefile because operators run terraform directly.
  validation {
    condition     = var.keycloak_password != ""
    error_message = "keycloak_password must be set. Source terraform/authserver/scripts/kc-admin-env.sh <namespace>, or export TF_VAR_keycloak_password."
  }
}

variable "keycloak_url" {
  description = "URL of keycloak"
  type        = string

  validation {
    condition     = can(regex("^https?://", var.keycloak_url))
    error_message = "keycloak_url must start with http:// or https://."
  }
}

variable "keycloak_admin_secret" {
  description = "Name of the secret containing the admin credentials for keycloak"
  default     = "authserver-admin"
  type        = string
}

# Written through the provider's write-only argument client_secret_wo, so it is
# not persisted in the state (see identity-providers.tf). ephemeral keeps it out
# of saved plans too.
variable "smc_b_client_secret" {
  description = "Secret of the SMC-B identity provider"
  type        = string
  default     = "**********"
  sensitive   = true
  ephemeral   = true
}

# A write-only argument is invisible to Terraform after the apply, so a changed
# secret alone produces no diff. Bump this to push a rotated secret.
variable "smc_b_client_secret_version" {
  description = "Increment whenever smc_b_client_secret changes, so the new value is pushed to Keycloak"
  type        = number
  default     = 1
}

variable "audience" {
  description = "Custom audience value included in access tokens by the audience mapper"
  type        = string
  default     = ""

  validation {
    condition     = var.audience == "" || can(regex("^https?://", var.audience))
    error_message = "audience must be empty or start with http:// or https://."
  }
}

variable "master_realm_frontend_url" {
  description = "Browser-facing base URL of the master realm, used when Terraform reaches Keycloak at a different endpoint than the administrators' browsers do (e.g. a tunnel while the admin hostname is not publicly resolvable). Must end in /auth. Leave empty to derive it from keycloak_url whenever audience is set (see master-realm.tf)."
  type        = string
  default     = ""

  # SET IT when `keycloak_url` is not the URL administrators open in a browser.
  # The derivation assumes those two are the same, which holds as long as
  # Terraform goes through the admin hostname. It stops holding exactly where the
  # hardening guidance points: an admin hostname that does not resolve publicly
  # forces Terraform through a tunnel or port-forward, and the derived pin would
  # then be that tunnel — leaving the console dead for everyone else.
  #
  # NOT a way to relocate or hide the Admin UI. The value is a declaration, not a
  # redirect: Keycloak only builds the URLs it advertises from it (issuer,
  # endpoints, the console's authServerUrl). Where the UI actually answers is
  # decided by the ingress and --hostname-admin. Pointing this at a host or path
  # with no route to the authserver does not move the console, it breaks it,
  # while the UI stays reachable under its real address. It is not access control.
  #
  # Keycloak appends the realm path to this value verbatim and does NOT add the
  # context path, so a value without the trailing /auth produces endpoints like
  # https://host/<wrong>/realms/master/... — the Admin Console then advertises
  # them as its authServerUrl and its login redirect 404s. Nothing fails at apply
  # time, the breakage only shows in the browser, so catch it here instead.
  validation {
    condition     = var.master_realm_frontend_url == "" || can(regex("^https?://[^/]+/auth$", var.master_realm_frontend_url))
    error_message = "master_realm_frontend_url must be empty or of the form https://<host>/auth — Keycloak appends the realm path without adding the context path, so any other path makes the Admin Console login unreachable."
  }
}

# Required — no default. This scope is the sole carrier of the
# zeta-guard-accesstoken-mapper, i.e. of the claims the PEP validates on every
# request (aud, profession_oid, client_id, ip_address, product_id,
# product_version, common_name, organization_name). A silently defaulted name
# would issue tokens without those claims wherever a Fachdienst mandates its own
# scope name (e.g. VSDM's "vsdservice", A_26744), so every stage must state it.
variable "audience_scope_name" {
  description = "Name of the audience scope carrying the access-token claims the PEP requires (e.g. \"zero:audience\"). Required — must be set per stage and must not also appear in pdp_scopes."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_:.-]+$", var.audience_scope_name))
    error_message = "audience_scope_name must only contain alphanumeric characters, underscores, colons, periods, or hyphens."
  }
}

variable "pdp_scopes" {
  description = "List of additional PDP scopes"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.pdp_scopes : can(regex("^[a-zA-Z0-9_:.-]+$", s))])
    error_message = "Each pdp_scope must only contain alphanumeric characters, underscores, colons, periods, or hyphens."
  }
}

variable "use_vau_db_enc" {
  description = "Whether to apply client side encryption to this realm. Use recommended only if you have to run in a trusted execution environment (German VAU)."
  type        = bool
  default     = false
}

variable "enable_sekidp" {
  description = "Register the zeta-sekidp-oidc IdP, mobile browser flow (sekidp-direct-redirector), entity-statement keys, and email-binding scopes"
  type        = bool
  default     = false

  # gsi-server >= 8.5.1 validates authserver's PAR against the entity statement
  # mounted via sekidp.gsiServer.entityStatementAboutRp (GSI_FEDMASTER_MODE=local).
  # See docs/how-to_guides/How_to_configure_sekidp.md.
}

variable "sekidp_client_id" {
  description = "client_id of the zeta-sekidp-oidc IdP, i.e. the public issuer of the zeta-guard realm (e.g. https://<host>/auth/realms/zeta-guard). gsi-server fetches this realm's entity statement from it. Leave empty to derive it from keycloak_url; set it when keycloak_url points at the admin hostname, which the sectoral IDP cannot reach."
  type        = string
  default     = ""

  validation {
    condition     = var.sekidp_client_id == "" || can(regex("^https?://[^/]+/.*realms/zeta-guard$", var.sekidp_client_id))
    error_message = "sekidp_client_id must be the realm's issuer URL ending in /realms/zeta-guard or an empty string."
  }
}

variable "smtp_host" {
  description = "SMTP server host for the realm's smtpServer config (email-binding OTP delivery, e.g. mailcatcher). Empty omits the smtp_server block entirely."
  type        = string
  default     = ""
}

variable "smtp_port" {
  description = "SMTP server port"
  type        = string
  default     = "25"

  validation {
    condition     = can(regex("^[0-9]+$", var.smtp_port)) && try(tonumber(var.smtp_port) >= 1 && tonumber(var.smtp_port) <= 65535, false)
    error_message = "smtp_port must be an integer between 1 and 65535."
  }
}

variable "smtp_from" {
  description = "Sender address for realm emails — required by Keycloak whenever smtp_host is set (DefaultEmailSenderProvider.checkFromAddress rejects a missing/invalid from)"
  type        = string
  default     = ""
}

variable "smtp_starttls" {
  description = "When true, enables StartTLS. Defaults to false."
  type        = bool
  default     = false
}

variable "smtp_ssl" {
  description = "When true, enables SSL. Defaults to false."
  type        = bool
  default     = false
}

variable "smtp_auth_username" {
  description = "(optional) The SMTP server username."
  type        = string
  default     = ""
}

variable "smtp_auth_password" {
  description = "(optional) The SMTP server password."
  type        = string
  default     = ""
}

# Keep in sync with notificationService.wellKnownResourceSuffix in the Helm chart (not
# wired together). Forms the NS token aud; a mismatch breaks NS token validation.
variable "notification_service_resource_suffix" {
  description = "Path suffix appended to the Guard's public base URL to form the Notification Service's resource identifier (aud). Must match notificationService.wellKnownResourceSuffix in the Helm chart values."
  type        = string
  default     = "/notification-service"

  validation {
    condition     = can(regex("^/", var.notification_service_resource_suffix))
    error_message = "notification_service_resource_suffix must start with '/'."
  }
}

# Keep in sync with notificationService.historyEnabled in the Helm chart (not wired
# together). Gates the notification.history.read Keycloak scope (A_29974).
variable "notification_history_enabled" {
  description = "Whether the Notification Service history feature (A_29974) is enabled. When true, the notification.history.read scope is created in Keycloak. Must match notificationService.historyEnabled in the Helm chart values."
  type        = bool
  default     = false
}

# Keycloak's defaults (idle 30m, max 10h) end the user session long before the
# refresh token the policy issues (refresh_token ttl, default 86400s), so a
# refresh after 30 minutes of inactivity failed with "Session not active". Both
# limits must be at least the largest refresh-token TTL the policy hands out
# (A_28527); the authserver caps every refresh token at the session's end, so
# the session — not the token — bounds re-authentication (A_25662).
variable "sso_session_idle_timeout" {
  description = "Realm SSO session idle timeout as a Go duration (e.g. \"24h\"). Must be at least the largest refresh-token TTL issued by the policy, otherwise the session ends before the refresh token expires."
  type        = string
  default     = "24h"

  validation {
    condition     = can(regex("^([0-9]+(h|m|s))+$", var.sso_session_idle_timeout))
    error_message = "sso_session_idle_timeout must be a duration such as \"24h\" or \"1h30m\"."
  }
}

variable "sso_session_max_lifespan" {
  description = "Realm SSO session max lifespan as a Go duration (e.g. \"24h\"). Must be at least the largest refresh-token TTL issued by the policy, otherwise the session ends before the refresh token expires."
  type        = string
  default     = "24h"

  validation {
    condition     = can(regex("^([0-9]+(h|m|s))+$", var.sso_session_max_lifespan))
    error_message = "sso_session_max_lifespan must be a duration such as \"24h\" or \"1h30m\"."
  }
}
