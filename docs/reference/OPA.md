# OPA in ZETA Guard

This reference summarizes what’s deployed, how OPA is configured, and how to use
it in the current showcase (auth-time consult by Keycloak, scope enforcement by
PEP).

## Overview

- Pattern: Keycloak consults OPA at authentication/token issuance.
- Decision: Allow if the requested scope for a given `client_id` is allowed by
  policy; else deny.

## What’s Deployed

- `Deployment/Service`: `opa` listening on `8181` (HTTP API).
- Config resources:
    - Bundle disabled: `ConfigMap/opa-policy` with `authz.rego` rendered from `policyRego`.
    - Bundle enabled: `Secret|ConfigMap/opa-config` with `opa.yaml` pointing OPA at a remote OCI bundle. Secret is used when credentials are present.
- Container args:
    - `opa run --server --addr=0.0.0.0:8181 [--config-file=/config/opa.yaml] [/policies/authz.rego]`
- Mounts:
    - Inline mode: `/policies/authz.rego` (policy)
    - Bundle mode: `/config/opa.yaml`
- Rollout trigger: `CHECKSUM_OPA` env var changes when policy/data/logging
  change, forcing a Deployment rollout.

## Values (Inline Policy Mode)

- `zeta-guard.opaPolicy.policyRego` (required): Rego v1 policy text. Example:
  ```rego
  package zeta.authz
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
         package zeta.authz
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
- Data present:
  ```bash
  curl -sS http://localhost:8181/v1/data/zeta/allowed_scopes | jq .
  ```
- Decision (expected true):
  ```bash
  curl -sS -H 'Content-Type: application/json' \
    -d '{"input":{"client_id":"zeta-client","requested_scopes":["zeta"]}}' \
    http://localhost:8181/v1/data/zeta/authz/allow
  ```

## Endpoints

- Policy decision: `POST /v1/data/zeta/authz/allow` with JSON body
  `{ "input": { ... } }`.
- Request/response contract: see `docs/explanations/Keycloak_OPA_Contract.md`.

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
```

Credentials via Secret (per namespace):
```bash
kubectl -n zeta-<env> create secret generic opa-bearer \
  --from-literal=token='USERNAME:PASSWORD' \
  --from-literal=scheme='Basic'
```

Notes
- Helm looks up the Secret during render and injects the token into `opa.yaml`; CI no longer passes tokens.
- When credentials are present, `opa-config` is rendered as a Secret to avoid exposing tokens in plain text.
- If the Secret is missing or empty, OPA will try anonymous pulls and likely fail with 401/403. There is no automatic fallback; set `zeta-guard.opa.bundle.enabled=false` to use inline policy.
- The status plugin may log 404/502 when pointed at a registry; this is benign. To silence, set `opaStatusPrometheus: false`.

---

## WIF Mode (AKS → GCP STS → GAR)

Goal: pull OPA bundles from Google Artifact Registry without static tokens, using AKS Workload Identity Federation to obtain short‑lived GCP access tokens.

Values (example):
```yaml
zeta-guard:
  opa:
    serviceAccountName: opa
    bundle:
      enabled: true
      serviceName: gar
      url: https://europe-west3-docker.pkg.dev
      resource: "<PROJECT_ID>/opa-bundles/zeta-authz:latest"
    workloadIdentityFederation:
      enabled: true
      sts:
        audience: "//iam.googleapis.com/projects/<PROJECT_NUM>/locations/global/workloadIdentityPools/aks-pool/providers/aks-provider"
        tokenUrl: https://sts.googleapis.com/v1/token
      gar:
        host: europe-west3-docker.pkg.dev
```

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
- Schema guards:
  - If `verification.enabled=true`, then `keyId` and `publicKey` are required.
  - If `bundle.enabled=true`, then `serviceName` and `resource` are required (non-empty).
  - If `workloadIdentityFederation.enabled=true`, `bundle.credentials.secretRef.name` must not be set (mutually exclusive with WIF).
- Environment strategy:
  - Non-jza envs typically disable verification via values overlay: `verification.enabled: false`.
  - jza enables verification (WIF + GAR) and provides `keyId`, `algorithm`, and `publicKey`.
