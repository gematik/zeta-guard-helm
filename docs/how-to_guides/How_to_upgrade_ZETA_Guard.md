# How to upgrade ZETA Guard

An upgrade of an existing installation is `helm upgrade` for the chart followed
by `terraform apply` for the realm configuration. **A full reinstallation is
never
required and no upgrade step deletes user data.**

This guide covers the supported path, how to protect the Terraform state, and
how
to recover when the state has been lost — the case that produces a wall of
`409 Conflict` / `400 Bad Request` errors on an otherwise healthy realm.

## What Terraform owns, and what it does not

`terraform/authserver/` manages **realm configuration only**:

- the `zeta-guard` realm itself and its attributes
- client scopes, protocol mappers and the realm's optional-scope list
- the SMC-B identity provider, client policy profiles and policies
- the ES256 signing key provider and the realm's event listener list

It does **not** manage and cannot delete:

- **users and their registrations** — rows in the CloudNativePG PostgreSQL
  cluster (`keycloak-db`)
- **clients created by dynamic client registration (DCR)** — every ZETA client
  instance registers itself at runtime; Terraform declares no
  `keycloak_openid_client`
  for them
- sessions, tokens, refresh tokens

The two live in different places, so **losing the Terraform state does not lose
data**, and a Terraform run against an existing realm does not touch user rows.
`terraform destroy` is not part of any upgrade — do not run it.

## The supported upgrade path

```shell
# 1. Chart
helm upgrade --install <release> . -f <values> -n <namespace> --rollback-on-failure

# 2. Realm configuration — repeatable and idempotent
make config stage=<stage>
```

Step 2 is only needed when the release changed the Terraform files or you
enabled
a feature that requires realm configuration. The release notes call out those
changes; running it anyway is harmless.

### Without the Makefile

The Makefile is a convenience wrapper, not a requirement — every step in this
guide can be run with plain `terraform`. The targets used below map to these
commands, all executed **from inside `terraform/authserver`**:

| Target               | Equivalent                                                                                                                              |
|----------------------|-----------------------------------------------------------------------------------------------------------------------------------------|
| `make config-init`   | the generator below, then `terraform init -backend-config=environments/<stage>.backend.hcl -reconfigure`                                |
| `make config`        | `terraform apply -parallelism=1 -var-file=../../<values-dir>/<stage>.tfvars -auto-approve`                                              |
| `make config-plan`   | `terraform plan -var-file=../../<values-dir>/<stage>.tfvars -var="skip_external_resources=true"`                                        |
| `make config-import` | `terraform import -var-file=../../<values-dir>/<stage>.tfvars -var="skip_external_resources=true" keycloak_realm.zeta_realm zeta-guard` |

`main.tf`, `providers.tf`, `credentials.tf` and the backend config are
**generated** and gitignored — Terraform will not run without them. Generate
them
first, then initialize:

```shell
cd terraform/authserver

STAGE=<stage> NAMESPACE=<namespace> \
  TF_VAR_use_kubernetes=true TF_VAR_config_path=~/.kube/config \
  ./generate-main-and-backend.sh

terraform init -backend-config=environments/<stage>.backend.hcl -reconfigure
```

Three details the wrapper otherwise handles for you:

- **`-parallelism=1` on every apply.** Concurrent writes against Keycloak race
  and fail with a Hibernate `StaleObjectStateException` (HTTP 500).
- **Retry the apply.** Right after a deploy the authserver may not serve the
  admin API yet; `make config` retries up to five times.
- **`-var="skip_external_resources=true"` on plan and import.** Without it the
  external policy-management script runs, which a plan should not do.

`<values-dir>` is the directory holding your stage's tfvars — `local-test/` in
the published repository. `<namespace>` defaults to `zeta-<stage>`. In local
mode
set `TF_VAR_use_kubernetes=false` and pass the admin credentials explicitly via
`TF_VAR_keycloak_username` / `TF_VAR_keycloak_password`.

### The Terraform state must survive the upgrade

In Kubernetes mode the state is the Secret `tfstate-default-state` in the stage
namespace (`terraform/authserver/templates/backend.k8s.tpl`). It is created by
the
Terraform Kubernetes backend, not by Helm, and carries no Helm ownership
metadata:

| Action           | State Secret | Realm data                                      |
|------------------|--------------|-------------------------------------------------|
| `helm upgrade`   | kept         | kept                                            |
| `helm uninstall` | kept         | kept (CNPG `Cluster` is Helm-owned, see caveat) |
| `make uninstall` | **deleted**  | **deleted** (CNPG cluster + PVCs)               |

`make uninstall` is a development target. It deletes the state *and* the
database
together, which keeps them consistent — but it is never the right command on a
productive stage. It is not a Terraform operation at all; the destructive part
is
`kubectl delete secret tfstate-default-state`,
`kubectl delete cluster keycloak-db`
and the deletion of the corresponding PVCs. Avoid those three on a stage you
intend to keep, however you drive your deployment.

Back the state up before an upgrade:

```shell
kubectl -n <namespace> get secret tfstate-default-state -o yaml \
  > tfstate-default-state.$(date +%F).yaml
```

Restore by re-applying that file with `kubectl apply -f`.

> **Caveat — the Keycloak database is not annotated
`helm.sh/resource-policy: keep`.**
> `charts/zeta-guard/templates/db/cnpg-notification-cluster.yaml` carries that
> annotation, `db/cnpg-cluster.yaml` (`keycloak-db`) does not. A
> `helm uninstall`
> of the release therefore removes the `Cluster` object for the Keycloak
> database.
> Take a CNPG backup before any teardown and do not rely on Helm to protect it.
> See [How to manage authserver DB](How_to_manage_authserver_DB.md).

### In local mode

With `use_kubernetes = false` the state is the file
`terraform/authserver/terraform.tfstate`. It is gitignored, so it exists only on
the machine that ran the apply — back it up yourself. Note that `make clean`
deletes it, along with `.terraform/`, the lock file and the generated
`main.tf` /
`providers.tf` / `credentials.tf`; do not run it, or its equivalent `rm`,
between
applies. Whoever runs the upgrade must have the same state file as whoever ran
the
previous apply.

## Recovering when the state was lost

Symptoms: `terraform apply` against a realm that is up and serving traffic
reports conflicts for objects that plainly exist, for example

```text
Error: error sending POST request to /auth/admin/realms/zeta-guard/identity-provider/instances:
409 Conflict. Response body: {"errorMessage":"Identity Provider zeta-smc-b-oidc already exists"}

Error: error sending POST request to /auth/admin/realms/zeta-guard/client-scopes:
409 Conflict. Response body: {"errorMessage":"Client Scope vsdservice already exists"}

Error: error sending PUT request to /auth/admin/realms/zeta-guard/client-policies/profiles:
400 Bad Request. Response body: {"errorMessage":"proposed client profile name duplicated."}
```

Terraform is trying to *create* what is already there because its state is
empty.
The fix is to **adopt** the live objects into the state. Nothing below deletes
user data.

### Step 0 — prerequisites

- `terraform`, `curl` and `jq` on the machine running the adoption
- a generated `main.tf` and an initialized backend:

  ```shell
  make config-init stage=<stage>
  # or, without the Makefile, the generator + `terraform init` from
  # "Without the Makefile" above
  ```

- an admin token for the `curl` calls below. In Kubernetes mode Terraform reads
  the credentials from the `authserver-admin` Secret itself; for `curl` read
  them
  the same way. `KC_URL` is your `keycloak_url` including `/auth`:

  ```shell
  NS=<namespace>
  KC_URL=https://<keycloak-host>/auth
  KC_USER=$(kubectl -n "$NS" get secret authserver-admin \
    -o go-template='{{ index .data "username" | base64decode }}')
  KC_PASS=$(kubectl -n "$NS" get secret authserver-admin \
    -o go-template='{{ index .data "password" | base64decode }}')
  ```

  In local mode use your `TF_VAR_keycloak_username` / `TF_VAR_keycloak_password`
  values instead. Then:

  ```shell
  TOKEN=$(curl -s -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d client_id=admin-cli -d grant_type=password \
    --data-urlencode "username=$KC_USER" \
    --data-urlencode "password=$KC_PASS" | jq -r .access_token)
  ```

The token is short-lived — repeat that call if it expires mid-run. Add `-k` to
every `curl` when the stage uses a self-signed certificate.

### Step 1 — remove the objects that cannot be imported

The Keycloak Terraform provider offers **no import** for three resource types
this
chart uses. Its documentation states this outright for each of them:

| Resource                                      | Handling                                                               |
|-----------------------------------------------|------------------------------------------------------------------------|
| `keycloak_realm_client_policy_profile`        | delete first, `apply` recreates it                                     |
| `keycloak_realm_client_policy_profile_policy` | delete first, `apply` recreates it                                     |
| `keycloak_realm_events`                       | nothing to do — the provider's create is a `PUT` and simply overwrites |

The client policy profile and its policy are **pure configuration** — a profile
name, the `dpop-bind-enforcer` executor and the client-type conditions. They
hold
no user data and no client state, so deleting and recreating them is safe. Both
endpoints replace the whole list, so an empty array clears them:

```shell
curl -s -X PUT "$KC_URL/admin/realms/zeta-guard/client-policies/policies" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"policies":[]}'

curl -s -X PUT "$KC_URL/admin/realms/zeta-guard/client-policies/profiles" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"profiles":[]}'
```

Delete the policy before the profile — a policy referencing a missing profile is
rejected. Keycloak's built-in global profiles are unaffected; only realm-level
ones are in that list.

### Step 2 — resolve the Keycloak IDs

Import IDs for scopes, mappers and key providers are UUIDs that Keycloak
assigned
at creation, so they must be read from the running instance. One call returns
the
scopes *and* their protocol mappers:

```shell
curl -s "$KC_URL/admin/realms/zeta-guard/client-scopes" \
  -H "Authorization: Bearer $TOKEN" \
| jq -r '.[] | .name as $s | .id as $sid
         | "SCOPE  \($s)  \($sid)",
           (.protocolMappers // [] | .[] | "MAPPER \($s)/\(.name)  \($sid)/\(.id)")'
```

The generated EC key providers:

```shell
curl -s "$KC_URL/admin/realms/zeta-guard/components?type=org.keycloak.keys.KeyProvider" \
  -H "Authorization: Bearer $TOKEN" \
| jq -r '.[] | select(.providerId == "ecdsa-generated") | "\(.name)  \(.id)"'
```

This returns **two** components on stages with `enable_sekidp = true`, and they
are told apart by their name, not by their provider ID. Match them carefully —
importing one under the other's address rotates a signing key:

| `name`                | Terraform address                                                                                    |
|-----------------------|------------------------------------------------------------------------------------------------------|
| `ES256-generated-key` | `keycloak_realm_keystore_ecdsa_generated.es256`                                                      |
| `ecdsa-generated`     | `keycloak_realm_keystore_ecdsa_generated.entity_statement_sig[0]` (only with `enable_sekidp = true`) |

### Step 3 — import

Start with the realm, which is the one address whose import ID is just its name:

```shell
make config-import stage=<stage>

# without the Makefile, from terraform/authserver:
terraform import -var-file=../../<values-dir>/<stage>.tfvars \
  -var="skip_external_resources=true" \
  keycloak_realm.zeta_realm zeta-guard
```

Then import the rest. Run these from `terraform/authserver` too — the shell
variable just keeps the table below readable:

```shell
TF="terraform import -var-file=../../<values-dir>/<stage>.tfvars -var=skip_external_resources=true"
```

| Address                                                                                   | Import ID                                      |
|-------------------------------------------------------------------------------------------|------------------------------------------------|
| `keycloak_realm.zeta_realm`                                                               | `zeta-guard`                                   |
| `keycloak_oidc_identity_provider.smc_b`                                                   | `zeta-guard/zeta-smc-b-oidc`                   |
| `keycloak_openid_client_scope.zero_audience`                                              | `zeta-guard/<scopeId>`                         |
| `keycloak_openid_client_scope.zeta_email_binding`                                         | `zeta-guard/<scopeId>`                         |
| `keycloak_openid_client_scope.zeta_email_verify`                                          | `zeta-guard/<scopeId>`                         |
| `keycloak_openid_client_scope.notification_scopes["<name>"]`                              | `zeta-guard/<scopeId>`                         |
| `keycloak_openid_client_scope.pdp_scopes["<name>"]`                                       | `zeta-guard/<scopeId>`                         |
| `keycloak_openid_audience_protocol_mapper.pdp_audience_mapper`                            | `zeta-guard/client-scope/<scopeId>/<mapperId>` |
| `keycloak_generic_protocol_mapper.zeta_guard_mapper`                                      | `zeta-guard/client-scope/<scopeId>/<mapperId>` |
| `keycloak_openid_audience_protocol_mapper.notification_service_audience_mapper["<name>"]` | `zeta-guard/client-scope/<scopeId>/<mapperId>` |
| `keycloak_generic_protocol_mapper.zeta_guard_mapper_notification["<name>"]`               | `zeta-guard/client-scope/<scopeId>/<mapperId>` |
| `keycloak_realm_optional_client_scopes.pdp_optional_scopes`                               | `zeta-guard`                                   |
| `keycloak_realm_keystore_ecdsa_generated.es256`                                           | `zeta-guard/<componentId>`                     |

The `for_each` addresses need quoting, and the map key is the scope name:

```shell
$TF 'keycloak_openid_client_scope.notification_scopes["notification.pusher.read"]' \
    zeta-guard/8e8f7fe1-df9b-40ed-bed3-4597aa0dac52
```

Stages with extra features have more addresses. Import them the same way:

- `enable_sekidp = true` —
  `keycloak_realm_keystore_ecdsa_generated.entity_statement_sig[0]`
  (the component named `ecdsa-generated`, see the table above),
  `keycloak_required_action.verify_profile_disabled[0]`
  (`zeta-guard/VERIFY_PROFILE`,
  see the note at `terraform/authserver/sekidp.tf`),
  `keycloak_oidc_identity_provider.zeta_sekidp_oidc[0]` and the mobile
  authentication flows and executions
- `use_fake_sekidp_testrealm = true` — the resources in
  `terraform/authserver/fakeSekIdp.tf`. This is a test-only realm; recreating it
  from scratch is usually simpler than importing it.

The `terraform_data.*` resources (`remove_rsa_keys`, `vau_db_enc`,
`hsm_token_signing`, …) are local-only triggers with no Keycloak counterpart.
Do not import them — they re-run on the next apply, which is expected and
idempotent.

### Step 4 — read the plan before applying

```shell
make config-plan stage=<stage>

# without the Makefile, from terraform/authserver:
terraform plan -var-file=../../<values-dir>/<stage>.tfvars \
  -var="skip_external_resources=true"
```

Two entries mean the adoption is not complete and applying would cause an
outage:

- **`keycloak_realm.zeta_realm` destroyed or replaced.** Stop. That would delete
  the realm and every user in it. Re-check the import of the realm and of the
  resources whose changes force replacement.
- **`keycloak_realm_keystore_ecdsa_generated.es256` created or replaced.** Stop
  and import it. A second ES256 provider makes Keycloak rotate to a new active
  signing key, and every access token already in flight — plus the PEP's cached
  JWKS — stops validating.

Expected and harmless in that plan:

- `terraform_data.*` re-running
- `keycloak_realm_client_policy_profile` / `..._policy` being created (step 1)
- `keycloak_realm_events` being updated

Everything else should be empty. Once the plan is clean, apply:

```shell
make config stage=<stage>

# without the Makefile, from terraform/authserver — keep -parallelism=1:
terraform apply -parallelism=1 \
  -var-file=../../<values-dir>/<stage>.tfvars -auto-approve
```

Verify with one authenticated request through the PEP that tokens still
validate.

## Version-specific notes

### Upgrading to 1.3.x

- **`audience_scope_name` has no default any more** and must be set in every
  stage's tfvars. It names the single scope that carries the claims the PEP
  validates (`aud`, `profession_oid`, `client_id`, …). If a Fachdienst mandates
  a
  scope name — VSDM requires `scope=vsdservice` (A_26744) — set it here and do
  **not** also list it in `pdp_scopes`.
- **`zero:register` and `zero:manage` are removed**, together with their
  authorization-server audience mapper. A `terraform apply` deletes them from
  existing realms. Clients still requesting either scope must drop it first.
- **The realm's event listener list is managed in full.** Manually added
  listeners are removed on every apply. Check the plan before applying to a
  realm
  that was configured by hand.
- Keycloak image bumps need a deployment cutover — a plain `helm upgrade` can
  hang
  when the new version ships a different JGroups protocol version. See the
  migration note for release 1.2.0 in [ReleaseNotes.md](../../ReleaseNotes.md).

## Troubleshooting

**`Error: Invalid for_each argument … will be known only after apply`**
during `terraform import`. Fixed in the current chart. `terraform import`
evaluates resources that are absent from the state as unknown, so a `for_each`
keyed on another resource cannot produce known instance keys and the run aborts
before importing anything. Two mappers in `scopes.tf` did this; they now key off
`local.notification_scope_names`. On an older chart, apply the same change
locally
or upgrade the Terraform files first — `plan` and `apply` are unaffected, so
only
adoption is blocked.

**Import succeeds but the plan still wants to create the object.** The address
or
the ID is wrong — a mapper imported under the client path (`/client/`) instead
of
the client-scope path (`/client-scope/`), or a `for_each` key that does not
match
the scope name. Remove it with
`terraform state rm '<address>'` and import again.

**`Error: Resource already managed by Terraform`.** That address is already in
the
state; skip it.

## Related resources

- [How to configure ZETA Guard Authserver](How_to_configure_authserver.md) —
  variables, operating modes, required Kubernetes permissions
- [How to manage authserver DB](How_to_manage_authserver_DB.md) — CNPG and
  external database modes
- [How to deploy ZETA Guard](How_to_deploy_ZETA_Guard.md)
- [Makefile reference](../reference/Makefile_reference.md)
