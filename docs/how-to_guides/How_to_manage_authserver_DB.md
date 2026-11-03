# How to manage authserver DB

This document describes supported PostgreSQL deployment options in ZETA
environments using CloudNativePG for managed Postgres, or externally managed
databases.

## Database modes

ZETA supports two database modes, configurable per environment via Helm values:
- CloudNativePG (managed Postgres via operator)
- External Database

Select the mode via:

```yaml
zeta-guard:
  databaseMode: cloudnative | external
```

## CloudNativePG (managed Postgres)

Install the CloudNativePG operator once per cluster:
```shell
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cloudnative-pg cnpg/cloudnative-pg \
  -n cnpg-system --create-namespace \
  --set config.clusterWide=true \
  --wait
```

Configure the chart to use CloudNativePG:
```yaml
zeta-guard:
  databaseMode: cloudnative
```

This creates a Cluster resource (kind: Cluster, apiVersion: postgresql.cnpg.io/v1)
named `keycloak-db` and wires Keycloak to it.

#### What a primary switchover or pod recreate does to the authserver

Losing the primary is not a clean disconnect. Deleting the primary **pod**
destroys its network namespace while the `keycloak-db-rw` ClusterIP stays valid,
so kube-proxy's existing conntrack entries keep routing to an IP that no longer
answers and nothing sends a TCP reset — the connection blackholes rather than
failing. This is why a graceful database *restart* recovers by itself while a
*pod recreate* used to hang the authserver until someone restarted it.

The authserver now handles this on its own: a bounded socket timeout and bounded
connection validation let the pool evict and rebuild its connections. See
[How to configure the authserver](How_to_configure_authserver.md#connection-resilience-and-database-failover)
for the settings and for how to verify the behaviour with the `agroal_*`
metrics.

> **If the authserver fails to start with a Liquibase lock error**, a schema
> migration was killed mid-flight (the socket timeout applies to DDL too) and
> the
> changelog lock is still held; the next start waits 30 minutes before failing.
> Release it:
>
> ```sql
> UPDATE databasechangeloglock SET locked = false, lockgranted = NULL, lockedby = NULL;
> ```

### Provisioning via the upstream cloudnative-pg/cluster chart (opt-in)

By default the Cluster resource above is created by a hand-rolled template
(`templates/db/cnpg-cluster.yaml`). As an opt-in alternative, `keycloak-db` can
instead be provisioned via the upstream
[cloudnative-pg/cluster](https://github.com/cloudnative-pg/charts/blob/main/charts/cluster/README.md)
chart, giving generic pass-through access to fields the hand-rolled template
doesn't expose (pod affinity, PodMonitor, PrometheusRule, PgBouncer poolers,
barman backups):

```yaml
zeta-guard:
  databaseMode: cloudnative
  keycloak-db:
    enabled: true
    fullnameOverride: keycloak-db
    cluster:
      instances: 1
      enableSuperuserAccess: false
      storage:
        size: 10Gi
      resources:
        requests:
          cpu: "2"
          memory: 2Gi
        limits:
          memory: 3Gi
      postgresql:
        parameters:
          shared_buffers: 512MB
          max_connections: "250"
      initdb:
        database: keycloak
        owner: zeta-guard
```

`keycloak-db.enabled: true` and the hand-rolled path are mutually exclusive —
enabling it skips `cnpg-cluster.yaml`, `cnpg-pooler.yaml` and
`cnpg-scheduledbackup.yaml` entirely, and this block replaces `cloudnativePg.*`
for keycloak-db rather than merging with it. `fullnameOverride: keycloak-db`
keeps the Cluster/Service/Secret names identical to the hand-rolled path, so
NetworkPolicies, Istio PeerAuthentication selectors and the
`cloudnativeDbUrl`/`cloudnativeDbSecretName` defaults keep working unchanged.

`cluster.enablePDB` is deliberately left unset by default, inheriting the
upstream chart's own default (`true`). Set it to `false` per stage for
single-instance clusters, where a PodDisruptionBudget would otherwise block
node drains — the same convention already used by `cloudnativePg.enablePDB`
for the hand-rolled path.

The connection-budget guard (which fails the render if
`authserver.dbPool.maxSize × replicaCount` would exceed the cluster's
`max_connections`) runs regardless of which path is enabled.

This is disabled by default; the hand-rolled template remains authoritative
until stages have explicitly migrated.

### Resetting CNPG operator and CRDs

If you need to remove the operator and all CNPG CRDs before a clean re-install, run:

```bash
# Uninstall the operator release (adjust namespace if different)
helm -n cnpg-system uninstall cloudnative-pg || true

# Remove cluster-scoped leftovers
kubectl delete mutatingwebhookconfiguration cnpg-mutating-webhook-configuration --ignore-not-found
kubectl delete validatingwebhookconfiguration cnpg-validating-webhook-configuration --ignore-not-found
kubectl delete clusterrole cloudnative-pg --ignore-not-found
kubectl delete clusterrolebinding cloudnative-pg --ignore-not-found

# Delete all CNPG CRDs (removes all CNPG objects cluster-wide; PVCs remain)
kubectl delete $(kubectl get crd -o name | grep postgresql.cnpg.io) --ignore-not-found
```

## External database configuration

ZETA can be configured to use an external database instead of a managed
PostgreSQL instance.

To enable this mode, set databaseMode to external and provide the following
values:
```yaml
zeta-guard:
  databaseMode: external
  authserverDb:
    kcDb: <database vendor>
    kcDbUrl: <jdbc url>
    kcDbSchema: <schema name>
    kcDbSecretName: <kubernetes secret name>
```

The database username and password are not configured directly. Instead, they are 
read from the Kubernetes Secret referenced by `authserverDb.kcDbSecretName`.
The Secret must contain a key named `username` and another key named `password`. 
Its value is injected into Keycloak at runtime.

All other database-related properties (kcDb, kcDbUrl, kcDbSchema) are passed 
through unchanged and behave exactly like the corresponding Keycloak environment 
variables.
