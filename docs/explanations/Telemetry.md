# Telemetry in ZETA Guard

This explanation focuses on the **helm-chart-specific** aspects of telemetry:
what each component emits, how it is enabled, and how to observe it locally. The
overall architecture of the telemetry data service (collector distribution,
pipelines, redaction, export to gematik) is documented in the gematik
documentation — see the *Telemetry data service* concept and the observability
how-tos in the
[gematik user manual](https://github.com/gematik/zeta/tree/main/docs/user-manual).
For the concrete catalog of trace attributes, see
[Telemetry attributes](../reference/Telemetry_attributes.md).

## Simplified telemetry flow to gematik

All telemetry from resource servers is exported to TI SIM, and select
security-related telemetry from ZETA guard is exported to TI SIEM.

```mermaid
graph LR;
    subgraph ZG["ZETA Guard Services"]
        HP["HTTP Proxy"]
        AS["Authorization Server"]
        PE["Policy Engine"]
    end

    subgraph COL["`Telemetrie-Daten Service
        (OTel collector)`"]
        PR["SIM pipelines"]
        PG["SIEM pipelines"]
    end

    subgraph G["gematik"]
        SIM["TI SIM"]
        SIEM["TI SIEM"]
    end


    RS["Resource Server"] --> PR --> SIM
    HP -.->|HTTP server spans| PR

    HP --> PG
    AS --> PG
    PE --> PG
    PG --> SIEM
```

## What each component emits

- **Authserver (Keycloak)** — runs on Quarkus with built-in OpenTelemetry
  instrumentation. Emits traces, metrics, and logs via OTLP to the
  telemetry-gateway, and also writes logs to stdout.
- **PEP proxy (NGINX + Rust module)** — emits traces via the native NGINX
  OpenTelemetry module (`ngx_otel_module`), nginx logs go to stdout and via syslog
  to the telemetry-gateway. `ngx_pep` emits traces, logs, and metrics via OTLP separately.
  It re-parents its spans under the `ngx_otel_module` spans, and emits [Trace Context](https://www.w3.org/TR/trace-context/)
  headers for outbound requests.
- **OPA / OPA simulation (policy engine)** — emit traces (OTLP) and metrics, and
  push decision logs and status updates to the telemetry-gateway through
  OPA's own mechanism.

All signals are collected and processed by the telemetry-gateway (an
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/); the
*Telemetriedaten-Service* in the specification), which exports them to the
gematik telemetry endpoints and, optionally, to the operating service provider's
own monitoring/SIEM.

```mermaid
flowchart LR
    subgraph ZG["ZETA Guard"]
        KC["Authserver (Keycloak)"]
        PEP["PEP proxy (nginx)"]
        OPA["Policy engine (OPA)"]
        GW["Telemetrie-Daten Service<br/>(OpenTelemetry Collector)<br/>filter · redact · transform · batch"]
    end
    subgraph GEM["gematik"]
        MON["SIM"]
        SIEM["SIEM"]
    end
    SP["service-provider backend<br/>(optional)"]
    KC -->|" logs, metrics, traces (OTLP) "| GW
    PEP -->|" traces (OTLP) "| GW
    PEP -->|" logs (syslog) "| GW
    OPA -->|" traces (OTLP) "| GW
    OPA -->|" decision logs, status (OPA push) "| GW
    GW -.->|" metrics (Prometheus scrape) "| ZG
    GW -->|OTLP| MON
    GW -->|OTLP| SIEM
    GW -.->|OTLP| SP
```

There are no log-collectors in ZETA Guard: Keycloak, OPA, and nginx send
parts of their logs directly to the telemetry-gateway as shown above; any other
container logs are not collected. The telemetry-gateway scrapes Prometheus
metrics from the components.

## Enabling telemetry

Telemetry is on by default. The base values live in
`charts/zeta-guard/values.yaml` and are overridden in several other values
files (per stage):

| Value                      | Effect                                                                        |
|----------------------------|-------------------------------------------------------------------------------|
| `telemetryGatewayEnabled`  | Deploys the telemetry-gateway (default `true`).                               |
| `telemetryGatewayHost`     | Fully-qualified hostname the telemetry gateway is reached at (default empty). |
| `pepproxyTracingEnabled`   | Loads `ngx_otel_module.so` and enables PEP tracing (default `true`).          |
| `authServerTracingEnabled` | Sets `KC_TRACING_ENABLED` on the authserver (default `true`).                 |

By default every signal is sent to the bundled telemetry-gateway under its bare
service name (`<release>-telemetry-gateway`, or
`telemetry-gateway.fullnameOverride`
when set), which relies on the pod's DNS search path to resolve. In some
clusters
that bare name does not resolve from the components — the cluster DNS does not
apply
the search path to the exporter's resolver, the gateway lives in another
namespace,
or the cluster domain is not `cluster.local` — and telemetry silently fails to
reach
the gateway. Set **`telemetryGatewayHost`** to the fully-qualified hostname of
the
gateway to fix this, e.g.
`zeta-guard-telemetry-gateway.<namespace>.svc.cluster.local`. The single value
redirects **all** telemetry destinations at once — the PEP OTLP traces endpoint
and
syslog `error_log`/`access_log`, the OPA OTLP address, and the authserver OTLP
endpoint — because they all resolve through the `telemetryGateway.hostname`
helper.
As a Helm value it survives chart upgrades, so no hand-editing of the rendered
ConfigMap is needed (which is not permitted in production). This mirrors the
pattern
the chart already uses for OPA via `authserver.provider.smcB.opaBaseUrl`.

The value changes **only the address** under which the telemetry-gateway is
reached — never the destination. Telemetry must always go to the
telemetry-gateway: the `redaction` processor and the `filter/ti_sim` /
`filter/ti_siem` filters live in its pipelines and are not bypassable. To feed
your own observability backend, add an exporter **inside** the gateway's
`dienst_hersteller` pipelines instead of redirecting the producers. It takes
precedence over `telemetry-gateway.fullnameOverride`. It is a hostname only; the
ports (`4317` OTLP, `54526` syslog, `49152`/`49153` OPA) are fixed. If you run
the gateway outside this chart, the operator must also allow egress to it — the
`pep-proxy`, `opa`, `opa-simulation` and `authserver` egress NetworkPolicies
only permit a same-namespace `opentelemetry-collector` pod as the destination.

The in-cluster hops to the gateway are plaintext; their transport security is
delegated to the service mesh. With `global.istio.enabled` the chart renders a
namespace-wide `STRICT` `PeerAuthentication` without port exceptions, so it
covers the OTLP, syslog and OPA ports as well. Without a mesh, secure them as
described in the produkthandbuch guide *Wie Sie Telemetrie des Resource Servers
an die gematik schicken* — mandatory mTLS applies to connections towards
ZETA-Guard-**external** services.

> **Note:** `pepproxyTracingEnabled` must be `false` whenever
> `telemetryGatewayEnabled` is `false` — otherwise NGINX fails to start with
> `unknown directive "otel_resource_attr"`.

Each component is tagged with an OpenTelemetry `service.name`. Service names are
important for observability in general (correlating signals to a component):

| Component                                        | `service.name`                              |
|--------------------------------------------------|---------------------------------------------|
| PEP proxy                                        | `ZETA Guard PEP HTTP proxy`                 |
| Authserver                                       | `ZETA Guard PDP authorization server`       |
| OPA                                              | `ZETA Guard PDP policy engine`              |
| OPA simulation                                   | `ZETA Guard PDP policy engine (simulation)` |
| Resource server (testfachdienst, test component) | `resource server` or `rs.*`                 |

## What the telemetry-gateway does

The gateway is the single egress point for all telemetry. For traces it filters,
redacts, transforms, and batches before export. Details (pipeline structure,
processors, export to gematik over TLS via the Google Identity-Aware Proxy with
a renewed bearer token) are documented in the gematik user manual and the
*Telemetry data service* concept; only the points relevant to security
telemetry are summarized here:

- Two separate filters (`ti_sim`, `ti_siem`) keep the security-relevant
  server-kind spans of the ZETA Guard services and drop client/internal spans
  and
  health probes.
- A `redaction` processor masks secrets and personal data: attributes whose key
  matches a blocked pattern (e.g. `*token*`) have their value masked, and values
  matching configured patterns (e.g. emails, phone numbers, addresses,
  credentials) are masked too. The attribute keys themselves are kept; nothing
  is
  deleted. Request bodies are never logged or attached to spans, so personal
  data
  cannot leak into telemetry that way.
- A `semantic_conventions_migration` processor renames the PEP's older-style
  attributes to current OpenTelemetry semantic conventions. This is a temporary
  workaround and is expected to be removed; it applies only to the
  `ZETA Guard PEP HTTP proxy` service. See
  [Telemetry attributes](../reference/Telemetry_attributes.md).

> The predefined filters and redactions are **not meant to be modified**.

No ZETA Guard component persists telemetry — collectors only cache until export
succeeds or the cache fills. Durable storage requires attaching an external
observability backend.

## Testing telemetry locally

For local development the chart can deploy a **test monitoring service** (based
on
the [OpenTelemetry Demo](https://opentelemetry.io/docs/platforms/kubernetes/helm/demo/)):
a collector that fans signals out to **OpenSearch** (logs), **Prometheus**
(metrics) and **Jaeger** (traces); **Grafana** then visualizes the data from
those stores. In a production deployment the gematik telemetry interface and
TI-SIEM take its place. See
[charts/test-monitoring-service/README.md](../../charts/test-monitoring-service/README.md).

In this test stack the fan-out collector tags each pipeline's copy of a span
with
a `gematik.zeta.kind` attribute (`dienst_hersteller`, `monitoring`, `siem`) so
the
three copies can be told apart in Jaeger and the other observability UIs (e.g.
Grafana). Only the `monitoring`/`siem` copies have the semantic-conventions
migration applied; the `dienst_hersteller` copy shows the raw, pre-migration
attribute names. This tag is a testing aid and is not part of the production
export.

## ngx_pep configuration

The nginx module supports the environment variables supported by
[opentelemetry_sdk](https://docs.rs/opentelemetry_sdk/0.32.1/opentelemetry_sdk/),
with some exceptions:
- sampling is always-on. This avoids dropping traces too early and skewing
  spanmetrics. Sampling should be done in the collector instead.
- only a single OTLP endpoint for traces, logs, and metrics is supported, which
  must support gRPC; `OTEL_EXPORTER_OTLP_ENDPOINT` is the only exporter setting evaluated

Note that this is separate from `ngx_otel_module` configuration, as the nginx
modules can't share any code with each other.
See [its documentation](https://nginx.org/en/docs/ngx_otel_module.html) for details.

## See also

- [Telemetry attributes](../reference/Telemetry_attributes.md) — attribute
  catalog and per-component coverage.
- [Tiger proxy](./Tiger-proxy.md) — how telemetry can optionally be routed
  through the Tiger proxy.
