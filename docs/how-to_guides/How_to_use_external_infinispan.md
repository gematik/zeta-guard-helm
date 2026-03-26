# How to use external Infinispan
This document describes how to configure and use an external infinispan in ZETA
environments for the ZETA Guard Authserver (PDP) component.

## External Infinispan modes
ZETA supports two external Infinispan modes, configurable per environment via Helm values:
- External Infinispan deployed with zeta-guard-helm
- External Infinispan deployed independently

### External Infinispan deployed with zeta-guard-helm
If `global.infinispanExternal.remote.host` and `global.infinispanExternal.remote.port` are not set:

- The Helm charts deploys Infinispan automatically.
- The number of replicas is controlled via `global.infinispanExternal.replicaCount`.
- Custom configuration can be provided via `global.infinispanExternal.config` in XML format.

Example:
```yaml
global:
  infinispanExternal:
    enabled: true
    replicaCount: 3
    admin:
      username: "admin"
      password: "admin"
```

### External Infinispan deployed independently
If both `global.infinispanExternal.remote.host` and `global.infinispanExternal.remote.port` are set:

- No Infinispan deployment is created by the Helm chart.
- Keycloak is configured to connect to the specified external Infinispan instance.
- You are responsible for managing the deployment of Infinispan.

Example:
```yaml
global:
  infinispanExternal:
    enabled: true
    remote:
      host: infinispan-host
      port: 11222
    admin:
      username: "admin"
      password: "admin"
```

### Admin credentials
Admin credentials can be configured in two ways

#### Chart managed Secret
The credentials are stored in a Kubernetes Secret created by the chart.

```yaml
global:
  infinispanExternal:
    admin:
      username: "admin"
      password: "admin"
```

#### Existing Secret
The chart does not create a Secret.
You must provide an existing Secret with the required credentials.

```yaml
global:
  infinispanExternal:
    admin:
      secretName: "admin-secret"
```
