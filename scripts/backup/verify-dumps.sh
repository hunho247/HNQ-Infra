#!/usr/bin/env bash
# Dump có thật sự lên tới R2 không, và có còn mới không?
#
# Backup không kiểm tra là backup không tồn tại: CronJob báo Succeeded mà file
# rỗng, hoặc rclone lỗi quyền, đều trông giống "mọi thứ ổn" cho tới lúc cần.
# Alert #6 (BackupOverdue) bắt trường hợp trễ; script này kiểm cả kích thước.
#
#   scripts/backup/verify-dumps.sh [env]
set -euo pipefail

ENV="${1:-prod}"
REMOTE="r2:hnq-dumps/$ENV"
MAX_AGE_MIN="${MAX_AGE_MIN:-120}"     # dump hằng giờ → quá 2 tiếng là hỏng
MIN_BYTES="${MIN_BYTES:-1024}"

fail=0
for svc in $(rclone lsf --dirs-only "$REMOTE" 2>/dev/null | tr -d '/'); do
  LAST="$(rclone lsl "$REMOTE/$svc" | sort -k2 | tail -1)"
  if [ -z "$LAST" ]; then
    echo "❌ $svc: không có dump nào"
    fail=1
    continue
  fi

  SIZE="$(printf '%s' "$LAST" | awk '{print $1}')"
  WHEN="$(printf '%s' "$LAST" | awk '{print $2" "$3}')"
  NAME="$(printf '%s' "$LAST" | awk '{print $4}')"
  AGE_MIN=$(( ( $(date +%s) - $(date -d "$WHEN" +%s) ) / 60 ))

  if [ "$AGE_MIN" -gt "$MAX_AGE_MIN" ]; then
    echo "❌ $svc: bản mới nhất đã $AGE_MIN phút ($NAME) — CronJob dump đang hỏng"
    fail=1
  elif [ "$SIZE" -lt "$MIN_BYTES" ]; then
    echo "❌ $svc: $NAME chỉ $SIZE byte — dump rỗng, lệnh dump đang lỗi"
    fail=1
  else
    echo "✅ $svc: $NAME, $SIZE byte, $AGE_MIN phút trước"
  fi
done

[ $fail -eq 0 ] && echo && echo "✅ dump $ENV còn mới và có nội dung"
exit $fail
