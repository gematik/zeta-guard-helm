#!/usr/bin/env bash
# Resolves Keycloak admin credentials (KC_USERNAME/KC_PASSWORD) at runtime so
# they never land in tfstate. Sourced by remove-*.sh (destroy provisioners may
# only reference `self`), fetch-entity-statement-pubkey.sh and
# managePolicies.sh.
# Resolution order:
#   1. KC_USERNAME / KC_PASSWORD already in the environment
#   2. TF_VAR_keycloak_username / TF_VAR_keycloak_password (use_kubernetes=false)
#   3. Kubernetes secret KC_ADMIN_SECRET in KC_NAMESPACE (use_kubernetes=true)
#
# Step 2 requires BOTH TF_VAR_* to be set. CI usually exports only the password,
# so a Kubernetes-mode run falls through to step 3 and reads both from the
# cluster Secret. That differs from Terraform's own precedence (an explicit
# variable beats the Secret, see templates/credentials.k8s.tpl) and is harmless
# as long as the two agree — but on a stage whose pipeline password has drifted
# from the Secret, these scripts authenticate differently than the provider.

resolve_kc_credentials() {
  if [[ -n "${KC_USERNAME:-}" && -n "${KC_PASSWORD:-}" ]]; then
    return 0
  fi

  if [[ -n "${TF_VAR_keycloak_username:-}" && -n "${TF_VAR_keycloak_password:-}" ]]; then
    KC_USERNAME="${TF_VAR_keycloak_username}"
    KC_PASSWORD="${TF_VAR_keycloak_password}"
    return 0
  fi

  if [[ -n "${KC_ADMIN_SECRET:-}" && -n "${KC_NAMESPACE:-}" ]]; then
    # go-template's base64decode keeps this portable across GNU/BSD base64.
    KC_USERNAME=$(kubectl -n "${KC_NAMESPACE}" get secret "${KC_ADMIN_SECRET}" \
      -o go-template='{{ index .data "username" | base64decode }}') || true
    KC_PASSWORD=$(kubectl -n "${KC_NAMESPACE}" get secret "${KC_ADMIN_SECRET}" \
      -o go-template='{{ index .data "password" | base64decode }}') || true
    if [[ -n "${KC_USERNAME}" && -n "${KC_PASSWORD}" ]]; then
      return 0
    fi
    echo "ERROR: could not read admin credentials from secret ${KC_ADMIN_SECRET} in namespace ${KC_NAMESPACE}." >&2
    return 1
  fi

  echo "ERROR: Keycloak admin credentials unavailable — set KC_USERNAME/KC_PASSWORD, or KC_ADMIN_SECRET/KC_NAMESPACE for a cluster lookup." >&2
  return 1
}
