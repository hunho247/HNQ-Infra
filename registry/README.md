# registry/ — nơi duy nhất sửa khi thêm hoặc đổi một service

Một service = một thư mục `registry/apps/<tên-service>/`. Không viết
Application nào bằng tay: `gitops/bootstrap/appset-apps.yaml` đọc thư mục này
và sinh ra Application (PLAN §5, §7).

```
registry/apps/<tên-service>/
├── service.yaml           # chart nào, bật env nào, cần secret gì
├── values-dev.yaml        # chỉ ghi phần KHÁC mặc định
├── values-prod.yaml
└── config/                # chỉ khi spec.config: true
    ├── config-dev.yaml
    └── config-prod.yaml
```

## Quy ước cứng (CI kiểm)

| Thứ | Quy ước |
|---|---|
| Namespace | `<tên-service>-<env>` — chart tự suy ra, không khai trong values |
| Release Helm | `<tên-service>` |
| Application | `<tên-service>-<env>` |
| Service (DNS) | `<tên-service>.<tên-service>-<env>.svc.cluster.local` |
| Secret | `<tên-service>-<thành-phần>`, file ở `secrets/<env>/<tên-service>/<thành-phần>.yaml` |
| Tag image | git SHA (không `latest`, không tag trôi) |

## `config/` là values file, không phải file cấu hình thô

ArgoCD chỉ đưa được **values file** từ gốc repo vào một chart; `.Files.Get`
của Helm không với ra ngoài thư mục chart. Nên nội dung cấu hình nằm dưới
khoá `app.config`:

```yaml
app:
  config: |
    env: "dev"
    server:
      address: ":1001"
```

Chart đưa chuỗi đó vào ConfigMap, rồi mount thành file
(`app.configMount: true`, mặc định) hoặc truyền qua biến môi trường
(`app.configEnvVar: APP_CONFIG_YAML`). Một nguồn sự thật, không có bước sinh
file trung gian nào phải nhớ chạy.

Bật bằng `spec.config: true` trong `service.yaml`.

## Bật prod

Mọi service đang chỉ khai `- env: dev`. Thêm `- env: prod` là có Application
prod ngay lần sync sau — **chỉ làm sau khi P5 xong** (Velero + dump hằng giờ),
đúng cửa chặn 2 của PLAN §16. `values-prod.yaml` đã viết sẵn cho từng service
nên bật prod là sửa đúng một dòng.

## Chưa migrate — và vì sao

| Service cũ | Vướng | Cần gì để migrate |
|---|---|---|
| `push-notify`, `gorush` | Chart cũ **không khai probe nào**; `webservice` bắt buộc `probePath` | Xác nhận endpoint sức khoẻ thật của hai app rồi thêm `probePath` |
| `push-notify-v2` + worker | Worker không phải HTTP service, và chart cũ dùng initContainer `yq` để trộn secret vào file cấu hình | Chart thứ ba cho worker, hoặc đổi app đọc secret qua env |
| `server-control` | Cần `hostNetwork` cho Wake-on-LAN — policy `ci/policy/security.rego` chặn | Quyết định có mở ngoại lệ không; nếu có thì ghi rõ lý do trong policy |

Ba service này vẫn nằm ở `infra/` (cây cũ) cho tới khi có quyết định — xem
`infra/README.md`.
