{{ define "opa.policyRego" -}}
{{ required "zeta-guard.opaPolicy.policyRego must be set (Rego v1 policy)" .Values.opaPolicy.policyRego }}
{{- end }}

{{ define "opa.opentelemetryGatewayService" -}}
opentelemetrygateway:
  url: http://{{ include "telemetryGateway.hostname" . }}:49152
  allow_insecure_tls: true
{{ end }}

{{/*
  Never render an empty 'service:' for decision_logs or status: OPA fills an empty
  service in with the FIRST configured service (v1/plugins/{logs,status}/plugin.go —
  "for backwards compatibility"), which in bundle mode is the policy registry. OPA
  then POSTs its status updates to <registry>/status/ once per bundle poll and the
  registry answers 403 Forbidden. The fallback only applies when no local sink is
  configured, so a block with console/prometheus off and no service must be dropped
  entirely rather than emitted with an empty service.
*/}}
{{ define "opa.common_config" -}}
{{- $gateway := .Values.telemetryGatewayEnabled -}}
{{- if or $gateway .Values.opa.logDecisions -}}
decision_logs:
  console: {{ .Values.opa.logDecisions | ternary "true" "false" }}
  {{- if $gateway }}
  service: opentelemetrygateway
  {{- end }}
{{- end }}
{{- if .Values.opaDistributedTracingEnabled }}
distributed_tracing:
  type: grpc
  address: {{ include "telemetryGateway.hostname" . }}:4317
  service_name: "ZETA Guard PDP policy engine"
{{- end }}
{{- if or $gateway .Values.opa.logStatusUpdates .Values.opaStatusPrometheus }}
status:
  console: {{ .Values.opa.logStatusUpdates | ternary "true" "false" }}
  prometheus: {{ .Values.opaStatusPrometheus | ternary "true" "false" }}
  {{- if $gateway }}
  service: opentelemetrygateway
  {{- end }}
{{- end }}
{{ end }}

{{/* configuration for OPA without bundles */}}
{{ define "opa.configYaml" -}}
{{ include "opa.common_config" . }}
{{- if .Values.telemetryGatewayEnabled }}
services:
  {{ include "opa.opentelemetryGatewayService" .  | nindent 2 }}
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

{{/*
  Helper: opa.simVerification
  Effective bundle verification settings for the simulation instance, as JSON.
  Uses opa.simulation.bundle.verification if non-empty; otherwise the shared opa.bundle.verification.
*/}}
{{ define "opa.simVerification" -}}
{{- (.Values.opa.simulation.bundle).verification | default .Values.opa.bundle.verification | toJson -}}
{{- end }}

{{/* configuration for OPA with bundles */}}
{{ define "opa.bundleConfigYaml" }}
{{- /* Support both direct call (.) and parameterized call (dict "ctx" . "bundleResource" "..." "verification" <dict>). */ -}}
{{- $ctx := .ctx | default . }}
{{- $bundleResource := .bundleResource | default $ctx.Values.opa.bundle.resource }}
{{- $token := "" }}
{{- $wif := $ctx.Values.opa.workloadIdentityFederation }}
{{- $useWif := (and $wif $wif.enabled) | default false }}
{{- $secretRef := $ctx.Values.opa.bundle.credentials.secretRef }}
{{- $useSecret := (and (not $useWif) $secretRef $secretRef.name) }}
{{- $pp := $ctx.Values.provisioningProcessor }}
{{- $useRegistryCa := or $pp.provisioningContainerCaSecretRef $pp.provisioningContainerCaConfigMapRef }}

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
    {{- if $useRegistryCa }}
    tls:
      # CA of the bundle registry, mounted from
      # provisioningProcessor.provisioningContainerCaSecretRef / ...CaConfigMapRef.
      ca_cert: "/var/registry-ca/ca.crt"
      # append the image's system CA pool, so a publicly trusted registry keeps working
      system_ca_required: true
    {{- end }}
bundles:
  authz:
    service: {{ $ctx.Values.opa.bundle.serviceName | quote }}
    resource: {{ required "opa.bundle.resource is required when bundle.enabled=true" $bundleResource | quote }}
    persist: true
    polling:
      min_delay_seconds: {{ $ctx.Values.opa.bundle.polling.min_delay_seconds }}
      max_delay_seconds: {{ $ctx.Values.opa.bundle.polling.max_delay_seconds }}
    {{- $verif := .verification | default $ctx.Values.opa.bundle.verification }}
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

{{/*
  OPA configuration *fragment* for the simulation instance — NOT a complete config.

  The simulation config is built in opa-policy-configmap.yaml from the very same
  "opa.bundleConfigYaml" helper as the active instance (only bundle resource and
  verification are parameterised); this fragment is then merged over it with
  mergeOverwrite. It therefore only carries what actually differs: the telemetry
  receiver service and the decision-log / status / tracing names pointing at it.
  Without a telemetry-gateway it collapses to the tracing service name (or to
  nothing at all) — see the note on "opa.common_config" for why it must not fall
  back to an empty 'service:'.
*/}}
{{ define "opa-simulation.config" -}}
{{ $serviceName := "opa_receiver_for_simulation" -}}
{{- if .Values.telemetryGatewayEnabled }}
decision_logs:
  service: {{ $serviceName }}
services:
  {{ $serviceName }}:
    url: http://{{ include "telemetryGateway.hostname" . }}:49153
    allow_insecure_tls: true
status:
  service: {{ $serviceName }}
{{- end }}
{{- if .Values.opaDistributedTracingEnabled }}
distributed_tracing:
  service_name: "ZETA Guard PDP policy engine (simulation)"
{{- end }}
{{- end }}
