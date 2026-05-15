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
  default     = "admin"
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
    condition     = can(regex("^[a-zA-Z0-9_:-]+$", var.audience_scope_name))
    error_message = "audience_scope_name must only contain alphanumeric characters, underscores, colons, or hyphens."
  }
}

variable "pdp_scopes" {
  description = "List of additional PDP scopes"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.pdp_scopes : can(regex("^[a-zA-Z0-9_:-]+$", s))])
    error_message = "Each pdp_scope must only contain alphanumeric characters, underscores, colons, or hyphens."
  }
}

variable "use_vau_db_enc" {
  description = "Whether to apply client side encryption to this realm. Use recommended only if you have to run in a trusted execution environment (German VAU)."
  type        = bool
  default     = false
}
