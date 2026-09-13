#!/usr/bin/env bash
# Kiểm LỆCH, không chỉ kiểm sức khoẻ.
#
# Ở topology này "mọi thứ Healthy" KHÔNG có nghĩa "còn dự phòng": cả 2 replica
# Traefik có thể đang nằm chung một node mà ArgoCD vẫn báo xanh — cho tới lúc
# node đó tắt. Chạy hằng tuần (OPERATIONS.md).
set -euo pipefail

warn=0

echo "1. Application lệch khỏi Git"
OUT="$(kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
  --no-headers 2>/dev/null | grep -v 'Synced *Healthy' || true)"
if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT" | sed 's/^/  ❌ /'
  warn=1
else
  echo "  ✅ mọi thứ khớp Git"
fi

echo
echo "2. Đường dữ liệu — mỗi thành phần phải 2 pod, trên 2 node khác nhau, không có hnq-01"
for app in traefik cloudflared coredns; do
  NODES="$(kubectl get pod -A -l "app.kubernetes.io/name=$app" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort || true)"
  [ -z "$NODES" ] && NODES="$(kubectl -n kube-system get pod -l "k8s-app=kube-dns" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort || true)"

  COUNT="$(printf '%s\n' "$NODES" | grep -c . || true)"
  UNIQ="$(printf '%s\n' "$NODES" | sort -u | grep -c . || true)"

  if [ "$COUNT" -lt 2 ]; then
    echo "  ❌ $app chỉ có $COUNT pod — KHÔNG CÒN DỰ PHÒNG"
    warn=1
  elif [ "$UNIQ" -lt 2 ]; then
    echo "  ❌ $app có $COUNT pod nhưng đều nằm trên $(printf '%s' "$NODES" | head -1) — KHÔNG CÒN DỰ PHÒNG"
    warn=1
  else
    echo "  ✅ $app: $COUNT pod trên $UNIQ node"
  fi

  if printf '%s\n' "$NODES" | grep -q hnq-01; then
    echo "  ⚠️  $app có replica trên master — sai nodeSelector hnq.dev/edge"
    warn=1
  fi
done

echo
echo "3. Workload lọt lên master (taint D9 phải giữ chúng ở ngoài)"
ON_MASTER="$(kubectl get pod -A --field-selector spec.nodeName=hnq-01 \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -Ev '^(kube-system|argocd|cert-manager|velero|system-upgrade|monitoring)/' || true)"
if [ -n "$ON_MASTER" ]; then
  printf '%s\n' "$ON_MASTER" | sed 's/^/  ❌ /'
  warn=1
else
  echo "  ✅ không có workload lạ trên hnq-01"
fi

echo
echo "4. CoreDNS còn 2 replica (kubectl scale không nằm trong Git — PLAN §3)"
REPLICAS="$(kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
if [ "$REPLICAS" = "2" ]; then
  echo "  ✅ coredns replicas=2"
else
  echo "  ❌ coredns replicas=$REPLICAS — chạy: kubectl -n kube-system scale deploy coredns --replicas=2"
  warn=1
fi

echo
echo "5. Backup còn mới không"
LAST_SNAP="$(ssh hnq-01 'ls -t /srv/k3s/snapshots/ 2>/dev/null | head -1' 2>/dev/null || true)"
if [ -n "$LAST_SNAP" ]; then
  echo "  ✅ etcd snapshot gần nhất: $LAST_SNAP"
else
  echo "  ⚠️  không đọc được /srv/k3s/snapshots trên hnq-01"
  warn=1
fi
kubectl -n velero get backup --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -3 | sed 's/^/  /' || \
  echo "  ⚠️  chưa có Velero backup nào"

echo
[ $warn -eq 0 ] && echo "✅ không có gì lệch" || echo "⚠️  có mục cần xử lý ở trên"
exit 0
