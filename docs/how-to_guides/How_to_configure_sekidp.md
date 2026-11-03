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
master — the same pattern `charts/testdriver-smcb` / `charts/testdriver-oidc` uses — exposing `gsi-server` 
at `/sekidp` and `gsi-fedmaster` at `/sekidp-fedmaster`. `gsi-fedmaster` needs to be externally reachable because
authserver's `zeta-sekidp-oidc` identity-provider broker (`terraform/authserver/sekidp.tf`) resolves federation 
trust against it directly (see "Reaching gsi-server and Fedmaster from Keycloak" below) — it's not purely an 
internal implementation detail of `gsi-server`.

Routing through this Ingress is independent of Tiger Proxy: `sekidp.routeViaTigerProxy` (default `false`)
optionally hops both paths through `tiger-proxy` instead of directly to `sekidp-gsi-server`/`sekidp-fedmaster` —
useful in stages that already run Tiger Proxy for request capture/tracing (`local` and `dev-novau` both set
this `true` today), but not required. Both components serve at `/`, so the `/sekidp` and `/sekidp-fedmaster`
prefixes are stripped before the request reaches them: by Tiger Proxy's route when hopping through it, otherwise
by the Ingress itself (`nginx.org/rewrite-target`). See "Enabling the chart and its Ingress" below.

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
dynamically via OIDC-Federation instead of a static `authorization_url`/`token_url`: the authserver reads the
Fedmaster URL from `/var/trust-data/federation-master.json` (provisioned by the provisioning-processor init
container, see `provisioningProcessor.federationMaster` in `values.yaml`), then fetches gsi-server's own entity
statement directly from `GSI_SERVER_URL` (`sekidp.gsiServer.env.serverUrl`). Both lookups are made by the
`authserver` pod itself — `GSI_SERVER_URL` is *also* fetched by the browser (front-channel authorization
redirect), but the Fedmaster URL only ever needs to be reachable from the authserver pod. Either way, both must
be the externally-resolvable Ingress URL (see above), not an in-cluster Service address — and the Fedmaster URL
must match `sekidp.fedmaster.env.serverUrl` exactly, since that's the issuer Fedmaster's own entity statement
publishes (self-consistency check).

Both URLs are HTTPS, so Keycloak has to trust their certificate. Behind a
publicly trusted certificate nothing
is needed; with the self-signed local CA (`issuers.local`) and no Tiger Proxy
hop in between, add it to
Keycloak's outbound truststore — otherwise the authorization request fails with
`PKIX path building failed`:

```yaml
zeta-guard:
  authserver:
    additionalTrustedCAs:
      - secretName: zeta-guard-tls
        secretKey: ca.crt
```

### The IdP's `client_id` (`sekidp_client_id`)

The `zeta-sekidp-oidc` IdP sends this realm's issuer URL as `client_id`, and
gsi-server fetches the realm's
entity statement from `<client_id>/.well-known/openid-federation`. By default
Terraform derives it from
`keycloak_url` (`<keycloak_url>/realms/zeta-guard`). That is only right as long
as Terraform reaches Keycloak
under its public hostname. Where `keycloak_url` points at the admin hostname
(`authserver.adminHostname`), the
sectoral IDP cannot reach it — set the public issuer explicitly:

```hcl
keycloak_url     = "https://admin.<host>/auth"                   # Terraform's way in
sekidp_client_id = "https://<host>/auth/realms/zeta-guard"       # what gsi-server sees
```

This has a NetworkPolicy consequence worth flagging: with `zeta-guard.networkPolicy.enabled: true`, `authserver`'s
egress to an Ingress-hostname URL goes to the NIC pods (on KIND via the CoreDNS rewrite to the NIC Service), not directly to the `tiger-proxy` pod —
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
`charts/sekidp/values.yaml`. Both components gate readiness with a `startupProbe` on the actuator readiness
endpoint (`sekidp.<component>.probes.startup`, default 3 s period × 40 = 120 s boot budget), so a pod turns
ready as soon as the app answers; readiness and liveness then run without an initial delay. `gsi-server`'s
init container waits for the `sekidp-fedmaster` Service, i.e. for Fedmaster to be ready, so the two start
times add up. `service.apiPort`/`service.managementPort` on each component configure the Service
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

`gsi-fedmaster` makes the same kind of outbound HTTPS call when resolving a federation member's entity statement,
so it has the identical `sekidp.fedmaster.additionalTrustedCAs` setting (same two entry forms).

### Relying parties known to this deployment

`gsi-server` (>= 8.5.1) validates authserver's PAR (`redirect_uri`, `scope`) against a statically mounted entity
statement instead of resolving authserver through `gsi-fedmaster`'s federation-fetch flow
(`GSI_FEDMASTER_MODE=local`, `GSI_FEDMASTER_LOCAL_ENTITY_STATEMENT_FILE`).

Set the statement as a signed JWT (`alg: HS256`; the signature itself isn't verified in local mode — the JWT
shape is what `gsi-server`'s parser expects):

```yaml
sekidp:
  gsiServer:
    entityStatementAboutRp: "<base64url header>.<base64url payload>.<base64url signature>"
```

Payload shape:

```json
{
  "sub": "<authserver-issuer-url>",
  "iss": "<this fedmaster's own published issuer, sekidp.fedmaster.env.serverUrl>",
  "iat": 1730000000,
  "exp": 4102444799,
  "metadata": {
    "openid_relying_party": {
      "redirect_uris": ["<redirect-uri>", "..."],
      "scope": "urn:telematik:display_name urn:telematik:versicherter urn:telematik:geburtsdatum openid",
      "jwks": { "keys": [] }
    }
  }
}
```

`sub` is the IdP's `client_id` (see `sekidp_client_id` above). `scope` must
contain every scope the IdP requests (`default_scopes` in
`terraform/authserver/sekidp.tf`) — gsi-server rejects a PAR asking for more
with
`invalid_scope` ("exceeds scopes found in entity statement"). Re-issue the
statement whenever that list changes.
gsi-server additionally accepts only the scopes it supports itself; the
birthdate is requested as
`urn:telematik:geburtsdatum` and arrives as the ID-token claim `birthdate`.

### Connecting to a real Fedmaster

For a real gematik Fedmaster (RU/TU) instead of the bundled test chart, keep `charts/sekidp` disabled
(`sekidp.enabled: false`), configure the Fedmaster URL via the provisioning-processor and register this
authserver there as a relying party.

```yaml
zeta-guard:
  provisioningProcessor:
    federationMaster:
      enabled: true
      environment: "production"   # or "test" — selects the URL from the provisioning container
```

```hcl
enable_sekidp      = true
# sekidp_client_id = "https://<host>/auth/realms/zeta-guard"   # only if keycloak_url is the admin hostname
```

What this deployment provides as a relying party, once the Terraform configuration has been applied with
`enable_sekidp = true`:

| Property             | Value                                                                                                       |
|----------------------|-------------------------------------------------------------------------------------------------------------|
| Issuer / `client_id` | `sekidp_client_id`, else `<keycloak_url>/realms/zeta-guard` (the `client_id` of the `zeta-sekidp-oidc` IdP) |
| Entity statement     | `<client_id>/.well-known/openid-federation`                                                                 |
| Signing key          | `ecdsa-generated` KeyProvider (ES256, P-256), created by the same run                                       |
| Encryption key       | `ecdh-generated` KeyProvider (ECDH-ES), created by the same run                                             |
| Scopes requested     | `urn:telematik:display_name urn:telematik:versicherter urn:telematik:geburtsdatum openid`                   |
| `acr_values`         | `gematik-ehealth-loa-high`                                                                                  |
| PKCE                 | enabled, `S256`                                                                                             |

The signing key is generated by Keycloak, so recreating the realm (or replacing the `ecdsa-generated` component)
yields a new key. The entity statement endpoint picks it up automatically.

The issuer URL must be reachable *by the Fedmaster*, since it resolves the RP's entity statement from it over
HTTPS with a publicly trusted certificate — the same requirement described in "Trusting the RP's (authserver's)
TLS certificate" above, which a self-signed local certificate does not meet.

The registration itself is a gematik process outside this repository; see
[Registrierung eines Fachdienstes in der TI-Föderation](https://wiki.gematik.de/spaces/IDPKB/pages/544316583/Registrierung+eines+Fachdienstes+in+der+TI-F%C3%B6deration+f%C3%BCr+die+Referenzumgebung+RU+Testumgebung+TU).
ZETA Guard does not change how it is carried out — it only determines which key and issuer you submit, and those
are the values in the table above.
