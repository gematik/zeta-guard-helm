# OPA in ZETA Guard

This reference summarizes what’s deployed, how OPA is configured, and how to use
it in the current showcase (auth-time consult by Keycloak, scope enforcement by
PEP).

## Overview

- Pattern: Keycloak consults OPA at authentication/token issuance.
- Decision: Allow if the requested scope for a given `client_id` is allowed by
  policy; else deny.

## What’s Deployed

- `Deployment/Service`: `opa` (active) and `opa-simulation` (simulation), both on `8181` (HTTP API, ClusterIP/internal-only).
- Simulation is enabled by default (`zeta-guard.opa.simulation.enabled: true`).
- Config resources:
    - Bundle disabled: `ConfigMap/opa-policy` with `authz.rego` rendered from `policyRego`.
    - Bundle enabled:
      - Active: `Secret|ConfigMap/opa-config`
      - Simulation: `Secret|ConfigMap/opa-simulation-config`
      Both point OPA at remote bundles; Secret is used when credentials are present.
- Container args:
    - `opa run --server --addr=0.0.0.0:8181 [--config-file=/config/opa.yaml] [/policies/authz.rego]`
- Mounts:
    - Inline mode: `/policies/authz.rego` (policy)
    - Bundle mode: `/config/opa.yaml`
- Rollout trigger: `CHECKSUM_OPA` env var changes when policy/data/logging
  change, forcing a Deployment rollout.
- Active bundle path: `zeta-guard.opa.bundle.resource` (typically `.../latest`).
- Simulation bundle path: derived automatically from active (`.../latest` -> `.../latest-sim`).

## Simulation Settings

- `zeta-guard.opa.simulation.enabled` (bool, default: `true`):
  deploys `opa-simulation` Deployment/Service.
- `zeta-guard.opa.simulation.replicaCount` (int, default: `1`):
  replica count for simulation Deployment.
- `zeta-guard.opa.simulation.bundle.resource` (string, optional):
  explicit simulation bundle resource. If empty, chart derives from active
  `opa.bundle.resource` by appending `-sim`.
- `opa-simulation-config` is rendered only when simulation is enabled and
  either bundle mode or decision logging requires `opa.yaml`.

## Values (Inline Policy Mode)

- `zeta-guard.opaPolicy.policyRego` (required): Rego v1 policy text. Example:
  ```rego
  package policies.zeta.authz
  default allow := false
  allow if {
    allowed := data.zeta.allowed_scopes[input.client_id]
    allowed != null
    input.requested_scopes[_] in allowed
  }
  ```
- `zeta-guard.opaPolicy.allowedScopesMap` (map): client_id → list of scopes.
  Example:
  ```yaml
  zeta-guard:
    opaPolicy:
      allowedScopesMap:
        zeta-client: [zeta]
  ```
- `zeta-guard.opaPolicy.logDecisions` (bool): enable console decision logs.

## Enable + Deploy (Inline Example)

1) Add to environment values:
   ```yaml
   zeta-guard:
     opaPolicy:
       allowedScopesMap:
         zeta-client: [zeta]
       policyRego: |
         package policies.zeta.authz
         default allow := false
         allow if {
           allowed := data.zeta.allowed_scopes[input.client_id]
           allowed != null
           input.requested_scopes[_] in allowed
         }
       logDecisions: true
   ```
2) Deploy: `make deploy stage=<env>` (or `helm upgrade --install ...`).

## Verify

- Port-forward: `kubectl -n <ns> port-forward svc/opa 8181:8181`
- Port-forward simulation: `kubectl -n <ns> port-forward svc/opa-simulation 8182:8181`
- Update the payload for different instances (opa-active vs. opa-simulation):
  ```bash
  PAYLOAD='{"input":{"authorization_request":{"scopes":["test_scope_read"],"audience":["https://example.com/testresource"],"grant_type":"urn:ietf:params:oauth:grant-type:token-exchange","ip_address":"172.18.0.4"},"user_info":{"professionOID":"1.2.276.0.76.4.50"},"client_assertion":{"posture":{"product_id":"ZETA-Test-Client","product_version":"1.0.0"}}}}'
  curl -sS --json "$PAYLOAD" http://localhost:8181/v1/data/policies/zeta/authz/decision
  curl -sS --json "$PAYLOAD" http://localhost:8182/v1/data/policies/zeta/authz/decision
  ```

## Endpoints

- Policy decision: `POST /v1/data/policies/zeta/authz/decision` with JSON body
  `{ "input": { ... } }`.

## Troubleshooting

- Data undefined in policy:
    - `GET /v1/data/zeta/allowed_scopes` returns only `{decision_id: ...}` →
      data not loaded. Check mounts/args and those values are under
      `zeta-guard`.
- Parser error "if keyword is required":
    - Ensure Rego v1 syntax (`default allow := false`, `allow if { ... }`) in
      `policyRego`.
- Duplicate default rules:
    - Use explicit file mounts/args (already configured). Avoid mounting
      directories that include `..data` symlinks.
- Rollouts:
    - Changes to policy/data/logging via Helm trigger a rollout (checksum env
      var). Manual ConfigMap edits require `kubectl rollout restart deploy/opa`.

---

## Bundle Mode (OCI registry)

Use a remote OPA bundle as the policy source.

Values (example):
```yaml
zeta-guard:
  opa:
    bundle:
      enabled: true
      serviceName: gitlab
      url: https://registry.example.com:443
      resource: registry.example.com/group/project/pip-pap:0.0.1
      credentials:
        secretRef:
          name: opa-bearer
    logLevel: info
    simulation:
      enabled: true
      replicaCount: 1
      bundle:
        # optional; when empty, active resource + "-sim" is used
        resource: ""
```

Credentials via Secret (per namespace):
```bash
kubectl -n zeta-<env> create secret generic opa-bearer \
  --from-literal=token='USERNAME:PASSWORD' \
  --from-literal=scheme='Basic'
```

Notes
- Helm looks up the Secret during render and injects the token into `opa.yaml`; CI no longer passes tokens.
- When credentials are present, `opa-config` and `opa-simulation-config` are rendered as Secrets to avoid exposing tokens in plain text.
- Bundle polling defaults: `min_delay_seconds: 60`, `max_delay_seconds: 60`.
- If the Secret is missing or empty, OPA will try anonymous pulls and likely fail with 401/403. There is no automatic fallback; set `zeta-guard.opa.bundle.enabled=false` to use inline policy.
- The status plugin may log 404/502 when pointed at a registry; this is benign. To silence, set `opaStatusPrometheus: false`.

### CA certificate for a private registry

If the registry's TLS certificate is issued by a CA that is not publicly
trusted, OPA fails the pull with
`x509: certificate signed by unknown authority`. Provide the CA via
`zeta-guard.provisioningProcessor.provisioningContainerCaSecretRef` (or
`...CaConfigMapRef`) — the same reference already used for the provisioning data
image. The chart mounts it into the `opa` and `opa-simulation` containers at
`/var/registry-ca/ca.crt` and renders:

```yaml
services:
  <serviceName>:
    tls:
      ca_cert: "/var/registry-ca/ca.crt"
      system_ca_required: true
```

`system_ca_required: true` appends the CA to the image's system trust store, so
enabling it cannot break a publicly trusted registry. Details and the
Secret/ConfigMap
variants: [How to Use a Custom OCI Registry](../how-to_guides/How_to_use_a_custom_OCI_registry.md).

### Bundle download failures

By default, OPA stays `Running` and reports Ready even when no bundle could be
downloaded or activated. Nothing in the pod status reflects it — the only
signals
are the `Bundle load failed` console log line, OPA's status updates (which carry
the bundle status but go only to the telemetry gateway unless
`opa.logStatusUpdates: true`), and the status metrics when `opaStatusPrometheus`
is enabled.
Set `zeta-guard.opa.bundleHealthCheck: true` to switch the readiness probe to
`/health?bundles=true`, so the pod becomes `NotReady` until a bundle is active.
The liveness probe stays on `/health` (a registry outage must not CrashLoop the
pod).

Off by default, because the protection is not free. During a rolling update the
previous pod keeps serving and the rollout simply stalls — a broken bundle
configuration cannot replace a working OPA. A *freshly scheduled* pod, however
(node drain, restart, scale-up), stays `NotReady` for as long as the registry is
unreachable, and at `replicaCount: 1` that takes OPA out of service. Since the
gate is fail-closed either way (next section), the choice is between a visible
outage and a silent one.

Note that OPA answers `/health?bundles=true` with **500** `one or more bundles 
are not activated`.

### Missing policy is fail-closed

A missing bundle never results in tokens being issued, with or without
`bundleHealthCheck`. A query against a package that was never loaded returns
HTTP 200 with no `result` field; the authserver maps that — and an unreachable
OPA - to `temporarily_unavailable` / HTTP 503, so the token exchange is refused.
See `OpaDecisionClient.parseDecision` and `OpaGateEnforcer.mapDecisionToOutcome`
in the `smc-b-token-exchange` plugin. `bundleHealthCheck` therefore does not
change security behavior; it only makes an already-failing state visible in
`kubectl get pods` instead of only in the OPA log.

---

## Rollout Restart

Goal: periodically restart the `opa` (and, if enabled, `opa-simulation`)
Deployment via `kubectl rollout restart`, without requiring a helm upgrade.
Disabled by default.

Values (example):
```yaml
zeta-guard:
  opa:
    rolloutRestart:
      enabled: true
      schedule: "0 3 * * *"   # default: daily at 3am, Europe/Berlin
```

How it works
- A CronJob (`opa-rollout-restart-cronjob`) runs `kubectl rollout restart
  deployment/opa`, and additionally `deployment/opa-simulation` when
  `opa.simulation.enabled` is `true` (the default) — both are treated 1:1,
  since `opa-simulation` is what gematik uses to test policies before they go
  into `opa`.
- The schedule's timezone is fixed to `Europe/Berlin` (`spec.timeZone` on the
  CronJob), independent of the cluster's default timezone.
- The container reuses `provisioningProcessor.image` (which includes
  `kubectl`) and `provisioningProcessor.containerSecurityContext`, instead of
  a separate, generic CI tooling image.

Notes
- By default the chart creates its own ServiceAccount and minimal RBAC
  (`get`/`patch`, scoped to the `opa`/`opa-simulation` Deployments only —
  see `opa-rollout-restart-serviceaccount.yaml` and
  `opa-rollout-restart-rbac.yaml`). Set
  `opa.rolloutRestart.serviceAccountName` to use an externally
  pre-provisioned ServiceAccount instead; the chart then creates no RBAC of
  its own and expects that ServiceAccount to already have equivalent
  `get`/`patch` rights.
- Trigger a run manually instead of waiting for the schedule:
  ```bash
  kubectl -n <ns> create job --from=cronjob/opa-rollout-restart-cronjob opa-rollout-restart-test
  ```

---

## WIF Mode (AKS → GCP STS → GAR)

Goal: pull OPA bundles from Google Artifact Registry without static tokens, using AKS Workload Identity Federation to obtain short‑lived GCP access tokens.

Values (example):
```yaml
zeta-guard:
  gematik:
    workloadIdentityFederation:
      projectNumber: "<PROJECT_NUM>"
      poolId: "aks-pool"
      workloadIdentityProvider: "aks-provider"
  opa:
    serviceAccountName: opa
    bundle:
      enabled: true
      serviceName: gar
      url: https://europe-west3-docker.pkg.dev
      resource: "europe-west3-docker.pkg.dev/<PROJECT_ID>/opa-bundles/zeta-authz:latest"
    workloadIdentityFederation:
      enabled: true
      sts:
        sa: "<gsa>@<project>.iam.gserviceaccount.com"
```

The STS/IAM endpoints and the `cloud-platform` scope are fixed in the
token-renewer CronJob; the STS audience is derived from
`gematik.workloadIdentityFederation.*`.

How it works
- A CronJob uses the projected KSA token (audience from the WIF provider) and exchanges it at GCP STS for a short‑lived access token, then impersonates a GSA to obtain a GAR‑compatible access token.
- The Job patches the Secret `opa-gcp-token` (base64 token in `.data.token`) with the exact plaintext form `oauth2accesstoken:<ACCESS_TOKEN>`.
- OPA reads the token via `credentials.bearer.scheme: "Basic"` with `token_path: /var/run/secrets/gcp/token` and authenticates to GAR; no static tokens in values/CI.

Notes
- Keep using the existing SecretRef flow for local/dev (set `opa.workloadIdentityFederation.enabled=false` and provide `credentials.secretRef.name`).
- Ensure the STS provider on GCP trusts your AKS OIDC issuer and the GSA has `roles/artifactregistry.reader`.
- The mounted token file must begin with `oauth2accesstoken:` to satisfy GAR Basic auth expectations.

---

## Signature Verification

- Default: bundle signature verification is enabled in chart values (`zeta-guard.opa.bundle.verification.enabled: true`).
- When enabled, OPA verifies bundle signatures; configure:
  - `zeta-guard.opa.bundle.verification.keyId`
  - `zeta-guard.opa.bundle.verification.algorithm` (e.g., `ES256`)
  - `zeta-guard.opa.bundle.verification.publicKey` (PEM)
- `zeta-guard.opa.bundle.verification.scope` (string, optional): when set, OPA enforces that the bundle signature was created with this scope value. Must match the scope embedded in the bundle's `.signatures.json`. Leave empty (default) if the bundle was signed without a scope — omitting it skips scope validation entirely.
- Schema guards:
  - If `verification.enabled=true`, then `keyId` and `publicKey` are required.
  - If `bundle.enabled=true`, then `serviceName` and `resource` are required (non-empty).
  - If `workloadIdentityFederation.enabled=true`, `bundle.credentials.secretRef.name` must not be set (mutually exclusive with WIF).
- Environment strategy:
  - enable verification (WIF + GAR) and provide `keyId`, `algorithm` and `publicKey`.
