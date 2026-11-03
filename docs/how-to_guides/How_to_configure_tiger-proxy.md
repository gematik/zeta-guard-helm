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

The shared Tiger proxy configuration, including its standard routes, is defined
centrally in `charts/tiger-proxy/values.yaml`. Environment-specific values
should only contain the settings needed to activate routing:

```yaml
tags:
  tiger-proxy: true

global:
  enableDNSRedirect: true

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

testfachdienst:
  notificationServiceRsBaseUrl: "http://tiger-proxy/notification-service-rs"

testdriver-smcb:
  routeViaTigerProxy: true

testdriver-oidc:
  routeViaTigerProxy: true
```

These settings control separate traffic paths:

| Setting | Effect |
| --- | --- |
| `tags.tiger-proxy` | Deploys or removes Tiger proxy. |
| `zeta-guard.routeViaTigerProxy` | Routes incoming Guard traffic through Tiger. |
| `zeta-guard.authserver.provider.smcB.opaBaseUrl` | Selects the authserver's OPA endpoint. |
| `global.enableDNSRedirect` | Adds responder hostname overrides to the authserver, PEP and testdriver pods. To intercept their requests through Tiger, set the redirect IP to Tiger's Service IP. |

DNS redirection is optional and disabled by default. Enabling ingress routing
through Tiger alone does not intercept OCSP requests.

Note: The `/popp`, `/.well-known/openid-federation`, and `/.well-known/signed-jwks`
routes point to the `popp-statics` Service from the `popp-mocks` chart. Keep these routes in place when
the PEP PoPP issuer is exposed through Tiger Proxy, otherwise federation metadata and signed JWKS lookups will bypass
or fail through the proxy path. Ensure `popp-mocks.enabled: true` (or adjust these targets and `poppIssuer`
to your own PoPP metadata/JWKS endpoints).

The telemetry exporter settings above require a `/telemetry/gateway` route in
`tiger-proxy.proxyConfig.proxyRoutes` pointing to your collector. This route is
not included in the default route list. Add it before pointing exporters to
`http://tiger-proxy:4138`; the dedicated OTLP HTTP entrypoint forwards requests
to `/telemetry/gateway`.

Helm replaces `proxyRoutes` lists rather than merging their entries. When
overriding the list, retain all standard routes needed by your environment,
including the responder hostname routes described below.

After setting these values the Tiger proxy chart will be deployed when running `make deploy stage=<target-stage>`.

### DNS redirection for non-configurable domains

In some cases clients need to contact a domain that is not or not easily configurable (e.g. CRL endpoints or OCSP responders in TLS certificates).
The ZETA Guard deployment can be configured to redirect DNS resolution of such domains to a statically assigned in-cluster service IP.
This can point to the standalone Tiger proxy or, for direct OCSP mock routing, to the OCSP mock service itself.
When routing through Tiger proxy, `global.dns.redirects[].proxyRoutes[]` are appended to the configured proxy routes when DNS redirection is enabled, even if no `/` route is configured.
Tiger automatically prioritizes more specific paths over the catch-all `/` route; `/` does not need to be last in YAML.

The default responder list is defined in `values.yaml`. To enable DNS
redirection with that list, set:

```yaml
global:
  enableDNSRedirect: true
  dns:
    tigerStaticClusterIP: "10.96.3.11"
    redirects:
      - fqdn: ehca.gematik.de
        proxyRoutes: []
      - fqdn: cert-mock.zeta.test
        proxyRoutes: []
      - fqdn: ocsp-testref.root-ca.ti-dienste.de
        proxyRoutes: []
```

This section is used to:

- assign the configured static IP to the Tiger proxy Service and use the same IP for client DNS redirects
- add `hostAliases` to the `template.spec.hostAliases` key of the PEP,
  authserver and testdriver-* deployments
- append any explicitly configured `redirects[].proxyRoutes` to the standard routes in the Tiger chart

This section is meant for test setups: every entry in `global.dns.redirects` is
mapped to the *same* IP (`tigerStaticClusterIP`), which is either the Tiger
proxy
or the OCSP mock. Do not use it to steer unrelated name resolution — to give the
PEP its own `/etc/hosts` entries use `pepproxy.hostAliases`, and to reach the
authserver in-cluster use `pepproxy.nginxConf.pepInternalUrl` (see
[How to configure the authserver](How_to_configure_authserver.md)). The PEP's
custom `hostAliases` are merged with the entries generated here.

### Selecting the DNS redirect target

Achelos enables the OCSP signer truststore and keeps Tiger proxy disabled.
It redirects the certificate AIA hostname `cert-mock.zeta.test`
directly to the OCSP mock Service IP. The resulting path is:

`authserver -> cert-mock.zeta.test/ocsp/smb (zeta-cert-validation-mock)`

The mock Service and DNS redirect both default to `10.0.0.240`. The Makefile
preserves the mock's existing Service IP and uses it for the DNS redirect when
rendering or deploying. For a first install, ensure the address is available in
the cluster's Service CIDR, or override both the mock Service IP and the DNS
redirect IP for that cluster.

`Service.spec.clusterIP` is immutable after Kubernetes creates the Service. If `tiger-proxy` already exists,
set `global.dns.tigerStaticClusterIP` to the current `tiger-proxy` Service IP, or deploy through the Makefile
targets so the live Service IP is injected automatically before rendering.
For direct mock routing, the same applies to `zeta-cert-validation-mock.service.clusterIP`.

`zeta-guard.routeViaTigerProxy` controls incoming Guard traffic. OPA traversal
is selected separately with `authserver.provider.smcB.opaBaseUrl`.
With `global.enableDNSRedirect: true` and Tiger's Service IP configured in
`global.dns.tigerStaticClusterIP`, the authserver, PEP and testdrivers resolve
the hostnames in `global.dns.redirects` through Tiger. The defaults include
the three responder hostnames. This is independent of the ingress and OPA
settings. The Tiger chart has one route per
hostname, preserving the original hostname and path:

| Incoming hostname | Tiger destination |
| --- | --- |
| `ehca.gematik.de` | `http://ehca.gematik.de/` |
| `cert-mock.zeta.test` | `http://zeta-cert-validation-mock/` |
| `ocsp-testref.root-ca.ti-dienste.de` | `http://ocsp-testref.root-ca.ti-dienste.de/` |

These routes also match ordinary HTTP requests redirected by DNS. The proxy
itself resolves public responders normally. For `cert-mock.zeta.test`, Tiger
forwards to the `zeta-cert-validation-mock` Service through Kubernetes DNS,
preserving the original Host header and path. This also works on a first
installation or with offline manifest rendering, without a pinned mock Service IP.
Tiger's Service and the client DNS redirects both use
`global.dns.tigerStaticClusterIP`. The Makefile injects Tiger's existing Service
IP into this value for upgrades; for direct Helm upgrades, set it to the
existing Service IP explicitly. ConfigMap changes trigger a Tiger rollout
through its configuration checksum.

This interception applies to HTTP requests for the listed hostnames from
the pods with these hosts-file entries. Other OCSP responder hostnames use
normal DNS resolution. An explicit endpoint such as
`http://zeta-cert-validation-mock/ocsp/asl` also bypasses Tiger; configure a
Tiger URL and a matching route if that traffic should be captured too.
DNS redirection does not enable or disable the OCSP checks themselves.

| Tiger deployed | DNS redirection | Redirect target | OCSP path for listed hostnames |
| --- | --- | --- | --- |
| Yes | Enabled | Tiger Service IP | Client -> Tiger -> public responder or mock, according to the route. |
| Yes | Disabled | Unused | Normal DNS resolution; deploying Tiger alone does not intercept the requests. |
| No | Disabled | Unused | Normal DNS resolution without Tiger. |
| No | Enabled | Mock Service IP | Client -> mock directly; the mock must serve the certificate's AIA path. |

When DNS redirection is enabled, its target Service must exist. Disabling
Tiger while leaving redirects pointed at its former IP does not restore
direct responder access.

The same DNS setting supports direct mock routing by selecting the mock's
Service IP instead, as in Achelos. The local values enable DNS redirection
through Tiger alongside the separate ingress and OPA settings. The k3s
overlay explicitly disables DNS redirection.

For direct OCSP mock routing without Tiger proxy, override the static IP and give the OCSP mock service that ClusterIP.
The IP must be valid for the target cluster's Service CIDR. Do not copy an IP from another cluster.
For achelos deployments the Makefile preserves the live `zeta-cert-validation-mock` Service IP before reinstalling.
If there is no live Service, it falls back to the reserved achelos IP `10.0.0.240` and fails before Helm deploy if
another Service already owns that IP.

```yaml
tags:
  tiger-proxy: false

zetaCertValidationMockEnabled: true

global:
  enableDNSRedirect: true
  dns:
    tigerStaticClusterIP: "<cluster-service-ip>"
    redirects:
      - fqdn: cert-mock.zeta.test
        proxyRoutes: []

zeta-cert-validation-mock:
  service:
    clusterIP: "<cluster-service-ip>"
```

This example redirects only `cert-mock.zeta.test`; public responder hostnames
continue to resolve normally. Add other certificate AIA hostnames only when
the mock should answer those requests too.

**Note**: The full list of DNS redirections (`global.dns.redirects[]`) is written to the `hosts` file of the authserver, PEP and testdriver-* containers.
The standard hostname routes in the Tiger chart preserve all paths. Add routes for any additional redirected hostnames to `tiger-proxy.proxyConfig.proxyRoutes`.
If a redirect is routed directly to a backend service, the backend must expose the exact path embedded in the certificate AIA, for example `/ecc-ocsp` or `/ocsp`.


## Deactivate routing via tiger proxy

Set the following values in the `values.yaml` file for the respective environment to deactivate routing via Tiger proxy:

```yaml
tags:
  tiger-proxy: false

global:
  enableDNSRedirect: false

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

testfachdienst:
  notificationServiceRsBaseUrl: "http://notification-service-rs:8080"

testdriver-smcb:
  routeViaTigerProxy: false

testdriver-oidc:
  routeViaTigerProxy: false
```

After setting these values the Tiger proxy chart will be ignored when running `make deploy stage=<target-stage>`.

If OCSP requests should continue to use the mock directly, keep DNS
redirection enabled and configure the mock Service IP as shown above instead.

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
