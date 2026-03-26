# Makefile reference

> The Makefile commands are for ease of use and are optional.

## Makefile Targets

- `make help` – lists all targets, usage, and effective variables
- `make deps` – vendor/update chart deps (refreshes `Chart.lock`; included in `deploy`)
- `make template` – render manifests
- `make dry-run` – server-side validation
- `make deploy stage=STAGE [namespace=NAMESPACE] [DB_MODE=cloudnative]` – install/upgrade the release with `--rollback-on-failure --timeout 10m`
  - Stage defaults to `local` when omitted.
  - Release name is always `zeta-testenv-<STAGE>` (not overridable).
  - Namespace defaults to `zeta-<STAGE>` and can be overridden via `namespace=<ns>`.
  - `DB_MODE=cloudnative` installs the CloudNativePG operator for local environments if desired.
- `make deploy-debug stage=STAGE [namespace=NAMESPACE] [DB_MODE=cloudnative]` – same as deploy with `--debug`
 - `make install-cnpg-operator [namespace=cnpg-system]` – install CloudNativePG operator (clusterWide=true) into the specified namespace (create it first if needed)
 - `make uninstall-cnpg-operator [namespace=cnpg-system]` – uninstall the CNPG operator release (keeps CRDs)
 - `make reset-cnpg-operator [namespace=cnpg-system]` – uninstall the operator and delete CNPG CRDs (destructive)
- `make config-plan stage=STAGE [namespace=NAMESPACE]` – view incoming changes to the authserver by make config
- `make config stage=STAGE [namespace=NAMESPACE]` – configure the authserver
- `make status stage=STAGE [namespace=NAMESPACE]` – show release status
- `make clean` – remove rendered.yaml and local terraform files
- `make uninstall stage=STAGE [namespace=NAMESPACE]` – uninstall and remove tf state secret
- `make kind-up [HOST_IP=<ip>] [KIND_INGRESS_HOSTS="<host1> <host2>"]` – create local kind cluster and patch CoreDNS so in-cluster clients resolve ingress hostnames to your host IP (hosts are auto-detected from local values by default)
- `make kind-down` – delete the local kind cluster

## Notes

- The Makefile expects `SMB_KEYSTORE_PW_FILE` and `SMB_KEYSTORE_FILE_B64` to be set for most targets.
- `VALUES_DIR` is selected automatically: `private/` when present, otherwise `local-test/`.
- For `make config` and `make config-plan`, set `TF_VAR_keycloak_password` to the Keycloak admin password (used by Terraform).
- `KIND_INGRESS_HOSTS` is auto-derived from ingress-related host keys in `values.local.yaml` (`ingressRulesHost`, `hostname`, `zetaBaseUrl`, `wellKnownBase`, `requiredAudience`, `pepIssuer`). If auto-detection yields nothing, it falls back to `zeta-kind.local`.
- CloudNativePG: install a single operator per cluster. If you previously installed the operator in another namespace and hit Helm ownership errors, remove the old release and CNPG CRDs before installing into the desired namespace.

## Examples

- `make deploy` (equivalent to `stage=local` and `namespace=zeta-local`)
- `make deploy stage=my-env namespace=my-ns`
- `make template stage=demo`  (renders with `values.demo.yaml`)
- `make config stage=demo` (uses configured terraform variables)
- `make kind-up KIND_INGRESS_HOSTS="zeta-kind.local zeta-client.local"`
