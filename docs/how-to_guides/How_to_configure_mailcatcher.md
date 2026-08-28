# How to configure the MailCatcher test chart?

> **Warning – no authentication**
> MailCatcher's web UI enforces no authentication at all. Anyone who can reach `/mailcatcher` can read every
> captured message. Do **not** run this chart in production or any security-sensitive environment. Keep it
> disabled unless you are testing in an isolated sandbox:
>
> ```yaml
> mailcatcher:
>   enabled: false
> ```

`charts/mailcatcher` is a thin, local/demo-only deployment of [MailCatcher](https://mailcatcher.me/), an
SMTP catch-all with a web UI for inspecting mail sent during testing — e.g. authserver's Keycloak realm
`smtpServer` config backing the ZETA client TOFU **F1** "verified email" factor (email-binding OTP delivery),
wired via `terraform/authserver`'s `smtp_host`/`smtp_port`/`smtp_from` variables (see "Wiring a real sender
later" below). It's a single stateless container: no database, no config file, no other backing service, and no
persistence (caught mail lives in memory and is lost on restart).

## Providing an image

MailCatcher is a public, third-party tool, not built by this org. The chart ships a placeholder
`image.repository`/`image.tag` — verify it resolves in your environment before enabling this chart, or point it
at your own build/mirror:

```yaml
mailcatcher:
  image:
    registry: "<registry>/<path>/"  # full prefix including trailing slash — optional full override
    repository: "<your-image>"
    tag: "<version>"
```

Unlike `charts/sekidp`'s org-built images, this does **not** consult `global.registry_host`/`registry_name` by
default — it's pulled directly, the same way `charts/push-gateway` pulls its bundled `postgres`/`artemis`
images. Pull credentials come from `global.imagePullSecrets` or `mailcatcher.imagePullSecrets`.

## Enabling the chart and wiring Tiger Proxy

```yaml
tags:
  mailcatcher: true

mailcatcher:
  enabled: true
  httpPath: /mailcatcher

tiger-proxy:
  proxyConfig:
    proxyRoutes:
      - from: /mailcatcher
        to: http://mailcatcher:1080/mailcatcher
```

`mailcatcher.enabled` is the effective switch — the umbrella chart always defines it, and Helm conditions take
precedence over tags.

`mailcatcher.httpPath` must match the route's `from` (and the route's `to` must keep that same path suffix,
unlike most other routes here). MailCatcher's HTML hardcodes a `<base href>` and resolves its asset/favicon
URLs relative to it; `--http-path` (passed through as `mailcatcher.httpPath`) is MailCatcher's own flag for
setting that base to a mount prefix instead of `/`. Without it, those requests go out at the domain root
instead of under `/mailcatcher`, missing the tiger-proxy route entirely and falling through to whatever else
lives at `/` (typically 401s against the PEP proxy). Leave `httpPath` unset only if MailCatcher is reachable
unprefixed (i.e. not proxied under a subpath).

Only the web UI (port `1080`) is routed through tiger-proxy. **SMTP (port `1025`) is never routed through
tiger-proxy** — tiger-proxy is a purely HTTP(S) reverse proxy (path-based `proxyRoutes`, RBEL HTTP-message
capture; see `charts/tiger-proxy/values.yaml`), with no TCP-passthrough concept, so it structurally cannot carry
the SMTP protocol. SMTP stays `ClusterIP`-only, reached directly over cluster networking by whatever sends mail.

## Wiring a real sender

`terraform/authserver`'s `keycloak_realm.zeta_realm` renders a realm `smtp_server` block whenever
`smtp_host` is set (empty omits the block entirely, i.e. no SMTP configured, same as today's default):

```hcl
smtp_host = "mailcatcher"
smtp_port = "1025"
smtp_from = "noreply@zeta-kind.local"
```

Points at the in-cluster Service (`mailcatcher:1025`) directly — not via tiger-proxy, per above.

**`smtp_from` is required whenever `smtp_host` is set** — Keycloak's `DefaultEmailSenderProvider` rejects a
missing/invalid `from` address outright (`EmailException: Invalid sender address 'null'`), even though the
Terraform provider schema doesn't distinguish it from an optional-looking field at the values level. Any
syntactically valid address works; MailCatcher doesn't validate the domain.

If `zeta-guard.networkPolicy.enabled: true`, the consumer's own `*-netpol.yaml` will also need a new
podSelector egress rule targeting the `mailcatcher` pod on port `1025`, following the shape already used for
`authserver → tiger-proxy` in `charts/zeta-guard/templates/netpol/authserver-netpol.yaml` — not yet added, see
[How to configure Egress NetworkPolicies](How_to_configure_NetworkPolicies.md).

## Further configuration

Resources, security contexts, the PodDisruptionBudget and `devMode` are configured via the chart values — see
`charts/mailcatcher/values.yaml`. `service.smtpPort`/`service.httpPort` configure the Service ports only; the
container listens on fixed ports `1025` (SMTP) and `1080` (web UI).
