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

variable "config_path" {
  description = "Path to kubeconfig (only used when use_kubernetes = true)"
  type        = string
  default     = "~/.kube/config"
}

variable "keycloak_namespace" {
  description = "Namespace where Keycloak is deployed"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.keycloak_namespace))
    error_message = "keycloak_namespace must be a valid Kubernetes namespace name."
  }
}

variable "keycloak_username" {
  description = "Keycloak admin username (required when use_kubernetes = false)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "keycloak_password" {
  description = "Keycloak admin password (required when use_kubernetes = false)"
  type        = string
  default     = ""
  sensitive   = true
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

variable "smc_b_client_secret" {
  description = "Secret of the SMC-B identity provider"
  type        = string
  default     = "**********"
  sensitive   = true
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

variable "audience_scope_name" {
  description = "Name of the audience scope (zero:audience)"
  type        = string
  default     = "zero:audience"

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

variable "use_fake_sekidp_testrealm" {
  description = "NEVER USE IN PRODUCTION. Whether to create a very basic fake sekIdP realm. This var will probably only have use intermittently."
  type        = bool
  default     = false
}

variable "dummy_client_for_fake_sekidp_clientsecret" {
  description = "NEVER USE IN PRODUCTION. Client Secret for the dummy client for testing with the fake sekIdp"
  type        = string
  default     = ""
}

variable "dummy_user_for_fake_sekidp_password" {
  description = "NEVER USE IN PRODUCTION. Password for the dummy user for testing with the fake sekIdp"
  type        = string
  default     = ""
}

variable "enable_sekidp" {
  description = "Register the zeta-sekidp-oidc IdP, mobile browser/first-login flows, entity-statement keys, and email-binding scopes"
  type        = bool
  default     = false
}

variable "sekidp_fedmaster_url" {
  description = "Fedmaster URL the zeta-sekidp-oidc IdP uses to resolve federation trust. Must be the externally-reachable Ingress URL (e.g. https://<host>/sekidp-fedmaster) matching sekidp.fedmaster.env.serverUrl, not the in-cluster Service URL — authserver fetches Fedmaster's entity statement from this URL, and it must equal Fedmaster's own published issuer for self-consistency."
  type        = string
  default     = ""
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
}

variable "smtp_from" {
  description = "Sender address for realm emails — required by Keycloak whenever smtp_host is set (DefaultEmailSenderProvider.checkFromAddress rejects a missing/invalid from)"
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
