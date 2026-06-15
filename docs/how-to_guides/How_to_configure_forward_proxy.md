# How to Configure a Forward Proxy

ZETA Guard supports routing all outbound HTTP/HTTPS traffic through a forward
proxy. This is required in environments where egress to external endpoints
(e.g. PoPP issuer JWKs, OPA bundle registry, GCP services) must pass through a
corporate or compliance proxy.

---

## Affected components

The following components pick up the proxy configuration automatically:

| Component                                 | Outbound targets                             |
|-------------------------------------------|----------------------------------------------|
| `pepproxy` (nginx / reqwest)              | PoPP JWK endpoint, external OIDC issuer JWKs |
| `authserver` (Keycloak)                   | OCSP, external OIDC validation               |
| `opa` / `opa-simulation`                  | OPA bundle registry (OCI)                    |
| `provisioning-processor` (init container) | OCI provisioning image registry              |
| `opa-token-renewer` (CronJob)             | GCP STS / IAM APIs                           |

These components intentionally do **not** receive proxy configuration:

| Component                           | Reason                                       |
|-------------------------------------|----------------------------------------------|
| `keycloak-build` init container     | Runs `kc.sh build` locally, no outbound HTTP |
| `keychain-generator` init container | gRPC to cluster-internal HSM only            |

### Sub-charts (manual configuration required)

The following sub-charts are **not** covered by `global.httpProxy`
automatically,
because they are upstream Helm charts that do not consume global proxy values.
Configure them manually in your values override file when needed:

| Component                             | Outbound targets            | Configuration key               |
|---------------------------------------|-----------------------------|---------------------------------|
| `telemetry-gateway` (OTel Collector)  | gematik telemetry endpoints | `telemetry-gateway.extraEnvs`   |
| `test-monitoring-service` (OTel Demo) | cluster-internal only       | not needed — no external egress |

Example for `telemetry-gateway` when `gematikConnectionEnabled: true`:

```yaml
telemetry-gateway:
  extraEnvs:
    - name: HTTP_PROXY
      value: "http://proxy.example.com:8080"
    - name: http_proxy
      value: "http://proxy.example.com:8080"
    - name: HTTPS_PROXY
      value: "http://proxy.example.com:8080"
    - name: https_proxy
      value: "http://proxy.example.com:8080"
    - name: NO_PROXY
      value: ".cluster.local"
    - name: no_proxy
      value: ".cluster.local"
    - name: ALL_PROXY
      value: "http://proxy.example.com:8080"
    - name: all_proxy
      value: "http://proxy.example.com:8080"
```

---

## Configuration

Set the four proxy values once under `global:` in your values override file.
Helm propagates `global` automatically to all subcharts, so a single entry
covers the entire chart.

```yaml
global:
  httpProxy: "http://proxy.example.com:8080"
  httpsProxy: "http://proxy.example.com:8080"
  allProxy: "http://proxy.example.com:8080"
  # Comma-separated list of hosts / suffixes that bypass the proxy.
  # Leading dot (.cluster.local) means "any subdomain" in most tools.
  noProxy: ".cluster.local,<your-internal-hosts>"
```

All four values default to `null` (proxy disabled).

### What gets set in each pod

For each affected container, the chart sets each proxy variable in both
uppercase and lowercase — because different HTTP clients and tools follow
different conventions (`HTTP_PROXY` vs `http_proxy`):

| Uppercase     | Lowercase     |
|---------------|---------------|
| `HTTP_PROXY`  | `http_proxy`  |
| `HTTPS_PROXY` | `https_proxy` |
| `NO_PROXY`    | `no_proxy`    |
| `ALL_PROXY`   | `all_proxy`   |

For **nginx** (PEP), the chart additionally emits `env HTTP_PROXY;` etc.
directives in `nginx.conf` so the worker processes inherit the variables. The
`reqwest` HTTP client reads them at worker-process init time.

For **Keycloak** (authserver), the chart appends
`-Dhttp.nonProxyHosts=<converted>` to `JAVA_OPTS_APPEND`. Java's
`http.nonProxyHosts` uses a different format from Unix `NO_PROXY` (pipe
separator, `*` wildcard instead of leading dot); the chart performs the
conversion automatically:

| `noProxy` entry      | `http.nonProxyHosts` equivalent |
|----------------------|---------------------------------|
| `authserver`         | `authserver`                    |
| `.cluster.local`     | `*.cluster.local`               |

---

## noProxy recommendations

Include at minimum your cluster's internal DNS suffix so that pod-to-pod
traffic does not route through the proxy:

```yaml
noProxy: ".cluster.local"
```

The leading dot is a **de-facto convention** — there is no RFC standard for
`NO_PROXY` syntax. Behavior varies across tools:

| Tool          | Behaviour of `.cluster.local`                                                              |
|---------------|--------------------------------------------------------------------------------------------|
| curl, reqwest | Suffix-match — dot is treated as optional; matches `foo.cluster.local` and `cluster.local` |
| Go / grpc-go  | Subdomains only — matches `foo.cluster.local` but **not** `cluster.local` itself           |

Using `.cluster.local` (single entry with leading dot) covers
`*.pod.cluster.local` and all other Kubernetes-internal FQDNs with curl,
reqwest,
and Go alike.

Add any other internal or directly reachable hostnames as needed. Services
referenced by **short name** (without the `.cluster.local` suffix) do not
match the leading-dot pattern and will be sent to the proxy unless listed
explicitly:

```yaml
noProxy: ".cluster.local,authserver,opa"
```

> **Note:** Java's Apache HTTP Client (used by Keycloak internally) ignores
> the leading-dot convention in `NO_PROXY`. The chart handles this by
> automatically converting `global.noProxy` to `http.nonProxyHosts` format.
> The `.cluster.local` entry becomes `*.cluster.local` in the JVM system
> property.

---

## Opt-out for individual components

The proxy configuration is applied globally — there is no per-component proxy
value. If a specific component's outbound targets should bypass the proxy, add
those targets to `global.noProxy` rather than trying to configure the proxy
per-component.

For example, to let the `provisioning-processor` reach the provisioning
container registry directly without going through the proxy:

```yaml
global:
  httpsProxy: "http://proxy.example.com:8080"
  httpProxy: "http://proxy.example.com:8080"
  noProxy: ".cluster.local,europe-west3-docker.pkg.dev"
```

---

## Example: minimal production overlay

```yaml
global:
  httpsProxy: "http://squid.corp.example.com:3128"
  httpProxy: "http://squid.corp.example.com:3128"
  allProxy: "http://squid.corp.example.com:3128"
  noProxy: >-
    .cluster.local,
    <authserver-hostname>,
    <opa-hostname>
```

---

## Verification

After deployment, verify that the env vars are present in the PEP container:

```shell
kubectl exec -n <namespace> deploy/pep-deployment -- env | grep -i proxy
```

Expected output includes `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, `ALL_PROXY`
(upper and lower case variants).

Check that nginx received the `env` directives:

```shell
kubectl exec -n <namespace> deploy/pep-deployment -- \
  sh -c 'grep "^env" /etc/nginx/nginx.conf'
```

Expected:

```
env HTTP_PROXY;
env http_proxy;
env HTTPS_PROXY;
env https_proxy;
env ALL_PROXY;
env all_proxy;
env NO_PROXY;
env no_proxy;
```
