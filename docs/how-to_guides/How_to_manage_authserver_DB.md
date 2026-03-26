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
