#!/usr/bin/env bash
# Nạp lại một database từ dump hằng giờ trên R2 (RECOVERY.md R4 bước 5, R7).
#
#   scripts/dr/restore-db.sh <service> <env> [latest|<tên file>] [--to-temp]
#
# Mặc định nạp vào database TẠM (<db>_restore) chứ KHÔNG đè bản chính — đó là
# cách biến sự cố mất 1 giờ dữ liệu thành sự cố mất 1 ngày. Muốn đè thật thì
# phải gõ --overwrite và xác nhận bằng tay.
set -euo pipefail

SVC="${1:-}"; ENV="${2:-}"; WHICH="${3:-latest}"; MODE="${4:---to-temp}"
[ -n "$SVC" ] && [ -n "$ENV" ] || { echo "dùng: restore-db.sh <service> <env> [latest|<file>] [--overwrite]"; exit 1; }

NS="$SVC-$ENV"
REMOTE="r2:hnq-dumps/$ENV/$SVC"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Service:  $SVC ($NS)"
echo "Nguồn:    $REMOTE"
echo "Chế độ:   $MODE"
echo

# 1. Chọn bản dump
if [ "$WHICH" = "latest" ]; then
  FILE="$(rclone lsf "$REMOTE" | sort | tail -1)"
  [ -n "$FILE" ] || { echo "❌ không có dump nào ở $REMOTE"; exit 1; }
else
  FILE="$WHICH"
fi
echo "→ dùng $FILE"
rclone lsl "$REMOTE/$FILE"
echo

read -r -p "Đúng bản này chứ? [y/N] " ok
[ "$ok" = "y" ] || exit 1

rclone copy "$REMOTE/$FILE" "$WORK/"

POD="$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$SVC" -o name | head -1)"
[ -n "$POD" ] || { echo "❌ không thấy pod nào ở $NS"; exit 1; }

# 2. Nạp
case "$SVC" in
  storage-mariadb)
    TARGET="restore_$(date +%Y%m%d%H%M)"
    if [ "$MODE" = "--overwrite" ]; then
      echo "⚠️  SẼ ĐÈ database đang chạy. Gõ đúng chữ ĐÈ để tiếp tục:"
      read -r c; [ "$c" = "ĐÈ" ] || exit 1
      gunzip -c "$WORK/$FILE" | kubectl -n "$NS" exec -i "$POD" -- \
        sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
    else
      kubectl -n "$NS" exec -i "$POD" -- \
        sh -c "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" -e 'CREATE DATABASE $TARGET'"
      gunzip -c "$WORK/$FILE" | kubectl -n "$NS" exec -i "$POD" -- \
        sh -c "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" $TARGET"
      echo "✅ nạp vào database tạm $TARGET — lấy đúng phần cần bằng INSERT ... SELECT (RECOVERY.md R7 bước 3)"
    fi
    ;;
  storage-postgres)
    if [ "$MODE" = "--overwrite" ]; then
      echo "⚠️  SẼ ĐÈ database đang chạy. Gõ đúng chữ ĐÈ để tiếp tục:"
      read -r c; [ "$c" = "ĐÈ" ] || exit 1
      gunzip -c "$WORK/$FILE" | kubectl -n "$NS" exec -i "$POD" -- \
        sh -c 'psql -U "$POSTGRES_USER" postgres'
    else
      TARGET="restore_$(date +%Y%m%d%H%M)"
      kubectl -n "$NS" exec -i "$POD" -- sh -c "createdb -U \"\$POSTGRES_USER\" $TARGET"
      gunzip -c "$WORK/$FILE" | kubectl -n "$NS" exec -i "$POD" -- \
        sh -c "psql -U \"\$POSTGRES_USER\" $TARGET"
      echo "✅ nạp vào database tạm $TARGET"
    fi
    ;;
  storage-redis)
    echo "Redis: dump là file RDB, phải thay file rồi khởi động lại pod."
    echo "  1. kubectl -n $NS scale sts $SVC --replicas=0"
    echo "  2. chép $WORK/$FILE vào /srv/k3s/data/$NS-$SVC-data/dump.rdb trên node"
    echo "  3. kubectl -n $NS scale sts $SVC --replicas=1"
    echo "Không tự động hoá: thao tác đụng thẳng vào file trên đĩa node."
    exit 0
    ;;
  *)
    echo "❌ chưa có quy trình nạp cho $SVC — dump nằm ở $WORK/$FILE"
    exit 1
    ;;
esac

echo
echo "Đừng quên: RUNBOOK.md — mất bao nhiêu dữ liệu, và làm gì để không lặp lại."
