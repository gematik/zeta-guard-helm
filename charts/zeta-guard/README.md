# Requirements

* Kubernetes 1.19+ is required for OpenTelemetry Operator installation
* Helm 4.0+
* [cert-manager](https://cert-manager.io/)
* [Postgres Operator](https://postgres-operator.readthedocs.io/)

## How to install the requirements

```shell
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.1/cert-manager.yaml

helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator

helm install postgres-operator postgres-operator-charts/postgres-operator
```

## How to install

```shell
helm dependencies build
helm install guard . \
  --namespace zeta-guard --create-namespace \
  --values values-demo.yaml \
  --rollback-on-failure
```

## Mergeable Ingress (F5 NIC)

- This chart uses NIC mergeable Ingresses by default (master + minions).
- NIC-only feature; requires the bundled NIC (`nginx-ingress.enabled=true`) or an external NIC compatible with `nginx.org/mergeable-ingress-type`.
- Master Ingress (`zeta-guard`): carries TLS and annotations (no rules).
- Minion Ingress (`zeta-guard-minion`): carries rules for `/auth` and `/`.
- Same-host requirement: master and all minions must share the same host. Set `authserver.hostname` to apply a host; TLS is configured on the master only.
- Both master and minions use the same `ingressClassName` value.

Notes:
- Mergeable mode does not require NIC CRDs (`enableCustomResources=false`).

## On resource conflicts

This chart uses of the official [OpenTelemetry Collector Helm chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-collector). Certain features of said chart relay on `ClusterRole(Binding)s` and `hostPorts`. Deploying this chart more than once into the same cluster – or installing it into a cluster with pre-existing OpenTelemetry collector deployments – requires cluster-specific configuration. Here is an example of such a configuration:

```yaml
log-collector:
  config:
    receivers:
      # limit filelog receiver to a single namespace
      filelog:
        include:
          - /var/log/pods/NAMESPACE_*/*/*.log
    exporters:
      # update endpoint to point to the overridden telemetry-gateway service
      otlp/telemetry-gateway:
        endpoint: telemetry-gateway-POSTFIX.NAMESPACE.svc.cluster.local:4317
  # move host ports to unoccupied ports
  ports:
    otlp:
      hostPort: 14317   # default 4317
    otlp-http:
      hostPort: 14318   # default 4318
telemetry-gateway:
  # overrides ClusterRole and Service names – referenced in the endpoint above
  fullnameOverride: telemetry-gateway-POSTFIX
```
