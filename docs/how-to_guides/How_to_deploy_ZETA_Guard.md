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

### OPA bundle registry credentials (optional)

If you enable OPA bundle mode to pull policies from a private OCI registry, create a Secret per namespace with registry credentials and reference it via values.

1) Create Secret (per namespace):
```bash
kubectl -n zeta-<env> create secret generic opa-bearer \
  --from-literal=token='USERNAME:PASSWORD' \
  --from-literal=scheme='Basic'
```

2) Values snippet:
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
- The chart looks up the Secret during render; CI no longer passes bearer tokens.
- If the Secret is missing, OPA will attempt anonymous pulls and likely fail. To use inline policy instead, set `zeta-guard.opa.bundle.enabled=false`.

## How to deploy ZETA Guard for local development

If you lack a local Kubernetes cluster, you
can [enable Kubernetes in Docker Desktop](https://docs.docker.com/desktop/features/kubernetes/#install-and-turn-on-kubernetes).
Kind is the recommended provisioning method. Docker Desktop will also install
`kubectl` if missing.

- Database: Bitnami PostgreSQL subchart is used, exposed via service `<release>-postgresql`.
- Ingress controller: the zeta-guard chart bundles the F5 NGINX Ingress Controller (NIC) and enables it by default.
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
  - Set `zeta-guard.ingressClassName` to the name of the IngressClass that the cluster's controller serves. This must match an existing `IngressClass.metadata.name`.
  - Discover available classes: `kubectl get ingressclass` and use the value from the NAME column (examples: `nginx`, `nginx-dev`, `nginx-cd`, or a platform class like `gce`, `openshift-default`).
  - When using the bundled F5 NIC dependency, set `zeta-guard.nginx-ingress.controller.ingressClass.name` to the same value so the controller watches that class.
