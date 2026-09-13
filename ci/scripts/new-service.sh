#!/usr/bin/env bash
# Thêm một service mới: chỉ sinh file trong registry/apps/, không đụng ArgoCD.
#
#   ci/scripts/new-service.sh NAME=abc-clinic CHART=webservice [CONFIG=true]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

NAME=""; CHART=""; CONFIG="false"
for arg in "$@"; do
  case "$arg" in
    NAME=*)   NAME="${arg#NAME=}" ;;
    CHART=*)  CHART="${arg#CHART=}" ;;
    CONFIG=*) CONFIG="${arg#CONFIG=}" ;;
    *) echo "tham số lạ: $arg"; exit 1 ;;
  esac
done

[ -n "$NAME" ]  || { echo "thiếu NAME="; exit 1; }
[ -n "$CHART" ] || { echo "thiếu CHART= (webservice|datastore)"; exit 1; }
case "$CHART" in webservice|datastore) ;; *) echo "CHART phải là webservice hoặc datastore"; exit 1 ;; esac
[[ "$NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "NAME sai định dạng"; exit 1; }

DIR="registry/apps/$NAME"
[ -e "$DIR" ] && { echo "$DIR đã có"; exit 1; }
mkdir -p "$DIR"

cat > "$DIR/service.yaml" <<EOF
apiVersion: hnq.dev/v1
kind: ServiceRelease
metadata:
  name: $NAME
spec:
  category: app
  chart: $CHART
  config: $CONFIG
  environments:
    # Thêm "- env: prod" khi service đã chạy ổn ở dev (PLAN §14).
    - env: dev
  requiredSecrets:
    - name: $NAME-credentials
      keys: [CHANGEME]
EOF

if [ "$CHART" = "webservice" ]; then
  for env in dev prod; do
    host="$NAME-dev.l2cteam.work"; [ "$env" = prod ] && host="$NAME.l2cteam.work"
    cat > "$DIR/values-$env.yaml" <<EOF
# $NAME — $env. Chỉ ghi phần KHÁC mặc định của charts/webservice/values.yaml
# và /env/$env.yaml.
image:
  repository: ghcr.io/hnq-tech/$NAME
  tag: "CHANGEME"

containerPort: 8080
probePath: /health

ingress:
  host: $host

app:
  secretName: $NAME-credentials
EOF
  done
else
  for env in dev prod; do
    cat > "$DIR/values-$env.yaml" <<EOF
# $NAME — $env. Chỉ ghi phần KHÁC mặc định của charts/datastore/values.yaml
# và /env/$env.yaml.
image:
  repository: CHANGEME
  tag: "CHANGEME"

port: 5432
portName: db
secretName: $NAME-credentials

persistence:
  mountPath: /var/lib/data
EOF
  done
  cat >> "$DIR/values-prod.yaml" <<EOF

backup:
  # Lệnh dump ghi ra \$DUMP_FILE. Job chạy ở pod riêng — nhớ -h trỏ vào Service.
  command: |
    CHANGEME > "\$DUMP_FILE"
EOF
fi

if [ "$CONFIG" = "true" ]; then
  mkdir -p "$DIR/config"
  for env in dev prod; do
    cat > "$DIR/config/config-$env.yaml" <<EOF
# Cấu hình ứng dụng của $NAME ($env) — đây là VALUES FILE, nội dung nằm dưới
# app.config (xem registry/README.md).
app:
  config: |
    env: "$env"
EOF
  done
fi

echo "✅ đã tạo $DIR"
echo
echo "Còn 3 việc:"
echo "  1. thay mọi CHANGEME trong $DIR"
echo "  2. niêm phong secret → secrets/dev/$NAME/credentials.yaml, rồi bỏ dòng trong secrets/PENDING"
echo "  3. make validate → commit → PR"
echo
echo "Không phải viết Application nào: ApplicationSet tự sinh $NAME-dev."
