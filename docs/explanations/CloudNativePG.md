# CloudNativePG Operator (Terraform-managed)

- We use the CloudNativePG operator to manage PostgreSQL clusters for
  non-local environments (e.g., cd/dev/staging/prod).
- The operator is cluster-scoped (installs CRDs and cluster-wide controllers),
  so it should be installed once per cluster — not per app release.
- Installation is handled outside this repo via a Terraform module using the
  Helm provider. This keeps concerns separated and avoids duplicate operator
  installs.
- Ownership/conflicts: cluster‑scoped resources (CRDs/Webhooks/ClusterRoles)
  can only be owned by a single Helm release. Do not install multiple operator
  releases across namespaces.

## How it ties in here

- The `charts/zeta-guard` chart creates a minimal CloudNativePG `Cluster`
  custom resource (apiVersion `postgresql.cnpg.io/v1`) named `keycloak-db` in
  the target namespace (for cd). The operator reconciles this CR and
  provisions a Postgres cluster.
- Keycloak uses the operator‑generated credentials Secret and connects via the
  Service `keycloak-db-rw:5432`.
