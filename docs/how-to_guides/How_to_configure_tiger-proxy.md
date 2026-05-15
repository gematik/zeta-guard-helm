# How to configure and use the Tiger proxy?

> **Warning – insecure components**
> Tiger Testsuite and Tiger Proxy may contain critical security flaws. Do **not** run them in
> production or any security-sensitive environment. Remove the chart or keep the chart disabled unless you are testing
> in an isolated sandbox:
>
> ```yaml
> tags:
>   tiger-proxy: false
> ```


## Activate routing via tiger proxy

Set the following values in the `values.yaml` file for the respective environment to activate routing via Tiger proxy:

```yaml
tags:
  tiger-proxy: true

tiger-proxy:
  proxyConfig:
    proxyRoutes:
      - from: /testfachdienst
        to: https://testfachdienst:443
      - from: /auth
        to: http://authserver/auth
      - from: /proxy
        to: http://testdriver/proxy
      - from: /telemetry/gateway
        to: http://test-monitoring-collector-local:4328
      - from: /opa
        to: http://opa:8181
      - from: /.well-known/openid-federation
        to: http://popp-statics/.well-known/openid-federation
      - from: /.well-known/signed-jwks
        to: http://popp-statics/.well-known/signed-jwks
      - from: /popp
        to: http://popp-statics
      - from: /
        to: http://pep-proxy-svc

zeta-guard:
  routeViaTigerProxy: true
  authserver:
    provider:
      smcB:
        opaBaseUrl: "http://tiger-proxy/opa"
  pepproxy:
    nginxConf:
      fachdienstUrl: https://tiger-proxy:80/testfachdienst
      poppIssuer: "http://tiger-proxy/popp"
  telemetry-gateway:
    config:
      exporters:
        otlp_http/test-monitoring-service:
          endpoint: http://tiger-proxy:4138
        otlp_http/ti_siem:
          endpoint: http://tiger-proxy:4138

testdriver:
  routeViaTigerProxy: true
```

Note: The `/popp`, `/.well-known/openid-federation`, and `/.well-known/signed-jwks`
routes point to the `popp-statics` Service from the `popp-mocks` chart. Keep these routes in place when
the PEP PoPP issuer is exposed through Tiger Proxy, otherwise federation metadata and signed JWKS lookups will bypass
or fail through the proxy path. Ensure `popp-mocks.enabled: true` (or adjust these targets and `poppIssuer`
to your own PoPP metadata/JWKS endpoints).

For telemetry, the switch works the same way as for the other Tiger routes: keep the
`/telemetry/gateway` entry in `tiger-proxy.proxyConfig.proxyRoutes` and point the OTLP HTTP exporter to
`http://tiger-proxy:4138` instead of the real collector. The dedicated Tiger OTLP entrypoint on port `4138`
forwards to the Tiger route `/telemetry/gateway`, which then forwards to the configured backend target.

After setting these values the Tiger proxy chart will be deployed when running `make deploy stage=<target-stage>`.

### DNS redirection for non-configurable domains

In some cases clients need to contact a domain that is not or not easily configurable (e.g. CRL endpoints or OCSP responders in TLS certificates).
The ZETA Guard deployment can be configured to redirect DNS resolution of such domains to the statically assigned IP of the standalone Tiger proxy.
Additionally, the (unique) URL path for the target domains has to be added to the `tiger-proxy.proxyConfig.proxyRoutes[]` or else the client will not 
be able to receive a useful response.

See `values.yaml` for the following `global` section:

```yaml
global:
  enableDNSRedirect: true
  dns:
    tigerStaticClusterIP: "10.96.3.11"
    redirects:
      - fqdn: ocsp.example.com
        ip: "10.96.3.11"
```

This section is used to:
- assign a static ClusterIP to the Tiger proxy `Service`
- add `hostAliases` to the `template.spec.hostAliases` key of the PEP, PDP and testdriver deployments

**Note**: The full list of DNS redirections (`global.dns.redirects[]`) is written to the `hosts` file of the PEP, PDP and testdriver containers. This means that if there are domains that are contacted for multiple purposes, all unique URL paths have to be added to `tiger-proxy.proxyConfig.proxyRoutes[]`.


## Deactivate routing via tiger proxy

Set the following values in the `values.yaml` file for the respective environment to deactivate routing via Tiger proxy:

```yaml
tags:
  tiger-proxy: false

tiger-proxy: {}

zeta-guard:
  routeViaTigerProxy: false
  authserver:
    provider:
      smcB:
        opaBaseUrl: "http://opa:8181"
  pepproxy:
    nginxConf:
      fachdienstUrl: https://testfachdienst:443
      poppIssuer: http://popp-statics
  telemetry-gateway:
    config:
      exporters:
        otlp_http/test-monitoring-service:
          endpoint: http://test-monitoring-collector-local:4328
        otlp_http/ti_siem:
          endpoint: http://test-monitoring-collector-local:4338

testdriver:
  routeViaTigerProxy: false
```

After setting these values the Tiger proxy chart will be ignored when running `make deploy stage=<target-stage>`.

If the Tiger proxy chart stays enabled but telemetry should bypass it, remove the `/telemetry/gateway` route
from `tiger-proxy.proxyConfig.proxyRoutes` and point the exporter directly to the real collector.

## Deployment configuration

### ServiceAccount

By default, a dedicated ServiceAccount is created with
`automountServiceAccountToken: false`:

```yaml
tiger-proxy:
  serviceAccount:
    create: true
    name: tiger-proxy
```

### Resources

Resource requests and limits can be configured separately for the main
container and the nginx sidecar:

```yaml
tiger-proxy:
  resources:
    limits:
      cpu: "900m"
      memory: "1Gi"
    requests:
      cpu: "500m"
      memory: "512Mi"
  nginxSidecar:
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
      requests:
        cpu: "50m"
        memory: "64Mi"
```

### Nginx sidecar image

The nginx sidecar image is configurable:

```yaml
tiger-proxy:
  nginxSidecar:
    image:
      repository: docker.io/nginxinc/nginx-unprivileged
      tag: "alpine3.22-slim"
```

### Replicas and PodDisruptionBudget

```yaml
tiger-proxy:
  replicaCount: 2
  podDisruptionBudget:
    enabled: true
    minAvailable: 1
```

### Security context

The pod-level and container-level security contexts are configurable:

```yaml
tiger-proxy:
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

Note: `runAsUser` is intentionally not set by default, as it is not supported
on OpenShift.

## Enable TLS for the testfachdienst route

When `testfachdienst` is configured to serve HTTPS (for example, by setting `SERVER_SSL_ENABLED=true`), the Tiger proxy must
both forward traffic via HTTPS to the backend and present its own certificate to the callers. Configure the TLS support
in the chart values:

```yaml
testfachdienst:
  env:
    - name: SERVER_SSL_ENABLED
      value: "true"

tiger-proxy:
  proxyConfig:
    proxyRoutes:
      - from: /testfachdienst
        to: https://testfachdienst:443
      # … other routes …
    tls:
      domainName: tiger-proxy
```

The `domainName` must match the hostname that clients use when calling the proxy. In the local profiles the service is
still exposed on port 80, so refer to it as `https://tiger-proxy:80/testfachdienst` from the PEP proxy configuration. The
Tiger proxy will generate a self-signed CA and per-host certificates on the fly (see section 4.4 of the Tiger
documentation), so clients either need to trust that CA or disable certificate verification for this upstream.
