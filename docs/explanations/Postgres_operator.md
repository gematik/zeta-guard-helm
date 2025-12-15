# Postgres Operator (Terraform-managed)

- We use the Zalando Postgres Operator to manage PostgreSQL clusters for
  non-local environments (e.g. cd/dev/staging/prod).
- The operator is cluster-scoped (installs CRDs and cluster-wide controllers),
  so it should be installed once per cluster — not per app release.
- Installation is handled outside this repo via a Terraform module using the
  Helm provider. This keeps concerns separated and avoids duplicate operator
  installs.

## How it ties in here

- The `charts/zeta-guard` chart creates a minimal `postgresql` Custom Resource
  named `keycloak-db` in the target namespace (for cd). The operator
  reconciles this CR and provisions a Postgres cluster.
- Keycloak uses the operator-generated secret
  `keycloak.keycloak-db.credentials.postgresql.acid.zalan.do` for DB credentials
  and the Service `keycloak-db:5432` for connectivity.
