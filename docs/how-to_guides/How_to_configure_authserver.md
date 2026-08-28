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
> - Audience scope name (default: `zero:audience`) — the scope that carries the
>   access-token claims the PEP requires (see the note under "Terraform
    Variables")
>
> Predefined settings:
> - PDP scopes `zero:manage` and `zero:register` are automatically created
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

|                   | **Kubernetes mode** (default)             | **Local mode**                                |
|-------------------|-------------------------------------------|-----------------------------------------------|
| **State backend** | Kubernetes Secret in the cluster          | Local `terraform.tfstate` file                |
| **Credentials**   | Read from K8s Secret `authserver-admin`   | Must be provided explicitly                   |
| **Typical use**   | CI/CD pipelines, cluster-connected admins | Local development, no cluster access required |
| **Set via**       | `TF_VAR_use_kubernetes=true` (default)    | `TF_VAR_use_kubernetes=false`                 |

---

## Prerequisites

### Common (both modes)

- Terraform installed (version compatible with the providers)
- Make installed
- `curl` and `jq` available in PATH
- Network access to the Keycloak instance from the machine running Terraform

### Kubernetes mode (default)

- A running ZETA Guard Kubernetes cluster
- `kubectl` configured to access the cluster
- Keycloak admin credentials stored in K8s Secret `authserver-admin` (created by
  the Helm chart)

### Local mode

- `TF_VAR_use_kubernetes=false` set in the Makefile invocation or as environment
  variable
- Keycloak admin credentials are provided explicitly:
    - `TF_VAR_keycloak_password` (required)
    - `TF_VAR_keycloak_username` (defaults to `admin`)
- Terraform state is stored locally in `terraform.tfstate` (not in the cluster)

> When using self-signed certificates (e.g. local KIND cluster), set
> `insecure_tls = true`
> in the tfvars file. The management script will automatically extract the
> server certificate
> and configure a temporary Java truststore for `kcadm.sh`.

---

## Terraform Variables

Set environment-specific variables in `environments/STAGE.tfvars` (or
`private/STAGE.tfvars` for local development). Key variables include:

```hcl
insecure_tls = true                                     # Set to true if using self-signed certificates
use_kubernetes = true                                   # Set to false for local mode (no K8s backend)
keycloak_url = "https://.../auth"                       # URL of the Keycloak instance
keycloak_namespace = "zeta-demo"                        # Kubernetes namespace where Keycloak runs
pdp_scopes = [
  "zero:read", "practitionerAccount.crud"
]  # Optional additional scope list
# audience_scope_name = "zero:audience"                 # Optional: rename the audience scope (default: "zero:audience")
# audience            = "https://..."                   # Optional: explicit audience value (default: derived from keycloak_url)
```

The following validations are enforced:

- `keycloak_namespace` must be a valid Kubernetes namespace name
- `keycloak_url` must start with `http://` or `https://`
- `audience` must be empty or start with `http://` or `https://`
- `pdp_scopes` entries may only contain alphanumeric characters, underscores,
  colons, periods, or hyphens
- `audience_scope_name` may only contain alphanumeric characters, underscores,
  colons, periods, or hyphens
- When `use_kubernetes = false`, both `keycloak_username` and
  `keycloak_password` must be set

> **Important — the audience scope carries the access-token claims the PEP
requires.**
> The scope named by `audience_scope_name` (default `zero:audience`) carries the
> protocol
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
> evaluated. Note that setting `audience_scope_name` replaces the default
> `zero:audience` scope.

---

## Applying Configuration

### Kubernetes mode (default)

```shell
# Set the Keycloak admin password (optional if stored in K8s Secret)
export TF_VAR_keycloak_password=your_password

# Configure the authserver
make config stage=demo
```

If the Keycloak admin password is stored in the K8s Secret `authserver-admin`,
you can omit `TF_VAR_keycloak_password` entirely:

```shell
make config stage=demo
```

### Local mode

```shell
# Required: set credentials
export TF_VAR_keycloak_password=your_password

# Run without Kubernetes backend
make config stage=local TF_VAR_use_kubernetes=false
```

> If using the terminal the default path to the kubeconfig is `~/.kube/config`.
> Set `TF_VAR_config_path` if it differs.

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

1. **`generate-main-and-backend`** generates `main.tf`, `providers.tf`, and the
   backend configuration file from templates, based on `TF_VAR_use_kubernetes`:

- `true`: uses `backend "kubernetes"` with state stored in a K8s Secret;
  includes the `hashicorp/kubernetes` required provider and
  `provider "kubernetes"` block
- `false`: uses `backend "local"` with state stored on disk;
  the Kubernetes provider is omitted entirely (no download or configuration
  required)

2. **`config-init`** runs the generator and initializes the Terraform backend
3. **`config`** runs `config-init`, then applies the Terraform configuration
4. **`config-plan`** runs `config-init`, then plans without applying
5. **`config-import`** imports existing resources not yet managed by Terraform

Key Makefile variables:

| Variable                   | Default          | Description                        |
|----------------------------|------------------|------------------------------------|
| `TF_VAR_use_kubernetes`    | `true`           | Toggle Kubernetes vs. local mode   |
| `TF_VAR_config_path`       | `~/.kube/config` | Path to kubeconfig (K8s mode only) |
| `TF_VAR_keycloak_password` | *(empty)*        | Keycloak admin password            |

---

## Pipeline Considerations

### CI/CD with Kubernetes mode

The pipeline uses Kubernetes mode by default. Required CI/CD variables:

| Variable                   | Required | Description                                        |
|----------------------------|----------|----------------------------------------------------|
| `TF_VAR_config_path`       | Yes      | Path to the kubeconfig file on the runner          |
| `TF_VAR_keycloak_password` | No       | Override password (otherwise read from K8s Secret) |
| `KUBECONFIG_B64`           | Yes      | Base64-encoded kubeconfig for cluster access       |

The pipeline stages `config` and `config-plan` rely on:

- The runner having `terraform`, `curl`, and `jq` available
- Network connectivity from the runner to the Keycloak endpoint
- A valid kubeconfig with permissions to read Secrets and manage the TF state
  Secret

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
    - In local mode: ensure `TF_VAR_keycloak_password` is set.
    - If you encounter TLS certificate errors (`x509: certificate signed by unknown
    authority` or `PKIX path validation failed`), set `insecure_tls = true` in
      the
      tfvars.
- **`curl` or `jq` not found:** The policy management script requires `curl` and
  `jq`. Both are standard tools available on most systems and CI runners.
- **State conflicts in local mode:** If switching between K8s and local mode,
  run
  `make clean` first to remove the old backend state and re-initialize.

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
- In some cases when starting from scratch, deleting the Terraform state may be
  required.

---

## Protecting the Keycloak Admin API

The Keycloak Admin REST API and Admin Console (`/auth/admin/*`) must not be
publicly accessible. ZETA Guard supports protecting it via a dedicated admin
hostname.

### How it works

When `authserver.adminHostname` is set, the chart activates two-part
protection:

1. **`/auth/admin` is routed to the PEP proxy, which denies it** — the
   `zeta-guard-pep` minion gains a `/auth/admin` path pointing at
   `pep-proxy-svc`, where a `location ~ ^/auth/admin` block returns
   `403 Forbidden` before the request reaches Keycloak. Every other `/auth/*`
   path (token exchange, nonce, registration, well-known) keeps routing straight
   to the authserver via the `zeta-guard-auth` minion and never touches the PEP.

2. **Separate admin ingress** — a dedicated ingress is created for the admin
   hostname that routes `/auth` directly to the authserver, bypassing the PEP
   proxy block. Terraform and CI/CD runners use this hostname exclusively.

The split relies on overlapping prefixes being resolved **longest-match-first**,
which both nginx and the Ingress specification guarantee regardless of
declaration order: `/auth/admin` wins over `/auth`.

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
    # When set, /auth/admin is blocked on the main hostname via the PEP proxy,
    # and a dedicated admin ingress is created for this hostname.
    adminHostname: "admin.zeta.example.com"
```

Update `keycloak_url` in the corresponding `*.tfvars` to point to the admin
hostname:

```hcl
keycloak_url = "https://admin.zeta.example.com/auth"
```

To **disable** the feature again, remove `adminHostname` (or set it to `""`) in
the values file and run `make deploy stage=<env>`. The admin ingress, the
`/auth/admin` Ingress path and the PEP proxy location block are removed
automatically on the next Helm upgrade — `/auth/admin` then stays reachable on
the main hostname, since otherwise there would be no way to reach it at all.

### Limitation: tiger-proxy environments

When `routeViaTigerProxy: true`, the `/auth/admin` Ingress path is **not**
rendered: tiger-proxy forwards `/auth → http://authserver/auth` internally and
bypasses the PEP entirely, so routing the path there would not block anything.
With F5 NIC the `location-snippets` layer on `zeta-guard-auth` still returns
`404`; with any other ingress controller `/auth/admin` stays reachable on the
main hostname. This is expected — tiger-proxy is a test tool and is never used
in production. Set `routeViaTigerProxy: false` (the default for production) to
activate the controller-agnostic admin API block.

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
    initContainer:
      resources:
        limits:
          cpu: "2"
          memory: "1Gi"
        requests:
          cpu: "500m"
          memory: "512Mi"
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

The pod-level and container-level security contexts are configurable:

```yaml
zeta-guard:
  authserver:
    podSecurityContext:
      seccompProfile:
        type: RuntimeDefault
    container:
      containerSecurityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop: [ "ALL" ]
    initContainer:
      containerSecurityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop: [ "ALL" ]
  provisioningProcessor:
    containerSecurityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: false
      runAsNonRoot: true
      capabilities:
        drop: [ "ALL" ]
```

Note: `runAsUser` is intentionally not set by default, as it is not supported
on OpenShift.

### Probes

Liveness, readiness and startup probe thresholds are configurable:

```yaml
zeta-guard:
  authserver:
    probes:
      liveness:
        initialDelaySeconds: 0
        periodSeconds: 15
        failureThreshold: 5
      readiness:
        initialDelaySeconds: 30
        periodSeconds: 10
        failureThreshold: 5
      startup:
        initialDelaySeconds: 30
        periodSeconds: 10
        failureThreshold: 20
```

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
# private/<stage>.tfvars
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

| Variable                                 | Description                                         | Default |
|------------------------------------------|-----------------------------------------------------|---------|
| `hsm_token_signing_enabled`              | Register HSM-backed ES256 KeyProvider               | `false` |
| `hsm_token_signing_endpoint`             | gRPC endpoint of the HSM Proxy                      | `""`    |
| `hsm_token_signing_key_id`               | Identifier of the signing key in the HSM            | `""`    |
| `hsm_token_signing_priority`             | Provider priority (higher wins)                     | `"200"` |
| `hsm_token_signing_remove_software_keys` | Remove software signing keys after HSM registration | `true`  |

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

## Related Resources

- [Terraform Kubernetes Provider](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs)
- [Terraform Keycloak Provider](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs)
- [Keycloak Admin REST API](https://www.keycloak.org/docs-api/latest/rest-api/index.html)

```
helm lint charts/zeta-guard --strict -f charts/zeta-guard/values-demo.yaml --set authserver.admin.password=dummy --set authserver.hsm.tokenSigning.enabled=true --set authserver.hsm.enabled=false
```
