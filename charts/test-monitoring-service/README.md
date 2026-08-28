# ZETA test-monitoring-service Helm Chart

This helm chart provides a fanout OpenTelemetry collector, OpenSearch,
Prometheus, Grafana and Jaeger for a zeta-guard deployment for testing purposes.

## How to install (using Helm 4)

```shell
helm dependencies build
helm install test-monitoring-service . \
  --namespace test-monitoring --create-namespace \
  --rollback-on-failure
```

You need to add an exporter to the telemetry gateway's configuration in
`zeta-guard` values:

```yaml
telemetry-gateway:
  config:
    exporters:
      otlp_grpc/test-monitoring-service:
        # endpoint: SERVICE.NAMESPACE.svc.cluster.local:4317
        endpoint: opentelemetry-collector.test-monitoring.svc.cluster.local:4317
        tls:
          insecure: true
```

And finally, you need to set up a port-forward from your cluster to your
development machine. The deployed instances of Jaeger and Grafana require no
authentication.

## How to view logs

Visit [Grafana](http://localhost:8080/grafana/), _Explore_, select _OpenSearch_
as data source, and switch from _Metric_ to _Logs_ if necessary. 

## How to view metrics

Visit [Grafana](http://localhost:8080/grafana/), _Drilldown_, and _Metrics_.
Filter
by label `service_name` to see metrics from individual services.

## How to view traces

Visit [Jaeger](http://localhost:8080/jaeger/ui/), select a service in the filter
sidebar, and press "Find Traces".
