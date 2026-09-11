{{- define "push-notify-v2.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "push-notify-v2.appFullname" -}}
{{- if .Values.api.fullnameOverride }}
{{- .Values.api.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "push-notify-v2.workerFullname" -}}
{{- if .Values.worker.fullnameOverride }}
{{- .Values.worker.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-worker" (include "push-notify-v2.appFullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "push-notify-v2.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "push-notify-v2.labels" -}}
helm.sh/chart: {{ include "push-notify-v2.chart" . }}
{{ include "push-notify-v2.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "push-notify-v2.selectorLabels" -}}
app.kubernetes.io/name: {{ include "push-notify-v2.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
