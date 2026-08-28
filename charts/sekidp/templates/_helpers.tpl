{{/*
  Helper: sekidp.baseLabels
  Recommended labels shared by all sekidp resources.
*/}}
{{- define "sekidp.baseLabels" -}}
helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}"
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: "{{ .Chart.AppVersion }}"
{{- end }}
app.kubernetes.io/managed-by: "{{ .Release.Service }}"
app.kubernetes.io/part-of: sekidp
{{- end -}}

{{/*
Common labels for gsi-server
*/}}
{{- define "sekidp-gsi-server.labels" -}}
{{ include "sekidp-gsi-server.selectorLabels" . }}
app.kubernetes.io/component: sekidp-gsi-server
{{ include "sekidp.baseLabels" . }}
{{- end -}}

{{/*
Selector labels for gsi-server
*/}}
{{- define "sekidp-gsi-server.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: sekidp-gsi-server
{{- end -}}

{{/*
Common labels for gsi-fedmaster
*/}}
{{- define "sekidp-fedmaster.labels" -}}
{{ include "sekidp-fedmaster.selectorLabels" . }}
app.kubernetes.io/component: sekidp-fedmaster
{{ include "sekidp.baseLabels" . }}
{{- end -}}

{{/*
Selector labels for gsi-fedmaster
*/}}
{{- define "sekidp-fedmaster.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: sekidp-fedmaster
{{- end -}}

{{/*
  Helper: sekidp-gsi-server.image
  Builds the full gsi-server image reference including registry, repository, tag and digest.
*/}}
{{- define "sekidp-gsi-server.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.gsiServer.image.registry -}}
{{- printf "%s%s" $registry .Values.gsiServer.image.repository -}}
{{- if .Values.gsiServer.image.tag }}:{{ .Values.gsiServer.image.tag }}{{ end }}
{{- if .Values.gsiServer.image.digest }}@{{ .Values.gsiServer.image.digest }}{{ end }}
{{- end -}}

{{/*
  Helper: sekidp-fedmaster.image
  Builds the full gsi-fedmaster image reference including registry, repository, tag and digest.
*/}}
{{- define "sekidp-fedmaster.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.fedmaster.image.registry -}}
{{- printf "%s%s" $registry .Values.fedmaster.image.repository -}}
{{- if .Values.fedmaster.image.tag }}:{{ .Values.fedmaster.image.tag }}{{ end }}
{{- if .Values.fedmaster.image.digest }}@{{ .Values.fedmaster.image.digest }}{{ end }}
{{- end -}}
