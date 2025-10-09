{{- /* vim: set ft=helm: */ -}}
{{- define "configmap" -}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    {{- if .app }}
    app: "{{ .app }}"
    {{- end }}
  name: "{{ .name }}"
data:
  {{ .filename | default .name | quote }}: |
{{ .source | indent 4 }}
{{ end }}
