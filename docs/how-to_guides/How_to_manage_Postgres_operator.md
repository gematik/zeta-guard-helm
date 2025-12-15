# How to manage Postgres operator

## How to switch database mode

- Local uses Bitnami PostgreSQL. cd/Staging/Prod can use the operator. Toggle
  via:
    - `zeta-guard.databaseMode=bitnami` (default) or `operator` in the
      environment values file.

## Hot to prepare Postgres operator for cd/staging/prod

- Ensure the operator is installed and healthy (Terraform pipeline):
    - CRDs present: `kubectl get crd postgresqls.acid.zalan.do`
    - Operator pods running (in its namespace, e.g., `postgres-operator`).
- If operator is configured to watch only labeled namespaces, label the target
  namespace (e.g.,
  `kubectl label namespace zeta-dev postgres-operator=enabled --overwrite`).
