# Demo environment Terraform variables.
# Copy this file as <stage>.tfvars and adjust for your environment.
#
# This file lists every variable the authserver configuration accepts. Required
# variables are active; all optional ones are commented out and annotated with
# their default, so a copy of this file is a complete reference.
#
# Operating modes (use_kubernetes) select the state backend, not the credential
# source:
#   use_kubernetes = true  → State in a K8s Secret
#   use_kubernetes = false → State in a local file, no cluster access needed
#
# The admin credentials always come from TF_VAR_keycloak_username and
# TF_VAR_keycloak_password, in both modes. Terraform does not read the
# authserver-admin Secret itself — that read put the password into the state.
# Fill the variables from the Secret with
# `. terraform/authserver/scripts/kc-admin-env.sh <namespace>` (what `make config`
# does), or export them yourself.
#
# Both are ephemeral: they never land in the state or in a saved plan and must be
# supplied on every terraform run. Do not set them in this file.
# Requires Terraform >= 1.11.
#
# Admin API protection (optional):
#   When authserver.adminHostname is set in your values file, point keycloak_url at
#   the admin hostname and set audience explicitly to the main public hostname:
#     keycloak_url = "https://admin.example.domain/auth"
#     audience     = "https://example.domain"

# ── Required ─────────────────────────────────────────────────────────────────

keycloak_url       = "https://example.domain/auth" # External URL of the Keycloak server (or admin hostname)
keycloak_namespace = "zeta-demo"                   # Namespace where the authserver is deployed

# The audience scope carries the access-token claims the PEP validates on every
# request (aud, profession_oid, client_id, ip_address, product_id,
# product_version, common_name, organization_name). If a Fachdienst mandates its
# own scope name — e.g. VSDM requires scope=vsdservice (A_26744) — set that name
# here, and do NOT also list it in pdp_scopes (a duplicate name fails the apply).
audience_scope_name = "zero:audience"

# ── Connection and state ─────────────────────────────────────────────────────

# insecure_tls            = false              # Skip TLS verification — enable for self-signed certificates
# use_kubernetes          = true               # Kubernetes state backend, credentials from the cluster secret
# keycloak_admin_secret   = "authserver-admin" # Secret holding the Keycloak admin credentials
# keycloak_username       = ""                 # Required when use_kubernetes = false (prefer TF_VAR_keycloak_username)
# keycloak_password       = ""                 # Required when use_kubernetes = false (prefer TF_VAR_keycloak_password)
# skip_external_resources = false              # Skip external scripts that would otherwise run on `terraform plan`

# ── Scopes and audience ──────────────────────────────────────────────────────

# pdp_scopes = []  # Additional PDP scopes, created as realm optional scopes.
#                  # They carry no claim mapper — see the audience_scope_name note above.
#                  # Example: ["zero:read", "zero:write"]

# audience = "https://example.domain"  # Explicit audience value; required when keycloak_url points at an admin
#                                      # hostname. Empty (default) derives it from keycloak_url.

# ── Admin hostname ───────────────────────────────────────────────────────────

# master_realm_frontend_url = ""  # Browser-facing base URL of the master realm. It keeps the Admin Console's
#                                 # login redirect on the admin hostname instead of the public one, which
#                                 # denies it. Empty (default) derives it from keycloak_url whenever audience
#                                 # is set — correct as long as Terraform uses the same URL administrators
#                                 # open in a browser.
#                                 #
#                                 # SET IT when those two differ: an admin hostname that does not resolve
#                                 # publicly forces Terraform through a tunnel or port-forward, and the
#                                 # derived pin would be that tunnel — dead for every other browser:
#                                 #   keycloak_url              = "https://localhost:8443/auth"
#                                 #   master_realm_frontend_url = "https://admin.example.domain/auth"
#                                 #
#                                 # NOT a way to relocate or hide the Admin UI: it only changes the URLs
#                                 # Keycloak advertises, never where it answers (ingress + --hostname-admin).
#                                 # A host or path without a route to the authserver breaks the console
#                                 # instead of moving it, and the UI stays reachable at its real address.
#                                 # Must end in /auth; a validation rejects anything else at plan time.

# ── Identity providers ───────────────────────────────────────────────────────

# smc_b_client_secret = "**********"  # Secret of the SMC-B identity provider

# enable_sekidp        = false  # Register the zeta-sekidp-oidc IdP, mobile browser flow
#                               # entity-statement keys and email-binding scopes

# ── Email binding (F1) ───────────────────────────────────────────────────────

# smtp_host = ""    # Realm SMTP host for email-binding OTP delivery. Empty omits the smtp_server block.
# smtp_port = "25"  # SMTP port
# smtp_from = ""    # Sender address — required by Keycloak whenever smtp_host is set

# ── Notification Service ─────────────────────────────────────────────────────
# Both must match the Helm chart values; they are not wired together.

# notification_service_resource_suffix = "/notification-service" # Must match notificationService.wellKnownResourceSuffix.
#                                                               # Appended to the Guard's public base URL to form the NS aud.
# notification_history_enabled         = false                  # Must match notificationService.historyEnabled. When true,
#                                                               # the notification.history.read scope is created (A_29974).

# ── HSM-backed token signing ─────────────────────────────────────────────────

# hsm_token_signing_enabled              = false  # Register an HSM-backed ES256 KeyProvider in the zeta-guard realm
# hsm_token_signing_endpoint             = ""     # gRPC endpoint of the HSM Proxy (e.g. hsm-sim:50051)
# hsm_token_signing_key_id               = ""     # Signing key identifier in the HSM
#                                                 # (e.g. zeta-guard-keycloak-token-es256-v1.p256)
# hsm_token_signing_priority             = "200"  # Provider priority (higher wins; software keys sit at 100)
# hsm_token_signing_remove_software_keys = true   # Remove software signing keys after HSM key registration

# ── VAU database encryption ──────────────────────────────────────────────────

# use_vau_db_enc = false  # Client-side encryption for this realm. Recommended only when running in a
#                         # trusted execution environment (German VAU).

# ── Session lifetime ─────────────────────────────────────────────────────────
# Both must be at least the largest refresh-token TTL the policy issues (ttl.refresh_token).

# sso_session_idle_timeout = "24h"  # Realm SSO session idle timeout (Go duration)
# sso_session_max_lifespan = "24h"  # Realm SSO session max lifespan (Go duration)
