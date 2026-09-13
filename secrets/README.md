# secrets/ — SealedSecret, không bao giờ là Secret thô

```
secrets/<env>/<service>/<thành-phần>.yaml     # kind: SealedSecret
```

Tên file suy ra từ tên Secret: Secret `lotus-clinic-backend` của env `dev` nằm
ở `secrets/dev/lotus-clinic/backend.yaml`. `ci/scripts/check-secrets.sh` đối
chiếu đúng theo quy ước đó với `requiredSecrets` trong `service.yaml`, và kiểm
cả namespace lẫn danh sách key.

## Niêm phong

```bash
kubectl create secret generic lotus-clinic-backend -n lotus-clinic-prod \
  --from-literal=DB_PASSWORD='...' --dry-run=client -o yaml \
| kubeseal --format yaml > secrets/prod/lotus-clinic/backend.yaml
```

⚠️ SealedSecret gắn chặt với **namespace + tên**. Đổi một trong hai là phải
niêm phong lại — controller sẽ từ chối giải mã, và thông báo lỗi nằm trong log
của controller chứ không nằm ở Application.

## Sealing key là món #3 của recovery kit

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml
```

Mất nó thì mọi file trong thư mục này thành vô nghĩa. Controller xoay key mỗi
30 ngày → backup lại hằng quý. `make kit-check` kiểm hằng tháng.

## `PENDING`

Service nào chưa niêm phong secret thì nằm ở [`PENDING`](./PENDING). Đó là nợ
nhìn thấy được, không phải ngoại lệ im lặng: mọi lỗi khác vẫn làm CI đỏ.
