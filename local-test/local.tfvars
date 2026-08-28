insecure_tls       = true
use_kubernetes     = true
keycloak_namespace = "zeta-local"
keycloak_url       = "https://zeta-kind.local/auth"
pdp_scopes         = ["zero:read", "zero:write"]

# Email-binding OTP delivery (F1) — MailCatcher SMTP catch-all, see
# docs/how-to_guides/How_to_configure_mailcatcher.md
smtp_host = "mailcatcher"
smtp_port = "1025"
smtp_from = "noreply@zeta-kind.local"
