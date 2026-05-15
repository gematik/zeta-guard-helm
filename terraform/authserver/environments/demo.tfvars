# Demo environment Terraform variables.
# Copy this file as <stage>.tfvars and adjust for your environment.
#
# Operating modes:
#   use_kubernetes = true  → State in K8s Secret, credentials from cluster secret
#   use_kubernetes = false → State in local file, credentials must be set explicitly
#                            (TF_VAR_keycloak_password and TF_VAR_keycloak_username)
#
# Admin API protection (optional):
#   When authserver.adminHostname is set in your values file, point keycloak_url at
#   the admin hostname and set audience explicitly to the main public hostname:
#     keycloak_url = "https://admin.example.domain/auth"
#     audience     = "https://example.domain"

insecure_tls       = false                         # Enable for self-signed certificates (optional, default is false)
use_kubernetes     = true                          # Use Kubernetes backend and fetch credentials from cluster
keycloak_url       = "https://example.domain/auth" # External URL of the Keycloak server (or admin hostname)
keycloak_namespace = "zeta-demo"                   # Namespace where the authserver is deployed
pdp_scopes         = ["zero:read", "zero:write"]   # Additional PDP scopes
# audience            = "https://example.domain"        # Required when keycloak_url points to an admin hostname
# audience_scope_name = "zero:audience"                 # Name of the audience scope (optional, default is "zero:audience")
