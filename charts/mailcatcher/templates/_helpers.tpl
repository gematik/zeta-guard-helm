{{/*
  Helper: mailcatcher.baseLabels
  Recommended labels shared by all mailcatcher resources.
*/}}
{{- define "mailcatcher.baseLabels" -}}
helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}"
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: "{{ .Chart.AppVersion }}"
{{- end }}
app.kubernetes.io/managed-by: "{{ .Release.Service }}"
app.kubernetes.io/part-of: mailcatcher
{{- end -}}

{{/*
Common labels for the mailcatcher app
*/}}
{{- define "mailcatcher.labels" -}}
{{ include "mailcatcher.selectorLabels" . }}
app.kubernetes.io/component: mailcatcher
{{ include "mailcatcher.baseLabels" . }}
{{- end -}}

{{/*
Selector labels for the mailcatcher app
*/}}
{{- define "mailcatcher.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: mailcatcher
{{- end -}}

{{/*
  Helper: mailcatcher.image
  Builds the image reference including tag and digest. Public third-party
  image — pulled directly (repository[:tag][@digest]), NOT prefixed with
  global.registry_host, unless image.registry fully overrides it.
*/}}
{{- define "mailcatcher.image" -}}
{{- if .Values.image.registry -}}
{{- printf "%s%s" .Values.image.registry .Values.image.repository -}}
{{- else -}}
{{- .Values.image.repository -}}
{{- end -}}
{{- if .Values.image.tag }}:{{ .Values.image.tag }}{{ end }}
{{- if .Values.image.digest }}@{{ .Values.image.digest }}{{ end }}
{{- end -}}
