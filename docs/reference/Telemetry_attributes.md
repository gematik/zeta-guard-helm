# Telemetry attributes reference

This reference lists the security-relevant trace attributes that ZETA Guard
is expected to emit on its security-relevant spans, where each attribute comes
from and the current coverage. For the surrounding architecture see
[Telemetry](../explanations/Telemetry.md).

The requirement behind this catalog is gematik A_27725 (security-relevant
information in traces): an analyst must be able to reconstruct *who* did *what*,
*where* and with *what result* from a span.

## Required attributes

| Source datum       | OpenTelemetry attribute        | Purpose                                 |
|--------------------|--------------------------------|-----------------------------------------|
| IP address         | `client.address`               | Identify the requesting instance        |
| User agent         | `user_agent.original`          | Detect attacks / anomalies              |
| HTTP method        | `http.request.method_original` | Detect unauthorized / abnormal requests |
| HTTP route         | `http.route`                   | Monitor access, detect enumeration      |
| Target host (FQDN) | `server.address`               | Identify the target server              |
| HTTP status        | `http.response.status_code`    | Detect errors / attacks (401/403, 5xx)  |
| Client ID          | `app.installation.id`          | Identify the requesting client          |

## Security-relevant spans

| Component        | Span (operation)                                        | What it represents             |
|------------------|---------------------------------------------------------|--------------------------------|
| Authserver (PDP) | `POST /realms/{realm}/clients-registrations/{provider}` | Dynamic client registration    |
| Authserver (PDP) | `POST /realms/{realm}/protocol/{protocol}/token`        | Token exchange (RFC 8693)      |
| PEP proxy        | resource-server route (NGINX location, e.g. `/pep/…`)   | Authenticated resource request |

## Where each attribute comes from

ZETA Guard does not set most of these attributes by hand — they come from the
underlying instrumentation:

- **Authserver:** Keycloak/Quarkus emits the current semantic-convention names
  natively (no transformation needed).
- **PEP proxy:** the native NGINX OpenTelemetry module emits older-style
  attribute
  names, which the telemetry-gateway renames to the current conventions via a
  `semantic_conventions_migration` processor. This is a temporary workaround
  (expected to be removed), applied only to the `ZETA Guard PEP HTTP proxy`
  service and only in the gematik-bound pipelines.

- **`app.installation.id`** is domain-specific (the client ID). It is *not* part
  of standard HTTP instrumentation and must be set explicitly by the component
  (Keycloak / PEP).

## Current coverage

As of ZETA Guard release 1.2.0. The table reflects the attributes actually
present on the spans as exported to gematik, as verified against live traces.
Because the attributes come from generic instrumentation that does not
distinguish the PDP's routes, coverage is shown per component.

| Attribute                      | PDP (Keycloak)  | PEP             |
|--------------------------------|-----------------|-----------------|
| `client.address`               | present         | present         |
| `user_agent.original`          | present         | present         |
| `http.request.method_original` | not observed\*  | not observed\*  |
| `http.route`                   | present         | present         |
| `server.address`               | present         | present         |
| `http.response.status_code`    | present         | present         |
| `app.installation.id`          | not yet emitted | present         |

\* `http.request.method_original` is only set for non-standard HTTP methods; the
verified traffic used standard methods, so its absence is expected — not a gap.
See the note below.

Summary: of the seven required attributes, PDP spans carry five and PEP spans
carry six. `http.request.method_original` is conditional (see note); the
remaining missing attributes are tracked as gaps below.

### Known limitations

These gaps are tracked for implementation:

- **`app.installation.id` (PDP)** — not emitted. Requires explicit
  instrumentation: a custom span attribute in the Keycloak plugins

### Note on `http.request.method_original`

This attribute is not a tracked gap. Per the OpenTelemetry HTTP semantic
conventions, `http.request.method` is the *normalized* method, while
`http.request.method_original` is only set when the original method is
non-standard — e.g., a client sending `Get` (normalized to `GET`) or an unknown
verb like `FOOBAR` (normalized to `_OTHER`). For ordinary `GET`/`POST` traffic
it is correctly absent and would be identical to `http.request.method` anyway.

Both are required because they serve different roles: the normalized
`http.request.method` for statistics and `http.request.method_original` for
anomaly/attack detection — so an unusual or malformed method is preserved
instead of collapsing to `_OTHER`.

### Caveats when reading PEP spans

- **`http.route`** carries the NGINX *location* (e.g. `/pep/`), not the concrete
  resource path. The concrete path is in `http.target`. This is conventional to
  limit cardinality in spanmetrics and other reporting, which is normally
  grouped by `http.route`
- **`server.address`** is the internal service name (`pep-proxy-svc`), not the
  externally visible FQDN.
