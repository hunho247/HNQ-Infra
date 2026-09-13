{{/*
hnq.name / hnq.fullname — tên release chính là tên service (PLAN §4).
*/}}
{{- define "hnq.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hnq.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
hnq.env — tên môi trường, bắt buộc đến từ env/<env>.yaml.
*/}}
{{- define "hnq.env" -}}
{{- $env := (.Values.env).name -}}
{{- if not $env -}}
{{- fail "hnq.env: env.name rỗng — Application phải nạp /env/<env>.yaml" -}}
{{- end -}}
{{- $env -}}
{{- end -}}

{{/*
hnq.labels — nhãn chuẩn cho mọi tài nguyên.
*/}}
{{- define "hnq.labels" -}}
app.kubernetes.io/name: {{ include "hnq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: hnq
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
hnq.dev/env: {{ include "hnq.env" . }}
hnq.dev/service: {{ include "hnq.name" . }}
{{- end -}}

{{/*
hnq.selectorLabels — chỉ phần bất biến, dùng cho selector của Deployment/Service.
*/}}
{{- define "hnq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hnq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
hnq.namespace — <service>-<env>, suy ra chứ không khai trong values (PLAN §4).
*/}}
{{- define "hnq.namespace" -}}
{{- printf "%s-%s" (include "hnq.name" .) (include "hnq.env" .) -}}
{{- end -}}
