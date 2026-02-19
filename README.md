<img align="right" width="250" height="47" src="docs/img/Gematik_Logo_Flag.png"/> <br/>

# ZETA Guard Helm Charts

Compact umbrella chart to deploy ZETA Guard (Keycloak + PEP) and simple test apps. The zeta-guard chart bundles the F5 NGINX Ingress Controller (NIC) by default.
TLS via Let’s Encrypt is supported (requires cert-manager installed cluster-wide).

Of particular interest is the _zeta-guard_ chart at `charts/zeta-guard`

## What’s Included
- Umbrella chart: `zeta-testenv` with subcharts:
  - `charts/zeta-guard` (Keycloak + nginx PEP + OPA + DB)
  - `charts/test-monitoring-service`,
  - `charts/testfachdienst`,
  - `charts/exauthsim`,
  - `charts/test-driver`
  - `charts/tiger-testsuite` (Tiger based regression service + Workflow UI)

## Notes
- Re-run `make deps` after changing `Chart.yaml` or any `charts/*/Chart.yaml`.
- Commit `Chart.lock` so CI stays in sync with local dependency resolution.
- The Zalando Postgres Operator is intentionally NOT a chart dependency here; install it once per cluster with Terraform.

## Installing zeta-guard

> **Warning – insecure components**
> Tiger Testsuite, Tiger Proxy, ExAuthSim and TestFachdienst may contain critical security flaws. Do **not** run them in
> production or any security-sensitive environment. Remove the chart or keep the chart disabled unless you are testing
> in an isolated sandbox:
>
> ```
> tags:
>   testfachdienst: false
>   exauthsim: false
>   tiger-proxy: false
>   tiger-testsuite: false
> ```

### Prerequisites

Acquire a suitable SMCB keystore, then define `SMB_KEYSTORE_FILE_B64` and `SMB_KEYSTORE_PW_FILE` in your environment.

This can be done by (single-line) base64-encoding the PKCS#12 keystore to `.smb_keystore` and the password (as
plain-text, single-line) to `.smb_keystore_pw`. Then installing the `.envrc.local.tpl` and allowing direnv for this directory:

```shell
printf "password: " && read -rs pw && printf "\n" && printf "%s" "$pw" > .smb_keystore_pw
base64 -w0 ../path/to/smcb-certificates.p12 > .smb_keystore # or
# or base64 -w0 -i ../path/to/smcb-certificates.p12 -o .smb_keystore

cp .envrc.local.tpl .envrc.local
direnv allow
```

NOTE: `.envrc.local`, `.smb_keystore` and `.smb_keystore_pw` are in `.gitignore` and
`.helmignore`, do not commit these files.

### Using the zeta-guard helm chart

You can deploy the zeta-guard helm chart directly from this source or via the published chart. Deployment from source is described here.

You will need a values file to configure your zeta-guard installation, e.g. `values-myguard.yaml`. This chart includes a demo file `values-demo.yaml` in the zeta-guard chart that you could use.

Given that kubectl is using the correct context, you can install the helm chart via

```shell
    cd charts/zeta-guard
    helm upgrade --install zeta-guard . -f values-demo.yaml --rollback-on-failure
```

### During development

#### Registry & Tag

During development,
you may want to change the registry from which images are pulled and the tag that is used.
You can do that via a values file as follows

```yaml
global:
  # generally use the following registry
  registry: my-registry.example.org:443/zeta/zeta-guard

zeta-guard:
  authserver:
    image:
      # you could also change the registry for just this image
      # registry: my.private.registry.example.org:443/something
      # use 0.1.2 tag for PDP
      tag: 0.1.2
  pepproxy:
    image:
      # you could also change the registry for just this image
      # registry: my.private.registry.example.org:443/something
      # use 0.1.3-canary tag for PEP
      tag: 0.1.3-canary
```

#### Image pull secret

During development, you may pull images from a private registry.
You can create an appropriate image pull secret in your cluster as follows

```shell
kubectl create secret docker-registry my-image-pull-secret-name \
    -n NAMESPACE \
    --docker-server=your.registry.example.org:443 \
    --docker-username=<USERNAME> \
    --docker-password=<ACCESS_TOKEN> \
    --docker-email=<EMAIL> 
```

After creating the image pull secret, you can use it in the helm chart via the following values file:

```yaml
global:
  # use this image pull secret
  image_pull_secret: my-image-pull-secret-name
```

#### OPA bundle credentials (registry access)

When OPA pulls a policy bundle from a private OCI registry, provide credentials via a namespaced Secret that Helm looks up during render. Do not pass tokens via values/CI.

1) Create the Secret once per environment/namespace (token is raw `USERNAME:PAT`, not base64):

```shell
kubectl -n zeta-<env> create secret generic opa-bearer \
  --from-literal=token='USERNAME:PASSWORD' \
  --from-literal=scheme='Basic'
```

2) Configure values to enable bundle mode and reference the Secret:

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
```

Notes:
- Helm renders `opa-config` as a Secret when credentials are present and mounts it at `/config/opa.yaml`.
- If the Secret is missing, OPA will attempt anonymous pulls and likely fail; set `zeta-guard.opa.bundle.enabled=false` to use inline policy instead.
- Status plugin errors (404/502) against registries are benign and can be ignored, or disable by setting `opaStatusPrometheus: false`.

#### Workload Identity Federation (AKS → GCP) without static tokens

Use Workload Identity Federation with a CronJob that refreshes a short‑lived GCP Access Token into a Secret OPA reads via `Bearer` token_path.

Values overlay example (layer on top of your env values):

```yaml
zeta-guard:
  opa:
    serviceAccountName: opa
    bundle:
      enabled: true
      serviceName: gematik-pt-zeta-test
      url: https://europe-west3-docker.pkg.dev
      resource: gematik-pt-zeta-test/zeta-policies/pip-policy-example:latest
      credentials:
        secretRef:
          name: ""  # disable Basic auth in workload identity federation mode
    workloadIdentityFederation:
      enabled: true
      sts:
        audience: "//iam.googleapis.com/projects/<PROJECT_NUM>/locations/global/workloadIdentityPools/<pool>/providers/<provider>"
      tokenRenewer:
        enabled: true
        schedule: "*/45 * * * *"
```

Render checks:
- `helm template ... --show-only charts/zeta-guard/templates/opa-policy-configmap.yaml` → `scheme: "Bearer"`, `token_path: "/var/run/secrets/gcp/token"`
- `helm template ... --show-only charts/zeta-guard/templates/opa-deployment.yaml` → Secret mount at `/var/run/secrets/gcp`
- CronJob/RBAC/SA rendered for token renewer

## Troubleshooting
- Check resources: `kubectl -n <ns> get pod,svc,ingress`
- DNS/IP mismatch: `nslookup <dns-label>` must match `kubectl -n <ns> get svc -l app.kubernetes.io/name=ingress-nginx -o wide` EXTERNAL-IP (bundled NIC uses this label).
- Ingress issue: confirm `ingressClassName` in Ingress matches the controller’s `ingressClass`.
- OPA: Health check via port-forward `kubectl -n <ns> port-forward svc/opa 8181:8181`

## Additional documentation

* Explanations
    * [Postgres Operator](docs/explanations/Postgres_operator.md)
* How-to guides
    * [How to configure ZETA Guard Authserver](docs/how-to_guides/How_to_configure_authserver.md)
    * [How to create a docker-registry type secret for accessing the GitLab container registry](docs/how-to_guides/How_to_create_a_docker_registry_secret.md)
    * [How to deploy ZETA Guard](docs/how-to_guides/How_to_deploy_ZETA_Guard.md)
    * [How to install cert-manager](docs/how-to_guides/How_to_install_cert-manager.md)
    * [How to manage authserver DB](docs/how-to_guides/How_to_manage_authserver_DB.md)
    * [How to set up TLS](docs/how-to_guides/How_to_set_up_TLS.md)
    * [How to trigger the Tiger testsuite inside the cluster](docs/how-to_guides/How_to_run_tiger_testsuite.md)
* Reference
* [How to configure Ingress](docs/how-to_guides/How_to_configure_Ingress.md)
    * [Makefile reference](docs/reference/Makefile_reference.md)

## License

(C) tech@Spree GmbH, 2026, licensed for gematik GmbH

Apache License, Version 2.0

See the [LICENSE](./LICENSE) for the specific language governing permissions and limitations under the License

## Additional Notes and Disclaimer from gematik GmbH

1. Copyright notice: Each published work result is accompanied by an explicit statement of the license conditions for use. These are regularly typical conditions in connection with open source or free software. Programs described/provided/linked here are free software, unless otherwise stated.
2. Permission notice: Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
    1. The copyright notice (Item 1) and the permission notice (Item 2) shall be included in all copies or substantial portions of the Software.
    2. The software is provided "as is" without warranty of any kind, either express or implied, including, but not limited to, the warranties of fitness for a particular purpose, merchantability, and/or non-infringement. The authors or copyright holders shall not be liable in any manner whatsoever for any damages or other claims arising from, out of or in connection with the software or the use or other dealings with the software, whether in an action of contract, tort, or otherwise.
    3. We take open source license compliance very seriously. We are always striving to achieve compliance at all times and to improve our processes. If you find any issues or have any suggestions or comments, or if you see any other ways in which we can improve, please reach out to: ospo@gematik.de
3. Please note: Parts of this code may have been generated using AI-supported technology. Please take this into account, especially when troubleshooting, for security analyses and possible adjustments.
