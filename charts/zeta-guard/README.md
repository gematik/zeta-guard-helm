# Requirements

* Kubernetes 1.19+ is required for OpenTelemetry Operator installation
* Helm 3.0+
* [cert-manager](https://cert-manager.io/)
* [Postgres Operator](https://postgres-operator.readthedocs.io/)

## How to install the requirements

```shell
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.1/cert-manager.yaml

helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator

helm install postgres-operator postgres-operator-charts/postgres-operator
```

## How to install (using Helm 4)

```shell
helm dependencies build
helm install guard . \
  --namespace zeta-guard --create-namespace \
  --values values-demo.yaml \
  --rollback-on-failure
```
