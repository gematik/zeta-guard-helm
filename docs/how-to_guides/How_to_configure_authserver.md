# How to configure ZETA Guard Authserver

## Overview

This guide describes how to configure the ZETA Guard Authserver (PDP) using
Terraform and the provided Makefile. The Makefile supports robust CI/CD
execution and optional admin password handling to streamline deployments and
updates.

This step can be performed multiple times to configure and reconfigure the
authserver without the need to deploy it from scratch.

> Configuration is managed via Terraform and provides both customizable and
> predefined settings:
>
> Customizable properties:
> - Authserver URL
> - Kubernetes namespace
> - TLS configuration (self-signed certificates are supported)
> - Additional PDP scopes
> - Audience scope name (**required**, no default) — the scope that carries the
>   access-token claims the PEP requires (see the note under "Terraform
    Variables")
>
> Predefined settings:
> - Realm token encryption is set to ES256
> - All RSA key providers are removed; only ECC keys (ES256/P-256) appear in the
    JWKS endpoint
> - Trusted Hosts, Max Clients Limit, Consent Required Policies are removed
> - ZETA Max Clients Limit Policy added

> The name of the ZETA Guard realm is `zeta-guard` and must be kept unchanged.

---

## Operating Modes

Terraform can run in two modes, controlled by the `TF_VAR_use_kubernetes`
variable:

|                   | **Kubernetes mode** (default)                                                    | **Local mode**                                   |
|-------------------|----------------------------------------------------------------------------------|--------------------------------------------------|
| **State backend** | Kubernetes Secret in the cluster                                                 | Local `terraform.tfstate` file                   |
| **Credentials**   | `TF_VAR_keycloak_*`, filled from `authserver-admin` by `scripts/kc-admin-env.sh` | `TF_VAR_keycloak_*`, from wherever you keep them |
| **Typical use**   | CI/CD pipelines, cluster-connected admins                                        | Local development, no cluster access required    |
| **Set via**       | `TF_VAR_use_kubernetes=true` (default)                                           | `TF_VAR_use_kubernetes=false`                    |

---

## Prerequisites

### Common (both modes)

- Terraform **1.11 or newer** installed (1.10 for ephemeral input variables,
  1.11 for the write-only argument used by the SMC-B identity provider — see
  [Admin credentials](#admin-credentials))
- Make installed
- `curl` and `jq` available in PATH
- Network access to the Keycloak instance from the machine running Terraform

### Kubernetes mode (default)

- A running ZETA Guard Kubernetes cluster
- `kubectl` configured to access the cluster
- Keycloak admin credentials stored in K8s Secret `authserver-admin` (created by
  the Helm chart). Terraform does not read it — export
  `TF_VAR_keycloak_username` / `TF_VAR_keycloak_password` from it first, e.g.
  with `scripts/kc-admin-env.sh`; see
  [Admin credentials](#admin-credentials).

### Local mode

- `TF_VAR_use_kubernetes=false` set in the Makefile invocation or as environment
  variable
- Keycloak admin credentials are provided explicitly:
    - `TF_VAR_keycloak_username` (required)
    - `TF_VAR_keycloak_password` (required)
- `keycloak_namespace` can be left unset — nothing in local mode reads it
- Terraform state is stored locally in `terraform.tfstate` (not in the cluster)

Both variables are required in **both** modes and are *ephemeral*, so they must
be supplied on **every** Terraform invocation — see
[Admin credentials](#admin-credentials).

> When using self-signed certificates (e.g. local KIND cluster), set
> `insecure_tls = true`
> in the tfvars file. The management script will automatically extract the
> server certificate
> and configure a temporary Java truststore for `kcadm.sh`.

---

## Admin credentials

The admin credentials reach Terraform **only** through
`TF_VAR_keycloak_username` / `TF_VAR_keycloak_password`. Terraform does not read
the `authserver-admin` Secret itself: a `data "kubernetes_secret_v1"` result is
persisted, so that read wrote the admin password in cleartext into
`tfstate-<workspace>-state`.

Both variables are declared `ephemeral` and are required in both operating
modes. Two consequences:

- **They never reach the state or a saved plan.** Terraform enforces it:
  referencing them from a persisted context — a data source `query`, a
  `terraform_data` `input` — fails the run with `Invalid use of ephemeral
  value`. Only provider configuration and provisioner environments may consume
  them.
- **A `-out` plan file does not carry them.** `terraform plan -out=…` followed
  by `terraform apply <planfile>` needs them exported again for the apply.

### Filling them from the cluster Secret

`terraform/authserver/scripts/kc-admin-env.sh` resolves the credentials and
exports them. It writes nothing to stdout when sourced, so the values never
appear in the process list, in shell history or in a CI log:

```bash
cd terraform/authserver
. scripts/kc-admin-env.sh <namespace> [admin-secret-name]   # bash
terraform apply -var-file=../../<values-dir>/<stage>.tfvars
```

For a POSIX shell, the same script emits shell-quoted `export` lines instead:

```sh
eval "$(bash scripts/kc-admin-env.sh <namespace>)"
```

`make config` and `make config-plan` call the same script — the Makefile is one
consumer of it, not a prerequisite.

Resolution order (implemented in `scripts/kc-admin-credentials.sh`, which the
`data "external"` programs and the destroy-time provisioners also use):

1. `KC_USERNAME` / `KC_PASSWORD` already present in the environment
2. `TF_VAR_keycloak_username` / `TF_VAR_keycloak_password` — **both** must be
   set, otherwise this step is skipped
3. The Kubernetes Secret named by `keycloak_admin_secret` in
   `keycloak_namespace` (requires `kubectl` access)

Step 2 needing both variables matters in CI: exporting only the password falls
through to the cluster Secret. Where the pipeline value must win, export
`TF_VAR_keycloak_username` alongside it.

### What still reaches the state

The admin credentials no longer do, and neither does anything else: the client
secrets that used to be persisted all belonged to the fake sekIdP test realm,
which has been removed.

The production-relevant SMC-B identity provider secret uses the provider's
write-only argument (`client_secret_wo`) and is not persisted. Because a
write-only argument is invisible to Terraform after the apply, a changed secret
alone produces no diff — increment `smc_b_client_secret_version` to push a
rotated value.

Write-only arguments need Terraform 1.11+ and keycloak provider 5.9+. If your
working directory still has a `.terraform.lock.hcl` from an earlier run pinning
an older provider, `terraform init` keeps that version and the apply fails with
`The attribute client_secret is required` — delete the lock file (it is not
tracked) and re-run so init resolves a current provider.

## Terraform Variables

Set environment-specific variables in `<values-dir>/<stage>.tfvars`. The
directory is the Makefile's `VALUES_DIR` (default `local-test/`, so
`local-test/local.tfvars` for local development) — see the
[Makefile reference](../reference/Makefile_reference.md).
`terraform/authserver/environments/demo.tfvars` lists every accepted variable
with its default — copy it as a starting point. Key variables include:

```hcl
# Required — no defaults
keycloak_url        = "https://.../auth"  # URL of the Keycloak instance
audience_scope_name = "zero:audience"     # Name of the audience scope (see the note below)

# Required in Kubernetes mode, unused in local mode
keycloak_namespace  = "zeta-demo"         # Kubernetes namespace where Keycloak runs

# Optional — shown with their defaults
# insecure_tls   = false  # Set to true if using self-signed certificates
# use_kubernetes = true   # Set to false for local mode (no K8s backend)
# audience       = ""     # Explicit audience value; empty derives it from keycloak_url
# pdp_scopes     = []     # Additional PDP scopes, e.g. ["zero:read", "practitionerAccount.crud"]
```

### Complete variable reference

Variables marked **required** have no default; an apply without them fails.

#### Connection and state

| Variable                    | Type   | Default              | Description                                                                                                                                                                                                                                                                                       |
|-----------------------------|--------|----------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `keycloak_url`              | string | **required**         | External URL of the Keycloak instance, including the `/auth` path. With Admin API protection, point this at the admin hostname and set `audience` to the public one.                                                                                                                              |
| `keycloak_namespace`        | string | `""`                 | Kubernetes namespace the authserver is deployed in. Required when `use_kubernetes = true`; unused in local mode.                                                                                                                                                                                  |
| `master_realm_frontend_url` | string | `""`                 | Browser-facing base URL of the **master** realm, so the Admin Console's login stays on the admin hostname. Set it when Terraform reaches Keycloak at a different endpoint than administrators' browsers do. Must end in `/auth`. Empty derives it from `keycloak_url` whenever `audience` is set. |
| `use_kubernetes`            | bool   | `true`               | Store state in a Kubernetes Secret and read admin credentials from the cluster. `false` = local state file, credentials must be passed explicitly.                                                                                                                                                |
| `config_path`               | string | `"~/.kube/config"`   | Path to the kubeconfig; only used when `use_kubernetes = true`                                                                                                                                                                                                                                    |
| `keycloak_admin_secret`     | string | `"authserver-admin"` | Name of the Secret holding the Keycloak admin credentials                                                                                                                                                                                                                                         |
| `keycloak_username`         | string | `""`                 | Keycloak admin username. Ephemeral, required in both modes. Set via `TF_VAR_keycloak_username` — never in a tfvars file.                                                                                                                                                                          |
| `keycloak_password`         | string | `""`                 | Keycloak admin password. Ephemeral, required in both modes. Set via `TF_VAR_keycloak_password` — never in a tfvars file.                                                                                                                                                                          |
| `insecure_tls`              | bool   | `false`              | Skip TLS verification — enable for self-signed certificates (e.g. local KIND)                                                                                                                                                                                                                     |
| `skip_external_resources`   | bool   | `false`              | Skip the external scripts that would otherwise run on `terraform plan`                                                                                                                                                                                                                            |

#### Scopes and audience

| Variable              | Type         | Default      | Description                                                                                                                                              |
|-----------------------|--------------|--------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `audience_scope_name` | string       | **required** | Name of the audience scope. It carries the protocol mappers that inject the claims the PEP validates — see the note below.                               |
| `audience`            | string       | `""`         | Explicit audience value for the mappers. Empty derives it from `keycloak_url` (minus `/auth`). Required when `keycloak_url` points at an admin hostname. |
| `pdp_scopes`          | list(string) | `[]`         | Additional PDP scopes, created as realm optional scopes. They carry **no** claim mapper, so they cannot replace the audience scope.                      |

#### Identity providers

| Variable                      | Type   | Default        | Description                                                                                                                                                                                                                                                    |
|-------------------------------|--------|----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `smc_b_client_secret`         | string | `"**********"` | Client secret of the SMC-B identity provider. Ephemeral, written through the provider's write-only argument — not persisted in the state.                                                                                                                      |
| `smc_b_client_secret_version` | number | `1`            | Increment whenever `smc_b_client_secret` changes. A write-only argument is invisible to Terraform after the apply, so a changed secret alone produces no diff.                                                                                                 |
| `enable_sekidp`               | bool   | `false`        | Register the `zeta-sekidp-oidc` IdP, the mobile browser/first-login flows, the entity-statement keys and the email-binding scopes. The Fedmaster URL is provisioned via `provisioningProcessor.federationMaster` in `values.yaml`. |

#### Email binding (OTP delivery)

| Variable    | Type   | Default | Description                                                                                                 |
|-------------|--------|---------|-------------------------------------------------------------------------------------------------------------|
| `smtp_host` | string | `""`    | SMTP host for the realm's `smtpServer` config (e.g. MailCatcher). Empty omits the block entirely.           |
| `smtp_port` | string | `"25"`  | SMTP port                                                                                                   |
| `smtp_from` | string | `""`    | Sender address. Required by Keycloak whenever `smtp_host` is set — a missing or invalid `from` is rejected. |

#### Notification Service

Both must match the Helm chart values; they are not wired together.

| Variable                               | Type   | Default                   | Description                                                                                                                                                                                                                            |
|----------------------------------------|--------|---------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `notification_service_resource_suffix` | string | `"/notification-service"` | Path suffix appended to the Guard's public base URL to form the Notification Service's resource identifier (`aud`). Must match `notificationService.wellKnownResourceSuffix`; a mismatch breaks token validation. Must start with `/`. |
| `notification_history_enabled`         | bool   | `false`                   | Whether the history feature (A_29974) is enabled. When `true`, the `notification.history.read` scope is created. Must match `notificationService.historyEnabled`.                                                                      |

#### HSM-backed token signing

See [HSM Token Signing](#hsm-token-signing) for the full procedure.

| Variable                                 | Type   | Default | Description                                                        |
|------------------------------------------|--------|---------|--------------------------------------------------------------------|
| `hsm_token_signing_enabled`              | bool   | `false` | Register an HSM-backed ES256 KeyProvider in the `zeta-guard` realm |
| `hsm_token_signing_endpoint`             | string | `""`    | gRPC endpoint of the HSM Proxy (e.g. `hsm-sim:50051`)              |
| `hsm_token_signing_key_id`               | string | `""`    | Identifier of the signing key in the HSM                           |
| `hsm_token_signing_priority`             | string | `"200"` | Provider priority; higher wins (software keys sit at `100`)        |
| `hsm_token_signing_remove_software_keys` | bool   | `true`  | Remove software signing keys after the HSM key is registered       |

#### VAU database encryption

| Variable         | Type | Default | Description                                                                                                                |
|------------------|------|---------|----------------------------------------------------------------------------------------------------------------------------|
| `use_vau_db_enc` | bool | `false` | Apply client-side encryption to this realm. Recommended only when running in a trusted execution environment (German VAU). |

#### Session lifetime

The refresh-token TTL comes from the policy decision (`ttl.refresh_token`,
A_28527), but the authserver caps every
refresh token at the end of the user session behind it. Rotation does not extend
that session past the first refresh
token's expiry (A_25662). Set both limits to at least the largest refresh-token
TTL your policy issues — shorter values
end the session early, and the client has to run a full token exchange again.

| Variable                   | Type   | Default | Description                                                      |
|----------------------------|--------|---------|------------------------------------------------------------------|
| `sso_session_idle_timeout` | string | `"24h"` | Realm SSO session idle timeout as a Go duration (e.g. `"1h30m"`) |
| `sso_session_max_lifespan` | string | `"24h"` | Realm SSO session max lifespan as a Go duration                  |

### Validations

The following validations are enforced:

- `keycloak_namespace` (when `use_kubernetes = true`), `keycloak_url` and 
  `audience_scope_name` are required
  and have no default — an apply without them fails
- `keycloak_namespace` must be a valid Kubernetes namespace name
- `keycloak_url` must start with `http://` or `https://`
- `audience` must be empty or start with `http://` or `https://`
- `pdp_scopes` entries may only contain alphanumeric characters, underscores,
  colons, periods, or hyphens
- `audience_scope_name` may only contain alphanumeric characters, underscores,
  colons, periods, or hyphens
- `keycloak_username` and `keycloak_password` must both be non-empty, in both
  modes
- `sso_session_idle_timeout` and `sso_session_max_lifespan` must be durations
  such as `"24h"` or `"1h30m"`

> **Important — the audience scope carries the access-token claims the PEP
requires.**
> The scope named by `audience_scope_name` carries the protocol
> mappers that inject the claims the PEP validates on every request: `aud`,
> `profession_oid`,
> `client_id`, `ip_address`, `product_id`, `product_version`, `common_name`,
> `organization_name`. **The client must request this scope.** If a Fachdienst
> mandates a
> specific scope name — e.g. VSDM requires `scope=vsdservice` (A_26744) — set
> `audience_scope_name` to that value so the claims ride on it, and do not also
> list it in
> `pdp_scopes` (a duplicate scope name fails the apply). Otherwise, the issued
> token lacks those
> claims and the PEP rejects the request (e.g. `missing field 'aud'`) before any
> policy is
> evaluated. Exactly one audience scope exists per realm — the name you set here
> is the only one created.

---

## Applying Configuration

### Kubernetes mode (default)

`make config` resolves the credentials from the `authserver-admin` Secret via
`scripts/kc-admin-env.sh`, so nothing needs exporting:

```shell
make config stage=demo
```

Running terraform directly, source the same script first:

```shell
cd terraform/authserver
. scripts/kc-admin-env.sh zeta-demo
terraform apply -var-file=../../<values-dir>/demo.tfvars -auto-approve
```

To use a different password than the one in the Secret, export **both**
variables — the resolver only prefers them over the Secret when both are set:

```shell
export TF_VAR_keycloak_username=admin TF_VAR_keycloak_password=your_password
make config stage=demo
```

### Local mode

```shell
# Required: both credentials, no cluster fallback exists
export TF_VAR_keycloak_username=admin
export TF_VAR_keycloak_password=your_password

# Run without Kubernetes backend
make config stage=local TF_VAR_use_kubernetes=false
```

> If using the terminal the default path to the kubeconfig is `~/.kube/config`.
> Set `TF_VAR_config_path` if it differs.

`enable_sekidp = true` is supported in this mode. See
[How to configure the SEK-IDP / Fedmaster test chart](How_to_configure_sekidp.md).

### Dry-run (both modes)

In case you want a dry-run of the Terraform operations, use `config-plan`
instead.
This will not change your settings but print the differences between the current
state
and the desired state:

```shell
make config-plan stage=demo
```

---

## Makefile Details

The configuration targets perform the following steps:

1. **`generate-main-and-backend`** generates `main.tf`, `providers.tf`,
   `mode-assert.tf`, the backend configuration file from templates, based on
   `TF_VAR_use_kubernetes`:

- `true`: uses `backend "kubernetes"` with state stored in a K8s Secret;
- `false`: uses `backend "local"` with state stored on disk;

2. **`config-init`** runs the generator and initializes the Terraform backend
3. **`config`** runs `config-init`, then applies the Terraform configuration
4. **`config-plan`** runs `config-init`, then plans without applying
5. **`config-import`** imports the existing `zeta-guard` realm into the state.
   It is the first step when the state was lost — the remaining objects need
   Keycloak UUIDs resolved at runtime, listed in
   [How to upgrade ZETA Guard](How_to_upgrade_ZETA_Guard.md)

Key Makefile variables:

| Variable                   | Default          | Description                                                                              |
|----------------------------|------------------|------------------------------------------------------------------------------------------|
| `TF_VAR_use_kubernetes`    | `true`           | Toggle Kubernetes vs. local mode                                                         |
| `TF_VAR_config_path`       | `~/.kube/config` | Path to kubeconfig (K8s mode only)                                                       |
| `TF_VAR_keycloak_username` | *(empty)*        | Keycloak admin username. Filled from the Secret by `scripts/kc-admin-env.sh` when unset. |
| `TF_VAR_keycloak_password` | *(empty)*        | Keycloak admin password. Filled from the Secret by `scripts/kc-admin-env.sh` when unset. |

---

## Pipeline Considerations

### CI/CD with Kubernetes mode

The pipeline uses Kubernetes mode by default. Required CI/CD variables:

| Variable                   | Required | Description                                                              |
|----------------------------|----------|--------------------------------------------------------------------------|
| `TF_VAR_config_path`       | Yes      | Path to the kubeconfig file on the runner                                |
| `TF_VAR_keycloak_password` | No       | Overrides the K8s Secret — only together with `TF_VAR_keycloak_username` |
| `TF_VAR_keycloak_username` | No       | See above; the pipeline defaults it to `admin`                           |
| `KUBECONFIG_B64`           | Yes      | Base64-encoded kubeconfig for cluster access                             |

The pipeline stages `config` and `config-plan` rely on:

- The runner having `terraform`, `curl`, and `jq` available
- Network connectivity from the runner to the Keycloak endpoint
- A valid kubeconfig with permissions to read Secrets and manage the TF state
  Secret. `scripts/kc-admin-env.sh` reads `authserver-admin` with `kubectl`, so
  that permission is needed even though Terraform itself no longer reads it.

### CI/CD with local mode

For pipelines that cannot access the Kubernetes cluster (e.g. GitLab runners
without
cluster connectivity), set `TF_VAR_use_kubernetes=false` and provide credentials
explicitly via CI/CD variables.

> Note: In local mode, Terraform state is stored on the runner filesystem and
> will be
> lost between pipeline runs unless persisted via artifacts or cache.

### Self-signed certificates in CI/CD

When `insecure_tls = true` is set in the tfvars, the `managePolicies.sh` script
automatically skips TLS certificate verification for its API calls (`curl -k`).
No additional tools (openssl, keytool, Java) are required.

---

## Troubleshooting

- **Terraform init fails:** Verify that `config_path` points to a valid
  kubeconfig
  file and the current context is correct (`kubectl config get-contexts`).
- **Terraform apply fails initializing Keycloak provider:**
    - Check the `keycloak_url` in your `STAGE.tfvars`.
    - In K8s mode: confirm the admin password is present in the cluster secret
      (`kubectl get secret authserver-admin -n <namespace> -o yaml`). The secret
      should contain base64-encoded `username` and `password` fields.
  - Ensure `TF_VAR_keycloak_username` and `TF_VAR_keycloak_password` are both
    set — source `scripts/kc-admin-env.sh <namespace>` to fill them from the
    Secret. A missing value fails the run with a variable validation error.
    - If you encounter TLS certificate errors (`x509: certificate signed by unknown
    authority` or `PKIX path validation failed`), set `insecure_tls = true` in
      the
      tfvars.
- **`curl` or `jq` not found:** The policy management script requires `curl` and
  `jq`. Both are standard tools available on most systems and CI runners.
- **State conflicts in local mode:** If switching between K8s and local mode,
  run
  `make clean` first to remove the old backend state and re-initialize.
- **`409 Conflict` / `400 Bad Request` on apply against a realm that already
  exists** (`Client Scope … already exists`, `Identity Provider … already
  exists`, `proposed client profile name duplicated`): the objects are live but
  the state is empty, so Terraform tries to create them. Adopt them instead of
  reinstalling — see
  [How to upgrade ZETA Guard](How_to_upgrade_ZETA_Guard.md). No user data is at
  risk; Terraform does not manage users or DCR-registered clients.
- **`Error: Invalid for_each argument … will be known only after apply` during
  `terraform import`:** `terraform import` treats resources absent from the
  state
  as unknown, so a `for_each` keyed on another resource aborts the run. Fixed in
  the current chart (the notification mappers key off
  `local.notification_scope_names`); on an older one, upgrade the Terraform
  files
  before adopting. `plan` and `apply` are unaffected.

---

## Additional Notes

- In Kubernetes mode, Terraform state is stored in a Kubernetes Secret within
  the
  environment namespace. Secret name format: `tfstate-<workspace>-state`
  (e.g., `tfstate-default-state`).
- In local mode, state is stored in `terraform/authserver/terraform.tfstate` (
  gitignored).
- The `main.tf` and `providers.tf` files are generated dynamically and should
  not be edited manually (both gitignored).
- The Makefile and Terraform configurations are designed for seamless CI/CD
  integration.
- **The state is configuration, not data.** Terraform owns realm configuration
  only — users and DCR-registered clients live in the PostgreSQL database and
  are
  never touched by an apply. The state Secret carries no Helm ownership, so it
  survives `helm upgrade` and `helm uninstall`; only `make uninstall` deletes
  it,
  together with the database. Deleting the state is not an upgrade step: to
  carry
  an existing installation forward, or to recover a lost state, follow
  [How to upgrade ZETA Guard](How_to_upgrade_ZETA_Guard.md).

---

## Protecting the Keycloak Admin API

The Keycloak Admin REST API and Admin Console (`/auth/admin/*`) must not be
publicly accessible, and neither must the `master` realm
(`/auth/realms/master/*`): it carries the admin token endpoint — an admin access
token is minted there with `client_id=admin-cli` via direct grant — so leaving
it
public would re-open the credential surface that blocking `/auth/admin` closes.
The `master` realm serves no ZETA traffic; everything productive runs on the
`zeta-guard` realm. ZETA Guard supports protecting both via a dedicated admin
hostname.

### How it works

When `authserver.adminHostname` is set, the chart activates two-part
protection:

1. **`/auth/admin` and `/auth/realms/master` are routed to the PEP proxy, which
   denies them** — the `zeta-guard-pep` minion gains a `/auth/admin` and a
   `/auth/realms/master` path pointing at `pep-proxy-svc`, where a
   `location ~ ^/auth/(admin|realms/master)(/|$)` block returns `403 Forbidden`
   before the request reaches Keycloak. The `(/|$)` suffix keeps the `403` on
   segment boundaries, matching the Ingress `pathType: Prefix` that routes
   there,
   so a realm whose name merely starts with `master` is not denied — it still
   reaches the PEP (the controller turns the Ingress path into a plain nginx
   prefix, which is not segment-aware) and answers `401` for want of a token,
   exactly as `/auth/admin` has always behaved for e.g. `/auth/administration`.
   Every other `/auth/*` path (token exchange, nonce, registration,
   well-known, and the whole `zeta-guard` realm) keeps routing straight to the
   authserver via the `zeta-guard-auth` minion and never touches the PEP.

2. **Separate admin ingress** — a dedicated ingress is created for the admin
   hostname that routes `/auth` directly to the authserver, bypassing the PEP
   proxy block. Terraform and CI/CD runners use this hostname exclusively.

Terraform adds a third piece: it pins the **master realm's frontend URL** to the
admin hostname (`terraform/authserver/master-realm.tf`, applied on the next
`terraform apply`). The Admin Console is an OIDC client of the master realm and
derives its `authServerUrl` from that realm's frontend URL, which by default
follows Keycloak's `--hostname` — the public hostname. Without the pin the
console's login redirect would land on the now-blocked
`/auth/realms/master/protocol/openid-connect/auth` and the browser login would
break. The pin is derived automatically whenever `audience` is set (the marker
that `keycloak_url` points at the admin hostname). Only the master realm is
touched — the `zeta-guard` realm keeps the public issuer every access token
carries.

#### When `master_realm_frontend_url` is required

The derivation equates two things that are only usually the same: the URL
**Terraform** talks to, and the URL **administrators open in a browser**. Set
the variable where they diverge. The case to expect is the one the hardening
guidance itself creates: an admin hostname that deliberately does not resolve
publicly forces Terraform through a tunnel or port-forward, and the derived pin
would then be that tunnel — leaving the console dead for every other browser.

```hcl
keycloak_url              = "https://localhost:8443/auth"
audience                  = "https://zeta.example.com"
master_realm_frontend_url = "https://admin.example.com/auth"
```

**What it cannot do: relocate or hide the Admin UI.** The value is a
declaration, not a redirect. Keycloak only builds the URLs it *advertises* from
it — the issuer, the realm endpoints, and the `authServerUrl` the console uses.
Where the UI actually answers is decided by the ingress and `--hostname-admin`.
Pointing this at a host or path with no route to the authserver therefore does
not move the console, it breaks it, while the UI stays reachable at its real
address. It is not an access control.

The value must end in `/auth`: Keycloak appends the realm path verbatim and does
**not** add the context path, so any other path yields endpoints the console
advertises but cannot reach. A validation rejects such a value at plan time —
without it the mistake would surface only as a failing browser login.

The split relies on overlapping prefixes being resolved **longest-match-first**,
which both nginx and the Ingress specification guarantee regardless of
declaration order: `/auth/admin` and `/auth/realms/master` win over `/auth`.

This approach is ingress-controller-agnostic: it works with F5 NIC, standard
nginx-ingress, OpenShift Routes, GKE Ingress and any other ingress solution,
because enforcement needs nothing but plain Ingress path routing plus the PEP's
own nginx configuration — no controller-specific annotations.

> **IP-based access restriction** for the admin hostname must be configured at
> the infrastructure layer: Cloud Armor (GKE), NetworkPolicy/Route annotation
> (OpenShift), or firewall rules. The chart does not enforce IP-based access.

### Configuration

```yaml
zeta-guard:
  authserver:
    hostname: "zeta.example.com"
    # Separate hostname for Keycloak admin access.
    # When set, /auth/admin and /auth/realms/master are blocked on the main
    # hostname via the PEP proxy, and a dedicated admin ingress is created for
    # this hostname.
    adminHostname: "admin.zeta.example.com"
```

Update `keycloak_url` in the corresponding `*.tfvars` to point to the admin
hostname — Terraform authenticates against the `master` realm, which the main
hostname no longer serves:

```hcl
keycloak_url = "https://admin.zeta.example.com/auth"
```

To **disable** the feature again, remove `adminHostname` (or set it to `""`) in
the values file and run `make deploy stage=<env>`. The admin ingress, the
`/auth/admin` and `/auth/realms/master` Ingress paths and the PEP proxy location
block are removed automatically on the next Helm upgrade — both then stay
reachable on the main hostname, since otherwise there would be no way to reach
them at all.

### Limitation: tiger-proxy environments

When `routeViaTigerProxy: true`, the `/auth/admin` and `/auth/realms/master`
Ingress paths are **not** rendered: tiger-proxy forwards
`/auth → http://authserver/auth` internally and bypasses the PEP entirely, so
routing the paths there would not block anything. With F5 NIC the
`location-snippets` layer on `zeta-guard-auth` still returns `404`; with any
other ingress controller both stay reachable on the main hostname. This is
expected — tiger-proxy is a test tool and is never used in production. Set
`routeViaTigerProxy: false` (the default for production) to activate the
controller-agnostic admin API block.

### Local development (KIND)

`local-test/values.local.yaml` does not set `adminHostname` by default, because
the standard local setup routes traffic through tiger-proxy
(`routeViaTigerProxy: true`), which bypasses the PEP proxy location blocks.

To **test admin API blocking** with a local KIND cluster:

1. Add `adminHostname` and disable tiger-proxy in your local values file:

   ```yaml
   issuers:
     local:
       dnsNames:
         - zeta-kind.local
         - admin.zeta-kind.local   # add the admin hostname to the cert SAN list
         - localhost

   zeta-guard:
     authserver:
       adminHostname: admin.zeta-kind.local
       adminTlsSecretName: zeta-guard-tls   # reuse the existing cert (KIND has no ClusterIssuer)
     routeViaTigerProxy: false
   ```

Disable tiger-proxy following the steps
in [How to configure tiger-proxy](How_to_configure_tiger-proxy.md) under
"Deactivate routing via tiger proxy".

2. Redeploy: `make deploy stage=local`

3. In your Terraform variables file, point `keycloak_url` at the admin hostname
   and set the `audience` explicitly so access tokens carry the main hostname,
   not the
   admin one:

   ```hcl
   keycloak_url = "https://admin.zeta-kind.local/auth"
   audience     = "https://zeta-kind.local"
   ```

4. Apply Terraform: `make config stage=local`

The Makefile automatically picks up `adminHostname:` values when patching
CoreDNS for the KIND cluster, otherwise manual DNS entry is needed (adding the
host `https://admin.zeta-kind.local`.

---

## Deployment configuration

### ServiceAccount

By default, a dedicated ServiceAccount is created with
`automountServiceAccountToken: false`:

```yaml
zeta-guard:
  authserver:
    serviceAccount:
      create: true
      name: authserver
```

### Resources

Resource requests and limits can be configured separately for the main
container and the two init containers:

```yaml
zeta-guard:
  authserver:
    container:
      resources:
        limits:
          cpu: "8"
          memory: "4Gi"
        requests:
          cpu: "4"
          memory: "4Gi"
    initContainer:  # keycloak-copy, only copies the image's /opt/keycloak
      resources:
        limits:
          memory: "256Mi"
        requests:
          cpu: "100m"
          memory: "64Mi"
  provisioningProcessor:
    resources:
      limits:
        cpu: "1"
        memory: "200Mi"
      requests:
        cpu: "100m"
        memory: "100Mi"
```

> The `provisioningProcessor` is a shared init container used by authserver,
> OPA, OPA-simulation, and PEP-Proxy. It is configured at the top level of the
> zeta-guard chart, not under `authserver`. For the image source, mirroring the
> signed provisioning data image, and the registry CA configuration, see
> [How to use a custom OCI registry](How_to_use_a_custom_OCI_registry.md).

### Replicas and PodDisruptionBudget

```yaml
zeta-guard:
  authserver:
    replicaCount: 2
    podDisruptionBudget:
      enabled: true
      minAvailable: 1
```

> **Scaling `replicaCount` also scales database connections.** Each authserver
> pod opens its own JDBC pool, so the total number of PostgreSQL connections
> grows linearly with `replicaCount`. See
> [Database connection pool and scaling](#database-connection-pool-and-scaling)
> below before raising `replicaCount` — the chart refuses to render if the pool
> budget exceeds the database's `max_connections`.

### Security context

All security contexts of the chart start from two chart-wide defaults (PSS
`restricted`): `defaultPodSecurityContext` for every pod and
`defaultContainerSecurityContext` for every container. A component's
`podSecurityContext` / `containerSecurityContext` only lists what differs —
every
key set there wins, every other key comes from the default:

```yaml
zeta-guard:
  defaultPodSecurityContext:
    seccompProfile:
      type: RuntimeDefault
  defaultContainerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 1000
    capabilities:
      drop: [ "ALL" ]
  authserver:
    podSecurityContext: {}
    container:
      containerSecurityContext: {}
    initContainer:
      containerSecurityContext: {}
  provisioningProcessor:
    containerSecurityContext:
      readOnlyRootFilesystem: false
```

The merge is per top-level key: setting `capabilities` in a component replaces
the whole map, so keep `drop: [ "ALL" ]` when adding a capability. `runAsUser`
deliberately lives on the container level, so it is not inherited by injected
sidecars such as `istio-proxy`.

`runAsUser` is required because the Keycloak image declares a non-numeric user,
which the kubelet cannot verify against `runAsNonRoot`. On OpenShift, set
`defaultContainerSecurityContext.runAsUser: null` so the SCC assigns the UID.

### Probes

Liveness, readiness and startup probe thresholds are configurable:

```yaml
zeta-guard:
  authserver:
    probes:
      liveness:
        initialDelaySeconds: 0
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 5
      readiness:
        initialDelaySeconds: 0
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 3
      startup:
        initialDelaySeconds: 10
        periodSeconds: 5
        timeoutSeconds: 5
        failureThreshold: 60
```

**Why liveness stays DB-independent.** Keycloak's `/health/live` never touches
the database, and it deliberately stays that way. Pointing liveness at
`/health/ready` would make a single database outage fail the probe on *every*
authserver pod simultaneously, so the kubelet would restart them all at once and
the CrashLoopBackOff ramp would then delay recovery after the database came
back — one recoverable incident turned into a restart cascade. Liveness is for
an unresponsive JVM; database availability is readiness' job, and taking a pod
out of the Service endpoints is the correct response to it. What actually
recovers a wedged datasource is the connection validation described under
*Connection resilience* below, which needs no help from the kubelet.

> **⚠️ Do not leave `timeoutSeconds` unset.** Kubernetes defaults it to **1 s**,
> which is too tight here. Agroal's `invalidCount` is a monotonic counter that
> never resets, so once connection validation has evicted its first connection,
> Keycloak takes the *blocking* `DataSourceHealthCheck` branch on **every**
> readiness probe — opening a connection and validating it — instead of
> answering
> from pool metrics. Under load a 1 s timeout flaps. The ceiling is Agroal's
> acquisition timeout (`PT20S`), so 5 s is a safe middle ground.

### CloudNativePG database connection

When `databaseMode` is set to `cloudnative`, the JDBC URL, secret name and
schema are configurable:

```yaml
zeta-guard:
  databaseMode: cloudnative
  cloudnativeDbUrl: "jdbc:postgresql://keycloak-db-rw:5432/keycloak"
  cloudnativeDbSecretName: "keycloak-db-app"
  cloudnativeDbSchema: "public"
```

Extra JDBC parameters are appended to that URL via `authserver.db.urlProperties`
(this works the same way for `databaseMode: external` and
`authserverDb.kcDbUrl`):

```yaml
zeta-guard:
  authserver:
    db:
      urlProperties:
        socketTimeout: 600
```

This is where the pgjdbc driver settings live. They cannot be passed as
`QUARKUS_DATASOURCE_JDBC_ADDITIONAL_JDBC_PROPERTIES_*` environment variables:
that is a Map property, and an environment variable name cannot carry the
camelCase key — it would arrive as `sockettimeout`, which pgjdbc silently
ignores. In the URL the case survives, and pgjdbc gives URL values priority over
connection properties anyway.

> **⚠️ `connectTimeout` and `targetServerType` are rejected here** and the chart
> fails the render if you set them. Keycloak injects both itself
> (`db-connect-timeout` default `10s`, `db-postgres-target-server-type` default
> `primary`) but *skips* that injection as soon as it finds either name already
> in
> the URL — so naming one silently drops the other. Use `--db-connect-timeout`
> for
> the former and leave the latter alone. For the same reason, do not use
> `KC_DB_URL_PROPERTIES`: Keycloak ignores it whenever `db-url` is set, which
> the
> chart always does.

### Database connection pool and scaling

Each authserver pod maintains **its own** JDBC connection pool, so the total
number of PostgreSQL connections scales with `replicaCount`:

```
total worst-case connections = replicaCount × authserver.dbPool.maxSize
total idle connections       = replicaCount × authserver.dbPool.minSize
```

These must fit within the database's connection limit. For the managed
CloudNativePG cluster that limit is `cloudnativePg.parameters.maxConnections`.
The chart **enforces this at render time** and fails the deploy with a clear
message if the budget is exceeded (leaving ~25 connections in reserve for the
CNPG instance-manager, replication and superuser slots):

```
replicaCount × dbPool.maxSize + 25 ≤ cloudnativePg.parameters.maxConnections
```

If this is violated at runtime instead, PostgreSQL rejects new connections
(`SQLSTATE 53300 – remaining connection slots are reserved…`) and the database
can crash under load — which is exactly the failure this guard prevents.

> **⚠️ External databases (`databaseMode: external`).** The render-time guard runs
> **only** for the managed CloudNativePG database — the chart has no way to know
> the connection limit of a database it doesn't manage. If you bring your own
> database and run `replicaCount > 1`, **you** are responsible for ensuring:
>
> ```
> replicaCount × authserver.dbPool.maxSize + <your DB's reserved connections>
>   ≤ your database's max_connections
> ```
>
> A stock PostgreSQL defaults to `max_connections = 100`, so even two pods
> (2 × 100 = 200) will exhaust it. Either raise your database's `max_connections`
> (and size its memory for it), lower `authserver.dbPool.maxSize`, or put a
> connection pooler in front of your database. Otherwise, you hit the same
> `SQLSTATE 53300` exhaustion and crash — with no warning at deploy time.

The chart **defaults are intentionally minimal** — sized for a single authserver
pod (plus small multi-pod stages) so light environments don't over-allocate DB
resources:

```yaml
zeta-guard:
  authserver:
    dbPool:
      minSize: 10     # idle floor per pod
      maxSize: 100    # cap per pod (≤ httpPool.maxThreads = 300; above that is wasteful)
  cloudnativePg:
    parameters:
      maxConnections: 250
      sharedBuffers: 128MB
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        memory: 2Gi   # no cpu limit (see "Scaling out" below)
```

> **Note:** `dbPool.maxSize` above `httpPool.maxThreads` (300) is wasteful — a
> pod cannot use more DB connections than it has request-handling threads.

**Scaling out.** When you raise `replicaCount`, raise the DB capacity in the
**same environment overlay** — `dbPool.maxSize` (throughput per pod),
`maxConnections`, `sharedBuffers`, and `cloudnativePg.resources` — as a set. Size
memory for the connection count (~6MB per backend plus `shared_buffers`, e.g. ~6Gi
for ~650 connections) and keep memory `requests ≤ limits`. The DB intentionally
runs **without a CPU limit** (a CPU limit is a CFS quota that throttles the DB
under load); set `cpu.request` as the guaranteed floor and let it burst into spare
node CPU. Example for a 3-pod stage (3 × 200 + 25 reserve = 625 ≤ 650):

```yaml
zeta-guard:
  authserver:
    replicaCount: 3
    dbPool:
      maxSize: 200
  cloudnativePg:
    parameters:
      maxConnections: 650
      sharedBuffers: 512MB
    resources:
      requests: { cpu: "2", memory: 4Gi }   # cpu.request = guaranteed floor
      limits:   { memory: 8Gi }              # no cpu limit; memory sized for backends
```

If you raise `replicaCount` without raising the DB budget, the chart **fails the
render** with a clear message rather than shipping a config that exhausts
connections (`SQLSTATE 53300`) and crashes the DB under load.

A single PostgreSQL instance handling many hundreds of connections is itself a
bottleneck; for a large number of pods, prefer a connection pooler (PgBouncer,
via `cloudnativePg.pooler`) in front of the database so application connections
are multiplexed onto a small number of backends.

---

### Connection resilience and database failover

Losing the PostgreSQL primary is not a clean disconnect. Deleting the
CloudNativePG primary **pod** destroys its network namespace while the
`keycloak-db-rw` ClusterIP stays valid, so kube-proxy's existing conntrack
entries keep routing to an IP that no longer answers. Nothing sends a TCP reset,
so every packet is simply dropped — a *blackhole*, not an error. That is why a
graceful database restart recovers by itself (the sockets are closed, pgjdbc
raises `08006` immediately) while a pod recreate used to hang the authserver
until an operator restarted it.

The chart carries the defence — these are the values that provide it:

| Values key                            | Rendered as                                              | Default | Why                                                                                                                                                   |
|---------------------------------------|----------------------------------------------------------|---------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| `db.urlProperties.socketTimeout`      | `?socketTimeout=` on `KC_DB_URL`                         | `120`   | Seconds. The only bound on a blocking read — and the only bound on the authentication exchange of a *replacement* connection.                         |
| `db.urlProperties.tcpKeepAlive`       | `&tcpKeepAlive=` on `KC_DB_URL`                          | `true`  | Detects some dead peers earlier, though not a frozen server.                                                                                          |
| `dbPool.validationQueryTimeout`       | `QUARKUS_DATASOURCE_JDBC_VALIDATION_QUERY_TIMEOUT`       | `2S`    | Without it Agroal validates with `isValid(0)` — no timeout — and the validation hangs on the very socket it should detect.                            |
| `dbPool.foregroundValidationInterval` | `QUARKUS_DATASOURCE_JDBC_FOREGROUND_VALIDATION_INTERVAL` | `5S`    | Validate on acquire when a connection has been idle longer than this. Quarkus has no default, i.e. stale connections go straight to a request thread. |
| `dbPool.backgroundValidationInterval` | `QUARKUS_DATASOURCE_JDBC_BACKGROUND_VALIDATION_INTERVAL` | `15S`   | Sweeps idle connections (Quarkus default is 2 minutes).                                                                                               |
| `dbPool.idleRemovalInterval`          | `QUARKUS_DATASOURCE_JDBC_IDLE_REMOVAL_INTERVAL`          | `1M`    | Trims the burst tail; never shrinks the pool below `dbPool.minSize`.                                                                                  |

> **Why plain `QUARKUS_*` variables work.** Keycloak exposes no option for any
> of the validation settings. Its own `KcEnvConfigSource` reads only `KC_`- and
> `KCRAW_`-prefixed names, but it does not replace Quarkus' default
> `EnvConfigSource` — both are registered, so Quarkus properties Keycloak does
> not map are configurable this way. Note the failure mode: a **misspelled name
> is silently ignored**. To prove one is read, give it a value that cannot be
> converted; Keycloak then refuses to start with `SRCFG00039` naming the
> property.

Two further settings complete it:

- **`authserver.dbPool.maxLifetime`** (default `PT30M`) recycles every pooled
  connection periodically, so a socket orphaned by a switchover cannot be parked
  indefinitely. Set through Keycloak's own `--db-pool-max-lifetime`: it maps to
  `quarkus.datasource.jdbc.max-lifetime`, and setting that Quarkus name directly
  makes Keycloak log `Please use the first-class option ... instead`.

> **⚠️ `socketTimeout` also applies to schema migrations.** Any statement
> running
> longer than 120 s is killed with SQLSTATE `08006`, **Liquibase DDL
included** —
> and a migration killed mid-flight leaves `DATABASECHANGELOGLOCK` held, after
> which the next start waits 30 minutes before failing. If you expect a heavy
> migration, raise it for that release via
> `authserver.db.urlProperties.socketTimeout`. To release a stuck lock:
>
> ```sql
> UPDATE databasechangeloglock SET locked = false, lockgranted = NULL, lockedby = NULL;
> ```

Verify the behaviour with the `agroal_*` counters on the management port: during
an outage `agroal_invalid_count` and `agroal_destroy_count` must rise (the pool
evicted the dead connections) and `agroal_creation_count` must rise again once
the database returns (it built fresh ones rather than reusing the old).

> **Note.** `cloudnativePg.instances: 1` makes every primary replacement a full
> outage. Raising it to 3 gives automatic failover — but it also makes primary
> changes routine rather than exceptional, so the connection resilience above is
> a
> **prerequisite** for that to deliver availability instead of repeated long
> outages. PgBouncer (`cloudnativePg.pooler`) is not a substitute: the socket to
> a
> pooler pod blackholes in exactly the same way.

## ECC-Only Key Configuration

The `zeta-guard` realm must only contain ECC keys in its JWKS endpoint
(`/auth/realms/zeta-guard/protocol/openid-connect/certs`). RSA keys are
not permitted — access tokens are always signed with ES256 (P-256).

### Why RSA keys appear by default

Keycloak automatically creates default key providers when a realm is
initialized, including `rsa-enc-generated` (RSA-OAEP encryption key). This key
appears in the JWKS endpoint even though no component in ZETA Guard uses RSA
token encryption.

### How RSA keys are removed

`make config` unconditionally runs a Terraform-managed cleanup script
(`terraform/authserver/scripts/remove-rsa-keys.sh`) that queries the
`org.keycloak.keys.KeyProvider` components of the `zeta-guard` realm and deletes
every provider whose `providerId` starts with `rsa`. The script is idempotent —
it is safe to run repeatedly.

### Verify

```bash
curl -sk https://<hostname>/auth/realms/zeta-guard/protocol/openid-connect/certs | jq '.keys[].kty'
```

Expected output: only `"EC"` entries. No `"RSA"` entries should be present.

---

## HSM Token Signing

HSM-backed ES256 token signing ensures that the private key used to sign JWTs
(access tokens, ID tokens, refresh tokens) never leaves the HSM. The signing
operation is delegated via gRPC to the HSM Proxy.

### Prerequisites

- HSM Proxy reachable from authserver pods (e.g., `hsm-sim:50051`)
- A signing key provisioned in the HSM (e.g.,
  `zeta-guard-keycloak-token-es256-v1.p256`)
- `hsm-token-signing` plugin deployed in the Keycloak image (`providers/`
  directory)

### Step 1 — Enable HSM and token signing in Helm values

```yaml
zeta-guard:
  authserver:
    hsm:
      enabled: true
      endpoint: "hsm-sim:50051"
      keyId: "zeta-guard-keycloak-tls-es256-v1.p256"       # TLS key (if TLS is also HSM-backed)
      tokenSigning:
        enabled: true
        keyId: "zeta-guard-keycloak-token-es256-v1.p256"   # Token signing key
        failClosed: true                                   # Refuse software-key fallback if HSM unreachable (default)
  hsmsim:
    enabled: true   # Deploy hsm-sim pod (non-production only)
```

This sets `HSM_PROXY_ENDPOINT`, `HSM_PROXY_TOKEN_KEY_ID`, and
`KC_SPI_KEYS_ZETA_HSM_TOKEN_SIGNING_FAIL_CLOSED` on the authserver pod.

With `failClosed: true` (default), token issuance fails 500 when the HSM is
unreachable — no software-key fallback. Only applies to realms with a
registered `zeta-hsm-token-signing` component; `master` falls through at first
boot so admin auth can bootstrap. Set `false` only for HSM maintenance windows.

### Step 2 — Deploy

```bash
make deploy stage=<env>
```

Keycloak starts with the HSM plugin loaded. The JCA security provider is
registered at startup, but the KeyProvider component is not yet active.

### Step 3 — Register the HSM KeyProvider via Terraform

Add to the stage tfvars:

```hcl
# <values-dir>/<stage>.tfvars, e.g. local-test/local.tfvars
hsm_token_signing_enabled  = true
hsm_token_signing_endpoint = "hsm-sim:50051"
hsm_token_signing_key_id   = "zeta-guard-keycloak-token-es256-v1.p256"
```

Run the config job:

```bash
make config stage=<env>
```

This creates the HSM KeyProvider component in the `zeta-guard` realm and removes
software signing keys (`rsa-generated`, `ecdsa-generated`).

### Step 4 — Verify

```bash
curl -sk https://<hostname>/auth/realms/zeta-guard/protocol/openid-connect/certs \
  | jq '.keys[] | select(.use == "sig") | {kid, alg}'
```

Expected: a single ES256 signing key from the HSM. No RSA signing keys.

### Disable

Set `hsm_token_signing_enabled = false` in tfvars and run `make config` again.

### Terraform variables

See [HSM-backed token signing](#hsm-backed-token-signing) in the complete
variable reference.

---

## SMC-B OCSP revocation check

During token exchange the authserver checks the revocation status of the SMC-B
certificate via OCSP (the responder is taken from the certificate's AIA
extension). The OCSP request timeouts and the fail-closed are configurable:

```yaml
zeta-guard:
  authserver:
    provider:
      smcB:
        ocspConnectTimeoutMs: 1000    # connect timeout of the OCSP request (ms)
        ocspReadTimeoutMs: 3000       # read timeout of the OCSP request (ms)
        ocspFailClosed: false         # deny only on REVOKED; allow undetermined status (fail-open)
```

This sets
`KC_SPI_TOKEN_EXCHANGE_PROVIDER_ZETA_SMC_B_TOKEN_EXCHANGE_OCSP_CONNECT_TIMEOUT_MS`,
`..._OCSP_READ_TIMEOUT_MS` and `..._OCSP_FAIL_CLOSED` on the authserver pod.

| Value                                           | Description                                         | Default |
|-------------------------------------------------|-----------------------------------------------------|---------|
| `authserver.provider.smcB.ocspConnectTimeoutMs` | Connect timeout of the SMC-B OCSP request (ms)      | `1000`  |
| `authserver.provider.smcB.ocspReadTimeoutMs`    | Read timeout of the SMC-B OCSP request (ms)         | `3000`  |
| `authserver.provider.smcB.ocspFailClosed`       | Also deny when the OCSP status cannot be determined | `false` |

By default (`ocspFailClosed: false`) the check is **fail-open**: only a
positively `REVOKED` certificate is rejected (`invalid_token`); any undetermined
result — OCSP responder unreachable, timeout, or status `unknown` — 
is **allowed** so token issuance keeps working during an OCSP responder outage 
or maintenance window. Set `ocspFailClosed: true` to **fail-closed**, i.e. also 
reject when the revocation status cannot be determined (stricter, in line with 
TUC_PKI_006, gemSpec_PKI). A `REVOKED` certificate is always rejected regardless
of this setting; and when no OCSP signer truststore is configured the check is
disabled entirely (test environments only).

---

## Cluster-internal PEP → authserver communication

The PEP validates access tokens against the authserver's JWKS. It finds that
JWKS by fetching `<pepIssuer>/.well-known/openid-configuration` and then the
`jwks_uri` the discovery document advertises.

Because `pepIssuer` must be the **public** issuer — it is the `iss` the PEP
expects in every access token — both fetches would follow the public hostname.
They would then leave the cluster and come back in through the load balancer and
ingress, even though the authserver runs next to the PEP. In a multi-cluster
setup this can even cross sites.

`pepInternalUrl` keeps that traffic inside the cluster. The chart always deploys
the authserver as the `authserver` Service, so the value **defaults to it** —
the
same address `pep_revocation_url` already uses. No configuration is needed:

```yaml
zeta-guard:
  pepproxy:
    nginxConf:
      # public — stays the expected `iss` of the access tokens
      pepIssuer: "https://<public-host>/auth/realms/zeta-guard"
      # internal — the default; only override for a non-standard realm path,
      # or set to "" to disable
      pepInternalUrl: "http://authserver/auth/realms/zeta-guard"
```

This renders the `pep_pdp_url` directive into the PEP's nginx config. Discovery
is then fetched over the in-cluster Service, and the `jwks_uri` advertised by
the
authserver is rewritten from the public issuer prefix onto `pepInternalUrl`.

Notes:

- `pepInternalUrl` must mirror the issuer's **path structure** — the rewrite
  substitutes the issuer prefix. If the advertised `jwks_uri` does not sit under
  `pepIssuer`, the PEP fetches it as advertised and logs a warning.
- Token validation is unchanged and the issuer check stays strict. Reached over
  the internal Service, Keycloak would otherwise derive the scheme from the
  request and advertise `http://…` where the PEP expects `https://…`. The PEP
  therefore presents the public issuer's origin (`Host`, `X-Forwarded-Proto`,
  `X-Forwarded-Host`) on these two fetches, so the authserver renders its
  frontend URLs exactly as it does for public traffic.
- The internal hop can be plain HTTP to the `authserver` Service, so no
  certificate valid for the public hostname is needed.
- The session revocation endpoint (`pep_revocation_url`, SSE block list and
  reports) follows `pepInternalUrl` as `<pepInternalUrl>/zeta-guard-revocation`.
  `pepRevocationUrl` overrides it when the authserver is reachable under another
  address or realm path.
- Requires a PEP image from 1.3.1 on. Older images fail to start with
  `unknown directive "pep_pdp_url"` — pin `pepproxy.image.tag` accordingly and
  set `pepInternalUrl: ""` in that case.
- With `networkPolicy.enabled: true` the required egress (PEP → authserver pod,
  port 8080) is already part of `pep-proxy-egress`. Once `pepInternalUrl` is in
  use, the ingress IP in
  `networkPolicy.egress.providerInternal.resourceServers.ipBlocks` is no longer
  needed for the JWK fetch — see
  [How to configure NetworkPolicies](How_to_configure_NetworkPolicies.md).

### Alternative: host aliases

If the internal endpoint cannot be addressed by Service name, map the hostname
in the PEP pod instead:

```yaml
zeta-guard:
  pepproxy:
    hostAliases:
      - ip: 10.96.1.23          # ClusterIP of the *ingress controller*
        hostnames:
          - <public-host>
```

Point this at the ingress controller, not at the authserver: the PEP still
speaks HTTPS to the public hostname, and only the ingress controller serves a
certificate valid for that name. Entries are merged with those generated by
`global.enableDNSRedirect`.

Prefer `pepInternalUrl` where possible — it needs no IP address (ClusterIPs are
cluster-specific and change when a Service is recreated) and avoids the TLS
consideration entirely.

---

## Related Resources

- [How to upgrade ZETA Guard](How_to_upgrade_ZETA_Guard.md)
- [Terraform Keycloak Provider](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs)
- [Keycloak Admin REST API](https://www.keycloak.org/docs-api/latest/rest-api/index.html)

```
helm lint charts/zeta-guard --strict -f charts/zeta-guard/values-demo.yaml --set authserver.admin.password=dummy --set authserver.hsm.tokenSigning.enabled=true --set authserver.hsm.enabled=false
```
