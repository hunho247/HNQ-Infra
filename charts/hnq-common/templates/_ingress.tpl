{{/*
hnq.ingressAnnotations — annotation của env + cert-manager.io/cluster-issuer
lấy từ env.clusterIssuer (PLAN §6). Không có issuer thì domain chạy không TLS,
nên fail ngay ở template.
*/}}
{{- define "hnq.ingressAnnotations" -}}
{{- $issuer := (.Values.env).clusterIssuer -}}
{{- if not $issuer -}}
{{- fail "hnq.ingressAnnotations: env.clusterIssuer rỗng — Ingress sẽ không có TLS" -}}
{{- end -}}
{{- with (.Values.ingress).annotations }}
{{- toYaml . }}
{{- end }}
cert-manager.io/cluster-issuer: {{ $issuer }}
{{- end -}}

{{/*
hnq.ingress — Ingress đầy đủ cho một host + một service.
Tham số: dict "ctx" $ "host" <host> "serviceName" <svc> "servicePort" <port>
         "path" <path> ["nameSuffix" <hậu tố>]
nameSuffix cần khi một service có nhiều host (ví dụ API và console của MinIO):
hai Ingress trùng tên thì cái sau đè cái trước mà không báo gì.
*/}}
{{- define "hnq.ingress" -}}
{{- $ctx := .ctx -}}
{{- $host := .host -}}
{{- if not $host -}}
{{- fail "hnq.ingress: thiếu ingress.host" -}}
{{- end -}}
{{- $ing := ($ctx.Values.ingress | default dict) -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "hnq.fullname" $ctx }}{{ with .nameSuffix }}-{{ . }}{{ end }}
  namespace: {{ include "hnq.namespace" $ctx }}
  labels:
{{ include "hnq.labels" $ctx | trim | indent 4 }}
  annotations:
{{ include "hnq.ingressAnnotations" $ctx | trim | indent 4 }}
{{ include "hnq.syncWave" (dict "kind" "Ingress") | trim | indent 4 }}
spec:
  ingressClassName: {{ $ing.className | default "traefik" }}
  tls:
    - hosts:
        - {{ $host | quote }}
      secretName: {{ printf "%s-tls" (regexReplaceAll "\\." $host "-") }}
  rules:
    - host: {{ $host | quote }}
      http:
        paths:
          - path: {{ .path | default "/" }}
            pathType: Prefix
            backend:
              service:
                name: {{ .serviceName }}
                port:
                  number: {{ .servicePort }}
{{- end -}}
