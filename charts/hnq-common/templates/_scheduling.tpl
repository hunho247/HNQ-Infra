{{/*
hnq.nodeSelector — nạp từ env.nodeSelector, FAIL nếu rỗng (PLAN §6).
Pod rơi nhầm môi trường là lỗi im lặng và đắt: prod chạy trên node dev thì
mọi thứ vẫn xanh cho tới lúc node đó tắt.
*/}}
{{- define "hnq.nodeSelector" -}}
{{- $ns := (.Values.env).nodeSelector -}}
{{- if not $ns -}}
{{- fail "hnq.nodeSelector: env.nodeSelector rỗng — thiếu /env/<env>.yaml trong valueFiles" -}}
{{- end -}}
nodeSelector:
{{- toYaml $ns | nindent 2 }}
{{- end -}}

{{/*
hnq.tolerations — KHÔNG sinh toleration cho taint của hnq-01.
Chỉ 5 chart platform ở PLAN §2 được khai nó, và chúng dùng chart bên thứ ba
chứ không dùng library này. conftest chặn phần còn lại.
*/}}
{{- define "hnq.tolerations" -}}
{{- with .Values.tolerations -}}
tolerations:
{{- toYaml . | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
hnq.storageClass — luôn là hnq-local (D11). Class khác nghĩa là mất
reclaimPolicy Retain và mất khả năng backup bằng Velero FSB, nên fail sớm
thay vì để PVC bound nhầm rồi phát hiện lúc restore.
*/}}
{{- define "hnq.storageClass" -}}
{{- $sc := ((.Values.persistence).storageClass) -}}
{{- if not $sc -}}
{{- fail "hnq.storageClass: persistence.storageClass rỗng — thiếu /env/<env>.yaml" -}}
{{- end -}}
{{- if ne $sc "hnq-local" -}}
{{- fail (printf "hnq.storageClass: chỉ dùng hnq-local, đang là %s" $sc) -}}
{{- end -}}
{{- $sc -}}
{{- end -}}
