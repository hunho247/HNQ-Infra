{{- define "push-notify.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "push-notify.appFullname" -}}
{{- if .Values.app.fullnameOverride }}
{{- .Values.app.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "push-notify.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "push-notify.labels" -}}
helm.sh/chart: {{ include "push-notify.chart" . }}
{{ include "push-notify.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "push-notify.selectorLabels" -}}
app.kubernetes.io/name: {{ include "push-notify.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "push-notify.gorushFullname" -}}
{{- if .Values.gorush.fullnameOverride }}
{{- .Values.gorush.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-gorush" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
