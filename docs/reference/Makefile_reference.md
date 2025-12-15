# Makefile reference

## Makefile Targets

- `make help` – lists all targets and variables, including their default values
- `make deps` – vendor/update chart deps (refreshes `Chart.lock`)
- `make template` – render manifests
- `make dry-run` – server-side validation
- `make deploy` – install/upgrade with `--atomic --wait`
- `make deploy stage=STAGE` – equals:
  `make deploy RELEASE=zeta-testenv-STAGE NAMESPACE=zeta-STAGE VALUES=values.STAGE.yaml`
- `make config-plan stage=STAGE` – view incoming changes to the authserver by make config
- `make config stage=STAGE` – configure the authserver 
- `make status` – status
- `make uninstall` – uninstall

## Variables and Stage Shortcut

- Defaults: `RELEASE=zeta-testenv`, `NAMESPACE=zeta-staging`,
  `VALUES=values.staging.yaml`. `VALUES_DIR=private/`
- Single param: `stage=<name>` derives
    - `RELEASE=zeta-testenv-<stage>`
    - `NAMESPACE=zeta-<stage>`
    - `VALUES=private/values.<stage>.yaml`
- `BASE_RELEASE` can override the base (default `zeta-testenv`).

## Examples

- `make deploy stage=dev`
- `make deploy stage=dev RELEASE=myrel`  (override just the release)
- `make template stage=dev`  (renders with `values.dev.yaml`)
- `make config stage=dev` (uses password from cluster secret)
- `make config stage=dev -var="keycloak_password=xyz"` (uses password from variable)
