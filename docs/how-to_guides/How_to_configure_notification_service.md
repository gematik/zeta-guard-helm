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

Keep `/push-gateway` before the catch-all `/` route, as with the other Tiger routes. With NetworkPolicies
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
