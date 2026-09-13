#!/usr/bin/env bash
# Đưa image từ dev lên prod (PLAN §14, D5).
#
#   ci/scripts/promote.sh <tên-service> [--force]
#
# Chạy trên máy CÓ quyền vào cluster, nên kiểm được 3 thứ mà CI trên GitHub
# không thấy. Kết quả là một commit trên nhánh mới + gợi ý mở PR — script này
# không bao giờ tự push vào main.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SVC="${1:-}"
FORCE="${2:-}"
[ -n "$SVC" ] || { echo "dùng: promote.sh <tên-service> [--force]"; exit 1; }

DEV="registry/apps/$SVC/values-dev.yaml"
PROD="registry/apps/$SVC/values-prod.yaml"
[ -f "$DEV" ] && [ -f "$PROD" ] || { echo "không thấy $DEV hoặc $PROD"; exit 1; }

TAG="$(yq -r '.image.tag' "$DEV")"
CUR="$(yq -r '.image.tag' "$PROD")"

[ "$TAG" != "null" ] && [ -n "$TAG" ] || { echo "$DEV không có image.tag"; exit 1; }
if [ "$TAG" = "$CUR" ]; then
  echo "prod đã ở $TAG — không có gì để promote"
  exit 0
fi

echo "→ $SVC: prod $CUR → $TAG"
echo

# --- Cửa 1: dev phải Synced + Healthy --------------------------------------
STATUS="$(kubectl -n argocd get application "$SVC-dev" \
  -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo "?/?")"
if [ "$STATUS" != "Synced/Healthy" ]; then
  echo "❌ cửa 1: $SVC-dev đang $STATUS, phải Synced/Healthy"
  [ "$FORCE" = "--force" ] || exit 1
  echo "   (bỏ qua vì --force)"
else
  echo "✅ cửa 1: $SVC-dev Synced/Healthy"
fi

# --- Cửa 2: pod dev sống ≥ 30 phút, 0 restart ------------------------------
NS="$SVC-dev"
POD="$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$SVC" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$POD" ]; then
  echo "❌ cửa 2: không thấy pod nào ở $NS"
  [ "$FORCE" = "--force" ] || exit 1
else
  START="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.startTime}')"
  AGE_MIN=$(( ( $(date +%s) - $(date -d "$START" +%s) ) / 60 ))
  RESTARTS="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  if [ "$AGE_MIN" -ge 30 ] && [ "$RESTARTS" -eq 0 ]; then
    echo "✅ cửa 2: pod dev chạy ${AGE_MIN} phút, 0 restart"
  else
    echo "⚠️  cửa 2: pod dev chạy ${AGE_MIN} phút, $RESTARTS restart"
    [ "$FORCE" = "--force" ] || { echo "   dùng --force nếu chắc"; exit 1; }
  fi
fi

# --- Cửa 3: tag ở dev đúng là tag đang chạy ---------------------------------
RUNNING="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)"
if [ -n "$RUNNING" ] && [ "${RUNNING##*:}" != "$TAG" ]; then
  echo "❌ cửa 3: pod dev đang chạy ${RUNNING##*:}, còn values-dev.yaml ghi $TAG — dev chưa sync xong"
  [ "$FORCE" = "--force" ] || exit 1
else
  echo "✅ cửa 3: tag ở Git khớp tag đang chạy"
fi

# --- Sửa file + commit ------------------------------------------------------
BRANCH="promote/$SVC-$TAG"
git switch -c "$BRANCH" >/dev/null 2>&1 || git switch "$BRANCH"
yq -i ".image.tag = \"$TAG\"" "$PROD"
git add "$PROD"
git commit -q -F - <<EOF
release($SVC): prod $CUR → $TAG

Quay lui: git revert \$(git rev-parse --short HEAD) → prod về $CUR
dev đã chạy $TAG liên tục ${AGE_MIN:-?} phút, ${RESTARTS:-?} restart.
EOF

echo
echo "✅ đã commit trên nhánh $BRANCH"
echo "   git push -u origin $BRANCH  → mở PR → đọc diff → merge"
