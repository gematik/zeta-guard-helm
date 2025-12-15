# Ingress

- Ingress name: `zeta-guard`
- Paths (default): `/auth → authserver:80`, `/ → pep-proxy-svc:80`
- NGINX controller comes from the dependency; configure its Service annotations
  in the values-file.
- Set `zeta-guard.routeViaTigerProxy: true` to send all ingress traffic to the
  `tiger-proxy` service. When enabled, ensure the Tiger chart is deployed
  (`tags.tiger-proxy: true`) and its `proxyRoutes` cover the exposed paths.
  See [How to configure Tiger proxy](../how-to_guides/How_to_configure_tiger-proxy.md) for details.
- Host behavior:
    - When `zeta-guard.authserver.hostname` is set (cd/dev/staging), the Ingress
      includes that host. Ensure each environment uses a unique hostname to
      avoid admission conflicts.
    - When empty (local), the host is omitted so the Ingress matches any host on
      the local controller.

## Azure Load Balancer notes (cd/dev/staging)

- Health probe: When exposing the ingress controller via a LoadBalancer, set
  `service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz`
  on the controller Service so Azure marks backends healthy (the controller
  responds 200 on `/healthz`).
