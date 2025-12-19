# How to set up TLS via Let’s Encrypt

- Requires `cert-manager`: install once, cluster‑wide (see guide [How to install cert-manager](How_to_install_cert-manager.md)). This chart manages ClusterIssuers and Ingress TLS.
- Ingress: uses `secretName: zeta-guard-tls` and enforces HTTPS (301/308) with HSTS enabled.
- Where the issuer is selected:
    - Subchart default is `charts/zeta-guard/values.yaml: clusterIssuer: "letsencrypt-staging"`.
    - This is usually overridden in your installation-specific values
