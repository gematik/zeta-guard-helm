{{- define "telemetryGateway.hostname" -}}
{{- $telemetryGateway := get .Values "telemetry-gateway" }}
{{- $defaultHostname := tpl "telemetry-gateway-{{ .Release.Name }}" . }}
{{- $telemetryGateway.fullnameOverride | default $defaultHostname }}
{{- end -}}

{{/* The full resource name of the identity provider. Required when exchanging
     an external credential for a Google access token.
     See https://docs.cloud.google.com/iam/docs/reference/sts/rest/v1/TopLevel/token#request-body */}}
{{ define "gematik.full-resource-name-of-identity-provider" -}}
{{ list
    "//iam.googleapis.com"
    "projects" .Values.gematik.workloadIdentityFederation.projectNumber
    "locations" "global"
    "workloadIdentityPools" .Values.gematik.workloadIdentityFederation.poolId
    "providers" .Values.gematik.workloadIdentityFederation.workloadIdentityProvider
   | join "/" }}
{{- end }}

{{/* Audience for Kubernetes service account tokens recommended by Google Workload Identity Federation
   * See https://docs.cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation#provider-audience
   */}}
{{ define "gematik.token-audience" -}}
{{ list
    "https://iam.googleapis.com"
    "projects" .Values.gematik.workloadIdentityFederation.projectNumber
    "locations" "global"
    "workloadIdentityPools" .Values.gematik.workloadIdentityFederation.poolId
    "providers" .Values.gematik.workloadIdentityFederation.workloadIdentityProvider
   | join "/" }}
{{- end }}
