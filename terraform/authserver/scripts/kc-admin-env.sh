#!/usr/bin/env bash
# Resolves the Keycloak admin credentials and hands them to terraform as
# TF_VAR_keycloak_username / TF_VAR_keycloak_password.
#
# Terraform itself must not read the admin Secret: a `data "kubernetes_secret_v1"`
# result is persisted, so the credentials would end up in cleartext in the state.
# The read happens here instead, outside the Terraform graph.
#
# Two ways to use it — the Makefile is only one consumer, operators running
# terraform directly are first-class:
#
#   sourced (bash):   . scripts/kc-admin-env.sh zeta-staging
#                     terraform apply -var-file=../../private/staging.tfvars
#
#   executed (sh):    eval "$(bash scripts/kc-admin-env.sh zeta-staging)"
#
# Sourced, it exports the variables and writes nothing to stdout. Executed, it
# prints shell-quoted `export` lines for `eval`; the values pass through the
# command substitution, so they never appear in the process list or in shell
# history. Both forms keep them out of CI logs.
#
# Usage: kc-admin-env.sh <namespace> [admin-secret-name]
# Resolution order is kc-admin-credentials.sh's: KC_USERNAME/KC_PASSWORD in the
# environment, then TF_VAR_keycloak_* (both), then the cluster Secret.

_kc_admin_env() {
  local ns="${1:-}" secret="${2:-authserver-admin}" self

  self="${BASH_SOURCE[0]:-}"
  if [[ -z "$self" ]]; then
    echo "ERROR: kc-admin-env.sh needs bash (BASH_SOURCE unavailable)." >&2
    return 1
  fi

  if [[ -z "$ns" ]]; then
    echo "ERROR: usage: kc-admin-env.sh <namespace> [admin-secret-name]" >&2
    return 1
  fi

  local dir
  dir="$(cd "$(dirname "$self")" && pwd)"
  # shellcheck source=kc-admin-credentials.sh
  source "${dir}/kc-admin-credentials.sh" || return 1

  KC_NAMESPACE="$ns" KC_ADMIN_SECRET="$secret" resolve_kc_credentials || return 1

  if [[ -z "${KC_USERNAME:-}" || -z "${KC_PASSWORD:-}" ]]; then
    echo "ERROR: could not resolve Keycloak admin credentials." >&2
    return 1
  fi

  TF_VAR_keycloak_username="$KC_USERNAME"
  TF_VAR_keycloak_password="$KC_PASSWORD"
  export TF_VAR_keycloak_username TF_VAR_keycloak_password
}

# Sourced → export into the caller's shell. Executed → emit for `eval`.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  _kc_admin_env "$@"
else
  set -euo pipefail
  _kc_admin_env "$@"
  printf 'export TF_VAR_keycloak_username=%q\n' "$TF_VAR_keycloak_username"
  printf 'export TF_VAR_keycloak_password=%q\n' "$TF_VAR_keycloak_password"
fi
