{{/* Guard against the pre-1.3.0 flat gematik values. Splitting the single
     service account into tiSim/tiSiem replaced them, and they were
     announced as replaced in the release notes — but nothing reads them any more,
     so leaving one set would silently renew no token at all. Fail loudly instead
     of letting the CronJob run with an empty SERVICE_ACCOUNT / AUDIENCE. */}}
{{- define "gematik.assertNoLegacyValues" -}}
{{- if or .Values.gematik.idTokenAudience .Values.gematik.serviceAccountEmailAddress }}
{{- fail "gematik.idTokenAudience / gematik.serviceAccountEmailAddress were replaced by gematik.tiSim.* and gematik.tiSiem.* — set the values per stream (both CronJobs need their own service account and audience)" }}
{{- end }}
{{- end }}

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

