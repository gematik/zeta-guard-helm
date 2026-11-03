{{/*
  Helper: telemetryGateway.hostname
  Resolves the hostname that every telemetry stream is sent to. Used by:
    - pep/_pep-nginx-conf.tpl (OTLP exporter endpoint + syslog error_log/access_log)
    - opa/_opa.tpl (OTLP address)
    - authserver/authserver-deployment.yaml (OTLP endpoint env var)
  This always resolves to the telemetry-gateway itself — the values below change only
  the ADDRESS it is reached under, never the destination (its redaction and
  ti_sim/ti_siem filters must not be bypassed).
  Precedence:
    1. .Values.telemetryGatewayHost — address override for the telemetry-gateway,
       e.g. the FQDN when the bare service name does not resolve in the cluster.
    2. telemetry-gateway.fullnameOverride — name of the bundled collector subchart.
    3. {{ .Release.Name }}-telemetry-gateway — default in-namespace service name.
*/}}
{{- define "telemetryGateway.hostname" -}}
{{- $telemetryGateway := get .Values "telemetry-gateway" }}
{{- $defaultHostname := tpl "{{ .Release.Name }}-telemetry-gateway" . }}
{{- .Values.telemetryGatewayHost | default $telemetryGateway.fullnameOverride | default $defaultHostname }}
{{- end -}}

{{/*
  Helper: zeta-guard.ns-well-known-subpath
  RFC 9728 well-known subpath for the NS, derived from wellKnownResourceSuffix. Used by
  the nginx location/alias, the pep-well-known-resources ConfigMap key, and the
  pep-proxy volume mount so they stay in sync. Rejects multi-segment values (a
  ConfigMap key / subPath cannot contain '/').
*/}}
{{- define "zeta-guard.ns-well-known-subpath" -}}
{{- $suffix := .Values.notificationService.wellKnownResourceSuffix -}}
{{- $subpath := trimPrefix "/" $suffix -}}
{{- if or (not (hasPrefix "/" $suffix)) (eq $subpath "") (contains "/" $subpath) -}}
{{- fail (printf "notificationService.wellKnownResourceSuffix must be a single leading-slash path segment (e.g. /notification-service); got %q" $suffix) -}}
{{- end -}}
{{- $subpath -}}
{{- end -}}

{{/*
  Helper: zeta-guard.baseLabels
  Minimal shared labels; set name/component/version inline per resource for clarity.
*/}}
{{- define "zeta-guard.baseLabels" -}}
helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}"
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: "{{ .Chart.AppVersion }}"
{{- end }}
app.kubernetes.io/managed-by: "{{ .Release.Service }}"
app.kubernetes.io/part-of: zeta-guard
{{- with .Values.additionalLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "authserver.labels" -}}
{{ include "authserver.selectorLabels" . }}
app.kubernetes.io/component: pdp
app.kubernetes.io/version: "{{ .Values.authserver.image.tag }}"
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "authserver.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: authserver
{{- end }}

{{/*
  Helper: authserver.image
  Builds the full image reference including registry, repository and tag.
  Used by: authserver/authserver-deployment.yaml
*/}}
{{- define "keychainGenerator.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.authserver.dbEnc.keychainGenerator.image.registry -}}
{{- printf "%s%s" $registry .Values.authserver.dbEnc.keychainGenerator.image.repository -}}
{{- if .Values.authserver.dbEnc.keychainGenerator.image.tag }}:{{ .Values.authserver.dbEnc.keychainGenerator.image.tag }}{{ end }}
{{- if .Values.authserver.dbEnc.keychainGenerator.image.digest }}@{{ .Values.authserver.dbEnc.keychainGenerator.image.digest }}{{ end }}
{{- end -}}

{{/*
  Helper: authserver.image
  Builds the full image reference including registry, repository and tag.
  Used by: authserver/authserver-deployment.yaml
*/}}
{{- define "authserver.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.authserver.image.registry -}}
{{- printf "%s%s" $registry .Values.authserver.image.repository -}}
{{- if .Values.authserver.image.tag }}:{{ .Values.authserver.image.tag }}{{ end }}
{{- if .Values.authserver.image.digest }}@{{ .Values.authserver.image.digest }}{{ end }}
{{- end -}}

{{- define "authserver.otel-service-name" -}}
ZETA Guard PDP authorization server
{{- end -}}

{{/*
  Helper: provisioningProcessor.image
  Builds the full image reference including registry, repository and tag.
*/}}
{{- define "provisioningProcessor.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.provisioningProcessor.image.registry -}}
{{- printf "%s%s" $registry .Values.provisioningProcessor.image.repository -}}
{{- if .Values.provisioningProcessor.image.tag }}:{{ .Values.provisioningProcessor.image.tag }}{{ end }}
{{- if .Values.provisioningProcessor.image.digest }}@{{ .Values.provisioningProcessor.image.digest }}{{ end }}
{{- end -}}

{{/*
  Helper: opa.image
  Builds the full image reference including registry, repository and tag.
*/}}
{{- define "opa.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.opa.image.registry -}}
{{- printf "%s%s" $registry .Values.opa.image.repository -}}
{{- if .Values.opa.image.tag }}:{{ .Values.opa.image.tag }}{{ end }}
{{- if .Values.opa.image.digest }}@{{ .Values.opa.image.digest }}{{ end }}
{{- end -}}

{{/*
  Helper: authserver.kcDb
  Resolves the KC_DB value depending on databaseMode.
  Used by: authserver/authserver-deployment.yaml
*/}}
{{- define "authserver.kcDb" -}}
{{- if eq .Values.databaseMode "cloudnative" -}}
postgres
{{- else -}}
{{ .Values.authserverDb.kcDb }}
{{- end -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "opa.labels" -}}
{{ include "opa.selectorLabels" . }}
app.kubernetes.io/component: pdp
{{- with .Values.opa.image.tag }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "opa.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: opa
{{- end }}

{{/*
Common labels for simulation OPA
*/}}
{{- define "opaSimulation.labels" -}}
{{ include "opaSimulation.selectorLabels" . }}
app.kubernetes.io/component: pdp
{{- with .Values.opa.image.tag }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
Selector labels for simulation OPA
*/}}
{{- define "opaSimulation.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: opa-simulation
{{- end }}

{{/*
Common labels
*/}}
{{- define "ingress.labels" -}}
app.kubernetes.io/name: zeta-guard
app.kubernetes.io/component: ingress
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{- define "pep-proxy.image" }}
{{ default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.pepproxy.image.registry }}{{ .Values.pepproxy.image.repository }}
{{- if .Values.pepproxy.image.tag }}:{{ .Values.pepproxy.image.tag }}{{ end }}
{{- if .Values.pepproxy.image.digest }}@{{ .Values.pepproxy.image.digest }}{{ end }}
{{- end }}

{{- define "pep-proxy.otel-service-name" -}}
ZETA Guard PEP HTTP proxy
{{- end -}}

{{/*
Common labels
*/}}
{{- define "pep-proxy.labels" -}}
{{ include "pep-proxy.selectorLabels" . }}
app.kubernetes.io/component: pep
app.kubernetes.io/version: "{{ .Values.pepproxy.image.tag }}"
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pep-proxy.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: pep-proxy
{{- end -}}

{{/*
  Helper: zeta-guard.mergedSecurityContext (internal)
  Renders a `securityContext:` block from a component's values map (.sc) plus every
  key of .defaults the map does not set itself (shallow: a key present in the
  component map wins, even with a null value). Renders `securityContext: {}` if
  both are empty.
*/}}
{{- define "zeta-guard.mergedSecurityContext" -}}
{{- $sc := deepCopy (.sc | default dict) -}}
{{- range $key, $value := .defaults | default dict -}}
{{- if not (hasKey $sc $key) -}}
{{- $_ := set $sc $key $value -}}
{{- end -}}
{{- end -}}
{{- if $sc -}}
securityContext:
  {{- toYaml $sc | nindent 2 }}
{{- else -}}
securityContext: {}
{{- end -}}
{{- end -}}

{{/*
  Helper: zeta-guard.containerSecurityContext
  Container `securityContext:` — the component's map on top of
  .Values.defaultContainerSecurityContext. See that value for why runAsUser is set there.
  Usage: {{- include "zeta-guard.containerSecurityContext" (dict "root" $ "sc" .Values.x.containerSecurityContext) | nindent N }}
*/}}
{{- define "zeta-guard.containerSecurityContext" -}}
{{- include "zeta-guard.mergedSecurityContext" (dict "sc" .sc "defaults" .root.Values.defaultContainerSecurityContext) -}}
{{- end -}}

{{/*
  Helper: zeta-guard.podSecurityContext
  Pod `securityContext:` — the component's map on top of .Values.defaultPodSecurityContext.
  Usage: {{- include "zeta-guard.podSecurityContext" (dict "root" $ "sc" .Values.x.podSecurityContext) | nindent N }}
*/}}
{{- define "zeta-guard.podSecurityContext" -}}
{{- include "zeta-guard.mergedSecurityContext" (dict "sc" .sc "defaults" .root.Values.defaultPodSecurityContext) -}}
{{- end -}}

{{/*
  Helper: zeta-guard.proxyEnvVars
  Renders HTTP/HTTPS/NO/ALL proxy environment variables from a config map.
  Pass a values sub-map that contains httpProxy, httpsProxy, noProxy, allProxy.
  Usage: {{- include "zeta-guard.proxyEnvVars" .Values.someComponent | nindent N }}
*/}}
{{- define "zeta-guard.proxyEnvVars" -}}
{{- with .httpProxy }}
- name: HTTP_PROXY
  value: {{ . | quote }}
- name: http_proxy
  value: {{ . | quote }}
{{- end }}
{{- with .httpsProxy }}
- name: HTTPS_PROXY
  value: {{ . | quote }}
- name: https_proxy
  value: {{ . | quote }}
{{- end }}
{{- with .noProxy }}
- name: NO_PROXY
  value: {{ . | quote }}
- name: no_proxy
  value: {{ . | quote }}
{{- end }}
{{- with .allProxy }}
- name: ALL_PROXY
  value: {{ . | quote }}
- name: all_proxy
  value: {{ . | quote }}
{{- end }}
{{- end -}}

{{/*
Provisioning processor registry-CA wiring, shared by all init containers that run
the provisioning processor (authserver, pep, opa, opa-simulation).
Pass the root context (.) as the argument.

caEnv: PROVISIONING_CONTAINER_REGISTRY_CA_FILE env var (when a Secret or ConfigMap
ref is set), the registry credentials (when registryCredentialsSecretRef is set)
plus any provisioningProcessor.extraEnv.
  Usage: {{- include "zeta-guard.provisioningProcessor.caEnv" . | nindent N }}
*/}}
{{- define "zeta-guard.provisioningProcessor.caEnv" -}}
{{- if or .Values.provisioningProcessor.provisioningContainerCaSecretRef .Values.provisioningProcessor.provisioningContainerCaConfigMapRef }}
- name: PROVISIONING_CONTAINER_REGISTRY_CA_FILE
  value: "/var/registry-ca/ca.crt"
{{- end }}
{{- with .Values.provisioningProcessor.registryCredentialsSecretRef }}
- name: PROVISIONING_CONTAINER_REGISTRY_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .name }}
      key: {{ .usernameKey | default "username" }}
- name: PROVISIONING_CONTAINER_REGISTRY_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .name }}
      key: {{ .tokenKey | default "token" }}
{{- end }}
{{- with .Values.provisioningProcessor.extraEnv }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
caVolumeMounts: registry-ca mount (when a Secret or ConfigMap ref is set) plus any
provisioningProcessor.extraVolumeMounts.
  Usage: {{- include "zeta-guard.provisioningProcessor.caVolumeMounts" . | nindent N }}
*/}}
{{- define "zeta-guard.provisioningProcessor.caVolumeMounts" -}}
{{- if or .Values.provisioningProcessor.provisioningContainerCaSecretRef .Values.provisioningProcessor.provisioningContainerCaConfigMapRef }}
- name: registry-ca
  mountPath: /var/registry-ca
  readOnly: true
{{- end }}
{{- with .Values.provisioningProcessor.extraVolumeMounts }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
caVolumes: registry-ca volume from a Secret or ConfigMap (mutually exclusive,
Secret takes precedence) plus any provisioningProcessor.extraVolumes.
  Usage: {{- include "zeta-guard.provisioningProcessor.caVolumes" . | nindent N }}
*/}}
{{- define "zeta-guard.provisioningProcessor.caVolumes" -}}
{{- if .Values.provisioningProcessor.provisioningContainerCaSecretRef }}
- name: registry-ca
  secret:
    secretName: {{ .Values.provisioningProcessor.provisioningContainerCaSecretRef.name }}
    items:
      - key: {{ .Values.provisioningProcessor.provisioningContainerCaSecretRef.key }}
        path: ca.crt
{{- else if .Values.provisioningProcessor.provisioningContainerCaConfigMapRef }}
- name: registry-ca
  configMap:
    name: {{ .Values.provisioningProcessor.provisioningContainerCaConfigMapRef.name }}
    items:
      - key: {{ .Values.provisioningProcessor.provisioningContainerCaConfigMapRef.key }}
        path: ca.crt
{{- end }}
{{- with .Values.provisioningProcessor.extraVolumes }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
registryCaVolumeMount: read-only registry-ca mount for a *main* container. OPA needs the
registry CA at runtime (not just in the init container) to pull the policy bundle from a
private OCI registry. Unlike caVolumeMounts this deliberately omits
provisioningProcessor.extraVolumeMounts, whose paths are init-container specific.
The registry-ca volume itself is emitted by zeta-guard.provisioningProcessor.caVolumes.
*/}}
{{- define "zeta-guard.provisioningProcessor.registryCaVolumeMount" -}}
{{- if or .Values.provisioningProcessor.provisioningContainerCaSecretRef .Values.provisioningProcessor.provisioningContainerCaConfigMapRef }}
- name: registry-ca
  mountPath: /var/registry-ca
  readOnly: true
{{- end }}
{{- end -}}

{{/*
  Helper: zeta-guard.dnsEgressRule
  Emits the DNS egress rule shared by all egress NetworkPolicies (netpol/*.yaml).
  Driven by `.Values.networkPolicy.dns`:
    - default: namespaceSelector + podSelector (kube-system / k8s-app: kube-dns)
    - OpenShift: openshift-dns / dns.operator.openshift.io/daemonset-dns=default,
      port 5353 (OVN-Kubernetes evaluates egress post-DNAT)
    - `dns.to`: a raw peer list rendered as-is, overriding the selectors
  Include with `nindent 4` as the first entry under `egress:`.
*/}}
{{- define "zeta-guard.dnsEgressRule" -}}
{{- $dns := .Values.networkPolicy.dns -}}
# DNS resolution
- to:
{{- if $dns.to }}
    {{- toYaml $dns.to | nindent 4 }}
{{- else }}
    - namespaceSelector:
        matchLabels:
          {{- toYaml $dns.namespaceSelector.matchLabels | nindent 10 }}
      podSelector:
        matchLabels:
          {{- toYaml $dns.podSelector.matchLabels | nindent 10 }}
{{- end }}
  ports:
    {{- toYaml $dns.ports | nindent 4 }}
{{- end -}}

{{/*
  Helper: zeta-guard.cnpgConnectionBudgetGuard
  Fails the render if authserver.replicaCount × authserver.dbPool.maxSize (+ a reserve for
  CNPG/superuser slots) would exceed the keycloak-db cluster's max_connections — exceeding it
  exhausts the DB (SQLSTATE 53300). Reads max_connections from whichever provisioning path is
  active (the hand-rolled cloudnativePg.* template, or the upstream keycloak-db chart), so the
  guard keeps working regardless of keycloak-db.enabled.
  Include unconditionally wherever databaseMode == "cloudnative" is already checked; produces
  no output on success.
*/}}
{{- define "zeta-guard.cnpgConnectionBudgetGuard" -}}
{{- $reserve := 25 }}
{{- $needed := add (mul (int .Values.authserver.replicaCount) (int .Values.authserver.dbPool.maxSize)) $reserve }}
{{- $keycloakDbEnabled := index .Values "keycloak-db" "enabled" }}
{{- $maxConn := 0 }}
{{- if $keycloakDbEnabled }}
{{- $maxConn = int (index .Values "keycloak-db" "cluster" "postgresql" "parameters" "max_connections") }}
{{- else }}
{{- $maxConn = int .Values.cloudnativePg.parameters.maxConnections }}
{{- end }}
{{- if gt $needed $maxConn }}
{{- fail (printf "zeta-guard connection budget exceeded: authserver.replicaCount (%d) × authserver.dbPool.maxSize (%d) + %d reserve = %d, which exceeds max_connections (%d, from %s). Lower dbPool.maxSize or replicaCount, or raise max_connections accordingly. See docs/how-to_guides/How_to_configure_authserver.md." (int .Values.authserver.replicaCount) (int .Values.authserver.dbPool.maxSize) $reserve $needed $maxConn (ternary "keycloak-db.cluster.postgresql.parameters.max_connections" "cloudnativePg.parameters.maxConnections" $keycloakDbEnabled)) }}
{{- end }}
{{- end -}}

{{/*
  Helper: authserver.dbUrl
  Renders the authserver JDBC URL for the active databaseMode, with
  authserver.db.urlProperties appended as query parameters.

  This is where the pgjdbc driver settings live (socketTimeout, tcpKeepAlive). They cannot
  be passed as QUARKUS_DATASOURCE_JDBC_ADDITIONAL_JDBC_PROPERTIES_* environment variables:
  that is a Map property, and an env var name cannot carry the camelCase key — it would
  arrive as "sockettimeout" and pgjdbc would silently ignore it. In the URL the case
  survives, and pgjdbc gives URL values priority over connection properties anyway
  (Driver.parseURL: "priority 1 - URL values").

  Deliberately NOT KC_DB_URL_PROPERTIES: Keycloak ignores that option whenever db-url is
  set (DatabaseOptions.DB_URL_PROPERTIES), which it always is here.

  A JDBC URL is an opaque URI, so urlParse leaves .host/.path empty and puts everything
  after "jdbc:" into .opaque — but it does split off an existing query, and urlJoin puts
  the pieces back together unchanged. Hence the existing query is merged rather than
  replaced: setting .query outright would silently drop it.

  Values are urlquery-escaped; pgjdbc decodes them again (URLCoder.decode -> URLDecoder).
  Pairs are sorted so repeated renders are byte-stable — Go map iteration order is
  randomised, and an unstable env value would roll the Deployment on every helm upgrade.
*/}}
{{- define "authserver.dbUrl" -}}
{{- $base := ternary .Values.cloudnativeDbUrl .Values.authserverDb.kcDbUrl (eq .Values.databaseMode "cloudnative") -}}
{{- $props := (.Values.authserver.db).urlProperties | default dict -}}
{{- if not $props -}}
{{- $base -}}
{{- else -}}
{{- range $forbidden := list "connectTimeout" "targetServerType" -}}
{{- if hasKey $props $forbidden -}}
{{- fail (printf "authserver.db.urlProperties.%s is not allowed: Keycloak substring-matches the JDBC URL and stops injecting its own default (db-connect-timeout=10s, db-postgres-target-server-type=primary) as soon as either name appears there. Use --db-connect-timeout for the former and leave the latter at Keycloak's default." $forbidden) -}}
{{- end -}}
{{- end -}}
{{- $pairs := list -}}
{{- range $k, $v := $props -}}
{{- $pairs = append $pairs (printf "%s=%s" (urlquery $k) (urlquery (toString $v))) -}}
{{- end -}}
{{- $url := urlParse $base -}}
{{- $query := join "&" (sortAlpha $pairs) -}}
{{- if $url.query -}}{{- $query = printf "%s&%s" $url.query $query -}}{{- end -}}
{{- $_ := set $url "query" $query -}}
{{- urlJoin $url -}}
{{- end -}}
{{- end -}}

{{/*
  Helper: zeta-guard.imageReference
  Builds an image reference from a {repository, tag, digest} dict, preferring
  the immutable digest when set (repository@digest) over the mutable tag
  (repository:tag) — same convention as telemetry-gateway.image above and
  the vendored opentelemetry-collector/prometheus-community charts' own
  image-reference logic, for our own (non-vendored) resources.
*/}}
{{- define "zeta-guard.imageReference" -}}
{{- if .digest -}}
{{- printf "%s@%s" .repository .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
{{- end -}}

{{/*
  Selector labels for the kpi-metrics-helper CronJob's pods (ADR 0001).
*/}}
{{- define "kpiMetricsHelper.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: kpi-metrics-helper
{{- end }}

{{/*
  Common labels for the kpi-metrics-helper CronJob.
*/}}
{{- define "kpiMetricsHelper.labels" -}}
{{ include "kpiMetricsHelper.selectorLabels" . }}
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
  Selector labels matching kpiPrometheus's server pod (ADR 0001) — derived
  from prometheus-community/prometheus's own prometheus.common.matchLabels/
  prometheus.server.matchLabels helpers (app.kubernetes.io/name resolves to
  kpiPrometheus's `nameOverride` ("kpi-prometheus" — the "kpiPrometheus" alias
  itself is camelCase, an invalid Kubernetes label/name component in some of
  the resources it would otherwise flow into, see kpiPrometheus.server.
  fullnameOverride in values.yaml for the fuller explanation);
  app.kubernetes.io/component to .Values.server.name, the chart's own
  "server" default). Used both by kpiPrometheus's own NetworkPolicy
  podSelector and by anything that needs to reach it as an egress peer (see
  kpi-metrics-helper-cronjob-netpol.yaml).
*/}}
{{- define "kpiPrometheus.selectorLabels" -}}
app.kubernetes.io/name: kpi-prometheus
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end }}

{{/*
  Common labels for kpiPrometheus-adjacent resources rendered by this chart
  (its NetworkPolicy) — not for kpiPrometheus's own resources, which come
  from the vendored dependency and use its own label helpers.
*/}}
{{- define "kpiPrometheus.labels" -}}
{{ include "kpiPrometheus.selectorLabels" . }}
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
  Selector labels matching telemetry-gateway's pods — derived from the
  vendored opentelemetry-collector chart's own opentelemetry-collector.
  selectorLabels helper (app.kubernetes.io/name resolves to .Chart.Name).
  IMPORTANT: telemetry-gateway is a Chart.yaml `alias:` of the
  opentelemetry-collector dependency (charts/zeta-guard/Chart.yaml) — Helm
  rewrites .Chart.Name to the alias for the aliased instance, so the
  rendered label is "telemetry-gateway", NOT the literal chart name
  "opentelemetry-collector". Verified against an actual `helm template`
  render (charts/zeta-guard/charts/telemetry-gateway/templates/
  deployment.yaml's pod template labels) — do not "correct" this back to
  "opentelemetry-collector" without re-checking a real render first.

  This also happens to be what keeps this selector from also matching
  charts/test-monitoring-service's own otel-collector pod (its
  opentelemetry-demo dependency vendors the same opentelemetry-collector
  chart, same pinned version — see charts/zeta-guard/Chart.yaml's comment —
  but un-aliased, so its app.kubernetes.io/name renders as the literal
  "opentelemetry-collector"). Both are subcharts of the same umbrella
  release (same app.kubernetes.io/instance), so name is what disambiguates
  them, not instance.

  app.kubernetes.io/part-of below is defense-in-depth on top of that,
  sourced from telemetry-gateway.podLabels (values.yaml) — deliberately not
  telemetry-gateway.additionalLabels, which lands on the Deployment's own
  metadata only, not the pod template that NetworkPolicy podSelectors
  actually match against.

  Used by telemetry-gateway's own NetworkPolicy podSelector and by anything
  that needs to reach it as an egress peer (authserver-netpol.yaml,
  opa-netpol.yaml, opa-simulation-netpol.yaml, pep-proxy-netpol.yaml,
  kpi-metrics-helper-cronjob-netpol.yaml).
*/}}
{{- define "telemetryGateway.selectorLabels" -}}
app.kubernetes.io/name: telemetry-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: zeta-guard
{{- end }}
