#!/usr/bin/env bash
# Đối chiếu requiredSecrets trong service.yaml với file thật trong secrets/.
# Bắt trước khi merge cái lỗi khó chịu nhất của Sealed Secrets: Application
# Synced, pod CrashLoop, log chỉ nói "missing env".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PENDING_FILE="secrets/PENDING"

# Trả về 0 nếu cặp <service>/<env> đang nằm trong danh sách nợ có chủ ý.
is_pending() {
  [ -f "$PENDING_FILE" ] || return 1
  grep -qx "$1/$2" "$PENDING_FILE"
}

fail=0
pending=0
for svc_file in registry/apps/*/service.yaml; do
  name="$(yq -r '.metadata.name' "$svc_file")"

  while read -r env; do
    [ -n "$env" ] || continue

    while read -r secret; do
      [ -n "$secret" ] && [ "$secret" != "null" ] || continue

      # Quy ước: secrets/<env>/<service>/<thành-phần>.yaml, trong đó
      # <thành-phần> là phần sau "<service>-" của tên Secret.
      component="${secret#"$name"-}"
      path="secrets/$env/$name/$component.yaml"

      if [ ! -f "$path" ]; then
        if is_pending "$name" "$env"; then
          echo "⏳ $name/$env: chưa niêm phong $path (có trong $PENDING_FILE)"
          pending=$((pending + 1))
        else
          echo "❌ $name/$env: thiếu $path (service.yaml khai Secret $secret)"
          fail=1
        fi
        continue
      fi

      kind="$(yq -r '.kind' "$path")"
      if [ "$kind" != "SealedSecret" ]; then
        echo "❌ $path: kind=$kind — chỉ được commit SealedSecret, không bao giờ Secret thô"
        fail=1
        continue
      fi

      ns="$(yq -r '.metadata.namespace' "$path")"
      if [ "$ns" != "$name-$env" ]; then
        echo "❌ $path: namespace=$ns, phải là $name-$env (SealedSecret gắn chặt với namespace)"
        fail=1
      fi

      sealed_name="$(yq -r '.metadata.name' "$path")"
      if [ "$sealed_name" != "$secret" ]; then
        echo "❌ $path: metadata.name=$sealed_name, phải là $secret"
        fail=1
      fi

      # Đủ key chưa — thiếu một key là pod chạy rồi mới chết.
      while read -r key; do
        [ -n "$key" ] || continue
        if ! yq -e ".spec.encryptedData | has(\"$key\")" "$path" >/dev/null 2>&1; then
          echo "❌ $path: thiếu key $key"
          fail=1
        fi
      done < <(yq -r ".spec.requiredSecrets[] | select(.name == \"$secret\") | .keys[]" "$svc_file")
    done < <(yq -r '.spec.requiredSecrets[]?.name' "$svc_file")
  done < <(yq -r '.spec.environments[].env' "$svc_file")
done

# Không có Secret thô nào lọt vào repo.
while read -r f; do
  [ -n "$f" ] || continue
  if [ "$(yq -r '.kind' "$f")" = "Secret" ]; then
    echo "❌ $f: Secret thô trong Git — phải kubeseal trước khi commit"
    fail=1
  fi
done < <(find secrets -name '*.yaml' 2>/dev/null)

if [ $fail -eq 0 ]; then
  echo "✅ secrets khớp với registry"
  [ $pending -gt 0 ] && echo "⏳ còn $pending secret chưa niêm phong — xem $PENDING_FILE"
fi
exit $fail
