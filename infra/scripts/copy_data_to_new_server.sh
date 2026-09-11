NEW_HOST="14.225.222.153"
NEW_USER="root"
NEW_PORT="22"
NEW_BASE="/home/hnq/hnq_data"

# Sửa nếu dev của bạn đang ở path khác
OLD_DEV_BASE="/srv/data/dev/platform/storage"
# OLD_DEV_BASE="/home/server01/k3s/mysrv/envs/dev/data/common/storage"

OLD_PROD_BASE="/home/server01/k3s/mysrv/envs/prod/data/common/storage"
OLD_OUTLINE="/home/server01/k3s/mysrv/envs/dev/data/common/admin/outline/data"
OLD_BACKUP="/home/server01/k3s/hnq_backup"

SERVICES="mariadb minio opensearch postgres redis"

ssh -p "$NEW_PORT" "$NEW_USER@$NEW_HOST" "mkdir -p \
$NEW_BASE/dev/platform/storage/{mariadb,minio,opensearch,postgres,redis} \
$NEW_BASE/prod/platform/storage/{mariadb,minio,opensearch,postgres,redis} \
$NEW_BASE/dev/platform/admin/outline/data \
$NEW_BASE/backup"

for svc in $SERVICES; do
  [ -d "$OLD_DEV_BASE/$svc" ] && rsync -aHAXv --numeric-ids --info=progress2 -e "ssh -p $NEW_PORT" \
    "$OLD_DEV_BASE/$svc/" "$NEW_USER@$NEW_HOST:$NEW_BASE/dev/platform/storage/$svc/"

  [ -d "$OLD_PROD_BASE/$svc" ] && rsync -aHAXv --numeric-ids --info=progress2 -e "ssh -p $NEW_PORT" \
    "$OLD_PROD_BASE/$svc/" "$NEW_USER@$NEW_HOST:$NEW_BASE/prod/platform/storage/$svc/"
done

[ -d "$OLD_OUTLINE" ] && rsync -aHAXv --numeric-ids --info=progress2 -e "ssh -p $NEW_PORT" \
  "$OLD_OUTLINE/" "$NEW_USER@$NEW_HOST:$NEW_BASE/dev/platform/admin/outline/data/"

[ -d "$OLD_BACKUP" ] && rsync -aHAXv --numeric-ids --info=progress2 -e "ssh -p $NEW_PORT" \
  "$OLD_BACKUP/" "$NEW_USER@$NEW_HOST:$NEW_BASE/backup/"
