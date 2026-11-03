# How to configure the Notification Service

> **Warning – insecure components**
> The bundled Push Gateway's HTTP API enforces no authentication. Do **not** run it in production or any
> security-sensitive environment. Keep it disabled unless you are testing in an isolated sandbox:
>
> ```yaml
> push-gateway:
>   enabled: false
> ```

The Notification Service manages push-notification registrations and dispatches notifications to a Push
Gateway. It is part of `charts/zeta-guard` and disabled by default (`zeta-guard.notificationService.enabled:
false`) — enable it per-stage once the component is ready to roll out beyond local.

## Enabling the Notification Service

```yaml
zeta-guard:
  notificationService:
    enabled: true
    env:
      pushGatewayAllowedBaseUrls:
        - "http://push-gateway:8080"
      channelsAllowed: "zeta"
```

Both `pushGatewayAllowedBaseUrls` (list of allowed dispatch-target base URLs) and `channelsAllowed`
(comma-separated allowed channels) must be set when enabled — the service has no defaults and fails config
validation at startup when they are empty.

### Encrypting push notifications

Payload encryption for dispatched notifications is controlled by a single flag, passed to the service as
`NOTIFICATION_ENCRYPTION_ENABLED` (`notification.encryption.enabled`). It is `false` by default — enable it
per stage:

```yaml
zeta-guard:
  notificationService:
    env:
      encryptionEnabled: true
```

The chart always emits the env var, so the value set here wins over the service's own built-in default.

### Message history

The optional message history (A_29974) is switched on with
`notificationService.historyEnabled`, passed to
the service as `NOTIFICATION_HISTORY_ENABLED`. Keep the Terraform variable
`notification_history_enabled` in
sync with it: it creates the `notification.history.read` scope the PEP requires
on `/push/v1/history/`. With
the history off, a client gets the PEP's `403`; the service itself would answer
`404 HISTORY_DISABLED`.

`notificationService.historyRetention`, passed as
`NOTIFICATION_HISTORY_RETENTION`, is a duration: once it has passed after the
first recorded notification was received by the notification service, the
complete history of that device is erased. The next notification restarts the
history and the erasure timer. Accepts ISO-8601 (`P30D`, `PT720H`) or the
Quarkus shorthand (`30d`, `720h`); unset keeps the service default, `P30D`.
A_29988 exempts the history from the short retention of the processing data;
its retention follows the operator's configuration.

```yaml
zeta-guard:
  notificationService:
    historyEnabled: true
    historyRetention: P14D
```

### RS client-certificate authentication

`notificationService.rs.mtls.enabled` defaults to `true`: the RS API then requires
a client certificate (A_29980). The chart does not configure RS TLS yet, so with the
default every RS call is rejected with `401` unless mTLS is terminated upstream. The
local test profile sets it to `false` so the Testfachdienst can call the RS API over
HTTP through Tiger:

```yaml
zeta-guard:
  notificationService:
    rs:
      mtls:
        enabled: false
```

The setting controls `QUARKUS_HTTP_AUTH_PERMISSION_RS_ENABLED` on the RS variant
only. With authentication disabled, restrict access to the internal RS Service with
your own NetworkPolicy; the chart ships none for it. FdV authentication and
outbound Push Gateway mTLS are configured independently.

Public ingress blocks `/notification-service-rs` and its subpaths with `404`,
including when `routeViaTigerProxy` is enabled. In-cluster callers can still use
`http://tiger-proxy/notification-service-rs` or
`http://notification-service-rs:8080` directly.
When supplying a custom PEP ConfigMap (`pepproxy.nginxConf.generateConfigMap: false`),
include equivalent deny locations for this prefix in its nginx configuration.

### mTLS to the Push Gateway

When the Push Gateway requires a client certificate, supply one under
`notificationService.pushGateway.mtls`. The client certificate and private key are two independent
references to existing Secrets (they may be the same Secret or different ones); both are read as PEM and
must be provided together — setting only one fails the chart render.

```yaml
zeta-guard:
  notificationService:
    pushGateway:
      mtls:
        clientCert:
          secretName: pgw-client-tls   # e.g. a kubernetes.io/tls Secret
          secretKey: tls.crt
        clientKey:
          secretName: pgw-client-tls
          secretKey: tls.key
        # Optional — only for an encrypted private key. Secret reference only.
        keyPassword:
          secretName: ""
          secretKey: ""
```

The cert/key are mounted at `/certs/push-gateway-client/tls.{crt,key}` and passed to the service via
`PUSH_GATEWAY_MTLS_CLIENT_CERTIFICATE_PATH` / `PUSH_GATEWAY_MTLS_CLIENT_KEY_PATH`. To trust the Push
Gateway's **server** certificate (a private/self-signed CA), use `notificationService.pushGateway.trustedCAs`
instead — that is the server-trust side and is independent of the client identity above.

### Persistent database

With `notificationService.db.mode: cloudnative` (default) the service gets a dedicated CloudNativePG cluster,
annotated `helm.sh/resource-policy: keep` so a failed upgrade/rollback never drops it. Caveat: disabling the
service or switching to `db.mode: external` orphans the Cluster and PVC — delete them (or run `make
uninstall`) before re-enabling, otherwise a database with a possibly stale schema gets adopted.

Since notification-service 1.3.2 the persistence layer is standard SQL and the database kind must be declared
explicitly: `notificationService.db.kind` (default `postgresql`) is passed to the service as
`NOTIFICATION_DATASOURCE_DB_KIND` — one of `postgresql`, `mariadb`, `mysql`, `mssql`, `oracle`. In
`cloudnative` mode the kind must stay `postgresql` (the chart fails the render otherwise). To run against a
different database, set `db.mode: external` plus a matching `db.kind`, `db.jdbcUrl` and `db.secretName`
(username/password keys), and point `db.waitForDb.host`/`port` at it (or disable `waitForDb`).

### HSM-backed sealing

Stored notification data can be sealed at rest with keys held in an HSM. The chart exposes this as two
blocks: `notificationService.hsm` (where the HSM Proxy is) and `notificationService.sealing` (whether to
seal, and where the keys come from). Keys marked optional emit an env var only when set, so anything left
unset keeps the service's own default.

```yaml
zeta-guard:
  notificationService:
    hsm:
      # host:port of the HSM Proxy
      endpoint: "hsm-sim:50051"
      # Accept an unprotected (plain-text gRPC) channel to the HSM Proxy
      plainTextAccepted: true
    sealing:
      enabled: true
      keychainGenerator:
        # KEK a new keychain is wrapped under, schema [component]-[purpose]-[algorithm]-v<N>
        kekId: "notification-service-keychain-kek-aesgcm-v1"
      initContainerProvideKeys: {}   # see below
      initContainerStoreKeys: {}     # see below
```

These values map to the following environment variables:

| Value                                                 | Environment variable                                  |
|-------------------------------------------------------|-------------------------------------------------------|
| `notificationService.hsm.endpoint`                    | `HSM_PROXY_ENDPOINT` (service and keychain generator) |
| `notificationService.hsm.plainTextAccepted`           | `HSM_PROXY_PLAIN_TEXT_ACCEPTED`                       |
| `notificationService.sealing.enabled`                 | `NOTIFICATION_PERSISTENCE_SEALING_ENABLED`            |
| `notificationService.sealing.keychainFileName`        | `NOTIFICATION_PERSISTENCE_SEALING_KEYCHAIN_FILE`      |
| `notificationService.sealing.rotationInterval`        | `NOTIFICATION_PERSISTENCE_SEALING_ROTATION_INTERVAL`  |
| `notificationService.sealing.keychainGenerator.kekId` | `HSM_PROXY_KEK_ID` (keychain generator)               |

`sealing.enabled: true` requires `hsm.endpoint`, and `sealing.keychainGenerator.kekId` while the generator
runs — there is no software fallback, and the chart fails the render when either is empty.

#### The keychain

The service takes its keys from a keychain: a JSON file of entries, each holding a DEK and a
pseudonymization key, wrapped together by the HSM. It reads the file `sealing.keychainFileName` (default
`/keychain/keychain.json`). The chart brings no volume for it: put the keychain on a volume of your choice
in `notificationService.extraVolumes`, typically a Secret, and mount it into the service with
`notificationService.extraVolumeMounts` (read-only is enough) and into the keychain generator with
`sealing.keychainGenerator.extraVolumeMounts`. The init containers run in this order:

1. `sealing.initContainerProvideKeys` (optional): a container spec of yours that puts the existing
   keychain at `keychainFileName`, e.g. from a secret store.
2. `keychain-generator`: creates a keychain with a first entry through the HSM Proxy, wrapped under
   `keychainGenerator.kekId`, if `keychainFileName` does not exist yet; otherwise it does nothing. Set
   `keychainGenerator.enabled: false` only when the keychain is always there.
3. `sealing.initContainerStoreKeys` (optional): a container spec of yours that stores the keychain found at
   `keychainFileName`.

```yaml
zeta-guard:
  notificationService:
    sealing:
      keychainGenerator:
        kekId: "notification-service-keychain-kek-aesgcm-v1"
        extraVolumeMounts:
          - name: notification-keychain
            mountPath: /keychain
    extraVolumes:
      - name: notification-keychain
        secret:
          secretName: notification-service-keychain   # key keychain.json
    extraVolumeMounts:
      - name: notification-keychain
        mountPath: /keychain
        readOnly: true
```

Both API variants (`rs`, `fdv`) and all replicas share one database and therefore must use the same
keychain. With a Secret that holds it, that is given. If the generator is to create the keychain on the
first start instead, mount a writable volume and add a store hook; it has to be authoritative: it stores the
keychain only if none is stored yet, and otherwise replaces the local one with the stored one, so that the
pod that loses a race on the very first start ends up with the winner's keychain. Without any of this, the
generator cannot write the keychain to the read-only root filesystem and the pod does not start.

The keychain generator image is `notification-keychain-generator`, with the registry and tag of
`notificationService.image` (the tag without variant suffix) unless `keychainGenerator.image` overrides them.
It needs `Encrypt` on the KEK, the service only `Decrypt`.

Key rotation is not driven by the chart: create the next keychain entry with the keychain generator outside
the cluster, as described in the notification-service README ("Key rotation"), put the resulting keychain into
your store, and roll both deployments. The service moves the records to the new entry every
`sealing.rotationInterval` (default `1h`).

`plainTextAccepted` concerns the **transport to the HSM Proxy**, not the stored records. The HSM proxy
client currently speaks plain-text gRPC only (mTLS per A_28830 is deferred), so with sealing enabled the
service refuses to start unless `plainTextAccepted: true` — it would otherwise leave the Encrypt/Decrypt
calls crossing the VAU trust boundary unauthenticated (A_29962). Set it only where the network itself
protects the channel, such as `hsm-sim` inside a local cluster.

`sealing.enabled` was `notificationService.env.persistenceSealingEnabled` up to chart 1.3.1;
`hsm.kek.dekKeyId`, `hsm.kek.pseudonymKeyId` and `sealing.dekCacheSize` are gone since the keychain came in.
The chart fails the render with a pointer when one of the old paths is still set.

With `zeta-guard.networkPolicy.enabled: true` the chart emits **no** egress rule towards the HSM Proxy —
the notification-service NetworkPolicy allows only DNS, the database and the Push Gateway path. The keychain
generator runs in the same pod and needs that rule too, as do your hooks for their store. Add a
`podSelector` (or `ipBlock`) rule for the HSM Proxy yourself, following
[How to configure Egress NetworkPolicies](How_to_configure_NetworkPolicies.md).

## The bundled Push Gateway test chart

`charts/push-gateway` is a thin, local/demo-only deployment of gematik's Push Gateway (upstream repo:
`gematik/push-gateway`). It serves as a dispatch target for the Notification Service in local/demo
deployments. For production setups, use the Push Gateway chart maintained in the upstream repository
instead: <https://github.com/gematik/push-gateway/tree/main/charts>. This chart is **not** representative of
a production deployment:

- A single instance runs `APP_MODE=BOTH` (ingestion and dispatch in one process) instead of upstream's
  separate producer/consumer Deployments.
- Postgres and the Artemis JMS broker run as single-replica pods backed by `emptyDir` — no HA, no persistence
  across reinstalls.
- `push-gateway.pushConfig` contains no APNs/Firebase credentials by default, so `POST /push/v1/notify*`
  calls are accepted and queued but never delivered to a device. This is enough to exercise the
  notification-service → push-gateway routing path, not real push delivery.

### Providing an image

gematik publishes no Push Gateway container image — building and publishing one (from the upstream
`gematik/push-gateway` repository) is the operator's responsibility. Point the chart at your own build:

```yaml
push-gateway:
  enabled: true
  image:
    registry: "<registry>/<path>/"  # full prefix including trailing slash
    tag: "<version>"
```

When `image.registry` is unset, the image prefix is assembled from `global.registry_host` plus the chart's
`registry_name`. Pull credentials come from `push-gateway.imagePullSecrets` or `global.imagePullSecrets`.
`push-gateway.enabled` is the effective switch — the umbrella chart always defines it, and Helm conditions
take precedence over tags.

Resources, security contexts, the PodDisruptionBudget and `devMode` are configured via the chart values —
see `charts/push-gateway/values.yaml`. `service.apiPort`/`service.managementPort` configure the Service ports
only; the container listens on fixed ports `8080` (API) and `8081` (management).

## Routing dispatch through Tiger proxy

To route dispatch through Tiger proxy instead of calling the Push Gateway directly, add a route and point
the allowlist at it:

```yaml
push-gateway:
  enabled: true

tiger-proxy:
  proxyConfig:
    proxyRoutes:
      - from: /push-gateway
        to: http://push-gateway:8080
      # … other routes …
      - from: /
        to: http://pep-proxy-svc

zeta-guard:
  notificationService:
    env:
      pushGatewayAllowedBaseUrls:
        - "http://tiger-proxy/push-gateway"
      channelsAllowed: "zeta"
```

With NetworkPolicies
enabled this dispatch path needs its own egress rule — see below. For general Tiger proxy setup, see
[How to configure and use the Tiger proxy](How_to_configure_tiger-proxy.md).

## NetworkPolicies

With `zeta-guard.networkPolicy.enabled: true` and `pushGatewayAllowedBaseUrls` non-empty,
`notification-service-netpol.yaml` emits one Push Gateway egress rule: an `ipBlock` on port `443` from
`networkPolicy.egress.providerInternal.resourceServers.ipBlocks`. This assumes the Push Gateway is reached
over the public ingress (e.g. `pushGatewayAllowedBaseUrls: [https://<host>/push-gateway]`), reusing the RS
JWK fetch ipBlock — set that ipBlock for the rule to take effect.

It does **not** cover dispatch via the tiger-proxy Service or a direct in-cluster Push Gateway call; for
those, add a `podSelector` egress rule (tiger-proxy or push-gateway on port `8080`) yourself, following
[How to configure Egress NetworkPolicies](How_to_configure_NetworkPolicies.md).
