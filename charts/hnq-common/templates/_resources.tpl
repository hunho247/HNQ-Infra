{{/*
hnq.resources — bắt buộc có cả requests và limits (PLAN §6).
Một pod không limit ăn hết CPU node là cách nhanh nhất để mất cả môi trường.
Tham số: dict "ctx" $ "resources" <override hoặc nil>
*/}}
{{- define "hnq.resources" -}}
{{- $ctx := .ctx -}}
{{- $res := .resources | default $ctx.Values.resources -}}
{{- if not $res -}}
{{- fail "hnq.resources: thiếu resources — nạp /env/<env>.yaml hoặc khai trong values" -}}
{{- end -}}
{{- if not $res.requests -}}
{{- fail "hnq.resources: thiếu resources.requests" -}}
{{- end -}}
{{- if not $res.limits -}}
{{- fail "hnq.resources: thiếu resources.limits" -}}
{{- end -}}
resources:
{{- toYaml $res | nindent 2 }}
{{- end -}}

{{/*
hnq.image — ghép repository:tag, cấm tag rỗng và cấm "latest" (D8).
Tag phải pin tuyệt đối: git SHA 7 ký tự cho image của mình, version cố định
cho image bên thứ ba. conftest kiểm đúng dạng, template chỉ chặn trường hợp
không thể tái tạo được.
Tham số: dict "ctx" $ "image" <dict repository/tag>
*/}}
{{- define "hnq.image" -}}
{{- $img := .image -}}
{{- if not $img.repository -}}
{{- fail "hnq.image: thiếu image.repository" -}}
{{- end -}}
{{- $tag := $img.tag | toString -}}
{{- if or (not $tag) (eq $tag "latest") -}}
{{- fail (printf "hnq.image: tag của %s phải pin tuyệt đối — không được rỗng hay 'latest'" $img.repository) -}}
{{- end -}}
{{- printf "%s:%s" $img.repository $tag -}}
{{- end -}}
