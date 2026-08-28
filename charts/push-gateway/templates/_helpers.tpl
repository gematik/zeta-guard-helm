{{/*
  Helper: push-gateway.baseLabels
  Recommended labels shared by all push-gateway resources.
*/}}
{{- define "push-gateway.baseLabels" -}}
helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}"
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: "{{ .Chart.AppVersion }}"
{{- end }}
app.kubernetes.io/managed-by: "{{ .Release.Service }}"
app.kubernetes.io/part-of: push-gateway
{{- end -}}

{{/*
Common labels for the push-gateway app
*/}}
{{- define "push-gateway.labels" -}}
{{ include "push-gateway.selectorLabels" . }}
app.kubernetes.io/component: push-gateway
{{ include "push-gateway.baseLabels" . }}
{{- end -}}

{{/*
Selector labels for the push-gateway app
*/}}
{{- define "push-gateway.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: push-gateway
{{- end -}}

{{/*
Common labels for the bundled Artemis broker
*/}}
{{- define "push-gateway-artemis.labels" -}}
{{ include "push-gateway-artemis.selectorLabels" . }}
app.kubernetes.io/component: push-gateway-artemis
{{ include "push-gateway.baseLabels" . }}
{{- end -}}

{{/*
Selector labels for the bundled Artemis broker
*/}}
{{- define "push-gateway-artemis.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: push-gateway-artemis
{{- end -}}

{{/*
Common labels for the bundled Postgres instance
*/}}
{{- define "push-gateway-postgres.labels" -}}
{{ include "push-gateway-postgres.selectorLabels" . }}
app.kubernetes.io/component: push-gateway-postgres
{{ include "push-gateway.baseLabels" . }}
{{- end -}}

{{/*
Selector labels for the bundled Postgres instance
*/}}
{{- define "push-gateway-postgres.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: push-gateway-postgres
{{- end -}}

{{/*
  Helper: push-gateway.otelResourceAttributes
  Renders a map into the OTEL_RESOURCE_ATTRIBUTES comma-separated key=value format.
*/}}
{{- define "push-gateway.otelResourceAttributes" -}}
{{- $attributes := list -}}
{{- range $key, $value := . -}}
{{- $attributes = append $attributes (printf "%s=%v" $key $value) -}}
{{- end -}}
{{- join "," $attributes -}}
{{- end -}}

{{/*
  Helper: push-gateway.image
  Builds the full image reference including registry, repository, tag and digest.
*/}}
{{- define "push-gateway.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.image.registry -}}
{{- printf "%s%s" $registry .Values.image.repository -}}
{{- if .Values.image.tag }}:{{ .Values.image.tag }}{{ end }}
{{- if .Values.image.digest }}@{{ .Values.image.digest }}{{ end }}
{{- end -}}

{{/*
  Helper: push-gateway-artemis.image
  Builds the Artemis image reference including tag and digest.
*/}}
{{- define "push-gateway-artemis.image" -}}
{{- .Values.artemis.image.repository -}}
{{- if .Values.artemis.image.tag }}:{{ .Values.artemis.image.tag }}{{ end }}
{{- if .Values.artemis.image.digest }}@{{ .Values.artemis.image.digest }}{{ end }}
{{- end -}}

{{/*
  Helper: push-gateway-postgres.image
  Builds the Postgres image reference including tag and digest.
*/}}
{{- define "push-gateway-postgres.image" -}}
{{- .Values.postgres.image.repository -}}
{{- if .Values.postgres.image.tag }}:{{ .Values.postgres.image.tag }}{{ end }}
{{- if .Values.postgres.image.digest }}@{{ .Values.postgres.image.digest }}{{ end }}
{{- end -}}
