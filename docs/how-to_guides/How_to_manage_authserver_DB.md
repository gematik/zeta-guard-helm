# How to manage authserver DB

This document describes supported PostgreSQL deployment options in ZETA
environments, including Bitnami PostgreSQL and the Zalando Postgres Operator
for local and cluster-based setups, as well as externally managed databases.

## Database modes

ZETA supports three database modes, configurable per environment via Helm values:
- **Bitnami PostgreSQL**
- **Zalando Postgres Operator**
- **External Database**

The mode is selected via:

```yaml 
zeta-guard:
  databaseMode: bitnami | operator | external
```

## Bitnami PostgreSQL (default for local)

Recommended when:
- a fast local startup is required
- no operator features (HA, backups, failover) are needed

Configuration:
```yaml
zeta-guard:
  databaseMode: bitnami
  postgresql:
    image:
      repository: bitnamilegacy/postgresql
    enabled: true
    auth:
      username: keycloak
      password: devpassword
      database: keycloak
    primary:
      persistence:
        enabled: false
```

No cluster-wide components are required.

## Postgres Operator

In shared or long-lived clusters (e.g., dev, test, prod):
- the Postgres Operator is optional (an external database can be used as well)
- the operator is considered cluster infrastructure

The Postgres Operator can also be used for local development environments, e.g., 
kind. This is useful when:
- behavior should closely match higher environments
- operator-specific features must be tested locally

Expectations
- Operator is installed once per cluster (see also [Manual CRD application](#manual-crd-application-recovery-only))
- CRDs are installed and owned by the operator Helm release

### Installing the Postgres Operator

Configuration:
```yaml
zeta-guard:
  databaseMode: operator
  postgresql: # internal bitnami postgres
    enabled: false 
```

The operator is installed via Helm and managed by the Makefile also by the 
deploy-step:
```shell
make deploy stage=local DB_MODE=operator
```

The included `make install-postgres-operator` command:
- adds the Zalando Helm repository
- installs or upgrades the operator
- installs CRDs via Helm

The operator runs in the `postgres-operator` namespace.

CRDs must be managed by exactly one mechanism and are owned by the 
postgres-operator Helm release

### Namespace preparation

If the operator is configured to watch only labeled namespaces, the target
namespace must be labeled explicitly:
```shell
kubectl label namespace <namespace> postgres-operator=enabled --overwrite
```

#### Verifying operator health

Check that the operator is running and verify CRDs exist:
```shell
kubectl get pods -n postgres-operator
kubectl get crd | grep acid.zalan.do
```

Expected CRDs:
```shell
postgresqls.acid.zalan.do
operatorconfigurations.acid.zalan.do
postgresteams.acid.zalan.do
```

### Manual CRD application (recovery only)

Manual CRD application is not part of normal operations.

It may be used only for recovery or debugging when:
- the operator Helm release is broken
- CRDs were deleted
- CRDs were never installed

The Makefile does not install CRDs automatically, but it can be done manually:
```shell
make install-postgres-crds
```
which installs the CRDs for postgres-operator v1.15.1 in the cluster under the 
`postgres-operator` namespace.

### Resetting the operator (destructive)

To completely remove the operator from a cluster:
```shell
make reset-postgres-operator
```

This will:
- delete the `postgres-operator` namespace
- delete all operator CRDs

> This removes all operator-managed PostgreSQL clusters!

## External database configuration

ZETA can be configured to use an external database instead of a managed 
PostgreSQL instance.

To enable this mode, set databaseMode to external and provide the following 
values:
```yaml
db:
  kcDb: <database vendor>
  kcDbUrl: <jdbc url>
  kcDbSchema: <schema name>
  kcDbUsername: <database user>
  kcDbPasswordSecretName: <kubernetes secret name>
```

The database password is not configured directly. Instead, it is read from the 
Kubernetes Secret referenced by `db.kcDbPasswordSecretName`.    
The Secret must contain a key named `password`. Its value is injected into Keycloak at runtime.

All other database-related properties (kcDb, kcDbUrl, kcDbSchema, kcDbUsername)
are passed through unchanged and behave exactly like the corresponding
Keycloak environment variables.
