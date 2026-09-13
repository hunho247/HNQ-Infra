#!/usr/bin/env bash
# Dựng lại hnq-01 trên VPS mới (RECOVERY.md R6). 45 phút.
#
# Script này KHÔNG tự chạy các bước — nó in đúng thứ tự, kiểm điều kiện, và
# chặn ở những chỗ làm sai là mất thêm hàng giờ. Lúc đang gấp, thứ cần là một
# danh sách đúng thứ tự, không phải một script tự động mà bạn không biết nó
# đang làm gì.
set -euo pipefail

KIT="${1:-$HOME/hnq-kit}"

echo "== Điều kiện cần =="
missing=0
for f in etcd-snapshot token encryption-config.json; do
  if [ -f "$KIT/$f" ]; then
    echo "  ✅ $f"
  else
    echo "  ❌ THIẾU $f"
    missing=1
  fi
done
if [ $missing -eq 1 ]; then
  cat <<'EOF'

Thiếu món #2 (token) hoặc #4 (encryption-config.json) thì quy trình R6 KHÔNG
chạy được:
  - thiếu token   → snapshot không restore được lên máy mới
  - thiếu #4      → cluster lên nhưng không đọc được Secret nào
Đi đường R8 (dựng lại từ Git, 3 giờ) — RECOVERY.md.
EOF
  exit 1
fi

cat <<'STEPS'

== Bước 0 — xác nhận có thời gian ==
  curl -sS -o /dev/null -w '%{http_code}\n' https://client-lotus-clinic.l2cteam.work/health
  200 → khách hàng không bị ảnh hưởng. Làm cẩn thận, đừng làm nhanh.

== ⚠️ Bước 1 — xoá device cũ khỏi tailnet TRƯỚC khi dựng máy mới ==
  Tailscale admin console → Machines → hnq-01 → Delete

  Không xoá thì máy mới bị đặt tên hnq-01-1, và tên MagicDNS mà 2 agent đang
  trỏ vào sẽ trỏ vào máy đã chết → phải SSH sửa từng agent lúc đang gấp.

== Bước 2 — VPS mới, Tailscale trước, k3s sau ==
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up --hostname=hnq-01
  sudo mkdir -p /srv/k3s/snapshots

== Bước 3 — config.yaml y hệt bản cũ ==
  Chép nodes/hnq-01.config.yaml, sửa node-ip + node-external-ip theo máy mới.
  ⚠️ tls-san phải giữ nguyên tên MagicDNS — đó là thứ 2 agent đang trỏ vào.

== Bước 4 — đặt lại token và encryption config TRƯỚC khi cài k3s ==
  sudo mkdir -p /var/lib/rancher/k3s/server/cred
  sudo cp <kit>/token                    /var/lib/rancher/k3s/server/token
  sudo cp <kit>/encryption-config.json   /var/lib/rancher/k3s/server/cred/
  sudo chmod 600 /var/lib/rancher/k3s/server/token \
                 /var/lib/rancher/k3s/server/cred/encryption-config.json

== Bước 5 — cài k3s rồi restore ngay từ snapshot ==
  curl -sfL https://get.k3s.io | sh -
  scripts/dr/restore-etcd.sh --from-r2 <tên object trên R2>

== Bước 6 — 2 agent tự quay lại ==
  Chúng trỏ vào tên MagicDNS nên không phải sửa gì. Nếu "Node password
  rejected" thì làm bước 3 của restore-etcd.sh.

== Bước 7 — xác nhận ==
  kubectl get nodes -o wide          # đủ 3, IP dải 100.x
  make drift
  make kit-check                     # snapshot mới, token mới → cất lại kit

- [ ] RUNBOOK.md: thời gian thực tế, chỗ nào chậm
STEPS
