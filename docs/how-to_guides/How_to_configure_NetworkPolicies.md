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

## DNS egress

Every egress NetworkPolicy allows DNS resolution. The DNS peer is configurable
via `networkPolicy.dns` and defaults to the upstream Kubernetes / KIND kube-dns
service:

```yaml
zeta-guard:
  networkPolicy:
    dns:
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

Overriding the peer — use `dns.to`, not the selectors. To point DNS egress
at a different service, set `networkPolicy.dns.to` to a raw list of
`NetworkPolicyPeer` entries. It is rendered verbatim and overrides
`namespaceSelector`/`podSelector`.

> Do not override `namespaceSelector`/`podSelector` directly: Helm
> deep-merges maps, so your label would be added to the default
> `k8s-app: kube-dns` (AND semantics), matching no pod and breaking DNS. Lists
> like `dns.to` are replaced wholesale, so they override cleanly.

### OpenShift

OpenShift does not run kube-dns. DNS is served by CoreDNS pods in
the `openshift-dns` namespace and - because OVN-Kubernetes evaluates egress
after DNAT - the destination port seen at the pod is 5353 instead of 53:

```yaml
zeta-guard:
  networkPolicy:
    dns:
      to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: openshift-dns
          podSelector:
            matchLabels:
              dns.operator.openshift.io/daemonset-dns: default
      ports:
        - port: 5353
          protocol: UDP
        - port: 5353
          protocol: TCP
```

> Always set `ports` together with `to`. `dns.to` and `dns.ports` are
> independent: overriding only `dns.to` for OpenShift and leaving `dns.ports`
> unset keeps the default `[53/UDP, 53/TCP]` — DNS then silently breaks against
> the 5353 CoreDNS pods. The default and the OpenShift preset set both together.

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
- Google Artifact Registry: use Google's published edge ranges from
  <https://www.gstatic.com/ipranges/goog.json>. The allowlist must cover both
  `europe-west3-docker.pkg.dev` (image manifest) and `storage.googleapis.com`
  (layer blobs).
- OCSP responders: `openssl x509 -in <cert.pem> -text | grep -A2 "OCSP"` →
  `dig +short <ocsp-host>`

**Known IPs (gematik/D-Trust re-verified 2026-07):**

| Category           | Hostname                                                 | IP                             |
|--------------------|----------------------------------------------------------|--------------------------------|
| `telemetry` (PU)   | `otlp.v1.bd.prod.ccs.gematik.solutions`                  | `34.117.144.61`                |
| `artifactRegistry` | `europe-west3-docker.pkg.dev` + `storage.googleapis.com` | `goog.json` ranges — see note  |
| `ocspCabForum`     | `ocsp.d-trust.net`                                       | `193.28.71.48`                 |
| `ocspCabForum`     | `crl.d-trust.net`                                        | `62.96.224.138`                |
| `ocspSmcbTsp`      | `ocsp.telematik.de`                                      | `104.247.81.99` (TI-internal)  |
| `ocspTiPki`        | `ocsp.ti.telematik.de`                                   | `104.247.81.99` (TI-internal)  |
| `telemetry` (RU)   | —                                                        | not yet resolved — ask gematik |
| `siem`             | —                                                        | not yet known — ask gematik    |
| `popp`             | —                                                        | stage-specific                 |

> **IP stability notes:**
>
> - `artifactRegistry` is served via Google CDN/anycast, so a single `/32` is
    unreliable — the resolved IP differs by location (e.g. `142.251.x` from
    one network, `74.125.x` from another) and layer blobs come from
    `storage.googleapis.com` on further IPs. Allow Google's published edge
    ranges from <https://www.gstatic.com/ipranges/goog.json>. Ranges confirmed
    to cover both hosts (2026-07): `74.125.0.0/16`, `142.250.0.0/15`,
    `192.178.0.0/15`, `172.217.0.0/16`, `216.58.192.0/19`, `209.85.128.0/17`.
    Re-check against `goog.json` before relying on them.
> - `ocspSmcbTsp` and `ocspTiPki` share the same IP (`104.247.81.99`) as of this
    writing, and resolve only inside the TI network. Verify against the actual
    certificate's AIA extension before deploying to production.
> - OCSP endpoints are embedded in each certificate's AIA extension and are
    authoritative. DNS-resolved IPs above are a starting point only — always
    cross-check with `openssl x509 -text`.

## Why IP blocks only — no DNS names (FQDN)

Standard Kubernetes `NetworkPolicy` (`networking.k8s.io/v1`) supports only
`ipBlock` (CIDR) peers - it cannot match egress by DNS name / FQDN. This is an
upstream limitation of the API, not a ZETA Guard restriction, and it is the
reason operators must resolve and maintain IP ranges.

FQDN-based egress requires a mechanism beyond plain NetworkPolicy and every
such mechanism is platform-specific:

| Mechanism                                                       | Availability                                                              |
|-----------------------------------------------------------------|---------------------------------------------------------------------------|
| Istio `ServiceEntry` (+ `outboundTrafficPolicy: REGISTRY_ONLY`) | Requires Istio. The path foreseen by the gemAnbT; provided separately.    |
| OpenShift `EgressFirewall` (`k8s.ovn.org/v1`, `dnsName`)        | OpenShift / OVN-Kubernetes only. A different resource than NetworkPolicy. |
| Cilium `CiliumNetworkPolicy` `toFQDNs`                          | Requires the Cilium CNI.                                                  |

Because providers run different platforms and service meshes, ZETA Guard does
not ship a single universal FQDN solution. In line with the gemAnbT, ZETA Guard
provides the (reference) NetworkPolicies – and, going forward, Istio resources;
when a different service mesh is used, the provider ports the policies to it.

## Provider-internal traffic

To allow all egress to any destination (e.g., during initial setup):

```yaml
zeta-guard:
  networkPolicy:
    egress:
      providerInternal:
        allowAll: true
```

Use `providerInternal.resourceServers.ipBlocks` for the more common case of
allowing egress to specific provider-controlled IPs — for example, the IP
address that your ingress hostname resolves to inside the cluster, which the PEP
proxy needs for JWK fetches. These IPs are deployment- and machine-specific and
should not be hardcoded in values files. Pass them at deploy time instead:

```sh
helm upgrade --install ... \
  --set "zeta-guard.networkPolicy.egress.providerInternal.resourceServers.ipBlocks[0]=<ip>/32"
```

Use `providerInternal.podSelectors` to allow egress to cluster-local pods that
the PEP proxy reaches via a Kubernetes service (ClusterIP). Because kindnet
enforces NetworkPolicy after kube-proxy DNAT, the destination seen by the kernel
is the pod IP on the pod's `targetPort`, not the ClusterIP on the service port.
Use `podSelector` with `targetPort` accordingly:

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
a pod in the same cluster. In production, upstream backends are external
services covered by `resourceServers.ipBlocks`.

## Pod-to-category mapping

| Pod                 | External categories used                                                                                                 |
|---------------------|--------------------------------------------------------------------------------------------------------------------------|
| `opa`               | `pip`, `artifactRegistry`, `providerArtifactRegistry`, `telemetry`, `siem`                                               |
| `opa-simulation`    | `pip`, `artifactRegistry`, `providerArtifactRegistry`                                                                    |
| `authserver`        | `telemetry`, `siem`, `ocspSmcbTsp`, `artifactRegistry`, `providerArtifactRegistry`                                       |
| `pep-proxy`         | `ocspCabForum`, `ocspSmcbTsp`, `ocspTiPki`, `popp`, `artifactRegistry`, `providerArtifactRegistry`, `providerInternal.*` |
| `telemetry-gateway` | `telemetry`, `siem`                                                                                                      |

> **Note:**
>
> - `authserver` and `pep-proxy` run the `provisioning-processor` as an init
    container, which pulls a signed OCI image from the artifact registry on
    every pod start. Both pods therefore require egress to `artifactRegistry`
    and `providerArtifactRegistry`.
> - Set `networkPolicy.egress.popp.mock: true` to allow egress to the
    `popp-mocks` test subchart pod (`app: popp-mock`); only needed when the
    `popp-mocks` subchart is deployed. The rule uses `podSelector` with target
    port `8080` (the pod's `targetPort`), not the service port `80`, because
    kindnet enforces NetworkPolicy after kube-proxy DNAT. External PoPP
    endpoints in production are covered by `egress.popp.ipBlocks`.
> - `opa-token-renewer-cronjob`, `opa-rollout-restart-cronjob`, and
    `ti-sim-token-renewer-cronjob` all use the same pod labels as the `opa`
    deployment (`app.kubernetes.io/name: opa`), so they are covered by the
    `opa-egress` NetworkPolicy — no separate policy is needed. Consequently,
    the `opa` egress must include both the artifact registry IPs (for OPA
    bundle pulls) and the gematik telemetry/OIDC IPs (for OIDC token renewal),
    covered by the `artifactRegistry` and `telemetry`/`siem` categories
    respectively. `opa-rollout-restart-cronjob` only talks to the in-cluster
    API server (`kubectl rollout restart`), so it needs none of these
    external categories.
> - When `zeta-guard.routeViaTigerProxy: true`, `authserver` additionally gets a
    `podSelector` egress rule to `tiger-proxy` (target port `8080`, the pod's
    `targetPort` — not the service port `80` — since kindnet enforces
    NetworkPolicy after kube-proxy DNAT). This covers outbound calls authserver
    routes through tiger-proxy, e.g. `authserver.provider.smcB.opaBaseUrl:
    http://tiger-proxy/opa` and (once configured) a Keycloak identity-provider
    broker to SEK-IDP (`charts/sekidp`) — see
    [How to configure the SEK-IDP / Fedmaster test chart](How_to_configure_sekidp.md).
> - When `notificationService.env.pushGatewayAllowedBaseUrls` is non-empty,
    `notification-service` gets one Push Gateway egress rule: an `ipBlock` on port
    `443` from `providerInternal.resourceServers.ipBlocks` (Push Gateway reached
    over the public ingress, reusing the RS JWK fetch ipBlock). Dispatch via
    tiger-proxy or a direct in-cluster call needs a `podSelector` rule added by hand.
