{{- define "obgyn-clinic-service.backendFullname" -}}
{{- if .Values.backend.fullnameOverride -}}
{{ .Values.backend.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else -}}
{{ printf "%s-backend" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end }}
