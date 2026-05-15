# How to use external Infinispan
This document describes how to configure and use an external infinispan in ZETA
environments for the ZETA Guard Authserver (PDP) component.

## External Infinispan modes
ZETA supports two external Infinispan modes, configurable per environment via Helm values:
- External Infinispan deployed with zeta-guard-helm
- External Infinispan deployed independently

### External Infinispan deployed with zeta-guard-helm
If `global.infinispanExternal.remote.host` and `global.infinispanExternal.remote.port` are not set:

- The Helm charts deploy Infinispan automatically.
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

### Image configuration

The Infinispan image is configurable via `global.infinispanExternal.image`:

```yaml
global:
  infinispanExternal:
    image:
      repository: infinispan/server
      tag: "15.2"
```

### ServiceAccount

By default, a dedicated ServiceAccount is created for the Infinispan pod with
`automountServiceAccountToken: false`.
This prevents the pod from using the default ServiceAccount and accessing the
Kubernetes API.

```yaml
global:
  infinispanExternal:
    serviceAccount:
      create: true
      name: infinispan
```

### Resources

Resource requests and limits can be configured via
`global.infinispanExternal.resources`:

```yaml
global:
  infinispanExternal:
    resources:
      limits:
        cpu: "2"
        memory: "1Gi"
      requests:
        cpu: "500m"
        memory: "512Mi"
```

### PodDisruptionBudget

A PodDisruptionBudget can be enabled to ensure availability during voluntary
disruptions:

```yaml
global:
  infinispanExternal:
    podDisruptionBudget:
      enabled: true
      minAvailable: 1
```

Either `minAvailable` or `maxUnavailable` can be set, but not both.

### Security context

The pod-level and container-level security contexts are configurable:

```yaml
global:
  infinispanExternal:
    podSecurityContext:
      seccompProfile:
        type: RuntimeDefault
    containerSecurityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      capabilities:
        drop: [ "ALL" ]
```

Note: `runAsUser` is intentionally not set by default, as it is not supported on
OpenShift.

### JVM options

The base JVM options for JGroups clustering are always set. Additional JVM
options can be configured
via `global.infinispanExternal.extraJavaOptions`:

```yaml
global:
  infinispanExternal:
    extraJavaOptions: "-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0 -XX:MinRAMPercentage=25.0"
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
