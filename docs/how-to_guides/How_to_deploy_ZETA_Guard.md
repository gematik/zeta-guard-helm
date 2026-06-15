# How to deploy ZETA Guard

## Prerequisites

- Tools: `helm` and `kubectl` in PATH
- Access: kubeconfig pointing to the AKS/K8s cluster (`export KUBECONFIG=...`)

ZETA Guards requires an installed `cert-manager` in the Kubernetes cluster.
Create one using the
guide [How to install cert manager](How_to_install_cert-manager.md) if it is
missing.

Kubernetes requires a certain docker registry secret in the target namespace to
pull the container images used by the charts.
Use `kubectl get secrets -n NAMESPACE` to verify the existence of a secret named
`private-registry-credentials-zeta-group`, and use the
guide [How to create a docker registry secret](How_to_create_a_docker_registry_secret.md)
to create it if missing.

Before deploying ZETA Guard, configure credentials for your initial Keycloak
administrator account
at [charts/zeta-guard/values.yaml](../../charts/zeta-guard/values.yaml),
`authserver.admin.username` and `authserver.admin.password`.
Additionally, `authserver.genesisHash` and `authserver.smcbHashingPepper` need
to be set on the initial deployment.

### OPA bundle registry credentials (optional)

If you enable OPA bundle mode to pull policies from a private OCI registry,
create a Secret per namespace with registry credentials and reference it via
values.

1. Create Secret (per namespace):

```bash
kubectl -n zeta-<env> create secret generic opa-bearer \
  --from-literal=token='USERNAME:PASSWORD' \
  --from-literal=scheme='Basic'
```

2. Values snippet:

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

- The chart looks up the Secret during render; CI no longer passes bearer
  tokens.
- If the Secret is missing, OPA will attempt anonymous pulls and likely fail. To
  use inline policy instead, set `zeta-guard.opa.bundle.enabled=false`.

## Configuring the PEP well-known discovery document

The PEP proxy serves
an [OAuth Protected Resource Metadata](https://www.rfc-editor.org/rfc/rfc9728)
document at `/.well-known/oauth-protected-resource`. Two values must be set
correctly for each deployment:

| Value                                | Description                                                                         | Default |
|--------------------------------------|-------------------------------------------------------------------------------------|---------|
| `pepproxy.wellKnownBase`             | Public base URL of the PEP (e.g. `https://zeta.example.com`)                        | `""`    |
| `pepproxy.wellKnownResourceSuffix`   | Path suffix appended to `wellKnownBase` for the `resource` field                    | `/pep/` |
| `authserver.wellKnownAuthServerPath` | Path suffix appended to `authserver.hostname` for the `authorization_servers` field | `/`     |

Minimal values snippet:

```yaml
zeta-guard:
  pepproxy:
    wellKnownBase: "https://zeta.example.com"
    wellKnownResourceSuffix: /pep/      # or / if the resource is rooted at the base URL
  authserver:
    hostname: "zeta.example.com"
    wellKnownAuthServerPath: /          # or /auth if Keycloak is served under a sub-path
```

This produces:

```json
{
  "resource": "https://zeta.example.com/pep/",
  "authorization_servers": [
    "https://zeta.example.com/"
  ],
  "zeta_asl_use": "required"
}
```

## Scaling pods via replicaCount

All main components support horizontal scaling. Set `replicaCount` in the
environment values file (default is `1` for all components):

```yaml
zeta-guard:
  authserver:
    replicaCount: 2
  pepproxy:
    replicaCount: 3
  opa:
    replicaCount: 2
    simulation:
      replicaCount: 2
```

**PEP (`pepproxy.replicaCount > 1`):** Sticky sessions are required and 
handled automatically: the bundled NIC sets a `zeta_route` cookie on the first
response and routes by `hash $zeta_route consistent`. The client must support cookies
(zeta-sdk does); no further config needed.

NGINX-Ingress-Controller routes requests using
`hash $http_x_forwarded_for consistent` — the real client IP from the
`X-Forwarded-For` header ensures each client always reaches the same PEP pod.

**Authserver (`authserver.replicaCount > 1`):** Multi-replica works out of the
box with the default `databaseMode: cloudnative` (shared PostgreSQL) and
Infinispan remote cache for session sharing. Above ~4 replicas, consider tuning
the Infinispan cache.

## How to deploy ZETA Guard for local development

If you lack a local Kubernetes cluster, you
can [enable Kubernetes in Docker Desktop](https://docs.docker.com/desktop/features/kubernetes/#install-and-turn-on-kubernetes).
Kind is the recommended provisioning method. Docker Desktop will also install
`kubectl` if missing.

- Database: Bitnami PostgreSQL subchart is used, exposed via service
  `<release>-postgresql`.
- Ingress controller: the zeta-guard chart bundles the F5 NGINX Ingress
  Controller (NIC) and enables it by default.
- Ingress host: omitted by default; matches any host on the controller.

```shell
make deps
make deploy stage=local
```

When all deployments have completed,
you can randomly verify the Keycloak deployment using
`open http://localhost/auth/`.

## How to deploy ZETA Guard to a non-local Stage

- Ensure the operator and CRDs are installed via Terraform before deploying.
- The first rollout may need a longer timeout to allow the operator to create
  the DB Secret before Keycloak starts:
    - Example:
      `helm upgrade --install <rel> . -f values.my-stage.yaml -n <ns> --rollback-on-failure --timeout 10m`
- IngressClass selection for non-local:
    - Set `zeta-guard.ingressClassName` to the name of the IngressClass that the
      cluster's controller serves. This must match an existing
      `IngressClass.metadata.name`.
    - Discover available classes: `kubectl get ingressclass` and use the value
      from the NAME column (examples: `nginx`, `nginx-dev`, `nginx-cd`, or a
      platform class like `gce`, `openshift-default`).
    - When using the bundled F5 NIC dependency, set
      `zeta-guard.nginx-ingress.controller.ingressClass.name` to the same value
      so the controller watches that class.
