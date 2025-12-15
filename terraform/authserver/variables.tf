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

variable "config_path" {
  description = "Path to kubeconfig"
  type        = string
  default     = "~/.kube/config"
}

variable "keycloak_namespace" {
  description = "Namespace where Keycloak is deployed"
  type        = string
}

variable "keycloak_password" {
  description = "Optional Keycloak admin password override (if not provided via cluster secret)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "keycloak_url" {
  description = "URL of keycloak"
  type        = string
}

variable "smc_b_client_secret" {
  description = "Secret of the SMC-B identity provider"
  type        = string
  default     = "**********"
  sensitive   = true
}

variable "realm_name" {
  description = "PDP realm name"
  type        = string
}

variable "realm_display_name" {
  description = "Descriptive name of the realm"
  type        = string
}

variable "pdp_scopes" {
  description = "List of additional PDP scopes"
  type        = list(string)
  default     = []
}
