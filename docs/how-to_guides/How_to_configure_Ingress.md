# How to Configure Ingress (F5 NIC, mergeable)

This chart uses F5 NGINX Ingress Controller (NIC) mergeable Ingresses by default:
- Master (`zeta-guard`) holds TLS and annotations (no paths)
- Minions (`zeta-guard-minion`, `testdriver`, `test-monitoring-ingress`) hold routing rules for the same host/class

## Prerequisites
- NIC installed/enabled (bundled by default): `zeta-guard.nginx-ingress.enabled: true`, or an external NIC compatible with `nginx.org/mergeable-ingress-type`.
- A host for the environment (required for mergeable): set `zeta-guard.authserver.hostname`.
- Consistent class across master and minions: set `zeta-guard.ingressClassName` and align subcharts (e.g., `testdriver.ingressClassName`).
- cert-manager installed when using TLS via ClusterIssuer.

## Configure
1) Set host and class
   - `zeta-guard.authserver.hostname: <env-host>`
   - `zeta-guard.ingressClassName: <class>`
   - `testdriver.ingressRulesHost: <env-host>`, `testdriver.ingressClassName: <class>`
   - `testMonitoringService.ingressRulesHost: <env-host>`, `ingressClassName: <class>`

2) Optional: route via Tiger Proxy
   - `zeta-guard.routeViaTigerProxy: true` to send `/auth` and `/` through `tiger-proxy`.
   - Ensure the Tiger chart is enabled and its `proxyRoutes` cover required paths.
   - For WebSocket upgrade support on routed services, ensure minion ingresses include NIC websocket annotations that match the actually routed backends:
     - `zeta-guard-minion`: `"tiger-proxy"` when `routeViaTigerProxy=true`, otherwise `"pep-proxy-svc"`
     - `testdriver`: `"tiger-proxy,testdriver"` when `routeViaTigerProxy=true`, otherwise `"testdriver"`

3) Deploy
   - `make deps`
   - `make deploy stage=<env>`

## Verify
- Master and minions exist and share host/class:
  - `kubectl -n <ns> get ingress zeta-guard zeta-guard-minion testdriver test-monitoring-ingress -o wide`
- Paths:
   - WebSocket annotations present on minions (required for WS upgrade passthrough):
     - `kubectl -n <ns> get ingress zeta-guard-minion testdriver -o yaml | rg websocket-services`
  - `/auth` → `authserver` (or `tiger-proxy` when routing via Tiger)
  - `/` → `pep-proxy-svc` (or `tiger-proxy` when routing via Tiger)
  - `/proxy` and `/testdriver-api` → owned by `testdriver` minion
- TLS policy:
  - `curl -vkI --tls-max 1.1 https://<host>` → fail
  - `curl -vkI --tls-max 1.2 https://<host>` → pass
  - `curl -vkI --tls-max 1.3 https://<host>` → pass

## Notes
- Azure Load Balancer: set `service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz` on the NIC Service for healthy probes.
- External controller: disable bundled NIC via `zeta-guard.nginx-ingress.enabled: false` and set only `zeta-guard.ingressClassName` to the cluster’s class.
- Minions must not duplicate the same path+host across Ingresses; define each path in exactly one minion.

## Troubleshooting
- Admission conflict: “host ... and path ... is already defined in ingress ...”
  - Remove legacy Ingress that still owns the path+host before applying mergeable minions, or roll out in two steps (master first, then minions).
- Hostless local: mergeable expects an explicit host; set `zeta-guard.authserver.hostname` for local (self‑signed issuer supported via `issuers.local`).
