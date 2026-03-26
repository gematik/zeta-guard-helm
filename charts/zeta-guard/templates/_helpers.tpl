{{/*
  Helper: telemetryGateway.hostname
  Used by:
    - pep/_pep-nginx-conf.tpl (OTLP exporter endpoint)
    - opa/_opa.tpl (OTLP address)
    - authserver/authserver-deployment.yaml (OTLP endpoint env var)
*/}}
{{- define "telemetryGateway.hostname" -}}
{{- $telemetryGateway := get .Values "telemetry-gateway" }}
{{- $defaultHostname := tpl "{{ .Release.Name }}-telemetry-gateway" . }}
{{- $telemetryGateway.fullnameOverride | default $defaultHostname }}
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
{{- define "authserver.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.authserver.image.registry -}}
{{- printf "%s%s" $registry .Values.authserver.image.repository -}}
{{- if .Values.authserver.image.tag }}:{{ .Values.authserver.image.tag }}{{ end }}
{{- if .Values.authserver.image.digest }}@{{ .Values.authserver.image.digest }}{{ end }}
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
{{- end }}
