# How to Configure Ingress (F5 NIC, mergeable)

This chart uses F5 NGINX Ingress Controller (NIC) mergeable Ingresses by
default:

- Master (`zeta-guard`) holds TLS and annotations (no paths)
- Minions (`zeta-guard-pep`, `zeta-guard-auth`, `testdriver`,
  `test-monitoring-ingress`) hold
  routing rules for the same host/class

## Prerequisites

- NIC installed/enabled (bundled by default):
  `zeta-guard.nginxIngressEnabled: true`, or an external NIC compatible with
  `nginx.org/mergeable-ingress-type`.
- A host for the environment (required for mergeable): set
  `zeta-guard.authserver.hostname`.
- Consistent class across master and minions: set `zeta-guard.ingressClassName`
  and align subcharts (e.g., `testdriver.ingressClassName`).
- cert-manager installed when using TLS via ClusterIssuer.

## Configure

1) Set host and class
    - `zeta-guard.authserver.hostname: <env-host>`
    - `zeta-guard.ingressClassName: <class>`
    - `testdriver.ingressRulesHost: <env-host>`,
      `testdriver.ingressClassName: <class>`
    - `testMonitoringService.ingressRulesHost: <env-host>`,
      `ingressClassName: <class>`

2) Optional: route via Tiger Proxy
    - `zeta-guard.routeViaTigerProxy: true` to send `/auth` and `/` through
      `tiger-proxy`.
    - Ensure the Tiger chart is enabled and its `proxyRoutes` cover required
      paths.
    - For WebSocket upgrade support on routed services, ensure minion ingresses
      include NIC websocket annotations that match the actually routed backends:
        - `zeta-guard-pep`: `"tiger-proxy"` when `routeViaTigerProxy=true`.
          Without Tiger routing, the annotation placement depends on how the
          resource-server paths are configured:
            - with `pepproxy.nginxConf.proxyLocations` entries marked
              `websocket: true` (preferred), a dedicated `zeta-guard-ws-minion`
              carries the annotation for exactly those paths — the main
              minion's locations then keep NIC→PEP connection keepalive
              (a blanket annotation forces `Connection: close` on every
              non-WebSocket request, which exhausts the NIC's ephemeral
              ports under load)
            - with only the legacy raw `locations` config, the main minion
              carries a blanket `"pep-proxy-svc"` annotation (all pep paths
              get WebSocket handling, no upstream keepalive)
        - `testdriver`: `"tiger-proxy,testdriver"` when
          `routeViaTigerProxy=true`, otherwise `"testdriver"`

3) Deploy
    - `make deps`
    - `make deploy stage=<env>`

## Verify

- Master and minions exist and share host/class:
    - `kubectl -n <ns> get ingress zeta-guard zeta-guard-pep zeta-guard-auth
    testdriver test-monitoring-ingress -o wide`

- Paths:
    - WebSocket annotations present on minions (required for WS upgrade
      passthrough):
        - `kubectl -n <ns> get ingress zeta-guard-pep testdriver -o yaml 
        | rg websocket-services`
    - `/auth` → `authserver` (or `tiger-proxy` when routing via Tiger)
    - `/auth/admin` → `pep-proxy-svc`, answering `403` (only with
      `adminHostname` set and `routeViaTigerProxy: false`)
    - `/` → `pep-proxy-svc` (or `tiger-proxy` when routing via Tiger)
    - `/proxy` and `/testdriver-api` → owned by `testdriver` minion
- TLS policy:
    - `curl -vkI --tls-max 1.1 https://<host>` → fail
    - `curl -vkI --tls-max 1.2 https://<host>` → pass
    - `curl -vkI --tls-max 1.3 https://<host>` → pass

## Protecting the Admin API via a separate hostname

When `zeta-guard.authserver.adminHostname` is set, the chart creates two
additional Ingress resources and activates admin API blocking on the main
hostname:

| Resource                    | Purpose                                                            |
|-----------------------------|--------------------------------------------------------------------|
| `zeta-guard-admin` (master) | TLS-terminating ingress for `adminHostname`                        |
| `zeta-guard-admin-auth`     | Routes `/auth` on `adminHostname` → `authserver` directly (no PEP) |

On the **main hostname**, `/auth` keeps routing to `authserver` via the
`zeta-guard-auth` minion — the realm endpoints (token, nonce, registration,
well-known) must stay reachable there. Only `/auth/admin` is peeled off: the
`zeta-guard-pep` minion gains a `/auth/admin` path pointing at `pep-proxy-svc`,
where a `location ~ ^/auth/admin` block returns `403`.

That works because both nginx and the Ingress specification resolve overlapping
prefixes **longest-match-first**, independent of declaration order — so
`/auth/admin` wins over `/auth`. Since it relies on nothing but plain Ingress
path routing, the block holds for F5 NIC, standard nginx-ingress, OpenShift
Routes, GKE Ingress and any other controller.

With F5 NIC a second, redundant layer exists: `zeta-guard-auth` carries a
`nginx.org/location-snippets` annotation that returns `404` for `/auth/admin`
nested inside its `/auth` location. It is shadowed by the longer `/auth/admin`
prefix above, and only takes effect when that path is absent — i.e. with
`routeViaTigerProxy: true`.

**Relationship with `routeViaTigerProxy`**

When `routeViaTigerProxy: true`, both `/auth` and `/` route to tiger-proxy,
which internally forwards `/auth → http://authserver/auth` and bypasses the PEP
entirely. The `/auth/admin` path is therefore **not** rendered in that mode, and
the controller-agnostic block does not apply. With F5 NIC the
`location-snippets`
layer still returns `404`; with any other controller `/auth/admin` stays
reachable on the main hostname. Tiger-proxy is a test tool only — production
deployments use `routeViaTigerProxy: false`.

**DNS for the admin hostname**

The admin hostname must resolve to the same ingress controller IP as the main
hostname. For KIND/local development, add the admin hostname to
`issuers.local.dnsNames` in local values file and include it in
`adminTlsSecretName: zeta-guard-tls` to reuse the existing self-signed
certificate. The Makefile awk regex already includes `adminHostname:` values
when generating the CoreDNS patch, otherwise manual DNS entry is needed.

## Forcing a NIC pod restart after TLS / HSM config changes

In-place `nginx -s reload` does not re-initialise OpenSSL providers (e.g.
`ossl_hsm`). Bump `nginx-ingress.controller.pod.annotations.config-rev` in
`charts/zeta-guard/values.yaml` whenever you change `controller.config.entries`
or any HSM-related ingress config; any change to the value triggers a NIC pod
rolling restart. Convention: `YYYY-MM-DD-<short-tag>`.

## Notes

- Azure Load Balancer: set
  `service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz`
  on the NIC Service for healthy probes.
- External controller: disable bundled NIC via
  `zeta-guard.nginxIngressEnabled: false` and set only
  `zeta-guard.ingressClassName` to the cluster’s class. If that NIC lacks the
  `$zeta_route` http-snippets, also set `zeta-guard.nginxIngressLbMethod: false`
  so the sticky-session lb-method is not rendered.
- Minions must not duplicate the same path+host across Ingresses; define each
  path in exactly one minion.

## Troubleshooting

- Admission conflict: “host ... and path ... is already defined in ingress ...”
    - Remove legacy Ingress that still owns the path+host before applying
      mergeable minions or roll out in two steps (master first, then minions).
- Hostless local: mergeable expects an explicit host; set
  `zeta-guard.authserver.hostname` for local (self‑signed issuer supported via
  `issuers.local`).
