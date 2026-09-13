#!/usr/bin/env bash
# Recovery kit có ĐỦ 4 MÓN và còn dùng được không? Chạy hằng tháng.
#
# So bằng sha256, KHÔNG in giá trị: mục đích là biết bản cất giữ có còn khớp
# bản trên cluster hay không, không phải để đọc lại bí mật.
#
#   scripts/dr/kit-check.sh [thư-mục-kit]
#
# Thư mục kit là nơi bạn giải nén bản sao từ password manager / USB. Không để
# nó nằm lại trên đĩa: script nhắc shred ở cuối.
set -euo pipefail

KIT="${1:-$HOME/hnq-kit}"
SERVER="${HNQ_SERVER:-hnq-01}"

fail=0
echo "Recovery kit: $KIT"
echo "Cluster:      $SERVER"
echo

check() {
  local n="$1" file="$2" live_cmd="$3" desc="$4"
  printf '%d. %-28s ' "$n" "$desc"

  if [ ! -f "$KIT/$file" ]; then
    echo "❌ THIẾU trong kit ($file)"
    fail=1
    return
  fi

  local kit_sum live_sum
  kit_sum="$(sha256sum < "$KIT/$file" | cut -d' ' -f1)"
  live_sum="$(eval "$live_cmd" 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"

  if [ -z "$live_sum" ] || [ "$live_sum" = "$(printf '' | sha256sum | cut -d' ' -f1)" ]; then
    echo "⚠️  có trong kit, KHÔNG đọc được bản trên cluster để đối chiếu"
    fail=1
  elif [ "$kit_sum" = "$live_sum" ]; then
    echo "✅ khớp"
  else
    echo "❌ LỆCH — bản trong kit đã cũ, cất lại ngay"
    fail=1
  fi
}

# Món 1 — etcd snapshot. Không so hash (mỗi snapshot một khác); kiểm còn mới.
printf '1. %-28s ' "etcd snapshot"
LAST="$(ssh "$SERVER" 'ls -t /srv/k3s/snapshots/ 2>/dev/null | head -1' 2>/dev/null || true)"
if [ -z "$LAST" ]; then
  echo "❌ không thấy snapshot nào trên $SERVER"
  fail=1
else
  AGE_H="$(ssh "$SERVER" "echo \$(( ( \$(date +%s) - \$(stat -c %Y /srv/k3s/snapshots/$LAST) ) / 3600 ))")"
  if [ "$AGE_H" -le 12 ]; then
    echo "✅ $LAST (${AGE_H}h trước)"
  else
    echo "❌ $LAST đã ${AGE_H}h — lịch 6 giờ đang không chạy"
    fail=1
  fi
fi
[ -f "$KIT/etcd-snapshot" ] || { echo "   ⚠️  kit không có bản snapshot rời (R8 cần nó khi mất cả 3 máy)"; fail=1; }

# Món 2 — k3s token. Thiếu nó thì snapshot vô dụng.
check 2 token "ssh $SERVER 'sudo cat /var/lib/rancher/k3s/server/token'" "k3s token"

# Món 3 — sealing key của Sealed Secrets. Thiếu nó thì cả thư mục secrets/
# thành vô nghĩa. Controller xoay key mỗi 30 ngày → backup lại hằng quý.
check 3 sealing-key.yaml \
  "kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml" \
  "sealing key"

# Món 4 — encryption-config.json. Thiếu nó thì restore được cluster nhưng
# không đọc được Secret nào (D14).
check 4 encryption-config.json \
  "ssh $SERVER 'sudo cat /var/lib/rancher/k3s/server/cred/encryption-config.json'" \
  "encryption-config.json"

echo
if [ $fail -eq 0 ]; then
  echo "✅ đủ 4 món và còn khớp"
else
  echo "❌ kit KHÔNG dùng được như hiện tại — xem RECOVERY.md mục Recovery kit"
fi
echo
echo "Nhớ: shred -u $KIT/* sau khi kiểm xong."
exit $fail
