#!/usr/bin/env bash
set -euo pipefail

# Assigns the realm's optional client scopes to clients that already exist.
#
# Why: keycloak_realm_optional_client_scopes only sets the realm defaults.
# Keycloak copies those into a client once, when the client is created. A scope
# added to the list later (pdp_scopes, notification scopes) therefore never
# reaches clients that registered before — only a DB wipe, which makes every
# client register again, used to fix that.
#
# Which clients: openid-connect clients that already carry KC_MARKER_SCOPE (the
# audience scope) as an optional scope. Clients created through DCR after the
# realm was configured have it; Keycloak's built-in clients and clients managed
# elsewhere do not, so they are left alone.
#
# Additive only: missing scopes are added as optional scopes, nothing is
# removed. A scope the client already holds as a default scope is not added
# again as an optional one.
#
# The client list is read page by page. Clients that expire while the script
# runs shift the pages, so a client can be missed in one pass; the script
# therefore repeats the pass until a pass adds nothing (at most MAX_PASSES).
#
# Required environment variables:
#   KC_URL          — Keycloak base URL (e.g. https://host/auth)
#   KC_REALM        — Target realm (e.g. zeta-guard)
#   KC_USERNAME     — Admin username
#   KC_PASSWORD     — Admin password
#   KC_MARKER_SCOPE — Optional scope that marks the clients to update
#   KC_SCOPES       — JSON array of the scope names to assign
#
# Optional:
#   KC_INSECURE     — "true" to skip TLS verification
#   KC_PAGE_SIZE    — clients per page (default 100)
#   KC_MAX_CLIENTS  — refuse to run if the realm has more clients (default 10000)
#
# Exit status: 0 in sync, 1 error, 3 realm has more than KC_MAX_CLIENTS clients.
# Terraform hides the output (the credentials are ephemeral), so the exit status
# is what an operator sees.

# --fail-with-body: non-2xx exits non-zero but keeps the body for diagnostics.
# --max-time bounds every single request, so a hanging connection cannot stall
# the apply.
CURL_OPTS=(-sS --fail-with-body --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120)
if [[ "${KC_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

PAGE_SIZE="${KC_PAGE_SIZE:-100}"
MAX_CLIENTS="${KC_MAX_CLIENTS:-10000}"
MAX_PASSES=3
EXIT_TOO_MANY_CLIENTS=3

for var in KC_URL KC_REALM KC_USERNAME KC_PASSWORD KC_MARKER_SCOPE KC_SCOPES; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} must be set" >&2
    exit 1
  fi
done

if ! [[ "$PAGE_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: KC_PAGE_SIZE must be a positive integer (got '${PAGE_SIZE}')" >&2
  exit 1
fi

if ! [[ "$MAX_CLIENTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: KC_MAX_CLIENTS must be a positive integer (got '${MAX_CLIENTS}')" >&2
  exit 1
fi

if ! jq -e 'type == "array" and all(.[]; type == "string")' <<<"$KC_SCOPES" >/dev/null 2>&1; then
  echo "ERROR: KC_SCOPES must be a JSON array of scope names (got '${KC_SCOPES}')" >&2
  exit 1
fi

ADMIN="${KC_URL}/admin/realms/${KC_REALM}"
TOKEN=""
TOKEN_AT=0
TOKEN_MAX_AGE=0

# ── Obtain an admin access token ──────────────────────────────────────────────
# The master realm's access token lives 60 s by default, which a realm with many
# clients (or a slow admin API) outlasts. ensure_token renews it once half of
# its lifetime has passed; a 401 on a write renews it as well (see add_scope).
authenticate() {
  local response expires_in
  TOKEN_AT=$SECONDS
  response=$(curl "${CURL_OPTS[@]}" -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    --data-urlencode "username=${KC_USERNAME}" \
    --data-urlencode "password=${KC_PASSWORD}") || {
      echo "ERROR: Failed to authenticate against Keycloak at ${KC_URL}" >&2
      echo "${response}" >&2
      exit 1
    }

  TOKEN=$(jq -r '.access_token' <<<"$response")
  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "ERROR: Failed to obtain access token from Keycloak." >&2
    exit 1
  fi

  expires_in=$(jq -r '.expires_in // 60' <<<"$response")
  TOKEN_MAX_AGE=$((expires_in / 2))
}

ensure_token() {
  if [[ -z "$TOKEN" ]] || ((SECONDS - TOKEN_AT >= TOKEN_MAX_AGE)); then
    authenticate
  fi
}

# Adds one optional scope to one client; prints the HTTP status code.
# `|| true`: --fail-with-body exits non-zero on a non-2xx response, which under
# `set -e` would abort before the caller can report the code.
put_scope() {
  curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -X PUT "${ADMIN}/clients/$1/optional-client-scopes/$2" 2>/dev/null || true
}

# Sets ADD_CODE rather than printing it: a token renewed inside $(…) would be
# lost for the following calls.
add_scope() {
  ensure_token
  ADD_CODE=$(put_scope "$1" "$2")
  if [[ "$ADD_CODE" == "401" ]]; then
    authenticate
    ADD_CODE=$(put_scope "$1" "$2")
  fi
}

# GET below the realm's admin URL; prints the body, fails the script on error.
# Call ensure_token first: run inside $(…), a token renewed here would be lost.
admin_get() {
  local body
  body=$(curl "${CURL_OPTS[@]}" -H "Authorization: Bearer ${TOKEN}" "${ADMIN}$1") || {
    echo "ERROR: GET ${ADMIN}$1 failed" >&2
    echo "${body}" >&2
    return 1
  }
  printf '%s' "$body"
}

# ── Resolve the scope names to their ids ─────────────────────────────────────
authenticate
all_scopes=$(admin_get "/client-scopes")
scope_ids=$(jq -c --argjson want "$KC_SCOPES" \
  '[.[] | select(.name as $n | $want | index($n)) | {(.name): .id}] | add // {}' <<<"$all_scopes")

unknown=$(jq -rn --argjson want "$KC_SCOPES" --argjson ids "$scope_ids" '$want[] | select($ids[.] == null)')
if [[ -n "$unknown" ]]; then
  echo "ERROR: client scopes not found in realm ${KC_REALM}: $(paste -sd, - <<<"$unknown")" >&2
  exit 1
fi

if ! jq -e --arg m "$KC_MARKER_SCOPE" --argjson want "$KC_SCOPES" -n '$want | index($m)' >/dev/null; then
  echo "WARNING: marker scope ${KC_MARKER_SCOPE} is not in KC_SCOPES" >&2
fi

# ── Refuse realms that are too large to scan ─────────────────────────────────
# The admin API has no client count, but a page that starts behind the limit is
# only non-empty when the realm has more clients than that.
beyond_limit=$(admin_get "/clients?first=${MAX_CLIENTS}&max=1")
if [[ "$(jq 'length' <<<"$beyond_limit")" -gt 0 ]]; then
  echo "ERROR: realm ${KC_REALM} has more than ${MAX_CLIENTS} clients; not scanning them." >&2
  echo "       Raise sync_existing_client_scopes_max_clients or disable sync_existing_client_scopes." >&2
  exit "$EXIT_TOO_MANY_CLIENTS"
fi

# ── One pass over all clients ────────────────────────────────────────────────
# Sets the counters below; pass_added is what the loop at the end checks.
run_pass() {
  local first=0 page count todo client_id client_name scope
  pass_scanned=0
  pass_matched=0
  pass_clients=0
  pass_added=0

  while :; do
    ensure_token
    page=$(admin_get "/clients?first=${first}&max=${PAGE_SIZE}")
    count=$(jq 'length' <<<"$page")
    pass_scanned=$((pass_scanned + count))

    # One line per missing assignment: <client uuid> TAB <clientId> TAB <scope name>
    todo=$(jq -r --arg m "$KC_MARKER_SCOPE" --argjson want "$KC_SCOPES" '
      .[]
      | select(.protocol == "openid-connect" and ((.optionalClientScopes // []) | index($m)))
      | . as $c
      | ($want - ($c.optionalClientScopes // []) - ($c.defaultClientScopes // []))[]
      | [$c.id, $c.clientId, .] | @tsv' <<<"$page")

    pass_matched=$((pass_matched + $(jq --arg m "$KC_MARKER_SCOPE" \
      '[.[] | select(.protocol == "openid-connect" and ((.optionalClientScopes // []) | index($m)))] | length' <<<"$page")))
    if [[ -n "$todo" ]]; then
      pass_clients=$((pass_clients + $(cut -f1 <<<"$todo" | sort -u | wc -l)))
    fi

    while IFS=$'\t' read -r client_id client_name scope; do
      [[ -z "$client_id" ]] && continue
      add_scope "$client_id" "$(jq -r --arg s "$scope" '.[$s]' <<<"$scope_ids")"
      if [[ "$ADD_CODE" != "204" ]]; then
        echo "ERROR: could not add optional scope ${scope} to client ${client_name} (HTTP ${ADD_CODE})" >&2
        exit 1
      fi
      pass_added=$((pass_added + 1))
    done <<<"$todo"

    if ((count < PAGE_SIZE)); then
      break
    fi
    first=$((first + PAGE_SIZE))
  done
}

echo "Syncing optional scopes $(jq -r 'join(", ")' <<<"$KC_SCOPES") to clients of realm ${KC_REALM} (marker: ${KC_MARKER_SCOPE})"

pass=1
while :; do
  run_pass
  echo "pass ${pass}: ${pass_scanned} clients read, ${pass_matched} with marker scope, ${pass_clients} updated, ${pass_added} scope assignments added"
  if ((pass_added == 0)); then
    break
  fi
  if ((pass >= MAX_PASSES)); then
    echo "ERROR: still adding scopes after ${MAX_PASSES} passes, giving up" >&2
    exit 1
  fi
  pass=$((pass + 1))
done

echo "Optional scopes in sync for realm ${KC_REALM}"
