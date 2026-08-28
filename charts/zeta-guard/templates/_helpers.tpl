{{/*
  Helper: telemetryGateway.hostname
  Resolves the hostname that every telemetry stream is sent to. Used by:
    - pep/_pep-nginx-conf.tpl (OTLP exporter endpoint + syslog error_log/access_log)
    - opa/_opa.tpl (OTLP address)
    - authserver/authserver-deployment.yaml (OTLP endpoint env var)
  This always resolves to the telemetry-gateway itself — the values below change only
  the ADDRESS it is reached under, never the destination (its redaction and
  ti_sim/ti_siem filters must not be bypassed).
  Precedence:
    1. .Values.telemetryGatewayHost — address override for the telemetry-gateway,
       e.g. the FQDN when the bare service name does not resolve in the cluster.
    2. telemetry-gateway.fullnameOverride — name of the bundled collector subchart.
    3. {{ .Release.Name }}-telemetry-gateway — default in-namespace service name.
*/}}
{{- define "telemetryGateway.hostname" -}}
{{- $telemetryGateway := get .Values "telemetry-gateway" }}
{{- $defaultHostname := tpl "{{ .Release.Name }}-telemetry-gateway" . }}
{{- .Values.telemetryGatewayHost | default $telemetryGateway.fullnameOverride | default $defaultHostname }}
{{- end -}}

{{/*
  Helper: zeta-guard.ns-well-known-subpath
  RFC 9728 well-known subpath for the NS, derived from wellKnownResourceSuffix. Used by
  the nginx location/alias, the pep-well-known-resources ConfigMap key, and the
  pep-proxy volume mount so they stay in sync. Rejects multi-segment values (a
  ConfigMap key / subPath cannot contain '/').
*/}}
{{- define "zeta-guard.ns-well-known-subpath" -}}
{{- $suffix := .Values.notificationService.wellKnownResourceSuffix -}}
{{- $subpath := trimPrefix "/" $suffix -}}
{{- if or (not (hasPrefix "/" $suffix)) (eq $subpath "") (contains "/" $subpath) -}}
{{- fail (printf "notificationService.wellKnownResourceSuffix must be a single leading-slash path segment (e.g. /notification-service); got %q" $suffix) -}}
{{- end -}}
{{- $subpath -}}
{{- end -}}

{{/*
  Helper: zeta-guard.baseLabels
  Minimal shared labels; set name/component/version inline per resource for clarity.
*/}}
{{- define "zeta-guard.baseLabels" -}}
helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}"
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: "{{ .Chart.AppVersion }}"
{{- end }}
app.kubernetes.io/managed-by: "{{ .Release.Service }}"
app.kubernetes.io/part-of: zeta-guard
{{- with .Values.additionalLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "authserver.labels" -}}
{{ include "authserver.selectorLabels" . }}
app.kubernetes.io/component: pdp
app.kubernetes.io/version: "{{ .Values.authserver.image.tag }}"
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "authserver.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: authserver
{{- end }}

{{/*
  Helper: authserver.image
  Builds the full image reference including registry, repository and tag.
  Used by: authserver/authserver-deployment.yaml
*/}}
{{- define "keychainGenerator.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.authserver.dbEnc.keychainGenerator.image.registry -}}
{{- printf "%s%s" $registry .Values.authserver.dbEnc.keychainGenerator.image.repository -}}
{{- if .Values.authserver.dbEnc.keychainGenerator.image.tag }}:{{ .Values.authserver.dbEnc.keychainGenerator.image.tag }}{{ end }}
{{- if .Values.authserver.dbEnc.keychainGenerator.image.digest }}@{{ .Values.authserver.dbEnc.keychainGenerator.image.digest }}{{ end }}
{{- end -}}

{{/*
  Helper: authserver.image
  Builds the full image reference including registry, repository and tag.
  Used by: authserver/authserver-deployment.yaml
*/}}
{{- define "authserver.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.authserver.image.registry -}}
{{- printf "%s%s" $registry .Values.authserver.image.repository -}}
{{- if .Values.authserver.image.tag }}:{{ .Values.authserver.image.tag }}{{ end }}
{{- if .Values.authserver.image.digest }}@{{ .Values.authserver.image.digest }}{{ end }}
{{- end -}}

{{- define "authserver.otel-service-name" -}}
ZETA Guard PDP authorization server
{{- end -}}

{{/*
  Helper: provisioningProcessor.image
  Builds the full image reference including registry, repository and tag.
*/}}
{{- define "provisioningProcessor.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.provisioningProcessor.image.registry -}}
{{- printf "%s%s" $registry .Values.provisioningProcessor.image.repository -}}
{{- if .Values.provisioningProcessor.image.tag }}:{{ .Values.provisioningProcessor.image.tag }}{{ end }}
{{- if .Values.provisioningProcessor.image.digest }}@{{ .Values.provisioningProcessor.image.digest }}{{ end }}
{{- end -}}

{{/*
  Helper: opa.image
  Builds the full image reference including registry, repository and tag.
*/}}
{{- define "opa.image" -}}
{{- $registry := default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.opa.image.registry -}}
{{- printf "%s%s" $registry .Values.opa.image.repository -}}
{{- if .Values.opa.image.tag }}:{{ .Values.opa.image.tag }}{{ end }}
{{- if .Values.opa.image.digest }}@{{ .Values.opa.image.digest }}{{ end }}
{{- end -}}

{{/*
  Helper: authserver.kcDb
  Resolves the KC_DB value depending on databaseMode.
  Used by: authserver/authserver-deployment.yaml
*/}}
{{- define "authserver.kcDb" -}}
{{- if eq .Values.databaseMode "cloudnative" -}}
postgres
{{- else -}}
{{ .Values.authserverDb.kcDb }}
{{- end -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "opa.labels" -}}
{{ include "opa.selectorLabels" . }}
app.kubernetes.io/component: pdp
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "opa.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: opa
{{- end }}

{{/*
Common labels for simulation OPA
*/}}
{{- define "opaSimulation.labels" -}}
{{ include "opaSimulation.selectorLabels" . }}
app.kubernetes.io/component: pdp
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
Selector labels for simulation OPA
*/}}
{{- define "opaSimulation.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: opa-simulation
{{- end }}

{{/*
Common labels
*/}}
{{- define "ingress.labels" -}}
app.kubernetes.io/name: zeta-guard
app.kubernetes.io/component: ingress
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{- define "pep-proxy.image" }}
{{ default (printf "%s%s" .Values.global.registry_host .Values.registry_name) .Values.pepproxy.image.registry }}{{ .Values.pepproxy.image.repository }}
{{- if .Values.pepproxy.image.tag }}:{{ .Values.pepproxy.image.tag }}{{ end }}
{{- if .Values.pepproxy.image.digest }}@{{ .Values.pepproxy.image.digest }}{{ end }}
{{- end }}

{{- define "pep-proxy.otel-service-name" -}}
ZETA Guard PEP HTTP proxy
{{- end -}}

{{/*
Common labels
*/}}
{{- define "pep-proxy.labels" -}}
{{ include "pep-proxy.selectorLabels" . }}
app.kubernetes.io/component: pep
app.kubernetes.io/version: "{{ .Values.pepproxy.image.tag }}"
{{ include "zeta-guard.baseLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pep-proxy.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: pep-proxy
{{- end -}}

{{/*
  Helper: zeta-guard.proxyEnvVars
  Renders HTTP/HTTPS/NO/ALL proxy environment variables from a config map.
  Pass a values sub-map that contains httpProxy, httpsProxy, noProxy, allProxy.
  Usage: {{- include "zeta-guard.proxyEnvVars" .Values.someComponent | nindent N }}
*/}}
{{- define "zeta-guard.proxyEnvVars" -}}
{{- with .httpProxy }}
- name: HTTP_PROXY
  value: {{ . | quote }}
- name: http_proxy
  value: {{ . | quote }}
{{- end }}
{{- with .httpsProxy }}
- name: HTTPS_PROXY
  value: {{ . | quote }}
- name: https_proxy
  value: {{ . | quote }}
{{- end }}
{{- with .noProxy }}
- name: NO_PROXY
  value: {{ . | quote }}
- name: no_proxy
  value: {{ . | quote }}
{{- end }}
{{- with .allProxy }}
- name: ALL_PROXY
  value: {{ . | quote }}
- name: all_proxy
  value: {{ . | quote }}
{{- end }}
{{- end -}}

{{/*
Provisioning processor registry-CA wiring, shared by all init containers that run
the provisioning processor (authserver, pep, opa, opa-simulation).
Pass the root context (.) as the argument.

caEnv: PROVISIONING_CONTAINER_REGISTRY_CA_FILE env var (when a Secret or ConfigMap
ref is set), the registry credentials (when registryCredentialsSecretRef is set)
plus any provisioningProcessor.extraEnv.
  Usage: {{- include "zeta-guard.provisioningProcessor.caEnv" . | nindent N }}
*/}}
{{- define "zeta-guard.provisioningProcessor.caEnv" -}}
{{- if or .Values.provisioningProcessor.provisioningContainerCaSecretRef .Values.provisioningProcessor.provisioningContainerCaConfigMapRef }}
- name: PROVISIONING_CONTAINER_REGISTRY_CA_FILE
  value: "/var/registry-ca/ca.crt"
{{- end }}
{{- with .Values.provisioningProcessor.registryCredentialsSecretRef }}
- name: PROVISIONING_CONTAINER_REGISTRY_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .name }}
      key: {{ .usernameKey | default "username" }}
- name: PROVISIONING_CONTAINER_REGISTRY_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .name }}
      key: {{ .tokenKey | default "token" }}
{{- end }}
{{- with .Values.provisioningProcessor.extraEnv }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
caVolumeMounts: registry-ca mount (when a Secret or ConfigMap ref is set) plus any
provisioningProcessor.extraVolumeMounts.
  Usage: {{- include "zeta-guard.provisioningProcessor.caVolumeMounts" . | nindent N }}
*/}}
{{- define "zeta-guard.provisioningProcessor.caVolumeMounts" -}}
{{- if or .Values.provisioningProcessor.provisioningContainerCaSecretRef .Values.provisioningProcessor.provisioningContainerCaConfigMapRef }}
- name: registry-ca
  mountPath: /var/registry-ca
  readOnly: true
{{- end }}
{{- with .Values.provisioningProcessor.extraVolumeMounts }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
caVolumes: registry-ca volume from a Secret or ConfigMap (mutually exclusive,
Secret takes precedence) plus any provisioningProcessor.extraVolumes.
  Usage: {{- include "zeta-guard.provisioningProcessor.caVolumes" . | nindent N }}
*/}}
{{- define "zeta-guard.provisioningProcessor.caVolumes" -}}
{{- if .Values.provisioningProcessor.provisioningContainerCaSecretRef }}
- name: registry-ca
  secret:
    secretName: {{ .Values.provisioningProcessor.provisioningContainerCaSecretRef.name }}
    items:
      - key: {{ .Values.provisioningProcessor.provisioningContainerCaSecretRef.key }}
        path: ca.crt
{{- else if .Values.provisioningProcessor.provisioningContainerCaConfigMapRef }}
- name: registry-ca
  configMap:
    name: {{ .Values.provisioningProcessor.provisioningContainerCaConfigMapRef.name }}
    items:
      - key: {{ .Values.provisioningProcessor.provisioningContainerCaConfigMapRef.key }}
        path: ca.crt
{{- end }}
{{- with .Values.provisioningProcessor.extraVolumes }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
registryCaVolumeMount: read-only registry-ca mount for a *main* container. OPA needs the
registry CA at runtime (not just in the init container) to pull the policy bundle from a
private OCI registry. Unlike caVolumeMounts this deliberately omits
provisioningProcessor.extraVolumeMounts, whose paths are init-container specific.
The registry-ca volume itself is emitted by zeta-guard.provisioningProcessor.caVolumes.
*/}}
{{- define "zeta-guard.provisioningProcessor.registryCaVolumeMount" -}}
{{- if or .Values.provisioningProcessor.provisioningContainerCaSecretRef .Values.provisioningProcessor.provisioningContainerCaConfigMapRef }}
- name: registry-ca
  mountPath: /var/registry-ca
  readOnly: true
{{- end }}
{{- end -}}

{{/*
  Helper: zeta-guard.dnsEgressRule
  Emits the DNS egress rule shared by all egress NetworkPolicies (netpol/*.yaml).
  Driven by `.Values.networkPolicy.dns`:
    - default: namespaceSelector + podSelector (kube-system / k8s-app: kube-dns)
    - OpenShift: openshift-dns / dns.operator.openshift.io/daemonset-dns=default,
      port 5353 (OVN-Kubernetes evaluates egress post-DNAT)
    - `dns.to`: a raw peer list rendered as-is, overriding the selectors
  Include with `nindent 4` as the first entry under `egress:`.
*/}}
{{- define "zeta-guard.dnsEgressRule" -}}
{{- $dns := .Values.networkPolicy.dns -}}
# DNS resolution
- to:
{{- if $dns.to }}
    {{- toYaml $dns.to | nindent 4 }}
{{- else }}
    - namespaceSelector:
        matchLabels:
          {{- toYaml $dns.namespaceSelector.matchLabels | nindent 10 }}
      podSelector:
        matchLabels:
          {{- toYaml $dns.podSelector.matchLabels | nindent 10 }}
{{- end }}
  ports:
    {{- toYaml $dns.ports | nindent 4 }}
{{- end -}}
