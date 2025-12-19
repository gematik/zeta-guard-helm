# Makefile reference

> The Makefile commands are for ease of use and are optional.

## Makefile Targets

- `make help` – lists all targets and variables, including their default values
- `make deps` – vendor/update chart deps (refreshes `Chart.lock`; included in `deploy`)
- `make template` – render manifests
- `make dry-run` – server-side validation
- `make deploy stage=STAGE` – install/upgrade with `--atomic --wait`
  `make deploy RELEASE=zeta-testenv-STAGE NAMESPACE=zeta-STAGE VALUES=values.STAGE.yaml`
- `make config-plan stage=STAGE` – view incoming changes to the authserver by make config
- `make config stage=STAGE` – configure the authserver 
- `make status` – status
- `make clean` – remove rendered.yaml and local terraform files
- `make uninstall` – uninstall and remove tf state secret

## Examples

- `make deploy stage=demo`
- `make deploy stage=demo RELEASE=myrel`  (override just the release)
- `make template stage=demo`  (renders with `values.demo.yaml`)
- `make config stage=demo` (uses password from cluster secret)
