# Master realm frontend URL — only relevant on stages with a dedicated admin
# hostname (`authserver.adminHostname`), where the chart denies
# /auth/realms/master on the public hostname. The Admin Console authenticates
# against the master realm's frontend URL, which otherwise follows Keycloak's
# --hostname (the public hostname) and would hit that block. Pinning it to the
# admin hostname keeps the console login on the hostname that serves it.
#
# Derived rather than configured per stage: `audience` is non-empty exactly when
# `keycloak_url` points at the admin hostname (same convention as
# local.guard_public_url in scopes.tf). Set `master_realm_frontend_url` to
# override — e.g. when the admin hostname differs from `keycloak_url`.
locals {
  master_frontend_url = (
    var.master_realm_frontend_url != ""
    ? var.master_realm_frontend_url
    : (var.audience != "" ? var.keycloak_url : "")
  )
}

resource "terraform_data" "master_frontend_url" {
  count = local.master_frontend_url != "" ? 1 : 0

  triggers_replace = {
    frontend_url = local.master_frontend_url
    script_hash  = filesha256("${path.module}/scripts/configure-master-frontend-url.sh")
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/configure-master-frontend-url.sh"

    environment = {
      KC_URL          = var.keycloak_url
      KC_FRONTEND_URL = local.master_frontend_url
      KC_USERNAME     = var.keycloak_username
      KC_PASSWORD     = var.keycloak_password
      KC_INSECURE     = var.insecure_tls ? "true" : "false"
    }
  }
}
