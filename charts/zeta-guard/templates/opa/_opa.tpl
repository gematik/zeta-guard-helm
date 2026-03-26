{{ define "opa.policyRego" -}}
{{ required "zeta-guard.opaPolicy.policyRego must be set (Rego v1 policy)" .Values.opaPolicy.policyRego }}
{{- end }}

{{ define "opa.configYaml" }}
{{- if .Values.opaPolicy.logDecisions }}
decision_logs:
  console: true

distributed_tracing:
{{- if .Values.opaDistributedTracingEnabled }}
  type: grpc
{{- end }}
  address: {{ include "telemetryGateway.hostname" . }}:4317

status:
  prometheus: {{ .Values.opaStatusPrometheus }}
{{- end }}
{{- end }}

{{/*
  Helper: opa.simBundleResource
  Derives the simulation bundle resource string.
  Uses opa.simulation.bundle.resource if explicitly set; otherwise appends "-sim" to the active resource.
  Only call this when opa.bundle.enabled=true.
*/}}
{{ define "opa.simBundleResource" -}}
{{- if .Values.opa.simulation.bundle.resource -}}
  {{- .Values.opa.simulation.bundle.resource -}}
{{- else -}}
  {{- $active := required "opa.bundle.resource is required when bundle.enabled=true" .Values.opa.bundle.resource -}}
  {{- printf "%s-sim" $active -}}
{{- end -}}
{{- end }}

{{ define "opa.bundleConfigYaml" }}
{{- /* Support both direct call (.) and parameterized call (dict "ctx" . "bundleResource" "..."). */ -}}
{{- $ctx := .ctx | default . }}
{{- $bundleResource := .bundleResource | default $ctx.Values.opa.bundle.resource }}
{{- $token := "" }}
{{- $wif := $ctx.Values.opa.workloadIdentityFederation }}
{{- $useWif := (and $wif $wif.enabled) | default false }}
{{- $secretRef := $ctx.Values.opa.bundle.credentials.secretRef }}
{{- $useSecret := (and (not $useWif) $secretRef $secretRef.name) }}

{{- if $useSecret }}
  {{- with (lookup "v1" "Secret" $ctx.Release.Namespace $secretRef.name) }}
    {{- with .data }}
      {{- with index . "token" }}{{- $token = b64dec . }}{{- end }}
    {{- end }}
  {{- end }}
{{- end }}

services:
  {{ required "opa.bundle.serviceName is required when bundle.enabled=true" $ctx.Values.opa.bundle.serviceName }}:
    {{- if $ctx.Values.opa.bundle.url }}
    url: {{ $ctx.Values.opa.bundle.url | quote }}
    {{- end }}
    type: oci
    {{- if $useSecret }}
      {{- if $token }}
    credentials:
      bearer:
        scheme: "Basic"
        token: {{ $token | quote }}
      {{- end }}
    {{- else if $useWif }}
    credentials:
      bearer:
        # GAR erwartet Basic mit Benutzer "oauth2accesstoken" und Passwort=<ACCESS_TOKEN>.
        # OPA setzt den Authorization-Header basierend auf scheme/token_path.
        # Datei-Inhalt muss daher "oauth2accesstoken:<ACCESS_TOKEN>" sein.
        scheme: "Basic"
        token_path: "/var/run/secrets/gcp/token"
    {{- end }}

bundles:
  authz:
    service: {{ $ctx.Values.opa.bundle.serviceName | quote }}
    resource: {{ required "opa.bundle.resource is required when bundle.enabled=true" $bundleResource | quote }}
    persist: true
    polling:
      min_delay_seconds: {{ $ctx.Values.opa.bundle.polling.min_delay_seconds }}
      max_delay_seconds: {{ $ctx.Values.opa.bundle.polling.max_delay_seconds }}
    {{- $verif := $ctx.Values.opa.bundle.verification }}
    {{- if and $verif.enabled $verif.keyId }}
    signing:
      keyid: {{ $verif.keyId | quote }}
      {{- if $verif.scope }}
      scope: {{ $verif.scope | quote }}
      {{- end }}
    {{- end }}
{{- if and $verif.enabled $verif.keyId $verif.publicKey }}
keys:
  {{ $verif.keyId }}:
    algorithm: {{ default "ES256" $verif.algorithm }}
    key: |
{{ $verif.publicKey | nindent 6 }}
{{- end }}

{{- if $ctx.Values.opaPolicy.logDecisions }}
decision_logs:
  console: true
{{- end }}

persistence_directory: /var/opa

status:
  prometheus: {{ $ctx.Values.opaStatusPrometheus }}
{{- end -}}
