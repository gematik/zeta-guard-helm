# How to configure the SEK-IDP / Fedmaster test chart?

> **Warning – test/reference component**
> Both services ship gematik's public reference/test signing keys and peer public keys baked into their
> container images. This is fine for exercising the OIDC-Federation protocol in a test environment, but these
> are **not** your own production keys — do not treat this chart as production-ready. Keep it disabled unless
> you are testing federation flows:
>
> ```yaml
> sekidp:
>   enabled: false
> ```

`charts/sekidp` is a thin, local/demo-only deployment of gematik's **SEK-IDP** (`gsi-server`) and
**Fedmaster** (`gsi-fedmaster`) — the sectoral Identity Provider and federation registry used in the
OIDC-Federation flow (upstream repo: `gematik/app-gemSekIdp`, packaged by this org's `gem-sekidp` repository).
Both are stateless Spring Boot services with no database or broker dependency; each component gets its own
`Deployment`/`Service`, following the same pattern as `charts/push-gateway`.

## How the two components are coupled

- `gsi-server` calls out to `gsi-fedmaster`'s `/.well-known/openid-federation` (`FEDMASTER_SERVER_URL`) to
  resolve federation membership.
- `gsi-fedmaster` publishes a static federation member list. Its `ISSUER_IDP_01` entry must **exactly match**
  the external issuer URL `gsi-server` publishes (`GSI_SERVER_URL`), or entity-statement validation fails.
  `sekidp.fedmaster.env.issuerIdp01` defaults to `sekidp.gsiServer.env.serverUrl` when left empty, so setting
  only `gsiServer.env.serverUrl` is normally enough.

Both `gsi-server` and `gsi-fedmaster` are reachable from outside the cluster: this chart declares its own
Ingress (`sekidp.ingressEnabled`), a NIC "mergeable minion" sharing the host/TLS of zeta-guard's own Ingress
master — the same pattern `charts/testdriver` uses — exposing `gsi-server` at `/sekidp` and `gsi-fedmaster` at
`/sekidp-fedmaster`. `gsi-fedmaster` needs to be externally reachable because authserver's `zeta-sekidp-oidc`
identity-provider broker (`terraform/authserver/sekidp.tf`) resolves federation trust against it directly (see
"Reaching gsi-server and Fedmaster from Keycloak" below) — it's not purely an internal implementation detail of
`gsi-server`.

Routing through this Ingress is independent of Tiger Proxy: `sekidp.routeViaTigerProxy` (default `false`)
optionally hops both paths through `tiger-proxy` instead of directly to `sekidp-gsi-server`/`sekidp-fedmaster` —
useful in stages that already run Tiger Proxy for request capture/tracing (`local` and `dev-novau` both set
this `true` today), but not required. See "Enabling the chart and its Ingress" below.

## Providing images

This org's own `gem-sekidp` pipeline builds and pushes `gsi-server` and `gsi-fedmaster` images from
`github.com/gematik/app-gemSekIdp`. Point the chart at your build:

```yaml
sekidp:
  gsiServer:
    image:
      registry: "<registry>/<path>/"  # full prefix including trailing slash
      tag: "<version>"
  fedmaster:
    image:
      registry: "<registry>/<path>/"
      tag: "<version>"
```

When `image.registry` is unset, the image prefix is assembled from `global.registry_host` plus the chart's
`registry_name`. Pull credentials come from `global.imagePullSecrets` (or `sekidp.gsiServer.imagePullSecrets` /
`sekidp.fedmaster.imagePullSecrets`).

## Enabling the chart and its Ingress

```yaml
tags:
  sekidp: true

sekidp:
  enabled: true
  # Must match zeta-guard.authserver.hostname/ingressClassName for this
  # chart's Ingress to merge onto the same NIC master — see "How the two
  # components are coupled" above.
  hostname: "<your-ingress-hostname>"
  ingressClassName: "nginx"
  # Optional: hop both /sekidp and /sekidp-fedmaster through tiger-proxy
  # instead of routing directly to sekidp-gsi-server/sekidp-fedmaster.
  routeViaTigerProxy: false
  gsiServer:
    env:
      # Baked into gsi-server's signed entity statement and used as the
      # browser-facing authorization redirect target, so it must be the
      # externally-resolvable Ingress URL a browser can reach — the
      # /sekidp path above.
      serverUrl: "https://<your-ingress-hostname>/sekidp"
  fedmaster:
    env:
      # Fedmaster's own published issuer — must also be the
      # externally-resolvable Ingress URL (the /sekidp-fedmaster path
      # above), since authserver's zeta-sekidp-oidc broker now fetches
      # Fedmaster's entity statement from here directly (see "Reaching
      # gsi-server and Fedmaster from Keycloak" below).
      serverUrl: "https://<your-ingress-hostname>/sekidp-fedmaster"

# Only needed when sekidp.routeViaTigerProxy: true:
tiger-proxy:
  proxyConfig:
    proxyRoutes:
      - from: /sekidp
        to: http://sekidp-gsi-server:8085
      - from: /sekidp-fedmaster
        to: http://sekidp-fedmaster:8083
```

`sekidp.enabled` is the effective switch — the umbrella chart always defines it, and Helm conditions take
precedence over tags.

`GSI_SERVER_URL` and `FEDMASTER_SERVER_URL` must both be externally-resolvable base URLs matching how they're
actually reached — each is baked into its own signed entity statement, so it must stay consistent with however
you route traffic to it (this chart's own Ingress, with or without the optional Tiger Proxy hop).

### Reaching gsi-server and Fedmaster from Keycloak (authserver)

The `zeta-sekidp-oidc` identity-provider broker (`terraform/authserver/sekidp.tf`) resolves gsi-server
dynamically via OIDC-Federation instead of a static `authorization_url`/`token_url`: it resolves federation
trust against Fedmaster at `var.sekidp_fedmaster_url` (Terraform), then fetches gsi-server's own entity
statement directly from `GSI_SERVER_URL` (`sekidp.gsiServer.env.serverUrl`). Both lookups are made by the
`authserver` pod itself — `GSI_SERVER_URL` is *also* fetched by the browser (front-channel authorization
redirect), but `sekidp_fedmaster_url`/`FEDMASTER_SERVER_URL` only ever needs to be reachable from the
authserver pod. Either way, both must be the externally-resolvable Ingress URL (see above), not an in-cluster
Service address — and `sekidp_fedmaster_url` must match `sekidp.fedmaster.env.serverUrl` exactly, since that's
the issuer Fedmaster's own entity statement publishes (self-consistency check).

This has a NetworkPolicy consequence worth flagging: with `zeta-guard.networkPolicy.enabled: true`, `authserver`'s
egress to an Ingress-hostname URL resolves to the cluster node/`HOST_IP`, not directly to the `tiger-proxy` pod —
different from the `tiger-proxy` podSelector egress rule used for purely backend-only calls (e.g.
`authserver.provider.smcB.opaBaseUrl`). This now applies to *both* the gsi-server and Fedmaster lookups.
`local`/`dev`/`staging` run with NetworkPolicies disabled, so this doesn't bite yet; revisit before exercising
SEK-IDP under `local-guard` or any other NetworkPolicy-enabled stage — see
[How to configure Egress NetworkPolicies](How_to_configure_NetworkPolicies.md).

If you need a specific set of allow-listed OIDC redirect URIs for a relying party under test, set
`sekidp.fedmaster.env.redirectUris` (comma-separated); left empty, the bundled reference defaults are used.

### Presenting a client certificate to sekidp (mTLS)

When sekidp requires the authserver to present a client certificate on its PAR/token endpoints, configure
the client identity under `zeta-guard.authserver.sekidp.mtls`. The credential is a single-entry PKCS12
(`.p12`) keystore, referenced from an existing Secret, plus its password:

```yaml
zeta-guard:
  authserver:
    config:
      oidcFlowEnabled: true          # required — mTLS is inactive otherwise
    sekidp:
      mtls:
        keystore:
          secretName: sekidp-client  # Secret holding the .p12 keystore
          secretKey: sekidp-client.p12
        keystorePassword:
          secretName: sekidp-client-pw
          secretKey: password        # mandatory
```

Enabling mTLS without `config.oidcFlowEnabled: true`, or without the keystore password, fails the chart
render with a descriptive error. To trust sekidp's **server** certificate, use
`authserver.additionalTrustedCAs` (a separate, PEM-based setting) — not this block.

## Further configuration

Resources, security contexts, the PodDisruptionBudget and `devMode` are configured via the chart values — see
`charts/sekidp/values.yaml`. `service.apiPort`/`service.managementPort` on each component configure the Service
ports only; the containers listen on fixed ports `8085`/`8185` (gsi-server) and `8083`/`8183` (gsi-fedmaster).

`gsi-server`'s container image declares a `/app/certs_trusted` volume for custom trust anchors; mount your own
via `sekidp.gsiServer.trustedCerts.configMapName` — left empty, an empty `emptyDir` is mounted instead (the app
tolerates an empty/missing directory). This feeds `gsi-server`'s mTLS client-certificate allowlist, not its
outbound TLS trust decisions.

### Trusting the RP's (authserver's) TLS certificate

When resolving the RP's entity statement, `gsi-server` calls out to the RP's issuer URL over HTTPS (e.g.
`https://<authserver-hostname>/auth/realms/zeta-guard`). If that certificate isn't signed by a publicly-trusted
CA — e.g. a self-signed local dev certificate — `gsi-server` fails with:

```
GsiException: 400 BAD_REQUEST "SSL certificate validation failed for relying party [https://...]".
Reason: javax.net.ssl.SSLHandshakeException: ...
```

Fix by pointing `sekidp.gsiServer.additionalTrustedCAs` at the Secret/key holding that CA's PEM certificate, e.g.
for the local stage's cert-manager-issued `zeta-guard-tls` Secret:

```yaml
sekidp:
  gsiServer:
    additionalTrustedCAs:
      - secretName: zeta-guard-tls
        secretKey: ca.crt
```

Or, to trust a CA you don't have a pre-existing Secret for, provide the PEM directly and let the chart manage the
Secret itself:

```yaml
sekidp:
  gsiServer:
    additionalTrustedCAs:
      - cert: |
          -----BEGIN CERTIFICATE-----
          ...
          -----END CERTIFICATE-----
```

Each entry must use exactly one of the two forms (`secretName`+`secretKey`, or `cert`) — mixing both, or setting
neither, fails the chart render with a descriptive error rather than a confusing runtime mount failure.

An init container builds a PKCS12 truststore from the referenced/inline certificates and applies it to `gsi-server`
via `-Djavax.net.ssl.trustStore`. This is chart-managed and picks up certificate rotation (or values changes) on
every pod restart — no manual `kubectl` steps required.

`gsi-fedmaster` makes the same kind of outbound HTTPS call when resolving a federation member's entity statement
(e.g. a relying party's issuer in `fedmaster.relyingPartyConfigs`, see below), so it has the identical
`sekidp.fedmaster.additionalTrustedCAs` setting (same two entry forms).

### Relying parties known to this deployment

`gsi-fedmaster` ships a hardcoded demo relying party (GRAS) baked into its bundled reference config — this
chart replaces it entirely with `sekidp.fedmaster.relyingPartyConfigs`, a values-driven list rendered into a
complete `fedmaster.relying-party-configs` config block (the app's own schema — see gsi-fedmaster's
`application.yml`) via a chart-managed ConfigMap:

```yaml
sekidp:
  fedmaster:
    relyingPartyConfigs:
      - issuer: https://<authserver-issuer-url>
        organizationName: authserver
        keyConfig:
          fileName: pubkey.pem
          keyId: "${RP01_KEY_ID:}"
          use: sig
          x5cInJwks: false
```

`issuer` must exactly match the `client_id` the `zeta-sekidp-oidc` Keycloak identity provider presents
(`terraform/authserver/sekidp.tf`), or entity-statement validation fails. `keyConfig.fileName` is resolved as a
**classpath resource**, not a filesystem path — see below for how a real, dynamically-generated key gets onto
the classpath at all.

### Trusting authserver's entity-statement signing key (RP-01)

For a relying-party entry to actually verify, `gsi-fedmaster` needs the real public key authserver signs its
entity statement with, not just trust its TLS certificate (above). That key doesn't exist until Keycloak
generates it, which only happens when `terraform/authserver/sekidp.tf`'s `entity_statement_sig` KeyProvider
component is created (i.e. during `make config`, after `make deploy` has already started both `authserver` and
`sekidp-fedmaster`).

`gsi-fedmaster`'s key loading (`ResourceReader.getFileFromResourceAsTmpFile`) is strictly classpath-only — it
never reads an arbitrary filesystem path, so a mounted Kubernetes Secret can't be referenced by
`keyConfig.fileName` unless the mount point is genuinely on the JVM's runtime classpath. The `gem-sekidp` image
build addresses this at the Dockerfile level (no Java code change): `gsi-fedmaster`'s jar is exploded at build
time and launched via `java -cp ".../BOOT-INF/classes:.../BOOT-INF/lib/*:/public-keys" ...` instead of
`java -jar ...`, so `/public-keys` is a real, always-present classpath entry (harmless when nothing is mounted
there — the JVM silently ignores a nonexistent classpath entry). **Requires a `gsi-fedmaster` image built from
a `gem-sekidp` revision with this Dockerfile change.**

To close the ordering gap for the key's actual value, `make config` (with `enable_sekidp = true`) also:

1. reads the newly-created key's public half and `kid` back out of Keycloak's Admin REST API
   (`terraform/authserver/scripts/fetch-entity-statement-pubkey.sh`, run as a `data "external"` source)
2. writes them into a `sekidp-rp01-pubkey` Secret (`kubernetes_secret_v1.sekidp_rp01_pubkey`), containing
   `pubkey.pem` (the key itself) and `keyid` (a plain string)
3. runs `kubectl rollout restart deployment/sekidp-fedmaster` — only when the `kid` actually changed — so the
   new key takes effect. Kubernetes deliberately doesn't restart pods automatically when a mounted
   Secret/ConfigMap changes, so an explicit rollout is the standard way to pick this up.

On the chart side, this only needs one value:

```yaml
sekidp:
  fedmaster:
    relyingPartyKeySecretName: sekidp-rp01-pubkey
```

which mounts that Secret at `/public-keys` and sets the `RP01_KEY_ID` env var (via `secretKeyRef`, `optional:
true`) from its `keyid` key — matched by the `relyingPartyConfigs` entry's `keyId: "${RP01_KEY_ID:}"` above.
Both the volume and the env var are optional, so the pod starts fine (falling back to whatever
`keyConfig.fileName` resolves to, or failing that entry only, if the reference isn't present yet) even before
`make config` has run for the first time.

To re-trigger just this sync step without a full `make config` run:
`terraform -chdir=terraform/authserver apply -target='terraform_data.sekidp_fedmaster_rollout[0]'`.
