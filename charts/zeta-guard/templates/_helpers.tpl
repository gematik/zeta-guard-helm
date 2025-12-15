{{- define "telemetryGateway.hostname" -}}
{{- $telemetryGateway := get .Values "telemetry-gateway" }}
{{- $defaultHostname := tpl "{{ .Release.Name }}-telemetry-gateway" . }}
{{- $telemetryGateway.fullnameOverride | default $defaultHostname }}
{{- end -}}
