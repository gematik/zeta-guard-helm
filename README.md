<img align="right" width="250" height="47" src="docs/img/Gematik_Logo_Flag.png"/> <br/>

# ZETA Guard Helm Charts

This repo houses the helm ZETA helm charts. Of particular interes is the zeta-guard Chart in `charts/zeta-guard`

## What’s Included
  - `charts/zeta-guard` (Keycloak + nginx PEP)

## Notes
- Commit `Chart.lock` so CI stays in sync with local dependency resolution.
 - The Zalando Postgres Operator is intentionally NOT a chart dependency here; install it once per cluster with Terraform.

## Installing zeta-guard

### Using the zeta-guard helm chart

You can deploy the zeta-guard helm chart directly from this source or via the published chart. Deployment from source is described here.

You will need a values file to configure your zeta-guard installation, e.g. `values-myguard.yaml`. This chart includes a demo file `values-demo.yaml` in the zeta-guard chart that you could use.

Given that kubectl is using the correct context you can install the helm chart via

```shell
    cd charts/zeta-guard
    helm upgrade --install zeta-guard . -f values-demo.yaml --wait --atomic
```

### During development

#### Registry & Tag

During development you may want to change the registry from which images are pulled and the tag that is used. You can do that via a values file as follows

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

During development you may pull images from a private registry. You can create an appropriate image pull secret in your cluster as follows

```shell
kubectl create secret docker-registry my-image-pull-secret-name \
    -n NAMESPACE \
    --docker-server=your.registry.example.org:443 \
    --docker-username=<USERNAME> \
    --docker-password=<ACCESS_TOKEN> \
    --docker-email=<EMAIL> 
```

After creating the image pull secret you can use it in the helm chart via the following values file:

```yaml
global:
  # use this image pull secret
  image_pull_secret: my-image-pull-secret-name
```

## License

(C) akquinet tech@Spree GmbH, 2025, licensed for gematik GmbH

Apache License, Version 2.0

See the [LICENSE](./LICENSE) for the specific language governing permissions and limitations under the License

## Additional Notes and Disclaimer from gematik GmbH

1. Copyright notice: Each published work result is accompanied by an explicit statement of the license conditions for use. These are regularly typical conditions in connection with open source or free software. Programs described/provided/linked here are free software, unless otherwise stated.
2. Permission notice: Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
    1. The copyright notice (Item 1) and the permission notice (Item 2) shall be included in all copies or substantial portions of the Software.
    2. The software is provided "as is" without warranty of any kind, either express or implied, including, but not limited to, the warranties of fitness for a particular purpose, merchantability, and/or non-infringement. The authors or copyright holders shall not be liable in any manner whatsoever for any damages or other claims arising from, out of or in connection with the software or the use or other dealings with the software, whether in an action of contract, tort, or otherwise.
    3. We take open source license compliance very seriously. We are always striving to achieve compliance at all times and to improve our processes. If you find any issues or have any suggestions or comments, or if you see any other ways in which we can improve, please reach out to: ospo@gematik.de
3. Please note: Parts of this code may have been generated using AI-supported technology. Please take this into account, especially when troubleshooting, for security analyses and possible adjustments.
