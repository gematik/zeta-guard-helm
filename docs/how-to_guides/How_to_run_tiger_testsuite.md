# How to trigger the Tiger testsuite inside the cluster

> **Warning – insecure components**
> Tiger Testsuite and Tiger Proxy may contain critical security flaws. Do **not** run them in
> production or any security-sensitive environment. Remove the chart or keep the chart disabled unless you are testing
> in an isolated sandbox:
>
> ```
> tags:
>   tiger-testsuite: false
> ```

The umbrella chart contains the `tiger-testsuite` subchart which wraps the Docker image maintained in
`../tiger-testsuite` (image tag `zeta/testing/tiger-testsuite:latest`). The chart now deploys the image
as a long-running Kubernetes `Deployment` together with an optional `Service` that exposes the Tiger
Workflow UI. This keeps the pod and its logs available so you can start or re-run scenarios whenever
you need them instead of only during a Helm upgrade.

## Enable the chart (local example)

1. Add the tag and configuration for the desired environment.  
   The local profile (`local-test/values.local.yaml`) already contains:

   ```yaml
   tags:
     tiger-testsuite: true

   tiger-testsuite:
     registry_name: zeta/testing
     env:
       zetaBaseUrl: https://zeta-kind.local
       zetaProxyUrl: http://tiger-proxy:80
       zetaProxy: proxy
       cucumberTags: "@smoke"
     workflowUi:
       activateWorkflowUi: true
       enableTestSelection: true
       runTestsOnStart: false
       tigerProxyConfiguration:
         adminPort: 9011
   ```

   The `zetaBaseUrl` points to the local ingress hostname which is already routed through the
   `tiger-proxy` service (see `How_to_configure_tiger-proxy.md`). This ensures every HTTP call of the
   testsuite is captured by the proxy. The `zetaProxyUrl` tells the testsuite how to reach the proxy
   itself so it can pull logs or use proxy-specific APIs during a run, and `zetaProxy` selects the
   proxy profile (`proxy` or `no-proxy`). When you set
   `workflowUi.tigerProxyConfiguration.adminPort`, the chart also passes that value to
   `tiger.tigerproxy.adminport`/`tiger.internal.localproxy.port` so the Workflow UI connects to the
   correct admin port. To reach the testsuite’s embedded Tiger proxy admin port from your host, enable
   the dedicated NodePort service:

   ```yaml
   tiger-testsuite:
     workflowUi:
       tigerProxyConfiguration:
         adminPort: 9011
     proxyAdminService:
       enabled: true
       type: NodePort
       nodePort: 32011
   ```

   With `kind-local.yaml` updated to map `32011 -> 9011`, the admin endpoint is available at
   `http://zeta-kind.local:9011`.

2. Deploy via `make deploy stage=local` (or a direct `helm upgrade --install ... -f
   local-test/values.local.yaml`). Helm will pull the dependency, deploy it and keep the
   Tiger Workflow UI service ready for interactive runs.

## Understanding the service lifecycle

- The rendered deployment and service name is `<release>-tiger-testsuite`.
- Each `helm upgrade` deploys the pod so you automatically pick up new configuration or images.
- You can trigger a manual restart with `kubectl rollout restart deployment/<release>-tiger-testsuite`
  whenever you want to cleanly re-run the container.

Useful commands:

```bash
kubectl -n <namespace> get deploy <release>-tiger-testsuite
kubectl -n <namespace> get pods -l app.kubernetes.io/name=tiger-testsuite
kubectl -n <namespace> logs -f deploy/<release>-tiger-testsuite
```

Use `kubectl cp` to retrieve Serenity reports from the pod after a test run finished:

```bash
POD=$(kubectl -n <namespace> get pods -l app.kubernetes.io/name=tiger-testsuite \
      -o jsonpath='{.items[0].metadata.name}')
kubectl -n <namespace> cp "${POD}:/app/target/site/serenity" ./serenity-report
```

## Customizing the run

All Maven/Tiger parameters are exposed via `tiger-testsuite.env`:

   ```yaml
   tiger-testsuite:
     env:
       zetaBaseUrl: https://zeta-kind.local
       zetaProxyUrl: https://proxy-kind.local
       zetaProxy: proxy
       cucumberTags: "@smoke and not @perf"
       mvnAdditionalArgs: "-Dzeta_base_url=https://zeta-kind.local \
                           -Dzeta_proxy_url=https://proxy-kind.local \
                           -Dtiger.lib.runTestsOnStart=true"
       serenityExportDir: /reports
       # Default (tiger:setup-testenv) keeps the Workflow UI alive. Switch to verify for one-off runs.
       mvnGoals: "tiger:setup-testenv"
   ```

Adjust these values and rerun `helm upgrade` to point the testsuite to a different environment or to
persist the generated Serenity HTML artifacts to a volume.

## Using the Tiger Workflow UI

The testsuite container ships with the Tiger Workflow UI but disables it by default to keep CI runs
headless. When you want to inspect scenarios locally, enable the UI, service exposure and test
selection:

```yaml
tiger-testsuite:
  workflowUi:
    activateWorkflowUi: true
    enableTestSelection: true   # allows selecting and running all tests on demand
    trafficVisualization: true
    workflowUiPort: 9010
    workflowUiStartTimeoutInSeconds: 300
    # tigerProxyConfiguration:
    #   adminPort: 9011
    runTestsOnStart: false      # keep the Workflow UI running and wait for manual starts
  service:
    enabled: true
    type: NodePort         # or ClusterIP + kubectl port-forward
    nodePort: 32010        # match kind-local.yaml to access http://localhost:9010
```

Setting `runTestsOnStart: false` prevents the container from executing all scenarios immediately and
keeps the Workflow UI up and running so you can trigger individual or full-suite runs as needed.

With the local profile (`local-test/values.local.yaml`) and the `kind-local.yaml` port mapping in place,
the UI is reachable on `http://localhost:9010` as long as the Deployment is running. On other
clusters, port-forward the service instead:

```bash
kubectl -n <namespace> port-forward svc/<release>-tiger-testsuite 9010:9010
```

The pod automatically triggers an internal `/status` call so the UI becomes responsive even if you
open it a little later. Because the Deployment stays up, you can keep the UI running, select any test
set and re-run the tests as often as needed without creating a fresh Helm release each time.
