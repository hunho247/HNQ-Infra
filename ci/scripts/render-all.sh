#!/usr/bin/env bash
# Render MỌI service × MỌI môi trường đúng như ApplicationSet sẽ làm.
# Đây là cửa duy nhất bắt được "ApplicationSet sinh sai tên" hay "values thiếu
# trường" TRƯỚC khi vào main — ArgoCD chỉ báo sau khi đã merge.
#
#   ci/scripts/render-all.sh [thư-mục-ra]        # mặc định: .render
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/.render}"
rm -rf "$OUT"; mkdir -p "$OUT"

cd "$ROOT"

# Chart library được nạp qua dependency file:// — build lại để chắc chắn bản
# đang render là bản trong repo, không phải .tgz cũ.
for c in charts/webservice charts/datastore; do
  helm dependency build "$c" >/dev/null 2>&1 || helm dependency update "$c" >/dev/null
done

fail=0
count=0
for svc_file in registry/apps/*/service.yaml; do
  name="$(yq -r '.metadata.name' "$svc_file")"
  dir="$(dirname "$svc_file")"
  chart="$(yq -r '.spec.chart' "$svc_file")"
  has_config="$(yq -r '.spec.config' "$svc_file")"

  # Tên thư mục phải bằng metadata.name — Application, namespace và đường dẫn
  # values đều suy ra từ đó.
  if [ "$name" != "$(basename "$dir")" ]; then
    echo "❌ $svc_file: metadata.name ($name) khác tên thư mục ($(basename "$dir"))"
    fail=1; continue
  fi

  while read -r env; do
    [ -n "$env" ] || continue
    args=(-f "charts/$chart/values.yaml" -f "env/$env.yaml" -f "$dir/values-$env.yaml")
    if [ "$has_config" = "true" ]; then
      args+=(-f "$dir/config/config-$env.yaml")
    fi
    if ! helm template "$name" "charts/$chart" "${args[@]}" \
          --namespace "$name-$env" > "$OUT/$name-$env.yaml" 2>"$OUT/$name-$env.err"; then
      echo "❌ $name-$env render lỗi:"
      sed 's/^/    /' "$OUT/$name-$env.err"
      fail=1
      continue
    fi
    rm -f "$OUT/$name-$env.err"
    count=$((count + 1))
  done < <(yq -r '.spec.environments[].env' "$svc_file")
done

# Manifest thô của platform cũng phải qua kubeconform/conftest như chart.
mkdir -p "$OUT/platform"
for d in gitops/manifests/*/; do
  dst="$OUT/platform/$(basename "$d").yaml"
  : > "$dst"
  for f in "$d"*.yaml; do
    # Dấu --- giữa từng file: nối thẳng thì hai manifest dính vào nhau thành
    # một document YAML hỏng.
    printf -- '---\n' >> "$dst"
    cat "$f" >> "$dst"
    printf '\n' >> "$dst"
  done
done

echo "✅ render $count Application vào $OUT"
exit $fail
