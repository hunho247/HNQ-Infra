#!/usr/bin/env bash
# Dời toàn bộ môi trường prod sang node còn sống (RECOVERY.md R4).
#
#   scripts/dr/failover-prod.sh <node-đích> [--yes]
#
# ⚠️ Đây là thao tác PHÁ HUỶ: phải xoá PVC prod để chúng được cấp lại trên node
# mới. Trước khi chạy, trả lời câu hỏi ở bước 0 của R4:
#     "Máy chết có sống lại trong ≤ 20 phút không?"
#     Có → CHỜ. Bật lại máy là mất 0 dữ liệu. Script này mất tới 1 giờ.
set -euo pipefail

TARGET="${1:-}"
YES="${2:-}"
[ -n "$TARGET" ] || { echo "dùng: failover-prod.sh <node-đích> [--yes]"; exit 1; }

DEAD="${HNQ_DEAD_NODE:-hnq-02}"

echo "Dời prod: $DEAD (chết) → $TARGET"
echo
echo "Trước khi tiếp tục, xác nhận: $DEAD KHÔNG sống lại trong 20 phút tới."
if [ "$YES" != "--yes" ]; then
  read -r -p "Gõ đúng tên node đích để tiếp tục: " c
  [ "$c" = "$TARGET" ] || { echo "huỷ"; exit 1; }
fi

echo
echo "0. Snapshot trước mọi thao tác phá huỷ"
ssh hnq-01 "sudo k3s etcd-snapshot save --name failover-$(date +%Y%m%d-%H%M)"

echo
echo "1. $TARGET nhận nhãn prod"
kubectl label node "$TARGET" hnq.dev/env-prod=true --overwrite

echo
echo "2. Nhường tài nguyên: tắt automated của dev TRƯỚC rồi mới scale 0"
# scale --replicas=0 một mình không đủ — selfHeal kéo lại sau ≤ 3 phút.
for a in $(kubectl -n argocd get app -o name | grep -- '-dev$'); do
  kubectl -n argocd patch "$a" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
done
for ns in $(kubectl get ns -o name | grep -- '-dev$' | cut -d/ -f2); do
  kubectl -n "$ns" scale deploy,statefulset --all --replicas=0
done
echo "⚠️  GHI NGAY vào RUNBOOK.md: dev đang tắt automated + scale 0. Rất dễ quên bật lại."

echo
echo "3. Cho Kubernetes biết $DEAD đã chết"
kubectl delete node "$DEAD" --wait=false

echo
echo "4. Giải phóng PVC prod (reclaimPolicy Retain → dữ liệu trên $DEAD vẫn còn)"
for ns in $(kubectl get ns -o name | grep -- '-prod$' | cut -d/ -f2); do
  kubectl -n "$ns" delete pvc --all --wait=false
  kubectl -n "$ns" delete pod --all --wait=false
done

echo
echo "5. Đợi PVC bound lại trên $TARGET"
kubectl get pvc -A | grep -- '-prod' || true

cat <<'NEXT'

Còn lại là việc phải nhìn kết quả mới quyết được:

  scripts/dr/restore-db.sh storage-mariadb  prod latest
  scripts/dr/restore-db.sh storage-postgres prod latest
  velero restore create --from-backup "$(velero backup get -o name | head -1)" \
    --include-namespaces storage-minio-prod --wait

Rồi:
  make drift
  curl -sS -o /dev/null -w '%{http_code}\n' https://client-lotus-clinic.l2cteam.work/health

⚠️ Trong lúc chưa dựng lại node chết: prod và dev chung một node, KHÔNG CÒN DỰ PHÒNG.
NEXT
