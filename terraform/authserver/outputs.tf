output "pdp_token_signing_algorithm" {
  description = "Currently active token signing algorithm for the PDP realm"
  value       = keycloak_realm.zeta_realm.default_signature_algorithm
}

output "pdp_supported_optional_scopes" {
  description = "List of all supported optional PDP scopes"
  value       = keycloak_realm_optional_client_scopes.pdp_optional_scopes.optional_scopes
}

output "policy_deletion_results" {
  description = "Policies deletion script output"
  value       = try(data.external.delete_policies[0].result, "No result for terraform plan")
}
