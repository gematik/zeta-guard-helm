{{/*
The bundled notification-service ships as one image repository built in two
API variants (rs-facing, fdv-facing) distinguished by an image tag suffix. Each
variant is deployed as its own Deployment/Service/NetworkPolicy; they share a
single Postgres database and do not talk to each other directly.

The templates below are variant-aware: every helper takes a dict
  (dict "root" $ "variant" "rs"|"fdv")
so the two renderings select disjoint pods.
*/}}

{{/*
Selector labels (variant-aware). Must differ per variant.
*/}}
{{- define "notificationService.selectorLabels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/name: notification-service-{{ .variant }}
{{- end }}

{{/*
Common labels (variant-aware).
*/}}
{{- define "notificationService.labels" -}}
{{ include "notificationService.selectorLabels" . }}
app.kubernetes.io/component: notification-service
{{ include "zeta-guard.baseLabels" .root }}
{{- end }}

{{/*
Resource name for a variant: notification-service-rs | notification-service-fdv.
*/}}
{{- define "notificationService.fullname" -}}
notification-service-{{ .variant }}
{{- end }}

{{/*
Comma-separated list of mounted Push Gateway CA paths, one per
notificationService.pushGateway.trustedCAs entry (matches the projected-volume
item paths). Value for PUSH_GATEWAY_TRUSTED_CA_PATHS. Arg: same dict.
*/}}
{{- define "notificationService.trustedCaPaths" -}}
{{- $paths := list -}}
{{- range $i, $ca := .root.Values.notificationService.pushGateway.trustedCAs -}}
{{- $paths = append $paths (printf "/certs/push-gateway/ca-%d.pem" $i) -}}
{{- end -}}
{{- join "," $paths -}}
{{- end -}}

{{/*
Full image reference for a variant. The tag is the shared prefix with the
variant suffix appended ("<image.tag>-<variant>"), matching the CI-published
floating tags (e.g. main-rs / main-fdv). Registry/repository are shared; the
digest is pinned per variant (notificationService.<variant>.image.digest), since
rs and fdv are distinct images with distinct digests.
*/}}
{{- define "notificationService.image" -}}
{{- $ns := .root.Values.notificationService -}}
{{- $variantCfg := index $ns .variant -}}
{{- $registry := default (printf "%s%s" .root.Values.global.registry_host .root.Values.registry_name) $ns.image.registry -}}
{{- $tag := printf "%s-%s" $ns.image.tag .variant -}}
{{- $digest := "" -}}
{{- if and $variantCfg $variantCfg.image $variantCfg.image.digest -}}
{{- $digest = $variantCfg.image.digest -}}
{{- end -}}
{{- printf "%s%s" $registry $ns.image.repository -}}
{{- if $tag }}:{{ $tag }}{{ end }}
{{- if $digest }}@{{ $digest }}{{ end }}
{{- end -}}

{{/*
Full Deployment manifest for one variant. Arg: dict "root" $ "variant" ...
*/}}
{{- define "notificationService.deployment" -}}
{{- $root := .root -}}
{{- $ns := $root.Values.notificationService -}}
{{- $mtls := $ns.pushGateway.mtls -}}
{{- $mtlsCert := $mtls.clientCert.secretName -}}
{{- $mtlsKey := $mtls.clientKey.secretName -}}
{{- if or (and $mtlsCert (not $mtlsKey)) (and $mtlsKey (not $mtlsCert)) -}}
{{- fail "notificationService.pushGateway.mtls: set both clientCert.secretName and clientKey.secretName, or neither" -}}
{{- end -}}
{{- $mtlsOn := and $mtlsCert $mtlsKey -}}
{{- /* Datasource JDBC URL / secret default to the CNPG cluster's -rw service and
       -app secret so clusterName stays the single source of truth in cloudnative
       mode; set explicitly for an external DB. */}}
{{- $dbJdbcUrl := $ns.db.jdbcUrl | default (printf "jdbc:postgresql://%s-rw:5432/notification" $ns.db.clusterName) -}}
{{- $dbSecretName := $ns.db.secretName | default (printf "%s-app" $ns.db.clusterName) -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "notificationService.fullname" . }}
  labels:
    {{- include "notificationService.labels" . | nindent 4 }}
spec:
  replicas: {{ $ns.replicaCount }}
  selector:
    matchLabels:
      {{- include "notificationService.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "notificationService.labels" . | nindent 8 }}
        {{- with $ns.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- if $ns.podAnnotations | or $root.Values.devMode }}
      annotations:
        {{- with $ns.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        {{- if $root.Values.devMode }}
        zeta.dev/rollout-timestamp: "{{ now | unixEpoch }}"
        {{- end }}
      {{- end }}
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      {{- if $ns.serviceAccountName }}
      serviceAccountName: {{ $ns.serviceAccountName | quote }}
      {{- end }}
      automountServiceAccountToken: false
      {{- with $ns.imagePullSecrets | default $root.Values.global.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if $ns.db.waitForDb.enabled }}
      {{- $wait := $ns.db.waitForDb }}
      {{- $dbHost := $wait.host | default (printf "%s-rw" $ns.db.clusterName) }}
      initContainers:
        # Wait for Postgres so the app doesn't crash-loop on Flyway's connect.
        - name: wait-for-db
          image: {{ $wait.image | quote }}
          imagePullPolicy: {{ $wait.imagePullPolicy | quote }}
          command:
            - sh
            - -c
            - |
              echo "Waiting for Postgres at {{ $dbHost }}:{{ $wait.port }}..."
              while ! nc -z {{ $dbHost }} {{ $wait.port }}; do sleep {{ $wait.intervalSeconds }}; done
              echo "Postgres ready"
          {{- with $ns.containerSecurityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $wait.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- end }}
      containers:
        - name: notification-service
          {{- with $ns.containerSecurityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          image: "{{ include "notificationService.image" . | trim }}"
          imagePullPolicy: "{{ $ns.imagePullPolicy }}"
          env:
            - name: PUSH_GATEWAY_ALLOWED_BASE_URLS
              value: {{ $ns.env.pushGatewayAllowedBaseUrls | join "," | quote }}
            {{- if $ns.pushGateway.trustedCAs }}
            # Extra CA(s) for outbound HTTPS to the Push Gateway, merged with the
            # system anchors. Only emitted when trustedCAs is set.
            - name: PUSH_GATEWAY_TRUSTED_CA_PATHS
              value: {{ include "notificationService.trustedCaPaths" . | quote }}
            {{- end }}
            {{- if $mtlsOn }}
            - name: PUSH_GATEWAY_MTLS_CLIENT_CERTIFICATE_PATH
              value: /certs/push-gateway-client/tls.crt
            - name: PUSH_GATEWAY_MTLS_CLIENT_KEY_PATH
              value: /certs/push-gateway-client/tls.key
            {{- if $mtls.keyPassword.secretName }}
            - name: PUSH_GATEWAY_MTLS_CLIENT_KEY_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ $mtls.keyPassword.secretName | quote }}
                  key: {{ required "notificationService.pushGateway.mtls.keyPassword.secretKey is required when keyPassword.secretName is set" $mtls.keyPassword.secretKey }}
            {{- end }}
            {{- end }}
            - name: NOTIFICATION_CHANNELS_ALLOWED
              value: {{ $ns.env.channelsAllowed | quote }}
            - name: NOTIFICATION_PERSISTENCE_SEALING_ENABLED
              value: {{ $ns.env.persistenceSealingEnabled | quote }}
            # A_29974: when false the NS disables /history/* (404/501) and persists nothing.
            - name: NOTIFICATION_HISTORY_ENABLED
              value: {{ $ns.historyEnabled | quote }}
            - name: QUARKUS_DATASOURCE_JDBC_URL
              value: {{ $dbJdbcUrl | quote }}
            - name: QUARKUS_DATASOURCE_USERNAME
              valueFrom:
                secretKeyRef:
                  name: {{ $dbSecretName | quote }}
                  key: username
            - name: QUARKUS_DATASOURCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ $dbSecretName | quote }}
                  key: password
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.version={{ $root.Chart.Version }}"
            {{- if $ns.accessLog.enabled }}
            - name: QUARKUS_HTTP_ACCESS_LOG_ENABLED
              value: "true"
            {{- with $ns.accessLog.pattern }}
            - name: QUARKUS_HTTP_ACCESS_LOG_PATTERN
              value: {{ . | quote }}
            {{- end }}
            {{- end }}
            {{- include "zeta-guard.proxyEnvVars" $root.Values.global | nindent 12 }}
          ports:
            - containerPort: 8080
              name: http
          livenessProbe:
            httpGet:
              path: /q/health/live
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /q/health/ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          {{- with $ns.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            {{- if $ns.pushGateway.trustedCAs }}
            - name: push-gateway-trusted-ca
              mountPath: /certs/push-gateway
              readOnly: true
            {{- end }}
            {{- if $mtlsOn }}
            - name: push-gateway-client
              mountPath: /certs/push-gateway-client
              readOnly: true
            {{- end }}
      volumes:
        # Quarkus/Vert.x needs a writable /tmp even with readOnlyRootFilesystem: true.
        - name: tmp
          emptyDir: {}
        {{- if $ns.pushGateway.trustedCAs }}
        # PEM CA(s) for outbound HTTPS to the Push Gateway; each lands at
        # /certs/push-gateway/ca-<i>.pem. Quarkus reads PEM directly (no keytool/PKCS12).
        - name: push-gateway-trusted-ca
          projected:
            sources:
              {{- range $i, $ca := $ns.pushGateway.trustedCAs }}
              {{- if and $ca.secretName $ca.cert }}
              {{- fail (printf "notificationService.pushGateway.trustedCAs[%d]: set either secretName+secretKey or cert, not both" $i) }}
              {{- else if $ca.secretName }}
              - secret:
                  name: {{ $ca.secretName }}
                  items:
                    - key: {{ required (printf "notificationService.pushGateway.trustedCAs[%d]: secretKey is required when secretName is set" $i) $ca.secretKey }}
                      path: {{ printf "ca-%d.pem" $i }}
              {{- else if $ca.cert }}
              - secret:
                  name: notification-service-additional-cas
                  items:
                    - key: {{ printf "ca-%d.pem" $i }}
                      path: {{ printf "ca-%d.pem" $i }}
              {{- else }}
              {{- fail (printf "notificationService.pushGateway.trustedCAs[%d]: must set either secretName+secretKey or cert" $i) }}
              {{- end }}
              {{- end }}
        {{- end }}
        {{- if $mtlsOn }}
        - name: push-gateway-client
          projected:
            sources:
              - secret:
                  name: {{ $mtls.clientCert.secretName }}
                  items:
                    - key: {{ required "notificationService.pushGateway.mtls.clientCert.secretKey is required" $mtls.clientCert.secretKey }}
                      path: tls.crt
              - secret:
                  name: {{ $mtls.clientKey.secretName }}
                  items:
                    - key: {{ required "notificationService.pushGateway.mtls.clientKey.secretKey is required" $mtls.clientKey.secretKey }}
                      path: tls.key
        {{- end }}
      {{- with $ns.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $ns.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end -}}
