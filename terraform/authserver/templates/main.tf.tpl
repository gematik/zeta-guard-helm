terraform {
  # >= 1.9  for cross-variable references in variable validation
  # >= 1.10 for ephemeral input variables (keycloak_username/keycloak_password)
  # >= 1.11 for write-only arguments (client_secret_wo in identity-providers.tf)
  required_version = ">= 1.11"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = ">= 5.7.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
{{KUBERNETES_REQUIRED_PROVIDER}}
  }

  {{BACKEND_BLOCK}}
}
