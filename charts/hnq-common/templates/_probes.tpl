{{/*
hnq.probes — readiness + liveness. Chặn deploy nếu chart không khai probePath
(PLAN §6): traffic vào pod chưa sẵn sàng là lỗi khách hàng thấy trước bạn.
Tham số: dict "ctx" $ "path" <probePath> "port" <containerPort>
*/}}
{{- define "hnq.probes" -}}
{{- $ctx := .ctx -}}
{{- $path := .path -}}
{{- $port := .port -}}
{{- if not $path -}}
{{- fail "hnq.probes: thiếu probePath — mọi workload phải khai đường kiểm tra sức khoẻ" -}}
{{- end -}}
{{- $p := ($ctx.Values.probes | default dict) -}}
{{- $r := ($p.readiness | default dict) -}}
{{- $l := ($p.liveness | default dict) -}}
readinessProbe:
  httpGet:
    path: {{ $path }}
    port: {{ $port }}
  initialDelaySeconds: {{ $r.initialDelaySeconds | default 3 }}
  periodSeconds: {{ $r.periodSeconds | default 10 }}
  failureThreshold: {{ $r.failureThreshold | default 3 }}
livenessProbe:
  httpGet:
    path: {{ $path }}
    port: {{ $port }}
  initialDelaySeconds: {{ $l.initialDelaySeconds | default 10 }}
  periodSeconds: {{ $l.periodSeconds | default 10 }}
  failureThreshold: {{ $l.failureThreshold | default 3 }}
{{- end -}}

{{/*
hnq.tcpProbes — bản TCP cho datastore (database không có HTTP endpoint).
Tham số: dict "ctx" $ "port" <port>
*/}}
{{- define "hnq.tcpProbes" -}}
{{- $ctx := .ctx -}}
{{- $port := .port -}}
{{- if not $port -}}
{{- fail "hnq.tcpProbes: thiếu port" -}}
{{- end -}}
{{- $p := ($ctx.Values.probes | default dict) -}}
{{- $r := ($p.readiness | default dict) -}}
{{- $l := ($p.liveness | default dict) -}}
readinessProbe:
  tcpSocket:
    port: {{ $port }}
  initialDelaySeconds: {{ $r.initialDelaySeconds | default 5 }}
  periodSeconds: {{ $r.periodSeconds | default 10 }}
  failureThreshold: {{ $r.failureThreshold | default 3 }}
livenessProbe:
  tcpSocket:
    port: {{ $port }}
  initialDelaySeconds: {{ $l.initialDelaySeconds | default 15 }}
  periodSeconds: {{ $l.periodSeconds | default 10 }}
  failureThreshold: {{ $l.failureThreshold | default 3 }}
{{- end -}}
