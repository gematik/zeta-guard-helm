<img align="right" width="250" height="47" src="docs/img/Gematik_Logo_Flag.png"/> <br/>

# Release Notes ZETA Guard Helm Charts

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
- PDP (OPA) will export its decision logs and status updates to telemetry-gateway
- OPA simulation will export its decision logs and status updates to telemetry-gateway
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
