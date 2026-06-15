{{/*
  Helper: infinispan.image
  Builds the full image reference including registry, repository and tag.
  Used by: infinispan-deployment.yaml
*/}}
{{- define "infinispan.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.global.infinispanExternal.registry_name) .Values.global.infinispanExternal.image.registry -}}
{{- printf "%s%s" $registry .Values.global.infinispanExternal.image.repository -}}
{{- if .Values.global.infinispanExternal.image.tag }}:{{ .Values.global.infinispanExternal.image.tag }}{{ end }}
{{- if .Values.global.infinispanExternal.digest }}@{{ .Values.global.infinispanExternal.image.digest }}{{ end }}
{{- end -}}