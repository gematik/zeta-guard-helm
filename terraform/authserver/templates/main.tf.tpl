terraform {
  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = ">= 5.7.0"
    }
{{KUBERNETES_REQUIRED_PROVIDER}}
  }

  {{BACKEND_BLOCK}}
}
