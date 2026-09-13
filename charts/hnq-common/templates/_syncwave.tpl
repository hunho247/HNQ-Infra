{{/*
hnq.syncWave — thứ tự sync theo bảng PLAN §6 (D16).
Bảng ở một chỗ duy nhất: đổi thứ tự là sửa một file, không phải đi tìm
annotation rải rác trong từng template.

  -3  Namespace, ResourceQuota, LimitRange
  -2  SealedSecret, ConfigMap
  -1  PVC
   0  Workload của datastore
   1  Workload của webservice
   2  Service, Ingress, ServiceMonitor

Tham số: dict "kind" <Kind> ["chart" <webservice|datastore>]
*/}}
{{- define "hnq.syncWaveValue" -}}
{{- $kind := .kind -}}
{{- $chart := .chart | default "webservice" -}}
{{- if has $kind (list "Namespace" "ResourceQuota" "LimitRange") -}}
-3
{{- else if has $kind (list "SealedSecret" "ConfigMap" "Secret") -}}
-2
{{- else if eq $kind "PersistentVolumeClaim" -}}
-1
{{- else if has $kind (list "Deployment" "StatefulSet" "DaemonSet" "CronJob" "Job") -}}
{{- if eq $chart "datastore" }}0{{ else }}1{{ end -}}
{{- else if has $kind (list "Service" "Ingress" "ServiceMonitor") -}}
2
{{- else -}}
{{- fail (printf "hnq.syncWave: chưa có wave cho kind %s — thêm vào bảng ở charts/hnq-common/templates/_syncwave.tpl" $kind) -}}
{{- end -}}
{{- end -}}

{{- define "hnq.syncWave" -}}
argocd.argoproj.io/sync-wave: {{ include "hnq.syncWaveValue" . | quote }}
{{- end -}}
