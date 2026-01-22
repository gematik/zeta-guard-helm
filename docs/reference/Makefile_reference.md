# Makefile reference

> The Makefile commands are for ease of use and are optional.

## Makefile Targets

- `make help` – lists all targets, usage, and effective variables
- `make deps` – vendor/update chart deps (refreshes `Chart.lock`; included in `deploy`)
- `make template` – render manifests
- `make dry-run` – server-side validation
- `make deploy stage=STAGE [namespace=NAMESPACE]` – install/upgrade the release with `--wait --atomic --timeout 10m`
  - Stage defaults to `local` when omitted.
  - Release name is always `zeta-testenv-<STAGE>` (not overridable).
  - Namespace defaults to `zeta-<STAGE>` and can be overridden via `namespace=<ns>`.
- `make deploy-debug stage=STAGE [namespace=NAMESPACE]` – same as deploy with `--debug`
- `make config-plan stage=STAGE [namespace=NAMESPACE]` – view incoming changes to the authserver by make config
- `make config stage=STAGE [namespace=NAMESPACE]` – configure the authserver
- `make status stage=STAGE [namespace=NAMESPACE]` – show release status
- `make clean` – remove rendered.yaml and local terraform files
- `make uninstall stage=STAGE [namespace=NAMESPACE]` – uninstall and remove tf state secret

## Notes

- The Makefile expects `SMB_KEYSTORE_PW_FILE` and `SMB_KEYSTORE_FILE_B64` to be set for most targets.
- `VALUES_DIR` is selected automatically: `private/` when present, otherwise `local-test/`.
- For `make config` and `make config-plan`, set `TF_VAR_keycloak_password` to the Keycloak admin password (used by Terraform).

## Examples

- `make deploy` (equivalent to `stage=local` and `namespace=zeta-local`)
- `make deploy stage=my-env namespace=my-ns`
- `make template stage=demo`  (renders with `values.demo.yaml`)
- `make config stage=demo` (uses configured terraform variables)
