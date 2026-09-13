#!/usr/bin/env bash
# Restore etcd từ snapshot (RECOVERY.md R5).
#
#   scripts/dr/restore-etcd.sh [<tên snapshot>|--from-r2 <tên object>]
#
# 10 phút, mất tối đa 6 giờ. Khách hàng KHÔNG bị ảnh hưởng trong lúc làm —
# Traefik, cloudflared và pod đang chạy đều nằm ở 2 máy nhà, không cần
# apiserver để phục vụ traffic. Làm cẩn thận, đừng làm nhanh.
set -euo pipefail

SERVER="${HNQ_SERVER:-hnq-01}"

echo "⚠️  Trước tiên: đường dữ liệu còn sống không?"
echo "    curl -sS -o /dev/null -w '%{http_code}' https://client-lotus-clinic.l2cteam.work/health"
echo
read -r -p "Đã kiểm và biết mức độ gấp? [y/N] " ok
[ "$ok" = "y" ] || exit 1

echo
echo "Bước 1 — thử cách rẻ trước. Khoảng một nửa số lần là xong ở đây."
ssh "$SERVER" 'sudo systemctl restart k3s'
sleep 20
if ssh "$SERVER" 'sudo k3s kubectl get nodes' 2>/dev/null; then
  echo "✅ apiserver lên lại sau restart — KHÔNG cần restore. Dừng ở đây."
  exit 0
fi

echo
echo "Bước 2 — restore snapshot"
ssh "$SERVER" 'sudo k3s etcd-snapshot ls' || true
echo
SNAP="${1:-}"
if [ -z "$SNAP" ]; then
  read -r -p "Tên snapshot (hoặc --from-r2 <tên object>): " SNAP EXTRA || true
fi

echo
echo "⚠️  Lệnh dưới đây chạy Ở FOREGROUND trên $SERVER."
echo "    Đợi dòng: 'Managed etcd cluster membership has been reset, restart"
echo "    without --cluster-reset flag now' rồi Ctrl-C. ĐỪNG để nó chạy tiếp."
echo
if [ "$SNAP" = "--from-r2" ]; then
  OBJ="${2:-${EXTRA:-}}"
  [ -n "$OBJ" ] || { echo "thiếu tên object trên R2"; exit 1; }
  echo "Chạy trên $SERVER (khoá R2 lấy từ recovery kit — lúc này chưa có cluster để đọc Secret):"
  cat <<EOF

  sudo k3s server --cluster-reset \\
    --etcd-s3 --etcd-s3-endpoint="<account>.r2.cloudflarestorage.com" \\
    --etcd-s3-bucket="hnq-etcd-snapshots" \\
    --etcd-s3-access-key="..." --etcd-s3-secret-key="..." \\
    --cluster-reset-restore-path="$OBJ"

EOF
  exit 0
fi

ssh -t "$SERVER" "sudo systemctl stop k3s && sudo k3s server --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/$SNAP" || true

echo
read -r -p "Đã thấy dòng 'membership has been reset' và Ctrl-C chưa? [y/N] " ok
[ "$ok" = "y" ] || { echo "dừng — đọc RECOVERY.md R5 trước khi đi tiếp"; exit 1; }

ssh "$SERVER" 'sudo systemctl start k3s'
sleep 15
kubectl get nodes || true

cat <<'NEXT'

Bước 3 — chỗ biến 10 phút thành 2 giờ: "Node password rejected".
Snapshot có từ TRƯỚC lúc agent join thì mật khẩu node không khớp, agent không
vào lại được. Nếu kubectl get nodes thiếu hnq-02/hnq-03:

  kubectl -n kube-system delete secret hnq-02.node-password.k3s hnq-03.node-password.k3s
  ssh hnq-02 'sudo systemctl restart k3s-agent'
  ssh hnq-03 'sudo systemctl restart k3s-agent'
  kubectl get nodes -w

Bước 4 — dọn phần lệch (snapshot cũ hơn main vài giờ):

  argocd app sync -l hnq.dev/env
  make drift

SealedSecret tạo sau thời điểm snapshot: file mã hoá vẫn ở Git nên ArgoCD
apply lại là controller giải lại — với điều kiện sealing key không đổi.
NEXT
