# How to install cert-manager (OCI, CRDs enabled)

Requires Helm 3.8+ (for OCI registry support).

```shell
helm upgrade cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --install \
    --version v1.18.2 \
    -n cert-manager \
    --create-namespace \
    --set crds.enabled=true
```

## Deploy

- Set a valid email for the active issuer in the environment values (see above).
- `make deps && make deploy`

## Verify issuance

- `kubectl get clusterissuer`
- `kubectl -n <ns> get certificate,secret`
- Inspect details if Not Ready:
    - `kubectl -n <ns> describe certificate zeta-guard-tls`
    - `kubectl get order,challenge -A | grep zeta-guard`

## Switching dev ↔ prod in place

- Change `zeta-guard.clusterIssuer` in the env values.
- Then either patch the existing Certificate’s `spec.issuerRef`, or delete the
  `Certificate` (and optionally the `zeta-guard-tls` secret) to force re‑issue
  with the new issuer.

## Related sources

* [cert-manager – Installing with Helm](https://cert-manager.io/docs/installation/helm/)
