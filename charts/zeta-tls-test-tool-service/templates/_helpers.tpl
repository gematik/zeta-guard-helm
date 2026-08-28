{{/*
Expand the name of the chart.
*/}}
{{- define "zeta-tls-test-tool-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "zeta-tls-test-tool-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "zeta-tls-test-tool-service.name" . }}
{{- end }}
