<img align="right" width="250" height="47" src="docs/img/Gematik_Logo_Flag.png"/> <br/>

# Requirements

* Kubernetes 1.19+ is required for OpenTelemetry Operator installation
* Helm 4.0+
* [cert-manager](https://cert-manager.io/)
* [CloudNativePG operator](https://cloudnative-pg.io/) (single cluster-wide operator; required when `zeta-guard.cloudnativePg.enabled: true`)

## How to install the requirements

```shell
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.1/cert-manager.yaml

# CloudNativePG: install a single cluster-wide operator
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cloudnative-pg cnpg/cloudnative-pg \
  -n cnpg-system --create-namespace \
  --set config.clusterWide=true \
  --wait
```

## How to install

```shell
helm dependencies build
helm upgrade --install zeta-guard . \
  --namespace zeta-guard --create-namespace \
  --values values-demo.yaml \
  --wait
```

Notes:
- CNPG operator is required only when `databaseMode` is set to `cloudnative`. For `external` database mode, CNPG is not required and no CNPG resources are created.
- When `databaseMode: cloudnative`, the chart creates a CNPG `Cluster` resource in the release namespace. Ensure a CNPG operator is installed once per cluster (cluster-wide) before installing this chart.

## Local development (kind)

The provided `make kind-up` target creates a kind cluster, configures CoreDNS, prepares the `zeta-local` namespace, installs cert-manager, and installs the CloudNativePG operator with clusterWide enabled.

Then deploy:

```shell
make deps
make deploy stage=local
```

## Mergeable Ingress (F5 NIC)

- This chart uses NIC mergeable Ingresses by default (master + minions).
- NIC-only feature; requires the bundled NIC (`nginxIngressEnabled=true`) or an external NIC compatible with `nginx.org/mergeable-ingress-type`.
- Master Ingress (`zeta-guard`): carries TLS and annotations (no rules).
- Minion Ingress (`zeta-guard-minion`): carries rules for `/auth` and `/`.
- Same-host requirement: master and all minions must share the same host. Set `authserver.hostname` to apply a host; TLS is configured on the master only.
- Both master and minions use the same `ingressClassName` value.

Notes:
- Mergeable mode does not require NIC CRDs (`enableCustomResources=false`).

## On resource conflicts

This chart uses of the
official [OpenTelemetry Collector Helm chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-collector).
Deploying this chart more than once into the same cluster – or installing it
into a cluster with pre-existing OpenTelemetry collector deployments – requires
cluster-specific configuration. Here is an example of such a configuration:

```yaml
telemetry-gateway:
  # overrides ClusterRole and Service names – referenced in the endpoint above
  fullnameOverride: telemetry-gateway-POSTFIX
```

## Usage in OpenShift 4.x

To run ZETA-Guard on OpenShift 4.x, the following configuration changes are
required:

#### 1. Enable OpenShift Ingress with TLS

Instead of using a dedicated OpenShift Route resource, a standard Kubernetes
Ingress with TLS configuration is used.
The OpenShift Ingress-to-Route Controller will automatically create
edge-terminated Routes with TLS redirect.

Set the following values:
```yaml
# Enable OpenShift Ingress-to-Route Controller with TLS
openshiftIngress:
  enabled: true
  certName: zeta-guard-tls  # Name of the TLS secret used in the Ingress TLS blocks

# Use the OpenShift-provided IngressClass
ingressClassName: openshift-default

# Disable NGINX Ingress Controller
nginxIngressEnabled: false

# Keep Ingress resources enabled
ingressEnabled: true
```

The TLS secret (e.g. zeta-guard-tls) must exist in the target namespace and
contain a valid certificate for the configured hostname.

#### 2. Disable Test Monitoring

Set `testMonitoringServiceEnabled` to `false`.
This component is not compatible with OpenShift’s restricted-v2 Security Context
Constraints (SCC).

#### 3. Remove Fixed User IDs from Security Contexts

Remove all occurrences of `runAsUser: 1000` from any securityContext
definitions.
OpenShift assigns user IDs dynamically per namespace/project, so fixed IDs will
cause permission issues.

## License

(C) tech@Spree GmbH, 2026, licensed for gematik GmbH

Apache License, Version 2.0

See the [LICENSE](../../LICENSE) for the specific language governing permissions and limitations under the License

## Additional Notes and Disclaimer from gematik GmbH

1. Copyright notice: Each published work result is accompanied by an explicit statement of the license conditions for use. These are regularly typical conditions in connection with open source or free software. Programs described/provided/linked here are free software, unless otherwise stated.
2. Permission notice: Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
    1. The copyright notice (Item 1) and the permission notice (Item 2) shall be included in all copies or substantial portions of the Software.
    2. The software is provided "as is" without warranty of any kind, either express or implied, including, but not limited to, the warranties of fitness for a particular purpose, merchantability, and/or non-infringement. The authors or copyright holders shall not be liable in any manner whatsoever for any damages or other claims arising from, out of or in connection with the software or the use or other dealings with the software, whether in an action of contract, tort, or otherwise.
    3. We take open source license compliance very seriously. We are always striving to achieve compliance at all times and to improve our processes. If you find any issues or have any suggestions or comments, or if you see any other ways in which we can improve, please reach out to: ospo@gematik.de
3. Please note: Parts of this code may have been generated using AI-supported technology. Please take this into account, especially when troubleshooting, for security analyses and possible adjustments.
