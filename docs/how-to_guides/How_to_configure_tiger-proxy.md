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
        preserveHostHeader: true
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
The ZETA Guard deployment can be configured to redirect DNS resolution of such domains to a statically assigned in-cluster service IP.
This can point to the standalone Tiger proxy or, for direct OCSP mock routing, to the OCSP mock service itself.
When routing through Tiger proxy, `global.dns.redirects[].proxyRoutes[]` are inserted before the catch-all `/` Tiger proxy route.
This keeps OCSP routes after any more specific routes and before the fallback route.

See `values.yaml` for the following `global` section:

```yaml
global:
  enableDNSRedirect: false
  dns:
    tigerStaticClusterIP: "10.96.3.11"
    redirects:
      - fqdn: ehca.gematik.de
        proxyRoutes:
          - from: /ecc-ocsp
            to: http://ehca.gematik.de/ecc-ocsp
      - fqdn: ocsp-testref.root-ca.ti-dienste.de
        proxyRoutes:
          - from: /ocsp
            to: http://ocsp-testref.root-ca.ti-dienste.de/ocsp
```

This section is used to:
- assign a static ClusterIP to the Tiger proxy `Service` when Tiger proxy is deployed
- add `hostAliases` to the `template.spec.hostAliases` key of the PEP, PDP and testdriver deployments
- add the matching OCSP proxy routes to the Tiger proxy configuration when Tiger proxy is deployed

`Service.spec.clusterIP` is immutable after Kubernetes creates the Service. If `tiger-proxy` already exists,
set `global.dns.tigerStaticClusterIP` to the current `tiger-proxy` Service IP, or deploy through the Makefile
targets so the live Service IP is injected automatically before rendering.
For direct mock routing, the same applies to `zeta-cert-validation-mock.service.clusterIP`.

Enable `global.enableDNSRedirect` in each environment that should route certificate AIA domains through Tiger proxy.

For direct OCSP mock routing without Tiger proxy, override the static IP and give the OCSP mock service that ClusterIP.
The IP must be valid for the target cluster's Service CIDR. Do not copy an IP from another cluster.
For achelos deployments the Makefile preserves the live `zeta-cert-validation-mock` Service IP before reinstalling.
If there is no live Service, it falls back to the reserved achelos IP `10.0.0.240` and fails before Helm deploy if
another Service already owns that IP.

```yaml
global:
  enableDNSRedirect: true
  dns:
    tigerStaticClusterIP: "<cluster-service-ip>"
    redirects:
      - fqdn: ehca.gematik.de
      - fqdn: ocsp-testref.root-ca.ti-dienste.de

zeta-cert-validation-mock:
  service:
    clusterIP: "<cluster-service-ip>"
```

**Note**: The full list of DNS redirections (`global.dns.redirects[]`) is written to the `hosts` file of the PEP, PDP and testdriver containers.
If a redirect is routed through Tiger proxy and the domain is contacted for multiple purposes, all unique URL paths have to be added to `global.dns.redirects[].proxyRoutes[]`.
If a redirect is routed directly to a backend service, the backend must expose the exact path embedded in the certificate AIA, for example `/ecc-ocsp` or `/ocsp`.


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
        preserveHostHeader: true
      # … other routes …
    tls:
      domainName: tiger-proxy
```

The `domainName` must match the hostname that clients use when calling the proxy. In the local profiles the service is
still exposed on port 80, so refer to it as `https://tiger-proxy:80/testfachdienst` from the PEP proxy configuration. The
Tiger proxy will generate a self-signed CA and per-host certificates on the fly (see section 4.4 of the Tiger
documentation), so clients either need to trust that CA or disable certificate verification for this upstream.

## Enable mTLS for direct PEP to testfachdienst traffic

The `testfachdienst` chart can enable the application's `mtls` Spring profile and mount the server keystore plus the
truststore used to verify client certificates:

```yaml
testfachdienst:
  mtls:
    enabled: true
    keyStore:
      secretName: testfachdienst-server-tls
      key: keystore.p12
      passwordSecretName: testfachdienst-server-tls
      passwordSecretKey: password
    trustStore:
      secretName: testfachdienst-client-ca
      key: truststore.p12
      passwordSecretName: testfachdienst-client-ca
      passwordSecretKey: password
```

Create the referenced Kubernetes Secrets before installing or upgrading the chart. The keystore must contain the
testfachdienst server private key and certificate chain. The truststore must contain the CA certificates that sign the
client certificates accepted by testfachdienst.

For direct `PEP -> testfachdienst` traffic, configure nginx to present a client certificate:

```yaml
tags:
  tiger-proxy: false

zeta-guard:
  pepproxy:
    nginxConf:
      proxyLocations:
        - path: /achelos_testfachdienst/ws
          upstream: https://testfachdienst
          upstreamPath: /achelos_testfachdienst/ws
          websocket: true
          # mTLS client certificate towards testfachdienst; the anchor is
          # reused below via *fachdienst-mtls
          extraConfig: &fachdienst-mtls |
            proxy_ssl_certificate /etc/nginx/fachdienst-client/tls.crt;
            proxy_ssl_certificate_key /etc/nginx/fachdienst-client/tls.key;
            proxy_ssl_trusted_certificate /etc/nginx/fachdienst-client/ca.crt;
            proxy_ssl_verify on;
            proxy_ssl_server_name on;
        - path: /pep
          upstream: https://testfachdienst
          extraConfig: |
            proxy_ssl_certificate /etc/nginx/fachdienst-client/tls.crt;
            proxy_ssl_certificate_key /etc/nginx/fachdienst-client/tls.key;
            proxy_ssl_trusted_certificate /etc/nginx/fachdienst-client/ca.crt;
            proxy_ssl_verify on;
            proxy_ssl_server_name on;
            {{- if .Values.openshiftIngress.enabled }}
            proxy_set_header Cookie ""; # do not pass OpenShift-session-cookies
            {{- end }}
        - path: /pep/achelos_testfachdienst/ws
          upstream: https://testfachdienst
          upstreamPath: /achelos_testfachdienst/ws
          websocket: true
          # SECURITY WARNING: bypassAsl makes this path public — it can be
          # called without the ASL protocol. This is ok and desired for this
          # test setup. If you want to copy this behaviour, make sure it is
          # permitted by the spec of your resource server.
          bypassAsl: true
          extraConfig: *fachdienst-mtls
    extraVolumes:
      - name: fachdienst-client-cert
        secret:
          secretName: nginx-mtls
          items:
            - key: tls.crt
              path: tls.crt
      - name: fachdienst-client-key
        secret:
          secretName: nginx-mtls
          items:
            - key: tls.key
              path: tls.key
      - name: fachdienst-server-ca
        secret:
          secretName: nginx-mtls
          items:
            - key: ca.crt
              path: ca.crt
    extraVolumeMounts:
      - name: fachdienst-client-cert
        mountPath: /etc/nginx/fachdienst-client/tls.crt
        subPath: tls.crt
        readOnly: true
      - name: fachdienst-client-key
        mountPath: /etc/nginx/fachdienst-client/tls.key
        subPath: tls.key
        readOnly: true
      - name: fachdienst-server-ca
        mountPath: /etc/nginx/fachdienst-client/ca.crt
        subPath: ca.crt
        readOnly: true
```

The PEP client certificate must be signed by a CA in the testfachdienst truststore. If `routeViaTigerProxy` stays enabled,
the Tiger proxy must also be able to present a trusted client certificate to `testfachdienst`; the current Tiger proxy
chart only configures TLS for traffic into Tiger and route targets, so use direct PEP routing for mTLS unless Tiger
outbound client-certificate support is added.
