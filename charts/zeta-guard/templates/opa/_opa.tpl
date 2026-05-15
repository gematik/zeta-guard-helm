{{ define "opa.policyRego" -}}
{{ required "zeta-guard.opaPolicy.policyRego must be set (Rego v1 policy)" .Values.opaPolicy.policyRego }}
{{- end }}

{{ define "opa.opentelemetryGatewayService" -}}
opentelemetrygateway:
  url: http://{{ include "telemetryGateway.hostname" . }}:49152
  allow_insecure_tls: true
{{ end }}

{{ define "opa.common_config" -}}
decision_logs:
  console: {{ .Values.opa.logDecisions | ternary "true" "false" }}
  service: {{ .Values.telemetryGatewayEnabled | ternary "opentelemetrygateway" "" }}
{{- if .Values.opaDistributedTracingEnabled }}
distributed_tracing:
  type: grpc
  address: {{ include "telemetryGateway.hostname" . }}:4317
  service_name: "ZETA Guard PDP policy engine"
  service_version: "{{ .Values.opa.image.tag }}"
{{- end }}
status:
  console: {{ .Values.opa.logStatusUpdates | ternary "true" "false" }}
  service: {{ .Values.telemetryGatewayEnabled | ternary "opentelemetrygateway" "" }}
  prometheus: {{ .Values.opaStatusPrometheus | ternary "true" "false" }}
{{ end }}

{{/* configuration for OPA without bundles */}}
{{ define "opa.configYaml" -}}
{{ include "opa.common_config" . }}
services:
  {{ include "opa.opentelemetryGatewayService" .  | nindent 2 }}
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

{{/* configuration for OPA with bundles */}}
{{ define "opa.bundleConfigYaml" }}
{{- /* Support both direct call (.) and parameterized call (dict "ctx" . "bundleResource" "..."). */ -}}
{{- $ctx := .ctx | default . }}
{{- $bundleResource := .bundleResource | default $ctx.Values.opa.bundle.resource }}
{{- $token := "" }}
{{- $wif := $ctx.Values.opa.workloadIdentityFederation }}
{{- $useWif := (and $wif $wif.enabled) | default false }}
{{- $secretRef := $ctx.Values.opa.bundle.credentials.secretRef }}
{{- $useSecret := (and (not $useWif) $secretRef $secretRef.name) }}

{{- include "opa.common_config" $ctx -}}

services:
  {{- if $ctx.Values.telemetryGatewayEnabled }}
  {{- include "opa.opentelemetryGatewayService" $ctx | nindent 2 -}}
  {{- end }}
  {{ required "opa.bundle.serviceName is required when bundle.enabled=true" $ctx.Values.opa.bundle.serviceName }}:
    {{- if $ctx.Values.opa.bundle.url }}
    url: {{ $ctx.Values.opa.bundle.url | quote }}
    {{- end }}
    type: oci
    {{- if $useSecret }}
    credentials:
      bearer:
        scheme: "Basic"
        token: "${CREDENTIAL_TOKEN}"
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
{{- if and $verif.enabled $verif.keyId }}
keys:
  {{ $verif.keyId }}:
    algorithm: {{ default "ES256" $verif.algorithm }}
    {{/* 'key' will be set via --set-file */}}
{{- end }}

persistence_directory: /var/opa
{{- end -}}

{{/* OPA configuration fragment used to override common configuration */}}
{{ define "opa-simulation.config" -}}
{{ $serviceName := "opa_receiver_for_simulation" -}}
decision_logs:
  service: {{ .Values.telemetryGatewayEnabled | ternary $serviceName "" }}
{{- if .Values.opaDistributedTracingEnabled }}
distributed_tracing:
  service_name: "ZETA Guard PDP policy engine (simulation)"
{{- end }}
services:
  {{ $serviceName }}:
    url: http://{{ include "telemetryGateway.hostname" . }}:49153
    allow_insecure_tls: true
status:
  service: {{ .Values.telemetryGatewayEnabled | ternary $serviceName "" }}
{{- end }}
