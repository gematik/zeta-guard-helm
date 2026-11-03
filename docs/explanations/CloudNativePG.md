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
  Service `keycloak-db-rw:5432`. That indirection is also what makes a primary
  replacement *invisible* at the socket level: the ClusterIP stays valid while
  kube-proxy's conntrack entries keep pointing at the vanished pod IP, so
  packets
  are dropped rather than reset. The authserver's datasource is configured to
  survive that (bounded socket timeout and connection validation); see
  [How to configure the authserver](../how-to_guides/How_to_configure_authserver.md#connection-resilience-and-database-failover).
- `cloudnativePg.instances: 1` is the default and makes every primary
  replacement a full outage. Raising it to 3 gives automatic failover, which is
  much shorter — but it also makes primary changes routine rather than
  exceptional, so the connection resilience above is a **prerequisite** for
  `instances >= 3` to deliver availability instead of repeated long outages.
- Two mutually exclusive templating paths can create this `Cluster`: a
  hand-rolled template (`templates/db/cnpg-cluster.yaml`, default) or,
  opt-in, the vendored upstream
  [cloudnative-pg/cluster](https://github.com/cloudnative-pg/charts/blob/main/charts/cluster/README.md)
  chart (`keycloak-db.enabled: true`, aliased in `Chart.yaml`), which exposes
  more of the operator's `Cluster` spec generically (affinity, monitoring,
  poolers, backups). Either way the operator sees the same `Cluster` kind and
  reconciles it identically — pods still carry the `cnpg.io/cluster:
  keycloak-db` label regardless of which chart created the CR, so
  NetworkPolicy and Istio PeerAuthentication selectors are unaffected by the
  choice. See
  [How to manage authserver DB](../how-to_guides/How_to_manage_authserver_DB.md)
  for configuration.
