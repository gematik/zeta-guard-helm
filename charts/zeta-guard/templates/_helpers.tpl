{{/*
  Helper: telemetryGateway.hostname
  Used by:
    - pep/_pep-nginx-conf.tpl (OTLP exporter endpoint)
    - opa/_opa.tpl (OTLP address)
    - authserver/authserver-deployment.yaml (OTLP endpoint env var)
*/}}
{{- define "telemetryGateway.hostname" -}}
{{- $telemetryGateway := get .Values "telemetry-gateway" }}
{{- $defaultHostname := tpl "telemetry-gateway-{{ .Release.Name }}" . }}
{{- $telemetryGateway.fullnameOverride | default $defaultHostname }}
{{- end -}}

{{/*
  Helper: zeta-guard.baseLabels
  Minimal shared labels; set name/component/version inline per resource for clarity.
*/}}
{{- define "zeta-guard.baseLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/part-of: zeta-guard
{{- end -}}

{{/*
  Helper: authserver.image
  Builds the full image reference including registry, repository and tag.
  Used by: authserver/authserver-deployment.yaml
*/}}
{{- define "authserver.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.authserver.image.registry -}}
{{- printf "%s%s:%s" $registry .Values.authserver.image.repository .Values.authserver.image.tag -}}
{{- end -}}

{{/*
  Helper: authserver.kcDb
  Resolves the KC_DB value depending on databaseMode.
  Used by: authserver/authserver-deployment.yaml
*/}}
{{- define "authserver.kcDb" -}}
{{- if or (eq .Values.databaseMode "operator") (eq .Values.databaseMode "bitnami") -}}
postgres
{{- else -}}
{{ .Values.authserverDb.kcDb }}
{{- end -}}
{{- end -}}
