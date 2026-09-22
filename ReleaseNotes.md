<img align="right" width="250" height="47" src="docs/img/Gematik_Logo_Flag.png"/> <br/>

# Release Notes ZETA Guard Helm Charts

## Release 1.3.3

### changed:

- pepproxy image `1.3.3`

## Release 1.3.2

### ⚠️ breaking — read before upgrading from 1.3.0/1.3.1:

- keycloak-zeta 1.3.2 fixes the identifier casing in the `ZETA_USER_DATA`/
  `ZETA_CLIENT_DATA` Liquibase migration. The already-applied
  changesets were edited in place, so their checksums changed: **every stage
  installed with 1.3.0/1.3.1 must, before upgrading, drop the `ZETA_USER_DATA`/
  `ZETA_CLIENT_DATA` tables AND delete the file's Liquibase bookkeeping**
  in the plugin's own `databasechangelog_zeta_guard` table — dropping alone is not
  enough, the stored checksums still fail validation and the authserver does not start:
  ```sql
  DROP TABLE IF EXISTS zeta_client_data, zeta_user_data CASCADE;
  DELETE FROM databasechangelog_zeta_guard WHERE filename LIKE '%jpa-changelog-26.6.3%';
  ```
  On startup the migration then re-runs and recreates both tables. Registered
  DCR clients are lost by the drop and have to re-register.

### added:

- `telemetryGatewaySendingQueuePVCAccessModes` (default `[ReadWriteOnce]`) and
  `telemetryGatewaySendingQueuePVCStorageClass` (default `""`, i.e. the
  cluster's default class) make the telemetry-gateway's sending-queue PVC match
  your storage system — `ReadWriteMany` for shared filesystems.
  See [Telemetry](docs/explanations/Telemetry.md#sending-queue-persistence-and-platform-constraints).
- Documented how to run the telemetry-gateway on OpenShift: it is the only
  component pinning `runAsUser`/`fsGroup` and both must be handed to the SCC
  with an explicit `null` — omitting the keys silently inherits the chart
  default because Helm merges maps.
  See [Telemetry](docs/explanations/Telemetry.md#openshift).
- `notificationService.db.kind`: database kind for the notification-service
  (`NOTIFICATION_DATASOURCE_DB_KIND`, required by images >= 1.3.2), default
  `postgresql`; cloudnative mode accepts only `postgresql`.
- [How to upgrade ZETA Guard](docs/how-to_guides/How_to_upgrade_ZETA_Guard.md):
  the supported upgrade path (`helm upgrade` + `make config`), what protects the
  Terraform state, and how to adopt an existing realm when the state was lost.
  A full reinstall was never required — Terraform owns realm configuration only,
  users and DCR-registered clients live in the database. Every step is given as
  both the `make` target and the plain `terraform` command, so the guide is
  usable without the Makefile.

### changed:
- updates notification-service to 1.3.2
- updates keycloak-zeta and ngx_pep to 1.3.2
- updates provisioning-processor to 1.3.2
- updates testdriver and nativedriver to 1.3.2
- updates zeta-telemetry-gateway to v0.156.0
- The Keycloak admin credentials no longer reach the Terraform state. Terraform
  no longer reads the `authserver-admin` Secret at all — the new
  `terraform/authserver/scripts/kc-admin-env.sh` fills
  `TF_VAR_keycloak_username`/`TF_VAR_keycloak_password` from it, and both are
  now `ephemeral` and required in either mode. The SMC-B identity provider
  secret moved to the provider's write-only argument; bump the new
  `smc_b_client_secret_version` to push a rotated value. **Terraform 1.11 or
  newer is required.** See
  [How to configure the authserver](docs/how-to_guides/How_to_configure_authserver.md).
- The Terraform variable `audience_scope_name` has no default any more and must
  be set in every stage tfvars. It names the only scope carrying the
  access-token claims the PEP validates, so a silent `zero:audience` fallback
  hid misconfiguration. See
  `docs/how-to_guides/How_to_configure_authserver.md`.
- `terraform/authserver/environments/demo.tfvars` now documents every accepted
  Terraform variable with its default and works as a copy-paste template.
- `enable_sekidp = true` now requires `use_kubernetes = true` and fails the plan
  otherwise — it creates a Kubernetes Secret and restarts the sekidp-fedmaster
  deployment, neither of which works without cluster access.
- updates OPA-Image to 1.19.1-static
- `values-demo.yaml` brought back in sync with `values.yaml`.
- the pre-1.3.0 flat `gematik.idTokenAudience` /
  `gematik.serviceAccountEmailAddress`
  are gone for good. Their transitional fallback in the ti-sim token renewer is
  removed (the ti-siem renewer never had one), and setting either value now
  fails the render with a pointer to `gematik.tiSim.*` / `gematik.tiSiem.*`
  instead of silently renewing a token for an empty service account. Stages
  already using the per-stream values are unaffected — the rendered CronJobs are
  unchanged.
- `gematik.tiSiem` is now also declared in `values.schema.json`.
- Logs, metrics and span attributes that serve solely security purposes are no
  longer available to Dienstherstellers.
- OPA decision logs are no longer written to console.

### fixed:
- `notificationService.<rs|fdv>.image.tag` had no effect: the documented
  per-variant tag override was ignored by the image helper (only `image.digest`
  was honored).
- `terraform import` against an existing realm aborted with `Invalid for_each
  argument` before importing anything: the two notification mapper resources
  keyed their `for_each` off `keycloak_openid_client_scope.notification_scopes`,
  and import evaluates resources absent from the state as unknown. Both now key
  off `local.notification_scope_names`; instance keys are unchanged, so an
  applied stage plans no changes.
- `make config-import` imported `keycloak_realm.pdp_realm`, an address renamed
  before 0.2.0, and its error fallback swallowed the failure — the target
  silently did nothing. It now imports `keycloak_realm.zeta_realm`, skips a
  realm
  already in the state and fails loudly otherwise.
- rendering the chart with a disabled telemetry pipeline
  (`telemetry-gateway.config.service.pipelines.<name>: null`)
  aborted with `index of untyped nil` — the opentelemetry-collector chart's
  deprecated-name auto-rewrite misses a nil guard. The rewrite is now off
  (`telemetry-gateway.rewriteDeprecatedComponentNames: false`); it only renames
  components we do not use, so rendered output is unchanged.
- With `use_kubernetes = false` the Kubernetes provider is no longer a provider
  requirement — `terraform init` no longer downloads it; the `kubernetes_*`
  blocks moved into the generated `sekidp-secret.tf`, which only exists in
  Kubernetes mode. In Kubernetes mode the `>= 2.38` version constraint applies
  again instead of resolving to latest.
- `authserver.provider.smcB.ocspFailClosed` had no effect: the value was
  accepted and documented, but the authserver deployment never rendered the
  corresponding env var.
- `global.noProxy`: a leading dot on the **first** entry (e.g.
  `".cluster.local,…"`, exactly what the forward-proxy guide recommends) was not
  converted to `*.` for `http.nonProxyHosts` — Java ignores `.cluster.local`, so
  Keycloak sent cluster-internal traffic through the forward proxy.

### removed

- The fixed client scopes `zero:register` and `zero:manage` and their
  authorization-server audience mapper. A terraform apply deletes them from
  existing realms; clients still requesting either scope must drop it.

## Release 1.3.1

### changed:

- Raise tag versions

## Release 1.3.0

### known issues:

- Database encryption and integrity for VAU: The readiness endpoint becomes
  "ready" prematurely. Under load this leads to bad keycloak instances that
  yield error 500 on most requests.
    - This is **no Problem for VSDM** and other services that don't use the VAU
      dbEnc feature.
    - **Workaround**: Set the `authserver.probes.readiness.initialDelaySeconds`
      in the kubernetes readiness Probe to a high value, so that spree integrity
      provider is ready in that time. A value like `240` should be a safe
      starting point for this.

### added:

- **ZETA Stufe 2 — OIDC mobile-client flow** (
  `authserver.config.oidcFlowEnabled`,
  default `false`): mobile clients authenticate via a federated sektoraler
  Identity Provider (SekIdP) instead of an SMC-B token exchange.
- **Notification Service** as a bundled, opt-in zeta-guard component
  (`notificationService.enabled`, default `false`) — the ZETA Stufe 2 push
  notification management and forwarding service, with its own PEP routes,
  discovery document, and database.
- Test-support subcharts for exercising the ZETA Stufe 2 flows locally
  (`push-gateway`, `sekidp`, `mailcatcher`, `nativedriver`) — not part of ZETA
  Guard, all disabled by default.
- `authserver.truststoreReload` (`enabled`, `interval`) lets the authserver pick
  up refreshed SMC-B, TPM and OCSP trust anchors while it runs, without a
  restart and without dropping requests. Needs an authserver image > 1.2.3.
- `provisioningProcessor.schedule` (`enabled`, `time`, `timezone`) keeps the
  provisioning processor resident as a native sidecar of the authserver and
  re-runs it daily. Enabled by default; needs Kubernetes >= 1.32 (OpenShift
  4.19) and a
  provisioning-processor image that supports `SCHEDULE_TIME`.
- `spree.config.realm.enabled` is now set to true at the very end in the
  bootstrap process of keycloak by terraform
- `telemetryGatewayHost` — sets the fully-qualified hostname the
  telemetry-gateway
  is reached at, for clusters where its bare service name does not resolve.
- `opa.simulation.bundle.verification` to override bundle signature
  verification for the simulation OPA instance only.
- `pepproxy.hsmTlsKeyId` / `hsmTlsCert` to configure the PEP TLS HSM key ID and
  certificate file (defaults unchanged: `tls.p256` / `tls.p256.pem`).
- `pepproxy.asl_hsm_key` — HSM-backed ASL signer key as `store:hsm:<key-id>`
  URI; replaces the file-based signer key from the `asl-identity` secret and
  drops its mount. Requires `pepproxy.hsmProxyAddr`.
- Session revocation support: `zetaGuardRevocations` cache in the Infinispan
  server config (dedicated-Infinispan deployments only — the authserver refuses
  to start
  without it), `zeta-guard-revocation-events` in the realm's `eventsListeners`
  (`terraform/authserver/events.tf`, which declares the complete list — check
  the plan
  before applying to an existing realm), and `pep_revocation_url` pointing at
  the
  authserver's in-cluster Service. That endpoint is intra-cluster only and
  cannot work
  through an ingress; with NIC it is denied on every exposed hostname.
- `authserver.provider.smcB.ocspConnectTimeoutMs` / `ocspReadTimeoutMs` /
  `ocspFailClosed` (default `false`, fail-open) for the SMC-B OCSP revocation
  check.
- `nginxIngressLbMethod` toggle for the sticky-session lb-method on the minion
  ingress.
- `cloudnativePg.enablePDB` and `cloudnativePg.storage.pvcTemplate` to
  parameterize the CNPG PDB and storage class.
- `cloudnativePg` config surface for `imagePullPolicy`, `affinity`,
  `monitoring`, `pooler`, and `backup` (pooler and backup disabled by default).
- `networkPolicy.dns` — make the DNS egress peer of the egress NetworkPolicies
  configurable (`namespaceSelector`, `podSelector`, `ports`, or a raw `to:`
  override). Defaults to the upstream `kube-system` / `k8s-app: kube-dns` /
  port 53 peer, so existing deployments are unchanged. For OpenShift, set the
  `openshift-dns` selector (`dns.operator.openshift.io/daemonset-dns: default`)
  and port 5353 — DNS runs in the `openshift-dns` namespace and OVN-Kubernetes
  evaluates egress post-DNAT, so the destination pod port is 5353, not 53.
- `pepproxy.nginxConf.proxyLocations` — structured, schema-validated
  configuration of the resource-server proxy locations. Each entry generates an
  http-level `upstream` block with connection keepalive, an exact + prefix
  location pair, and always includes `proxy_headers.conf`; supports
  `websocket`, `bypassAsl`, `keepalive`, and tpl-rendered `extraConfig`.
  Replaces the raw `locations` string, which is now **deprecated** and
  scheduled for removal; setting both at once fails the render (they are
  mutually exclusive — migrate entirely, do not mix).
- Dedicated `zeta-guard-ws-minion` Ingress, derived from `proxyLocations`
  entries with `websocket: true`. The NIC `websocket-services` annotation moves
  to this minion so only WebSocket paths get `Connection: upgrade` handling —
  all other locations regain NIC→PEP upstream keepalive (a blanket annotation
  forced `Connection: close` per request and exhausted NIC ephemeral ports
  under load).
- Stable `nginx-ingress-metrics` Service in front of the NIC's Prometheus
  exporter; the telemetry-gateway now scrapes NIC metrics into the
  Dienst-Hersteller stream.
- Expose additional CloudNativePG options: `cloudnativePg.extraParameters` (
  arbitrary
  reloadable postgres settings), `sharedPreloadLibraries`,
  `storage.storageClass`
  shortcut, and optional dedicated `walStorage` volume
- Specific information from the policy engine's decision logs will be extracted
  into OpenTelemetry attributes for further processing.
- Added counter metrics for ZETA client requests.
- New config options to configure nginx worker processes in pep.
  The defaults are the previous values.
  |value|description|default|
  |---|---|---|
  |pepproxy.workerProcesses|Number of worker processes; "auto"=cpu count|auto|
  |pepproxy.workerConnections|Max. number of connections per worker|16384|
  |pepproxy.workerRlimitNofile|Max. number of open files, per worker. Should be
  at least 2*workerConnections|40960|
- Support for serving the OPA policy bundle from an operator-hosted private
  registry whose TLS certificate is issued by an internal CA. Note the
  full-CA-bundle
  requirement in
  [How to Use a Custom OCI Registry](docs/how-to_guides/How_to_use_a_custom_OCI_registry.md).
- `opa.bundleHealthCheck` (default `false`) — surfaces a failed OPA bundle
  download
  as `NotReady` via the readiness probe. See
  [the OPA reference](docs/reference/OPA.md).
- Various client-ip and forward headers are now stripped by default at NIC, and
  externalTrafficPolicy now defaults to `Local`, to preserve client IPs.
    - NIC is now a DaemonSet, so all nodes continue to accept traffic, and don't
      request cpu resources any more
- `opa.rolloutRestart` — optional CronJob that periodically restarts the OPA
  Deployment via `kubectl rollout restart` (default: disabled). Runs on a
  configurable `schedule` (fixed `Europe/Berlin` timezone), reusing
  `provisioningProcessor.image` rather than a separate tooling image. The
  chart creates its own ServiceAccount + minimal RBAC (`get`/`patch` on the
  `opa` Deployment only) unless `opa.rolloutRestart.serviceAccountName` is
  set to an externally pre-provisioned ServiceAccount.

### changed:

- The chart now declares `kubeVersion: ">=1.32.0-0"`, the supported platform
  baseline
  sidecar init container used by `provisioningProcessor.schedule`.
- The `filter/ti_siem` whitelist now forwards the new security event
  `authn_client_deleted` to TI SIEM.
- Ingresses are split per route, since NIC applies `lb-method`, `ssl-services`
  and
  `location-snippets` per minion: `zeta-guard-pep` (`/`, renamed from
  `zeta-guard-minion`), `zeta-guard-auth` (`/auth`, new) and — with
  `authserver.adminHostname` — `zeta-guard-admin-auth` (`/auth` on that
  hostname, renamed
  from `zeta-guard-admin-minion`). `lb-method` on `/auth` is **required**, not
  tuning:
  nonces are kept per node, so with it off and more than one authserver replica,
  token
  exchange fails with `Invalid nonce value` about half the time.
- `zeta-guard-admin-auth` gained the `ssl-services` annotation it was missing (
  it routes
  to the authserver's `https` port when TLS is enabled).
- with `authserver.adminHostname` set, `/auth/admin` is denied with `403` on the
  public hostname. The `zeta-guard-pep` minion routes that one path to the PEP,
  which denies it, so the block needs nothing but plain Ingress path routing and
  holds for **any** ingress controller — overlapping prefixes resolve
  longest-match-first.
- NIC subchart install is now gated by `nginx-ingress.enabled` (was
  `nginxIngressEnabled`); annotations still gated by `nginxIngressEnabled`.
- Only logs and metrics from resource servers are exported to TI SIM.
- Only spans from resource servers and HTTP server spans from the ZETA guard
  HTTP proxy are exported to TI SIM.
- All logs and spans with a service name starting with "rs." are recognized as
  coming from a resource server.
- Only logs, metrics and spans about specific security events from ZETA guard
  are exported to TI SIEM:
    - Metrics and spans about detected attacks
    - HTTP server spans received by authorization server and HTTP proxy
    - HTTP client spans that trigger policy decisions
- Every log, metric, and span now has the resource attribute `service.version`
  with the chart version as value.
- Configured sending queue, retry behavior and timeout of telemetry exporter
  `otlp_grpc/ti_sim`.
- PEP nginx: `reuseport` on all listeners (per-worker accept queues),
  widened `net.ipv4.ip_local_port_range` via pod sysctl and raised
  `worker_rlimit_nofile`
  to optimize connection handling
- NIC ConfigMap defaults: upstream `keepalive`, `keepalive-requests: "10000"`,
  `worker-connections`, and `worker-rlimit-nofile` — prevents ephemeral-port
  exhaustion (TIME_WAIT churn) on NIC→backend connections under load.
- Resource baselines sized for the 300 rps performance target: authserver
  memory limit 6Gi, PEP 3 CPU / 2Gi requests, CNPG 2 CPU / 2Gi requests
  (3Gi limit), `sharedBuffers: 512MB`, `maxConnections: 250`, and
  `wal_compression: on` (≈3× WAL volume reduction, fewer forced checkpoints).
- The following security events are reported to TI-SIEM:
    - client registrations
    - token exchanges
- Renamed TI-SIM-related values, Secret and CronJob.
    - Replaced value `gematik.idTokenAudience` with
      `gematik.tiSim.idTokenAudience`.
    - Replaced value `gematik.serviceAccountEmailAddress` with
      `gematik.tiSim.serviceAccountEmailAddress`.
- Added separate values, Secret, CronJob, OTLP exporter, etc. for TI-SIEM.
- Any OPA status update log containing error codes will have severity 'error'
  set.
- Any log from ZETA guard with severity 'error' or 'fatal' is exported to
  TI-SIM.
- Repaired counter metric of detected attacks.
- Every log, metric and span passing through the telemetry-gateway receives the
  attribute `server.address` if missing.
- Updated OpenTelemetry collector to version 0.155.0
- Configured telemetry exporters with persistent storage for sending queues.
- updates OPA-Image to 1.19.0-static
- updates PostgreSQL-Image to postgresql:17.11-standard-trixie

### fixed:

- with `telemetryGatewayEnabled: false`, OPA logged `status update failed, server
  replied with HTTP 403 Forbidden` once per bundle poll: an empty
  `status.service` is silently defaulted by OPA to the first configured
  service — in bundle mode the policy registry, which rejects the status POST.
  `status` and
  `decision_logs` are now rendered only with a sink, never with an empty
  `service`. Policy decisions were never affected.
- with `authserver.adminHostname` set, the Keycloak admin console was
  unreachable: `--hostname-admin` was passed without the `/auth` context path,
  so Keycloak served the console at `/auth/admin/` but redirected to `/admin/` —
  a path neither Keycloak nor the admin Ingress answers. Both hostname flags now
  carry `/auth`. Discovery and the token `iss` are unchanged.
- secure Keycloak admin passwords (containing spaces, `&`, `$`, `+`, `"` or
  backticks) now work in the authserver config
- telemetry-gateway crash-looped on fresh namespaces until the first
  token-renewer CronJob run: the `ti-siem-token` and `ti-sim-token` Secrets now
  always render `data.token` — a placeholder on first install, the live value
  carried forward via `lookup` afterwards — so the pod starts immediately and
  upgrades never drop the renewed tokens. On the first upgrade from the
  pre-split chart, the legacy `gematik-oidc-token` Secret seeds both new
  Secrets so exports keep working until the renewers run.
- cert-manager first-issuance deadlock on fresh namespaces: the chart now
  creates an explicit `Certificate` with
  `cert-manager.io/issue-temporary-certificate`, so the NIC can serve a
  temporary certificate while the real one is being issued (ingress-shim does
  not propagate that annotation, and the ACME HTTP-01 solver could never be
  reached through a TLS-less ingress).

  **Upgrade note for existing namespaces:** previous releases let ingress-shim
  create the `zeta-guard-tls` (and `zeta-guard-admin-tls`) Certificates from
  Ingress annotations, and helm refuses to manage such pre-existing objects
  (`invalid ownership metadata`). The chart handles this automatically: while
  a foreign Certificate exists it is skipped from the release (the existing
  object keeps serving and renewing TLS), and a one-shot
  `post-install`/`post-upgrade` hook Job adopts it into the release —
  including removing the stale `ownerReference`, without which ingress-shim
  would garbage-collect the object once the Ingress annotations are gone. The
  **next** helm operation then renders and manages the Certificate normally
  (adoption is metadata-only: the TLS Secret is untouched and no certificate
  is reissued). Should that operation report a server-side-apply field
  conflict (only possible if the old Certificate's spec drifted from the
  chart values), run it once with `helm upgrade --force-conflicts`.

  When installing with `--no-hooks`, perform the adoption manually before
  upgrading (repeat for `zeta-guard-admin-tls` if present):

  ```sh
  kubectl -n <ns> patch certificate zeta-guard-tls --type=json \
    -p='[{"op":"remove","path":"/metadata/ownerReferences"}]'
  kubectl -n <ns> annotate certificate zeta-guard-tls \
    meta.helm.sh/release-name=<release> meta.helm.sh/release-namespace=<ns>
  kubectl -n <ns> label certificate zeta-guard-tls app.kubernetes.io/managed-by=Helm
  ```
- non-constrained tls 1.3 ciphers (accept only
  `TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256`
  instead of all defaults) and GS-A_5322 compliance (disable
  `ssl_session_tickets`
  because we can't guarantee compliant STEK, and enable shared session cache)

### removed

- all cpu limits in the chart defaults. They lead to issues with dropped
  connections
  during the time processes get “frozen” on quota exhaustion, and other knock-on
  effects.
- dead values `opa.workloadIdentityFederation.sts.{audience,tokenUrl,iamUrl,scope}` and
  `…gar.host` from schema/examples — never read by any template; the schema now rejects
  unknown `sts` keys.

## Release 1.2.3

### added:

- New value `provisioningProcessor.provisioningContainerCaConfigMapRef` — a
  ConfigMap alternative to `provisioningContainerCaSecretRef` for the
  provisioning container registry CA (e.g. the CA bundle generated by
  OpenShift's custom PKI mechanism, which is published as a ConfigMap). Mutually
  exclusive with the Secret reference; the Secret takes precedence if both are
  set.
- New values `provisioningProcessor.extraEnv`,
  `provisioningProcessor.extraVolumes`
  and `provisioningProcessor.extraVolumeMounts` on the provisioning processor
  init container, letting operators mount the registry CA (or other material)
  from any source — Secret, ConfigMap, projected volume, CSI, etc.
- New value `provisioningProcessor.registryCredentialsSecretRef` — references an
  existing Secret (e.g. created from a SealedSecret) holding a username and
  token, wiring `PROVISIONING_CONTAINER_REGISTRY_USERNAME` /
  `PROVISIONING_CONTAINER_REGISTRY_TOKEN` into the init container so the
  provisioning container can be pulled from registries that do not allow
  anonymous access. Configurable key names via `usernameKey`/`tokenKey`
  (defaults `username`/`token`).

### changed:

- updates OPA-Image to 1.18.2-static

### fixed:

- `opa-token-renewer-cronjob` annotated the wrong Secret (`gematik-oidc-token`)
  with its `last-updated` timestamp instead of the Secret it actually patches
  (`opa-gcp-token`). With `set -euo pipefail` this aborted the run when
  `gematik-oidc-token` did not exist (e.g. `gematikConnectionEnabled: false`),
  marking the CronJob as failed even though the GAR token had been written
  successfully.

## Release 1.2.2

### changed:

- VAU related bugfixes
- fixed: Now enforcing client and dpop key binding in smc-b token

## Release 1.2.1

### changed:

- Update authserver to 1.2.2 with an important VAU related bugfix
  (Note: The authserver version is not a typo. In the 3rd digit release versions
  of the individual components of the helm chart may differ from the helm chart
  version.)
- OTEL config for pep (+spanmetrics). It now emits OTLP logs, traces, and
  metrics (in addition to nginx-otel defaults)
- New value `issuer` — emits the namespace-scoped `cert-manager.io/issuer`
  annotation on the master Ingress resources instead of
  `cert-manager.io/cluster-issuer`. Takes precedence over `clusterIssuer` when
  set. Lets operators who are not permitted to deploy cluster-scoped
  `ClusterIssuer` resources (governance/security policy) use a namespace-scoped
  cert-manager `Issuer`. Default `""` keeps the existing ClusterIssuer behavior.
- Updated OpenTelemetry collector to version 0.154.0 and added spanmetrics
  connector
- Updated metric `attack.detection.count` to count attack spans from all
  sources, instead of attack logs from only the authorization server

## Release 1.2.0

### migration:

- **Keycloak version bumps require a deployment cutover.** Plain`helm upgrade`
  hangs when the new Keycloak version ships a different JGroups protocol
  version; mixed-version pods can't form a cluster. Liquibase migrations and
  Infinispan cache serialization can also clash across minor versions. Run one
  of the following before/during the upgrade:

  ```sh
  kubectl -n <namespace> delete deployment authserver   # then helm upgrade as usual
  # OR
  helm upgrade --force ...                              # delete + recreate as part of the upgrade
  ```

  Not needed for deploys that don't change the Keycloak image tag (config
  tweaks, label changes, resource bumps).

  NOTE: Once installations are in production this kind of update will be
  avoided / flanked
  with measurements supporting availability.

### added:

- Added `include proxy_headers.conf;` to each `pep on;` location using
  `proxy_pass` in PEP
- New value `authserver.hsm.tokenSigning.failClosed` (default: `true`) — when
  HSM token signing is enabled, refuse software-key fallback if HSM is
  unreachable.
- configuration for application level db encryption (only for VAU based
  applications)
- New values `pepproxy.wellKnownResourceSuffix` (default: `/pep/`) and
  `authserver.wellKnownAuthServerPath` (default: `/`) make the path components
  of the `/.well-known/oauth-protected-resource` document configurable.
- Forward proxy support for all ZETA Guard components
    - Env vars set in all affected pods: `HTTP_PROXY`, `http_proxy`,
      `HTTPS_PROXY`, `https_proxy`, `NO_PROXY`, `no_proxy`, `ALL_PROXY`,
      `all_proxy`.
    - PEP (nginx): proxy vars propagated to worker processes via `env`
      directives in `nginx.conf`, picked up by the `reqwest` HTTP client at
      worker init.
- Enabled SIEM telemetry delivery to gematik by default
- Enabled metrics delivery to gematik
- Filter telemetry sent to gematik (incl. SIEM).
    - Drop all logs except logs about authorization server, HTTP proxy, policy
      engine, and resource server.
    - Drop all metrics about zeta-guard components.
    - Drop all spans except for HTTP server spans about requests to public
      endpoints of authorization server, HTTP proxy, policy engine, and resource
      server.

### changed:

- Scope name validation in the Terraform authserver config (`pdp_scopes` and
  `audience_scope_name`) now allows periods (`.`).
- Updated OpenTelemetry collector to version 0.153.0.
- The terraform config step now removes all RSA key providers from the
  `zeta-guard` realm.
  Only ECC keys (ES256 / P-256) remain in the JWKS endpoint
  (`/auth/realms/zeta-guard/protocol/openid-connect/certs`). RSA keys that
  Keycloak creates automatically on realm initialization (e.g.
  `rsa-enc-generated`) are deleted unconditionally as part of every Terraform
  run.
- Copy existing OpenTelemetry attributes to `client.address`,
  `http.request.method`, `http.response.status_code`, `user_agent.original` und
  `server.address`. This is a workaround to fulfill A_27725 required until PEP
  adheres to OpenTelemetry semantic conventions 1.41.
- some APIs of the authserver now conform with gemSpec_ZETA 1.3.0 better but
  break compatibility with the client SDK 1.0.x . This affects OCSP for SMC-Bs
  audiences and some expected token content among other things (See
  keycloak-zeta release notes for more info)

### removed:

- `authserver.provider.smcB.opa.enabled`, `…opa.failClosed`, and chart-root
  `opa.enabled` — OPA enforcement is now mandatory and always fail-closed.
  **Migration**: stale toggle values in override files are silently ignored
  after upgrade — OPA will start unconditionally and return
  `503 temporarily_unavailable` when unreachable. Remove the keys from values to
  avoid confusion.

### known issues:

- TLS termination directly at the authserver and PEP does not yet fully conform
  to the spec. Therefore, this feature is *NOT PRODUCTION READY* yet.
  Termination at the ingress controller works as specified and is production
  ready.
- The authserver returns incorrect HTTP status codes for some denied tokens
  (some even return 500). These cases have been investigated, and no negative
  security implications have been identified. Some fixes for these issues depend
  on upstream pull requests.
- Expired clients are not automatically deleted yet. Additionally, clients are
  not removed when the maximum client limit per Telematik ID is reached.
- Request processing by the authserver may be slow under load. Remediation
  appears to be possible with a more powerful database (more memory, CPU, and
  connections).
- OCSP during token exchange does not yet support revoked issuer CAs and does
  not enforce the same TSP for the OCSP signer and the certificate issuer.
- Token signature keys do not yet support automatic rotation.
- Some PEP response codes for denied requests do not match the specification.
- Impossible/no travel is detected (and denied), but sessions are not
  invalidated.
- Telemetry delivery to gematik has some limitations regarding the exact fields
  that are delivered. Delivery from the resource server is passed on correctly,
  however.
- Some security KPIs are missing.
- Caching, ETags, etc., do not work yet.
- Rate limiting can be configured and works. However, communication to the
  client via headers does not work yet.

## Release 1.0.1

### added:

- configuration for application level db encryption (only for VAU based
  applications)

### changed:

- When using ASL `pepproxy.nginxConf.locations` are now by default not public
  anymore (nginx directive `deny all;`). This makes misconfiguration harder. In
  case there are locations that should be reachable without using ASL, you will
  now need to add `satisfy all; allow all;` to that location for it to be
  reachable. Make sure this is permitted by your spec.
- session affinity is cookie-based now (zeta-route), instead of relying on
  x-forwarded-for header from downstream

### removed

- `zeta-guard.sessionAffinity`, it is always enabled now (NIC)

## Release 1.0.0

### added:

- Egress NetworkPolicies (`networkPolicy.enabled`, default: `false`). When
  enabled, each ZETA
  Guard pod gets a `NetworkPolicy` (egress-only) that restricts outbound traffic
  to explicitly configured IP blocks.
- hsmsim: Allow mounting certs from secret, remove persistent mode (unused)
- ingress: Add `zeta-guard.nginxIngressHsm`. If true (and
  `zeta-guard.nginxIngressEnabled`),
  don't define `tls` on master ingress. This allows to use the ossl_hsm provider
  (controller image `ngx_pep/nginx-ingress` contains it), and inject custom TLS
  configuration.
- Keycloak Admin REST API protection via a dedicated admin hostname
  (`authserver.adminHostname`). When set:
    - The NGINX PEP proxy blocks `GET /auth/admin/*` on the main hostname with
      `403 Forbidden`, without any ingress-controller-specific annotations.
      Works with F5 NIC, standard nginx-ingress, OpenShift Routes, GKE Ingress,
      and others.
    - A separate `zeta-guard-admin` (master) + `zeta-guard-admin-minion` Ingress
      pair is created for the admin hostname, routing `/auth` directly to the
      authserver (no PEP token required).
        - The `/auth` path entry is removed from the main-hostname minion
          ingress;
          `/auth` reaches the PEP proxy via the existing `/` catch-all.
        - Keycloak's `--hostname-admin` flag is set automatically, keeping the
          Admin
          Console reachable exclusively via the admin hostname.
- New Terraform variable `audience` (default `""`). When non-empty, overrides
  the audience value embedded in access tokens by the audience mapper. Required
  when
  `keycloak_url` points to a separate admin hostname (so the audience stays tied
  to the main public hostname, not the admin hostname).
- `zeta-guard.pepproxy.nginxConf.poppValidity` to configure PoPP validity (fixed
  duration since iat or "quarter" mode — valid within current quarter)
- New value `provisioningProcessor.provisioningContainerCaSecretRef` to provide
  the CA certificate of the provisioning container registry as a Kubernetes
  Secret reference (mounted as a file). This avoids the kernel `ARG_MAX` limit
  that can be hit when passing large certificate chains as environment
  variables.
- New value `provisioningProcessor.provisioningContainer` to configure a custom
  registry mirror for the provisioning data image.
- New Terraform variable `audience_scope_name` (default `"zero:audience"`) to
  allow renaming the audience scope for environments that use a different scope
  naming convention. Set in the stage tfvars file:
  ```hcl
  audience_scope_name = "custom:audience"
  ```
- Dedicated ServiceAccount (`automountServiceAccountToken: false`) for
  authserver, PEP-Proxy, infinispan-external, exauthsim, test-driver, and
  tiger-proxy
- PodDisruptionBudget (disabled by default) for authserver,
  infinispan-external, exauthsim, test-driver, and tiger-proxy
- Configurable pod and container security contexts for all workloads; defaults
  include `seccompProfile: RuntimeDefault` and least-privilege container
  settings
- Configurable resources for authserver keycloak-build init container
  (`authserver.initContainer.resources`)
- Configurable probe thresholds for authserver liveness, readiness, and startup
  probes (`authserver.probes`)
- Configurable CloudNativePG database connection (`cloudnativeDbUrl`,
  `cloudnativeDbSecretName`, `cloudnativeDbSchema`)
- Configurable container security context for HSM-Sim and authserver HSM
- HSM-backed JWT token signing (`authserver.hsm.tokenSigning.enabled/keyId`) —
  access, ID, and refresh tokens signed with ES256 via HSM
- Terraform automation for HSM KeyProvider registration and software signing key
  cleanup. New tfvars to enable and configure HSM-backed token signing
- HSM status displayed in Helm NOTES output (hsm, hsm-tls, hsm-token-sign)
- Values schema (`values.schema.json`) extended with reusable `$defs` for
  `K8sServiceAccount`, `K8sPodDisruptionBudget`, and `K8sPodSecurityContext`
- Rename value of audience claim used in generateIdToken renamed from
  `zeta-guard.gematik.clientId` to `zeta-guard.gematik.IdTokenAudience`
- The Authserver (Keycloak) will export its logs to telemetry-gateway
- PDP (OPA) will export its decision logs and status updates to
  telemetry-gateway
- OPA simulation will export its decision logs and status updates to
  telemetry-gateway
- PEP (nginx) will export its logs to telemetry-gateway

### changed:

- Authserver container resources moved from `authserver.resources` to
  `authserver.container.resources`
- Removed erroneous pod-level `resources` blocks in authserver and PEP-Proxy
  deployments (were rendered twice)
- Authserver KC_DB_URL in cloudnative mode is no longer hardcoded
- Infinispan-external: image and container security context are now configurable
  (previously hardcoded)
- Tiger-proxy nginx sidecar: image template aligned with popp-mocks (supports
  optional registry prefix), `imagePullPolicy` added
- opa image is now configurable in the same way as all the other images
- `main.tf` and `providers.tf` are now generated dynamically from templates
  and gitignored; the backend block and Kubernetes provider are selected based
  on `use_kubernetes`. When `use_kubernetes = false`, neither the
  `hashicorp/kubernetes` required provider nor the `provider "kubernetes"`
  block are emitted, so Terraform no longer requires the Kubernetes provider
  in local/non-cluster mode.
- Updated OpenTelemetry collector to version 0.151.0.
- Authserver (Keycloak) will export traces as intended
- PDP (OPA) will export traces regardless of policy source
- Ingress TLS hardened to ECDSA-only: cert-manager now issues ECDSA P-256
  certificates for the master ingress (`cert-manager.io/private-key-algorithm:
  ECDSA`, `private-key-size: 256`); RSA cipher suites removed from
  `ssl-ciphers` and `@SECLEVEL=3` enforced; `brainpoolP512r1` added to
  `ssl-ecdh-curve`
- New value `nginx-ingress.controller.pod.annotations.config-rev` to force a
  NIC pod restart on TLS/HSM config changes (see
  `docs/how-to_guides/How_to_configure_Ingress.md`).

## Release 0.5.3

### changed:

- authserver 0.5.1
- hsm_sim 0.5.0

## Release 0.5.2

### added:

- authserver hsm support (TLS)
- upgrade cert-manager v1.20.1
- hsm_sim 0.5.0 disabled by default

## Release 0.5.1

### added:

- pep hsm support (TLS)

## Release 0.5.0

### added:

- Description and examples for more or less all values in
  `charts/zeta-guard/values.schema.json`
- Support configuration of OCSP stapling for ASL
- Option to enable or disable no-travel enforcement
- Option to deploy hsm proxy simulator for the test setup
- Provisioning Processor (run in sidecars) that downloads the provisioning
  container from gematik and derives the trust anchors from it.
- Terraform configuration now supports Kubernetes and local operating modes. Set
  `use_kubernetes = true` (default) to store state in a K8s Secret and fetch
  credentials from the cluster, or `use_kubernetes = false` to use a local state
  file and explicit credentials.
  See [How to configure authserver](docs/how-to_guides/How_to_configure_authserver.md).
- Terraform variable validations for `keycloak_namespace`, `keycloak_url`,
  `pdp_scopes`, and a cross-variable check that credentials are provided in
  local mode

### changed:

- Replaced OpenShift Route (`openshiftRoute`) with Ingress-based TLS support (
  `openshiftIngress`). The custom `openshift-route.yaml` template has been
  removed. Migrate from `openshiftRoute.enabled` / `openshiftRoute.host` /
  `openshiftRoute.issuer` to `openshiftIngress.enabled` +
  `openshiftIngress.certName`. This works with OpenShift's Ingress-to-Route
  controller and creates edge-terminated routes with TLS redirect.
- Testdriver ingress is now configurable: added `ingressEnabled`,
  `nginxIngressEnabled`, and `openshiftIngress` toggles to the testdriver
  subchart.
- Fixed configuration of telemetry-collector in `local-test/values.local.yaml`.
- Fixed erroneous TLS configuration for telemetry-gateway.
- You can now provide your own secrets to the zeta-guard sub chart instead of
  having them created.
- Make it optional for the chart to deploy secrets. It's now possible to
  reference existing secrets.
- `managePolicies.sh` now uses the Keycloak REST API (`curl`+`jq`) instead of
  `kubectl exec` + `kcadm.sh` into the Keycloak pod. No Java or Keycloak CLI
  installation required.
- `main.tf` is now generated dynamically from templates and gitignored; the
  backend block is selected based on `use_kubernetes`
- Keycloak admin username and password are resolved dynamically in both the
  Terraform provider and the policy management script
- `keycloak_password` and `keycloak_username` are now both marked `sensitive` in
  Terraform variables
- Keycloak provider version constraint updated to `>= 5.7.0`
- Updated OpenTelemetry collector to version 0.149.0.

## Release 0.4.1

### added:

- Configurable authserver DB connection pool and HTTP thread pool
- Configurable resource limits and requests

### changed:

- Updated OPA and NGINX-Ingress

### removed:

- Removed log-collector component

## Release 0.4.0

### added:

- Support for container image digests in compound `image` values
- Support for custom affinities, labels, pod annotations, and tolerances
- Support for individual security context per pod
- Support for OpenShift compatibility
- OPA simulation support
- Enabled telemetry delivery to gematik by default
- Configurable replica counts
- PEP sticky sessions for multi-replica deployments
- Support for external Infinispan

### changed:

- `GENESIS_HASH` and `SMCB_HASHING_PEPPER` are now provided exclusively via
  Kubernetes Secrets and are no longer configured directly in the template file.
  These values must be present in the respective values.yaml during the initial
  deployment; for upgrades, existing Secrets are retained.
- For external database configurations, both the Keycloak database username and
  password are now expected as keys within the same Kubernetes Secret (
  `authserverDb.kcDbSecretName`).
- Charts have been tested with RedHats local OpenShift testplatform, CodeReady
  Containers (CRC) with standard pod security `restricted-v2`.
- It is now possible to set the `securityContext` on a per-pod basis via Helm
  values.
- Support for lists of image pull secrets and aligned values with Kubernetes
  syntax
- Database modes: only `cloudnative` (CloudNativePG) and `external` are
  supported. Use a single cluster-wide CloudNativePG operator.
- `opa.image` is now a string value instead of a compound value.
- Container images of CronJobs and nginx-prometheus-exporter are now
  configurable.
- Aligned values for image pull policies with Kubernetes syntax.
- Updated OpenTelemetry collector to version 0.147.0.
- Updated OpenPolicyAgent to version 1.14.0-static.
- **BREAKING CHANGE** Pod selectors now use Kubernetes' well-known labels
- Configurable smc-b keystore
- The chart's Ingresses have become optional, and you can configure their
  annotations.
- `nginx-ingress.enabled` has been replaced by `nginxIngressEnabled`.
- k8sattributes processor deactivated for log-collector and telemetry-gateway
- Restricted log collection to OPA pods and containers.

### removed:

- Support for Bitnami PostgreSQL subchart removed.
- Support for Zalando Postgres Operator removed (`databaseMode: operator` no
  longer available).
- Unused value `global.registry`
- Labels containing container image tags

## Release 0.3.2

### changed

- authserver-version

## Release 0.3.1

### added

- websocket support

## Release 0.3.0

### added:

- added support for postgres operator by documentation and makefile; also in
  local test setup
- telemetry-gateway can redact known kinds of secrets and personal information
  from logs, metrics, and traces
- Mergeable Ingress (F5 NIC: master + minions)

### changed:

- Helm 4 required; Kubernetes >= 1.25;
- TLS defaults hardened (protocols, ciphers, HSTS)
- **BREAKING CHANGE**. We changed the ingress to F5 nginx-ingress NIC
  mergeable (master + minions).
  If you were using the original community ingress-nginx from the ZETA umbrella
  chart,
  delete the cluster-scoped IngressClass and ValidatingWebhookConfiguration, and
  remove the
  associated Deployment/Services/Lease in your target namespace before deploying
  the new
  version. For example (replace NAMESPACE and STAGE):
  ```shell
  # cluster-scoped admission webhook (community ingress-nginx)
  kubectl delete validatingwebhookconfiguration zeta-testenv-STAGE-ingress-nginx-admission --ignore-not-found

  # namespaced community controller objects
  kubectl -n NAMESPACE delete deploy zeta-testenv-STAGE-ingress-nginx-controller --ignore-not-found
  kubectl -n NAMESPACE delete svc zeta-testenv-STAGE-ingress-nginx-controller --ignore-not-found
  kubectl -n NAMESPACE delete svc zeta-testenv-STAGE-ingress-nginx-controller-admission --ignore-not-found
  kubectl -n NAMESPACE delete lease zeta-testenv-STAGE-ingress-nginx-leader --ignore-not-found

  # cluster-scoped IngressClass used by the old controller
  kubectl delete ingressclass nginx-STAGE --ignore-not-found
  ```
  If Helm fails with lease ownership/validation errors during upgrade:
    - Adopt the existing Lease into the release:
      ```shell
      kubectl -n NAMESPACE annotate lease zeta-testenv-STAGE-nginx-ingress-leader-election meta.helm.sh/release-name=zeta-testenv-STAGE --overwrite
      kubectl -n NAMESPACE annotate lease zeta-testenv-STAGE-nginx-ingress-leader-election meta.helm.sh/release-namespace=NAMESPACE --overwrite
      kubectl -n NAMESPACE label lease zeta-testenv-STAGE-nginx-ingress-leader-election app.kubernetes.io/managed-by=Helm --overwrite
      ```
    - Or delete the Lease and redeploy:
      ```shell
      kubectl -n NAMESPACE delete lease zeta-testenv-STAGE-nginx-ingress-leader-election
      ```

  Notes:
    - Stray community ingress-nginx ValidatingWebhookConfigurations from other
      environments can block Ingress
      applies cluster-wide if their admission Service has no endpoints. Remove
      unused
      `*-ingress-nginx-admission` webhooks (or temporarily set
      `failurePolicy: Ignore`) before deploying.
    - hardened security context for all components

## Release 0.2.8

### changed:

- authserver and testdriver/exauthsim now have separate keystores/truststores.
  This chart now includes an RU based truststore for the authserver. For the
  testdriver/exauthsim you still need to bring your own cert&key.
- The values for the SMCB keystore have changed slightly. Now they are
  `smcb_keystore.keystore` and `smcb_keystore.password` with the same semantics.
  No changes are needed when using the makefile for the test setup.

## Release 0.2.7

### added:

- ability to configure external DBs. See helm values authserverDb.* in
  zeta-guard subchart
- improvements for better compliance with some kubernetes security policies

### changed:

- Makefile: streamlined stage/namespace/values selection; safer templating;
  clearer help
- Enforce admin-password of Authserver on initial deployment

## Release 0.2.6

### added:

- config for ASL test mode
- improved Betriebsdatenlieferung

### changed:

- updated versions of several subcomponents

## Release 0.2.5

### changed:

- fix missing opa service account
- fix popp token config

## Release 0.2.4

### added:

- missing file(s) for local deployments

### changed:

- minor doc improvements
- updated individual components to their newes versions
- functional userdata and clientdata headers (beware clientdata schema is still
  subject to change)

## Release 0.2.0

### added:

- bundling functionality of milestone 2 incl client registration, smcb token
  exchange
- public release of test setup

## Release 0.1.3

### added:

- Helm chart for the prototype of ZETA Guard added
