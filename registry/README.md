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

## 15 service, và những chỗ phải thoả hiệp

Cả 13 service của cây cũ đã sang đây (`push-notify-v2` tách thành API + worker
nên thành 15). Bốn chỗ không khớp hoàn toàn với chart chung, mỗi chỗ khai rõ
tại chỗ và gỡ được:

| Service | Thoả hiệp | Gỡ bằng cách nào |
|---|---|---|
| `push-notify` | `probeType: tcp` — chart cũ không khai probe nào, app chưa rõ có endpoint sức khoẻ không. **Cổng mở không có nghĩa app còn phục vụ được.** | Xác nhận đường `/health` của app rồi đổi sang `probeType: http` |
| `server-control` | `hostNetwork: true` — Wake-on-LAN là broadcast UDP trong LAN, mạng pod không chuyển tiếp được | Chỉ gỡ được nếu bỏ tính năng WoL |
| `server-control` | Tag `1.1.0` không phải git SHA | Repo đó gắn tag SHA lúc build, rồi xoá dòng trong `ci/policy/workload.rego` |
| `gorush` | Tag `latest` của chart cũ đổi thành `1.18.5` | Renovate mở PR khi có bản mới |

Hai ngoại lệ của `server-control` nằm trong `ci/policy/*.rego` dưới dạng map có
tên và lý do — không phải một `--force` ở đâu đó. Xoá dòng là CI chặn lại ngay.

## Ứng dụng chỉ đọc file cấu hình, không đọc biến môi trường

`push-notify` và `push-notify-v2` thuộc loại này. Mật khẩu không thể nằm trong
ConfigMap (nó ở Git), nên chart dùng `app.configInject`: một initContainer chép
cấu hình sang `emptyDir` rồi `yq` trộn giá trị từ Secret vào.

```yaml
app:
  secretName: push-notify-config
  configInject:
    fields:
      - path: .database.user
        key: DB_USER
```

Container chính mount bản **đã trộn**, không mount ConfigMap. Giá trị bí mật chỉ
tồn tại trong bộ nhớ của pod.

## Worker không phải HTTP service

`push-notify-v2-worker` khai `service.enabled: false`: không Service, không
Ingress, không probe, không cổng. Chart gắn nhãn `hnq.dev/workload: worker` và
`ci/policy/workload.rego` đọc nhãn đó để biết được phép bỏ `readinessProbe` —
ngoại lệ theo **tính chất** của workload, không theo tên service.
