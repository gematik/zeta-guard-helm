# ADR 0001: Durable, restart-safe daily security-KPI counts for `count/security_kpis`

## Status

Accepted

## Context

`telemetry-gateway` is a vanilla `opentelemetry-collector` chart, vendored and
aliased (`charts/zeta-guard/Chart.yaml:9-14`), running a custom-compiled
gematik collector distro image (`charts/zeta-guard/values.yaml:883-889`). It
is deployed as a single-replica, stateless `Deployment`
(`telemetry-gateway.mode: deployment`, `values.yaml:882`) with
`readOnlyRootFilesystem: true` (`values.yaml:903`) and no `PersistentVolumeClaim`.
There is no `replicaCount` or `autoscaling` override for it anywhere in
`charts/zeta-guard/values.yaml` or in any stage's values file — it is
always exactly one pod, and that pod is expected to be freely restartable
(rolling upgrades, OOM kills, node drains, and — in stages with
`devMode: true` enabled — the forced-rollout annotation).

The `count/security_kpis` connector (`values.yaml:906-1008`) computes the security-KPI
counts required by gemSpec_ZETA
[A_25484-03](https://gemspec.gematik.de/docs/gemSpec/gemSpec_ZETA/latest/#A_25484-03):
`zeta_guard_kpi.failed_authorization_codes_24h`,
`.failed_client_activations_24h`, `.impossible_travel_24h`, and two
span-count KPIs (`requests_by_unregister_clients.*`), added in `3bee39e` and
fed by the log/span records whitelisted in `processors.filter/ti_siem`
(extended in `5ae8427`). Every metric carries a `zeta-client.date` attribute,
produced by `processors.transform/siem` via `FormatTime(log.time, "%F")`
(UTC calendar day). That attribute is how "daily" is implemented today: one
ever-growing counter per label-set-including-date, held entirely in the
`count` connector's in-process memory. These metrics are exported via
`otlp_grpc/ti_siem` straight to gematik's TI-SIEM backend
(`https://otlp.siem.prod.ccs.gematik.solutions`) — there is no Prometheus (or
any other durable store) in front of that export path in production.

The values file already carries a warning comment above the connector:

```yaml
# WARNING metrics created by count connector are discarded by prometheus.
# Use deltatocumulative processor to rectify metrics before sending them
# to prometheus.
```

but no such processor, PVC, or persistent queue exists anywhere in the
production pipeline. The only place `deltatocumulative` is actually used is
`charts/test-monitoring-service` (`values.yaml:105,202`) — a dev/test-only
fan-out to a local Grafana/Prometheus stack that **is not deployed in
production at all**.

`docs/explanations/Telemetry.md` already states this plainly: *"No ZETA
Guard component persists telemetry — collectors only cache until export
succeeds or the cache fills. Durable storage requires attaching an external
observability backend."* The practical consequence: any restart of
`telemetry-gateway` zeroes the `count` connector's in-memory counters, and
the current day's KPI total silently under-reports from that point on, with
nothing to reconcile it. Given the pod is single-replica and treated as
freely restartable, this isn't a rare edge case — it is the expected steady
state.

Two constraints came out of discussing the fix directly with the team:

- Reusing or sharing an existing stateful component — specifically the
  CNPG-backed authserver Postgres — for this purpose is **not acceptable**
  for security-isolation reasons (it would give a telemetry pipeline access
  to, or co-location with, the authserver's database).
- Adding an **entirely new, dedicated** service to the chart is fine.
- `charts/test-monitoring-service` already runs a Prometheus with
  `deltatocumulative` wired up, but since it's test-only tooling that's
  absent in production, it is not a viable base to extend for a
  compliance-critical path.

## Decision

Add a new, minimal, dedicated Prometheus instance (its own PVC) to
`charts/zeta-guard`, kept separate from `charts/test-monitoring-service`.
Deployed by vendoring the `prometheus-community/prometheus` chart as a new
dependency (rather than hand-rolled manifests) — chosen for being a known,
well-tested component over custom manifests written and maintained here.
This reintroduces, for a second component, the exact category of risk this
repo already hit once and fixed for `opentelemetry-collector` (two vendored
copies of the same underlying chart, at different versions, colliding in
Helm's global template namespace — `{{ define }}` names aren't scoped per
chart/subchart): if `charts/test-monitoring-service`'s own bundled Prometheus
(via `opentelemetry-demo`) ever shares template-defined names with this one
at a different version, the same failure mode recurs. This needs verifying,
and needs ongoing version-alignment discipline, during implementation — it
is not a one-time check to tick off.

Gate it behind its own opt-in flag, independent of `telemetryGatewayEnabled`:

```yaml
kpiMetricsPersistence:
  enabled: false
  storage:
    size: 2Gi
    storageClassName: ""
  retention: 7d
```

Retention is 7 days — more than the "today/yesterday" correctness requirement
strictly needs, but gives useful headroom for manual investigation. Actual
on-disk usage for this low-cardinality, low-volume metric set is expected to
stay far under the `2Gi` placeholder regardless of the exact retention
window chosen.

Enable it per-stage wherever A_25484-03 correctness actually matters for
compliance reporting; leave it off for local development and any stage
where ASL/compliance enforcement itself is disabled, or where nothing
consumes the KPI metrics for compliance purposes.

Mechanism:

1. Reshape the metrics defined under `count/security_kpis` — generically, for
   whatever KPI set exists there at any point, not just today's five — from
   per-day-bucketed deltas into plain monotonic counters: standard OTel `sum`
   with cumulative temporality since process start, with no
   `zeta-client.date` attribute baked into the counter series itself. Push
   them from `telemetry-gateway` to the new instance via an `otlp_http`
   exporter, straight into its OTLP receiver (disabled in Prometheus by
   default; enabled here via `--web.enable-otlp-receiver`) — not a
   `prometheus` exporter for it to scrape, since this collector build has no
   `prometheus` exporter component (`otlp`/`otlp_grpc`/`otlp_http`/`debug`
   only). The *original* `metrics/ti_siem` pipeline's SIEM-bound
   export (`otlp_grpc/ti_siem`) is removed at this point — its exporters
   become just the new `otlp_http` exporter. The raw, restart-vulnerable
   counters must stop reaching gematik's SIEM directly; only the corrected
   value (step 3) should, from a new, separate pipeline.
2. The new Prometheus's own durable storage (PVC) plus PromQL's
   counter-reset-aware `increase()`/`rate()` absorb collector restarts
   automatically: when `telemetry-gateway` restarts, the exposed raw counter
   drops back to zero, but Prometheus already has the pre-restart samples on
   disk, and `increase()` compensates for that discontinuity — a query
   spanning the restart still returns the correct total. No checkpoint/restore
   logic needs to be written or maintained by us.
3. Compute the true UTC-calendar-day total (per A_25484-03) from that durable
   series and feed the corrected value back into `telemetry-gateway` via a
   **direct OTLP push**, not a second scrape hop. A small CronJob — inline
   bash script running in an existing off-the-shelf public image, no bespoke
   container build, following the exact convention already established by
   `opa-token-renewer-cronjob`/`ti-siem-token-renewer-cronjob`/
   `ti-sim-token-renewer-cronjob` in this chart (`python3 -c` one-liners for
   JSON handling where needed) — runs once daily, at 23:59 UTC (the value
   must reach SIEM exactly once per day, not be continuously re-published;
   see the schedule comment in values.yaml for the accepted trade-off this
   implies), issues an instant PromQL query against the new Prometheus's
   HTTP API using a
   dynamically-computed UTC-midnight-aligned range (see implementation note
   below), and POSTs the result via OTLP/HTTP straight to a new, dedicated
   `otlp/security_kpis_corrected` receiver on `telemetry-gateway` —
   mirroring how every other telemetry source into this chart already
   arrives (PEP, OPA, authserver, ...), rather than introducing a Prometheus
   Pushgateway as the only pull-shaped input in an otherwise all-push
   architecture. A new pipeline, fed by `otlp/security_kpis_corrected`,
   exports the corrected value onward via the existing `otlp_grpc/ti_siem`
   exporter — the SIEM export removed
   from the original pipeline in step 1. `telemetry-gateway` remains the
   **sole** component with SIEM egress; `networkPolicy.egress.siem` needs no
   change. Two new NetworkPolicy rules are needed instead, following the
   existing pattern in `charts/zeta-guard/templates/netpol/`:
   `telemetry-gateway`'s egress to the new Prometheus's OTLP receiver
   (step 1), and the CronJob's egress to both the new Prometheus's query API
   and `telemetry-gateway`'s new OTLP receiver port.
4. Add basic self-monitoring on the new Prometheus: `PrometheusRule`s for
   PVC fill level, so a broken durability path doesn't quietly regress into
   the exact "looks fine, silently wrong" failure mode this ADR exists to
   fix. Push-based ingestion has no scrape target to key an "is it reachable"
   check off of, so that specific check is dropped rather than replaced with
   a fragile absence-of-data heuristic (a KPI legitimately having zero
   events for a while looks identical to broken ingestion under a naive
   `absent_over_time()` check) — a real ingestion-health signal is left for
   a future revision. No
   alert-delivery destination is wired up yet — this is a deliberate,
   accepted gap (see Consequences), not an oversight, pending a decision on
   which Alertmanager/destination this should route through.
5. Verification is a manual runbook, held with the team's internal operating
   documentation: restart `telemetry-gateway` mid-day under synthetic load and
   confirm the value it forwards onward is unaffected. No automated restart test
   is added as part of this decision.

**Implementation note (the mechanism behind step 3):** computing a
UTC-midnight-aligned "count so far today" from a plain monotonic counter is
not a single static Prometheus recording rule — PromQL range-vector
durations are fixed literals, not a "time since 00:00 UTC" expression. This
is solved by the CronJob computing the elapsed-seconds-since-UTC-midnight
itself on each run and using that as the dynamic range in its instant query
(e.g. `increase(metric[<N>s])` where `<N>` is computed fresh every run) —
the exact query text and error-handling are ordinary implementation work at
this point, not an open architectural question.

**Explicitly out of scope / accepted as-is by this decision:**

- Double-counting from the brief two-pod overlap during a `RollingUpdate` is
  accepted, uncorrected (no idempotency keys, no `maxUnavailable=0` change) —
  negligible error for a KPI trend/threshold metric.
- Event loss during the actual restart window itself (the literal seconds
  the pod is down) is accepted — no durable buffering is added upstream of
  `telemetry-gateway`. This decision fixes "the counter resets to zero on
  restart," not "events during the exact restart moment are missed."
- No local, on-cluster history of daily totals beyond "today" (and possibly
  "yesterday", for late-arriving events) is retained — gematik's SIEM is the
  system of record for history once a day's value has been sent. (The new
  Prometheus's own 7-day retention is for operational/debugging headroom, not
  because that history is a product requirement.)

## Consequences

**Positive:**

- The daily KPI totals gematik receives for A_25484-03 survive any restart
  of `telemetry-gateway` — including the routine, expected kind (rolling
  upgrades, OOM kills, `devMode` rollouts) — without any bespoke
  checkpoint/restore code on our part. Correctness comes from Prometheus's
  own well-tested counter-reset handling, not logic we have to write and
  maintain.
- `telemetry-gateway` itself stays exactly as hardened as it is today
  (`readOnlyRootFilesystem: true`, no PVC, stateless `Deployment`) — the
  durability requirement is fully absorbed by the new, separate component
  instead of forcing a security posture regression on the existing one.
- Delivering the corrected value via direct OTLP push, rather than a
  Pushgateway-and-scrape hop, keeps every telemetry source into
  `telemetry-gateway` — including this new one — on the same push-based
  ingestion model, and avoids standing up an always-on component whose only
  job would be to be scraped.
- `networkPolicy.egress.siem` is untouched — `telemetry-gateway` remains the
  only pod with a path to gematik's SIEM endpoint; the new Prometheus never
  needs SIEM connectivity or the `ti-siem-token` bearer secret.
- The fix generalizes to any future KPI added under `count/security_kpis`, not just
  today's five metrics — no repeated plumbing work per new KPI.
- Being opt-in per stage keeps the extra pod/PVC footprint off local
  development and any stage where nothing consumes the KPI metrics for
  compliance anyway.
- The CronJob helper needs no new container image, Dockerfile, or CI build
  job — it reuses this chart's existing inline-script-in-an-off-the-shelf-
  image convention, the same one already used for the token-renewer
  CronJobs.

**Negative / accepted tradeoffs:**

- A brand-new stateful component (Prometheus + PVC) is added to the chart,
  each with its own upgrade path, PVC-sizing, and `StorageClass`-availability
  story to get right across every enabled stage (Azure vs. local KIND vs.
  OpenShift CRC).
- Vendoring `prometheus-community/prometheus` as a new chart dependency
  reintroduces the class of risk already hit once in this repo (colliding
  global template names between two vendored copies of the same underlying
  chart) should `charts/test-monitoring-service`'s bundled Prometheus and
  this one ever diverge in version. This needs active version-alignment
  discipline going forward, not a one-time fix at implementation time.
- It runs as a single instance with no HA — a node drain or crash that takes
  the Prometheus pod down before it reschedules causes a gap in correct KPI
  reporting for that window, mirroring (not exceeding) the reliability bar
  already accepted elsewhere in this chart. If gematik's tolerance for
  reporting gaps turns out to be stricter than "brief gaps are acceptable,"
  this will need revisiting.
- The "count so far today" computation is not a plain Prometheus scrape of a
  static recording rule; it needs a small CronJob doing a dynamic-range
  query and an OTLP push, which is genuine new logic to write, test, and
  operate — see the implementation note above.
- No automated test protects this behavior going forward; a future change to
  the pipeline (e.g. someone re-adding per-day bucketing to `count/security_kpis`, or
  changing the `otlp_http`/`otlp` receiver/exporter wiring) could silently
  reintroduce the exact bug this ADR fixes, and only a manually-run runbook
  would catch it.
- No alert-delivery destination is wired up for the new self-monitoring
  `PrometheusRule`s yet (PVC fill level) — the rules exist, but nothing
  routes a firing alert anywhere actionable until a destination is decided.
  Revisit once one is. There is also no ingestion-health check at all right
  now (see mechanism step 4) — a second, independent gap from the
  alert-delivery one.
- Double-counting during rolling-update pod overlap and event loss during
  the literal restart window are both accepted, unaddressed risks — this
  decision narrows the problem to "the running total must not silently reset
  to zero," not "the count must be exactly correct under all circumstances."
- Metric *shape* changes (per-day-bucketed deltas → plain monotonic
  counters), which is a breaking change to anything downstream that assumed
  the old shape (e.g. local dashboards, and the team's collection of commonly
  used telemetry queries — though those queries target logs, not these metrics,
  so impact should be limited to metric consumers specifically).

## Alternatives considered

- **Make `telemetry-gateway` itself stateful** (convert to `StatefulSet`,
  attach a PVC, checkpoint/restore the `count` connector's counter state on
  shutdown/startup): rejected because it requires dropping
  `readOnlyRootFilesystem: true` and reworking the pod's security posture,
  and because OTel's `file_storage` extension only persists an *exporter's
  send queue*, not a connector's internal accumulator — so this would have
  meant writing and maintaining custom checkpoint logic ourselves rather than
  leaning on an existing, well-tested mechanism.
- **Trust gematik's SIEM-stored logs as the source of truth** (the
  individual security-event logs are already exported durably to SIEM
  alongside the metric; derive/reconcile daily counts from those instead of
  a pre-computed running counter): rejected — modifying or relying on
  behavior of telemetry stores outside this chart is explicitly not
  something we can do here.
- **External stateful counter service** (a small Redis/Postgres-backed
  increment API that `telemetry-gateway` calls per event): considered
  alongside the Prometheus option; rejected in favor of Prometheus because
  it's a known, already-operationally-understood technology on the team,
  versus new custom code (or another unfamiliar stateful dependency) to
  secure and maintain.
- **Reuse the existing CNPG/Postgres authserver database**: rejected
  outright for security-isolation reasons — sharing that database with a
  telemetry pipeline was ruled out regardless of technical feasibility.
- **Harden/promote `charts/test-monitoring-service`'s existing Prometheus**
  instead of building a new component: rejected because that chart is
  test/dev tooling only and is not deployed in production at all — there is
  nothing there to promote for the environments where A_25484-03 correctness
  actually matters.
- **Rolling trailing-24h window instead of UTC calendar day**: would have
  sidestepped the midnight-boundary query problem entirely (a plain
  `increase(metric[24h])` needs no day-alignment), but was rejected because
  A_25484-03's example anchors on calendar-day counts with a date attribute,
  and a rolling window never produces a stable, attributable "day" value.
- **Exactly-once counting via idempotent event keys** (to eliminate
  double-counting during rolling-update pod overlap): rejected for now as
  more correctness than the metric warrants — the overlap window is a few
  seconds during routine rollouts, and the resulting error is negligible for
  a trend/threshold KPI. Revisit if gematik's use of these metrics ever
  requires exact-count guarantees.
- **Automated restart test as part of this decision**: rejected for scope —
  only a manual verification runbook is included here. Not ruled out
  permanently; worth adding once the implementation has settled, since lack
  of a regression test is called out above as a real accepted risk.
- **Prometheus HA (replication/leader election)**: rejected as
  disproportionate to the reliability bar already accepted elsewhere in this
  chart (single-replica everything; some stages skip the component
  entirely). Revisit if a single-instance outage window turns out to matter
  more in practice than currently assumed.
- **Prometheus Pushgateway between the CronJob and `telemetry-gateway`**:
  considered as the delivery mechanism for the corrected value (CronJob
  pushes to a Pushgateway; `telemetry-gateway`'s existing `prometheus`
  receiver scrapes the Pushgateway). Rejected in favor of a direct OTLP push
  once weighed against the rest of this chart's shape: every other telemetry
  source here already pushes to `telemetry-gateway` via OTLP; a Pushgateway
  would introduce the only pull-shaped input in an otherwise all-push
  architecture, and be an extra always-running component for no benefit over
  a direct push straight to a new dedicated receiver.
- **Custom-built container image for the CronJob helper** (e.g. a small
  Python service with its own `Dockerfile` and CI build job): rejected —
  this chart already has an established convention for exactly this shape
  of task (`opa-token-renewer-cronjob`, `ti-siem-token-renewer-cronjob`,
  `ti-sim-token-renewer-cronjob`: inline bash script + `python3 -c`
  one-liners for JSON handling, running in an existing off-the-shelf public
  image), and there is no reason this helper needs more than that.
