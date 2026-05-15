# How to Configure Egress NetworkPolicies

ZETA Guard supports optional Kubernetes `NetworkPolicy` resources (egress-only)
that restrict outbound traffic from each pod to explicitly listed IP blocks.
This implements requirement A_27864-01.

## Enable

```yaml
# In your values override file
zeta-guard:
  networkPolicy:
    enabled: true
```

All pod-to-pod traffic within the cluster (DNS, OPA, PostgreSQL,
telemetry-gateway) is always allowed via pod/namespace selectors. External
egress is restricted to the IP blocks configured per category.

## Categories

| Key                                        | Destination                                             |
|--------------------------------------------|---------------------------------------------------------|
| `egress.telemetry`                         | gematik Telemetriedaten-Empfänger (OTLP endpoint)       |
| `egress.siem`                              | SIEM der gematik                                        |
| `egress.artifactRegistry`                  | ZETA Artifact Registry at gematik (OPA bundles, images) |
| `egress.providerArtifactRegistry`          | Provider-internal artifact registry                     |
| `egress.ocspCabForum`                      | OCSP/CRL for TLS TSPs per CAB Forum                     |
| `egress.ocspSmcbTsp`                       | SMC-B TSP OCSP responder                                |
| `egress.ocspTiPki`                         | OCSP responder for TI component PKI TSP                 |
| `egress.pip`                               | PIP — source of OPA policy bundles                      |
| `egress.popp`                              | PoPP service                                            |
| `egress.providerInternal.resourceServers`  | Provider-internal resource servers                      |
| `egress.providerInternal.telemetrySystems` | Provider-internal telemetry systems                     |

## Configure IP blocks

Each category accepts a list of CIDR strings. Leave empty to deny external
egress for that category.

```yaml
zeta-guard:
  networkPolicy:
    enabled: true
    egress:
      artifactRegistry:
        ipBlocks:
          - "34.90.0.0/16"   # Google Artifact Registry europe-west3
      ocspSmcbTsp:
        ipBlocks:
          - "1.2.3.4/32"
```

**IP acquisition:**

- gematik endpoints (telemetry, SIEM, PoPP): `dig +short <hostname>`
- Google Artifact Registry: <https://www.gstatic.com/ipranges/cloud.json> (
  filter `europe-west3`)
- OCSP responders: `openssl x509 -in <cert.pem> -text | grep -A2 "OCSP"` →
  `dig +short <ocsp-host>`

**Known IPs (as of 2025-04):**

| Category           | Hostname                                | IP                             |
|--------------------|-----------------------------------------|--------------------------------|
| `telemetry` (PU)   | `otlp.v1.bd.prod.ccs.gematik.solutions` | `34.117.144.61`                |
| `artifactRegistry` | `europe-west3-docker.pkg.dev`           | `142.251.127.82`               |
| `ocspCabForum`     | `ocsp.d-trust.net`                      | `193.28.71.48`                 |
| `ocspCabForum`     | `crl.d-trust.net`                       | `62.96.224.138`                |
| `ocspSmcbTsp`      | `ocsp.telematik.de`                     | `104.247.81.99`                |
| `ocspTiPki`        | `ocsp.ti.telematik.de`                  | `104.247.81.99`                |
| `telemetry` (RU)   | —                                       | not yet resolved — ask gematik |
| `siem`             | —                                       | not yet known — ask gematik    |
| `popp`             | —                                       | stage-specific                 |

> **IP stability notes:**
> - `artifactRegistry` (`europe-west3-docker.pkg.dev`) is served via Google
    CDN/anycast. The IP
    > resolved by DNS may change without notice. For production stages, use
    Google's published CIDR
    > ranges from <https://www.gstatic.com/ipranges/cloud.json> instead of a
    single `/32`.
> - `ocspSmcbTsp` and `ocspTiPki` share the same IP (`104.247.81.99`) as of this
    writing.
    > Verify against the actual certificate's AIA extension before deploying to
    production.
> - OCSP endpoints are embedded in each certificate's AIA extension and are
    authoritative.
    > DNS-resolved IPs above are a starting point only — always cross-check with
    `openssl x509 -text`.

## Provider-internal traffic

To allow all egress to any destination (e.g. during initial setup):

```yaml
zeta-guard:
  networkPolicy:
    egress:
      providerInternal:
        allowAll: true
```

Use `providerInternal.resourceServers.ipBlocks` for the more common case of
allowing egress to
specific provider-controlled IPs — for example the IP address that your ingress
hostname resolves
to inside the cluster, which the PEP proxy needs for JWK fetches. These IPs are
deployment- and
machine-specific and should not be hardcoded in values files. Pass them at
deploy time instead:

```sh
helm upgrade --install ... \
  --set "zeta-guard.networkPolicy.egress.providerInternal.resourceServers.ipBlocks[0]=<ip>/32"
```

Use `providerInternal.podSelectors` to allow egress to cluster-local pods that
the PEP proxy
reaches via a Kubernetes service (ClusterIP). Because kindnet enforces
NetworkPolicy **after**
kube-proxy DNAT, the destination seen by the kernel is the pod IP on the pod's
`targetPort`, not
the ClusterIP on the service port. Use `podSelector` with `targetPort`
accordingly:

```yaml
zeta-guard:
  networkPolicy:
    egress:
      providerInternal:
        podSelectors:
          - matchLabels:
              app: my-backend   # pod label
            port: 8443          # targetPort (not servicePort)
```

This is typically only needed in test stages where the upstream backend runs as
a pod in the same
cluster. In production, upstream backends are external services covered by
`resourceServers.ipBlocks`.

## Pod-to-category mapping

| Pod                 | External categories used                                                                                                 |
|---------------------|--------------------------------------------------------------------------------------------------------------------------|
| `opa`               | `pip`, `artifactRegistry`, `providerArtifactRegistry`, `telemetry`, `siem`                                               |
| `opa-simulation`    | `pip`, `artifactRegistry`, `providerArtifactRegistry`                                                                    |
| `authserver`        | `telemetry`, `siem`, `ocspSmcbTsp`, `artifactRegistry`, `providerArtifactRegistry`                                       |
| `pep-proxy`         | `ocspCabForum`, `ocspSmcbTsp`, `ocspTiPki`, `popp`, `artifactRegistry`, `providerArtifactRegistry`, `providerInternal.*` |
| `telemetry-gateway` | `telemetry`, `siem`                                                                                                      |

> **Note:** `authserver` and `pep-proxy` run the `provisioning-processor` as an
> init container,
> which pulls a signed OCI image from the artifact registry on every pod start.
> Both pods
> therefore require egress to `artifactRegistry` and `providerArtifactRegistry`.

> **Note:** Set `networkPolicy.egress.popp.mock: true` to allow egress to the
`popp-mocks` test
> subchart pod (`app: popp-mock`). This is only needed when the `popp-mocks`
> subchart is deployed.
> The rule uses `podSelector` with target port `8080` (the pod's `targetPort`),
> not the service
> port `80`, because kindnet enforces NetworkPolicy after kube-proxy DNAT.
> External PoPP endpoints
> in production are covered by `egress.popp.ipBlocks`.

> **Note:** `opa-token-renewer-cronjob` and `gematik-oidc-token-renewer-cronjob`
> both use the
> same pod labels as the `opa` deployment (`app.kubernetes.io/name: opa`). They
> are therefore
> covered by the `opa-egress` NetworkPolicy — no separate policy is needed. As a
> consequence,
> the OPA policy must include both artifact registry IPs (for OPA bundle pulls)
> and gematik
> telemetry/OIDC IPs (for the OIDC token renewal). Both are covered by the
`artifactRegistry`
> and `telemetry`/`siem` categories respectively.
