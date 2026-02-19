{{- define "tiger-testsuite.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tiger-testsuite.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "tiger-testsuite.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "tiger-testsuite.labels" -}}
helm.sh/chart: {{ include "tiger-testsuite.chart" . }}
app.kubernetes.io/name: {{ include "tiger-testsuite.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{- define "tiger-testsuite.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tiger-testsuite.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "tiger-testsuite.workflowUiArgs" -}}
{{- $workflowUi := .Values.workflowUi }}
{{- $args := list
  (printf "-Dtiger.lib.enableTestSelection=%t" $workflowUi.enableTestSelection)
  (printf "-Dtiger.lib.activateWorkflowUi=%t" $workflowUi.activateWorkflowUi)
  (printf "-Dtiger.lib.trafficVisualization=%t" $workflowUi.trafficVisualization)
  (printf "-Dtiger.lib.startBrowser=%t" $workflowUi.startBrowser)
  (printf "-Dtiger.lib.workflowUiPort=%v" $workflowUi.workflowUiPort)
  (printf "-Dtiger.lib.workflowUiStartTimeoutInSeconds=%v" $workflowUi.workflowUiStartTimeoutInSeconds)
  (printf "-Dtiger.lib.runTestsOnStart=%t" $workflowUi.runTestsOnStart)
}}
{{- with $workflowUi.tigerProxyConfiguration.adminPort }}
{{- $args = append $args (printf "-Dtiger.lib.tigerProxyConfiguration.adminPort=%v" .) }}
{{- $args = append $args (printf "-Dtiger.tigerproxy.adminport=%v" .) }}
{{- $args = append $args (printf "-Dtiger.internal.localproxy.port=%v" .) }}
{{- end }}
{{- join " " $args | trim -}}
{{- end -}}

{{- define "tiger-testsuite.mvnAdditionalArgs" -}}
{{- $userArgs := tpl (default "" .Values.env.mvnAdditionalArgs) . | trim -}}
{{- $workflowUiArgs := include "tiger-testsuite.workflowUiArgs" . | trim -}}
{{- $args := list -}}
{{- if $userArgs -}}
{{- $args = append $args $userArgs -}}
{{- end -}}
{{- if $workflowUiArgs -}}
{{- $args = append $args $workflowUiArgs -}}
{{- end -}}
{{- $featuresDirArg := "-Dtiger.featuresDir=/app/src/test/resources/features" -}}
{{- $hasFeaturesDir := or (regexMatch ".*-Dtiger\\.featuresDir=.*" $userArgs) (regexMatch ".*-Dtiger\\.featuresDir=.*" $workflowUiArgs) -}}
{{- if not $hasFeaturesDir -}}
{{- $args = append $args $featuresDirArg -}}
{{- end -}}
{{- $rbelAnsiArg := "-Dtiger.lib.rbelAnsiColors=false" -}}
{{- $hasRbelAnsi := or (regexMatch ".*-Dtiger\\.lib\\.rbelAnsiColors=.*" $userArgs) (regexMatch ".*-Dtiger\\.lib\\.rbelAnsiColors=.*" $workflowUiArgs) -}}
{{- if not $hasRbelAnsi -}}
{{- $args = append $args $rbelAnsiArg -}}
{{- end -}}
{{- join " " $args | trim -}}
{{- end -}}
