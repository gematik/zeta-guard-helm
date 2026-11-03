# How to Configure Ingress (F5 NIC, mergeable)

This chart uses F5 NGINX Ingress Controller (NIC) mergeable Ingresses by
default:

- Master (`zeta-guard`) holds TLS and annotations (no paths)
- Minions (`zeta-guard-pep`, `zeta-guard-auth`, `testdriver-smcb`, `testdriver-oidc`,
  `test-monitoring-ingress`) hold
  routing rules for the same host/class

## Prerequisites

- NIC installed/enabled (bundled by default):
  `zeta-guard.nginxIngressEnabled: true`, or an external NIC compatible with
  `nginx.org/mergeable-ingress-type`.
- A host for the environment (required for mergeable): set
  `zeta-guard.authserver.hostname`.
- Consistent class across master and minions: set `zeta-guard.ingressClassName`
  and align subcharts (e.g., `testdriver-smcb.ingressClassName`).
- cert-manager installed when using TLS via ClusterIssuer.

## Configure

1) Set host and class
    - `zeta-guard.authserver.hostname: <env-host>`
    - `zeta-guard.ingressClassName: <class>`
    - `testdriver-smcb.ingressRulesHost: <env-host>`,
      `testdriver-smcb.ingressClassName: <class>`
    - `testdriver-oidc.ingressRulesHost: <env-host>`,
      `testdriver-oidc.ingressClassName: <class>`
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
        - `testdriver-smcb` / `testdriver-oidc`: `"tiger-proxy,testdriver-smcb"` / `"tiger-proxy,testdriver-oidc"` when
          `routeViaTigerProxy=true`, otherwise `"testdriver-smcb"` / `"testdriver-oidc"`

3) Deploy
    - `make deps`
    - `make deploy stage=<env>`

## Verify

- Master and minions exist and share host/class:
    - `kubectl -n <ns> get ingress zeta-guard zeta-guard-pep zeta-guard-auth
    testdriver-smcb testdriver-oidc test-monitoring-ingress -o wide`

- Paths:
    - WebSocket annotations present on minions (required for WS upgrade
      passthrough):
        - `kubectl -n <ns> get ingress zeta-guard-pep testdriver-smcb testdriver-oidc -o yaml 
        | rg websocket-services`
    - `/auth` → `authserver` (or `tiger-proxy` when routing via Tiger)
  - `/auth/admin` and `/auth/realms/master` → `pep-proxy-svc`, answering `403`
    (only with `adminHostname` set and `routeViaTigerProxy: false`)
    - `/` → `pep-proxy-svc` (or `tiger-proxy` when routing via Tiger)
    - `/notification-service-rs` and all subpaths → `pep-proxy-svc`, answering `404`
      on every stage, including with Tiger routing enabled. Internal calls through
      `http://tiger-proxy/notification-service-rs` remain available.
    - `/zeta/clients` and `/zeta/identity/email` → served by the PEP, authserver behind it
      (only with `authserver.config.oidcFlowEnabled: true`): `curl -sk -i https://<host>/zeta/clients`
      → `401` with `zeta-error-origin: pep`
    - `/td-smcb/proxy` and `/td-smcb/testdriver-api` → owned by `testdriver-smcb` minion
    - `/td-oidc/proxy` and `/td-oidc/testdriver-api` → owned by `testdriver-oidc` minion
    - `/sekidp` → `sekidp-gsi-server`, `/sekidp-fedmaster` → `sekidp-fedmaster` (or `tiger-proxy` when
      `sekidp.routeViaTigerProxy: true`), owned by the `sekidp` minion; the prefix is stripped either way:
      `curl -sk https://<host>/sekidp/.well-known/openid-federation` must not return `404`
- TLS policy:
    - `curl -vkI --tls-max 1.1 https://<host>` → fail
    - `curl -vkI --tls-max 1.2 https://<host>` → pass
    - `curl -vkI --tls-max 1.3 https://<host>` → pass

## Client management via the PEP

With `zeta-guard.authserver.config.oidcFlowEnabled: true` the PEP serves the client management
endpoints of mobile users and proxies them to the authserver, which acts as a resource server here:

| Path                                                    | Methods     | Scope                    |
|---------------------------------------------------------|-------------|--------------------------|
| `/zeta/clients`, `/zeta/clients/{id}`                   | GET, DELETE | `zeta:client-management` |
| `/zeta/identity/email`, `.../email/verify`, `.../email/resend` | POST | `zeta:client-management` |
| `/auth/realms/zeta-guard/zeta/identity/bind-email`, `.../resend`, `.../verify` | POST | `zeta:email-verify` (reduced binding token; public path unchanged, routed to the PEP by Ingress / tiger-proxy) |

**Routing**

- `routeViaTigerProxy: false`: `/` already points at `pep-proxy-svc`, no extra Ingress path.
- `routeViaTigerProxy: true`: `tiger-proxy.proxyConfig.proxyRoutes` carries `/zeta` →
  `http://pep-proxy-svc/zeta` (more specific than `/`).
- The authserver is reached as `http://authserver:80/auth/realms/zeta-guard/zeta/...` (own upstream
  `authserver-upstream`, in-cluster, plain HTTP). Token, DCR and well-known stay on `/auth` and never
  touch the PEP; the registration's `bind-email/*` endpoints keep their `/auth/realms/...` path but are
  routed to the PEP as well (Ingress path / tiger-proxy route, on every stage).
- The public authserver paths `/auth/realms/zeta-guard/zeta/clients` and `.../zeta/identity/email` are
  **closed on every stage** (independent of `oidcFlowEnabled` and of `routeViaTigerProxy`, the
  endpoints exist regardless): the Ingress sends them to the PEP, which answers `404` (same
  mechanism as `/auth/admin`); the tiger-proxy routes do the same as a second layer. Behind the PEP the authserver trusts the `zeta-client-data`
  header, so these paths must not be reachable through the `/auth` minion with a client-supplied
  header. Verify: `curl -sk -i https://<host>/auth/realms/zeta-guard/zeta/clients` → `404`,
  `zeta-error-origin` absent (plain nginx `return`).

**PEP locations** (`_pep-nginx-conf.tpl`, exact + trailing-slash pair per prefix)

- Checked by the PEP: access token (issuer, audience, expiry, schema), DPoP proof, scope
  `zeta:client-management`, no-travel, block list. Not checked: PoPP (`pep_require_popp off`).
- `pep_forward_client_data on`: the authserver learns the caller from the `zeta-client-data` header
  the PEP builds from the verified token (`client-data.yaml`); it does not check the token again.
  `Authorization` and `DPoP` are stripped upstream as everywhere (`proxy_headers.conf`).
- Whether a client belongs to the caller's identity is checked by the authserver.
- Errors raised by the PEP (missing or invalid token, missing scope) are `401` with
  `zeta-error-origin: pep`; responses of the authserver carry no such header.

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
well-known) must stay reachable there. Two paths are peeled off: the
`zeta-guard-pep` minion gains a `/auth/admin` **and** a `/auth/realms/master`
path pointing at `pep-proxy-svc`, where a
`location ~ ^/auth/(admin|realms/master)(/|$)` block returns `403`. The `master`
realm goes with the admin API because it carries the admin token endpoint
(`client_id=admin-cli`, direct grant); the `zeta-guard` realm that serves all
ZETA traffic is untouched.

That works because both nginx and the Ingress specification resolve overlapping
prefixes **longest-match-first**, independent of declaration order — so
`/auth/admin` and `/auth/realms/master` win over `/auth`. Since it relies on
nothing but plain Ingress path routing, the block holds for F5 NIC, standard
nginx-ingress, OpenShift Routes, GKE Ingress and any other controller.

With F5 NIC a second, redundant layer exists: `zeta-guard-auth` carries a
`nginx.org/location-snippets` annotation that returns `404` for the same two
paths nested inside its `/auth` location. It is shadowed by the longer prefixes
above, and only takes effect when those paths are absent — i.e. with
`routeViaTigerProxy: true`.

**Relationship with `routeViaTigerProxy`**

When `routeViaTigerProxy: true`, both `/auth` and `/` route to tiger-proxy,
which internally forwards `/auth → http://authserver/auth` and bypasses the PEP
entirely. The `/auth/admin` and `/auth/realms/master` paths are therefore
**not**
rendered in that mode, and the controller-agnostic block does not apply. With F5
NIC the `location-snippets`
layer still returns `404`; with any other controller both stay
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
