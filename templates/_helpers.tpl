{{/*
  Creates an hostAliases block for pods to add explicit hostname resolution 
*/}}
{{- define "global.tigerDNSRedirect" }}
      hostAliases:
        - ip: {{ .Values.global.dns.tigerStaticClusterIP }}
          hostnames:
        {{- range $redirect := .Values.global.dns.redirects }}
            - {{ $redirect.fqdn }}
        {{- end }}
{{- end }}

{{/*
  Creates an hostAliases list entry for pods to add explicit hostname resolution
*/}}
{{- define "global.tigerDNSRedirectEntryOnly" }}
        - ip: {{ .Values.global.dns.tigerStaticClusterIP }}
          hostnames:
        {{- range $redirect := .Values.global.dns.redirects }}
            - {{ $redirect.fqdn | quote }}
        {{- end }}
{{- end }}
