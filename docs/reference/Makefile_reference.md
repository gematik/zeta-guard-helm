# Makefile reference

> The Makefile commands are for ease of use and are optional.

## Getting started

**Validate without credentials or a cluster** (works right after cloning):

```shell
make help           # list targets, usage, and effective variables
make lint           # Helm strict lint against demo values
make template-demo  # render zeta-guard with demo values + yamllint
make deps           # vendor chart dependencies
```

`make template` (non-demo), `deploy`, `dry-run` and `render` additionally
require the
SMCB keystore (`SMB_KEYSTORE_PW_FILE` / `SMB_KEYSTORE_FILE_B64`) — use
`make template-demo`
for a credential-free render.

**Values defaults:** `stage=local` uses the bundled
[local-test/values.local.yaml](../../local-test/values.local.yaml) and
[local-test/local.tfvars](../../local-test/local.tfvars) out of the box (their
base directory
is `VALUES_DIR`, default `local-test/`).

**Deploy to a local KIND cluster** (requires the SMCB keystore plus
`DOCKER_USER` /
`DOCKER_PASSWORD` — see the prerequisites in the [README](../../README.md) and
[How to deploy ZETA Guard](../how-to_guides/How_to_deploy_ZETA_Guard.md)):

```shell
make kind-up            # create the cluster, patch CoreDNS, create secrets, install operators
make deploy stage=local # install/upgrade the release
make status stage=local # check the release
```

See [Environment variables](#environment-variables) below for the full list of
settings, or run
`make help`.

## Makefile Targets

- `make help` – lists all targets, usage, and effective variables
- `make deps` – vendor the remote deps of `zeta-guard` and
  `test-monitoring-service` as pinned in their `Chart.lock` (included in
  `deploy`/`dry-run`/`template`). All remote deps are `oci://` and served from
  helm's content cache after the first pull — no repo registration, works
  offline. The umbrella's own subcharts are resolved directly from the
  unpacked directories in `charts/` — no vendoring involved. Runs
  `strip-remote-schemas` afterwards.
- `make strip-remote-schemas` – drop `values.schema.json` from vendored subchart
  tarballs whose `$ref`s point at remote URLs (currently `nginx-ingress`, which
  references `raw.githubusercontent.com`). helm resolves such refs over the
  network on every lint/template/upgrade, so a rate-limited egress IP fails the
  deploy with `429 (Too Many Requests)`. Included in `deps`/`deps-update`; only
  needed standalone after a manual `helm dependency build`.
- `make template` – render manifests
- `make dry-run` – server-side validation
- `make deploy stage=STAGE [namespace=NAMESPACE] [DB_MODE=cloudnative]` – install/upgrade the release with `--rollback-on-failure --timeout 10m`
  - Stage defaults to `local` when omitted.
  - Release name is always `zeta-testenv-<STAGE>` (not overridable).
  - Namespace defaults to `zeta-<STAGE>` and can be overridden via `namespace=<ns>`.
  - `DB_MODE=cloudnative` installs the CloudNativePG operator for local environments if desired.
- `make deploy-debug stage=STAGE [namespace=NAMESPACE] [DB_MODE=cloudnative]` – same as deploy with `--debug`
- `make install-cnpg-operator` – install CloudNativePG operator (
  clusterWide=true) into the fixed `cnpg-system` namespace (created
  automatically)
- `make uninstall-cnpg-operator` – uninstall the CNPG operator release from
  `cnpg-system` (keeps CRDs)
- `make reset-cnpg-operator` – uninstall the operator from `cnpg-system` and
  delete CNPG CRDs (destructive)
- `make generate-main-and-backend` – generates `main.tf`, `providers.tf`,
  `mode-assert.tf`, backend config and (Kubernetes mode only)
  `sekidp-secret.tf` from templates based on `TF_VAR_use_kubernetes`; the
  Kubernetes provider is only required when `TF_VAR_use_kubernetes=true`, since
  `sekidp-secret.tf` is then the only file with `kubernetes_*` blocks
- `make config-init stage=STAGE [namespace=NAMESPACE]` – runs `generate-main-and-backend` and initializes the Terraform backend
- `make config-plan stage=STAGE [namespace=NAMESPACE] [PLAN_OUT=<file>]` – view
  incoming changes to the authserver by make config
    - `PLAN_OUT=<file>` additionally saves the Terraform plan to a file so it
      can be reviewed later with `config-show-plan`. Empty (default) writes no
      file.
- `make config-show-plan stage=STAGE PLAN_OUT=<file>` – render a plan file saved
  by `config-plan` as a plain-text (no-color) diff to stdout, e.g.
  `make config-show-plan stage=dev PLAN_OUT=authserver.change.plan > authserver.change.txt`
- `make config stage=STAGE [namespace=NAMESPACE]` – configure the authserver
- `make config-import stage=STAGE [namespace=NAMESPACE]` – import the existing
  `zeta-guard` realm into the Terraform state. First step when the state was
  lost; the remaining objects need Keycloak UUIDs resolved at runtime, listed in
  [How to upgrade ZETA Guard](../how-to_guides/How_to_upgrade_ZETA_Guard.md).
  A realm already present in the state is reported and skipped.
- `make status stage=STAGE [namespace=NAMESPACE]` – show release status
- `make versions stage=STAGE [namespace=NAMESPACE]` – Show deployed component images and versions
- `make versions-debug stage=STAGE [namespace=NAMESPACE]` – Show deployed components with all images and digests
- `make clean` – remove rendered.yaml and local terraform files
- `make uninstall stage=STAGE [namespace=NAMESPACE]` – uninstall and remove tf
  state secret. **Destructive and development-only:** it also deletes the CNPG
  cluster and its PVCs, i.e. the realm's users. Never run it on a productive
  stage — a chart upgrade needs `helm upgrade` + `make config`, see
  [How to upgrade ZETA Guard](../how-to_guides/How_to_upgrade_ZETA_Guard.md).
- `make kind-up [HOST_IP=<ip>] [KIND_INGRESS_HOSTS="<host1> <host2>"]` – create local kind cluster and patch CoreDNS so in-cluster clients resolve ingress hostnames to your host IP (hosts are auto-detected from local values by default)
- `make kind-down` – delete the local kind cluster

## Environment variables

All of these can be set as an environment variable or as a `make` argument (
`VAR=value`).

### Stage & values selection

| Variable     | Purpose                                                                    | Default            |
|--------------|----------------------------------------------------------------------------|--------------------|
| `stage`      | Deployment stage; also sets the namespace (`zeta-<stage>`) and values file | `local`            |
| `namespace`  | Target namespace                                                           | `zeta-<stage>`     |
| `values`     | Path to the Helm values file (overrides the stage default)                 | derived from stage |
| `VALUES_DIR` | Base directory for values files and tfvars                                 | `local-test/`      |
| `DB_MODE`    | Database bootstrap mode for local convenience targets                      | `cloudnative`      |

### SMCB keystore (required for `deploy`, `deploy-debug`, `template`,
`template--debug`, `render`, `dry-run`)

| Variable                     | Purpose                                           | Required |
|------------------------------|---------------------------------------------------|----------|
| `SMB_KEYSTORE_PW_FILE`       | Path to a file holding the SMCB keystore password | yes      |
| `SMB_KEYSTORE_FILE_B64`      | Path to the base64-encoded PKCS#12 SMCB keystore  | yes      |
| `OCSP_SMB_KEYSTORE_PW_FILE`  | Password file for the OCSP mock signing keystore  | optional |
| `OCSP_SMB_KEYSTORE_FILE_B64` | Base64 PKCS#12 for the OCSP mock signing keystore | optional |

### Terraform / authserver configuration

| Variable                   | Purpose                                                                                                                                                                                                                                                       | Default          |
|----------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------|
| `TF_VAR_keycloak_password` | Keycloak admin password for `config` / `config-plan` / `config-import`. May be empty: the targets source `terraform/authserver/scripts/kc-admin-env.sh`, which fills it from the `authserver-admin` Secret.                                                   | *(empty)*        |
| `TF_VAR_keycloak_username` | Keycloak admin username. Same handling as the password — and it must be set for the exported password to take precedence over the Secret.                                                                                                                     | *(empty)*        |
| `TF_VAR_use_kubernetes`    | Terraform operating mode. `false` = local backend without Kubernetes (the generated files then contain no `kubernetes_*` block, so `terraform init` skips that provider). See [How to configure authserver](../how-to_guides/How_to_configure_authserver.md). | `true`           |
| `TF_VAR_config_path`       | Path to the kubeconfig used by the Kubernetes backend                                                                                                                                                                                                         | `~/.kube/config` |
| `PLAN_OUT`                 | Plan file written by `config-plan` and rendered by `config-show-plan`                                                                                                                                                                                         | *(none)*         |

### Container registry (for `kind-up`, `create-secrets`, `k3s`)

| Variable          | Purpose                                 | Required |
|-------------------|-----------------------------------------|----------|
| `DOCKER_REGISTRY` | Registry host for the image pull secret | yes      |
| `DOCKER_USER`     | Registry username                       | yes      |
| `DOCKER_PASSWORD` | Registry password / token               | yes      |

### Local KIND cluster

| Variable             | Purpose                                                                                                           | Default           |
|----------------------|-------------------------------------------------------------------------------------------------------------------|-------------------|
| `HOST_IP`            | LAN IP used to patch CoreDNS / NetworkPolicy                                                                      | auto-detected     |
| `KIND_CONFIG`        | KIND cluster config file                                                                                          | `kind-local.yaml` |
| `KIND_INGRESS_HOSTS` | Ingress hostnames for the CoreDNS patch; auto-derived from the local values file, falls back to `zeta-kind.local` | auto-derived      |

### ASL identity secret (for `generate-asl-identity-secret`)

| Variable               | Purpose                                  | Required |
|------------------------|------------------------------------------|----------|
| `ASL_SIGNER_CERT_FILE` | Path to the ASL signer certificate (PEM) | yes      |
| `ASL_SIGNER_KEY_FILE`  | Path to the ASL signer private key (PEM) | yes      |
| `ASL_ISSUER_CERT_FILE` | Path to the ASL issuer certificate (PEM) | yes      |

## Notes

- `VALUES_DIR` defaults to `local-test/`; override it with `VALUES_DIR=<dir>` (
  e.g. to point at your own values directory).
- CloudNativePG: install a single operator per cluster. If you previously installed the operator in another namespace and hit Helm ownership errors, remove the old release and CNPG CRDs before installing into the desired namespace.

## Examples

- `make deploy` (equivalent to `stage=local` and `namespace=zeta-local`)
- `make deploy stage=my-env namespace=my-ns`
- `make template stage=demo`  (renders with `values.demo.yaml`)
- `make config stage=demo` (uses configured terraform variables, K8s mode)
- `make config stage=local TF_VAR_use_kubernetes=false` (local mode, no K8s backend)
- `make kind-up KIND_INGRESS_HOSTS="zeta-kind.local zeta-client.local"`
- CI plan review (save, then render to a text diff):
  ```shell
  make config-plan stage=dev PLAN_OUT=authserver.change.plan
  make config-show-plan stage=dev PLAN_OUT=authserver.change.plan > authserver.change.txt
  ```
