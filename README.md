# HNQ-Infra

Hạ tầng **k3s + ArgoCD**: 1 VPS thuê (`hnq-01`, control-plane) + 2 máy ở nhà
(`hnq-02`, `hnq-03`), join qua Tailscale, vào từ internet qua Cloudflare
Tunnel, **1 người vận hành**.

Thiết kế và mọi quyết định đã chốt: **[docs/PLAN.md](./docs/PLAN.md)**.
Đang có sự cố: **[docs/RECOVERY.md](./docs/RECOVERY.md)** — bắt đầu ở "60 giây
đầu tiên".

## Cây thư mục

```text
registry/apps/          ⭐ NƠI DUY NHẤT sửa khi thêm service — registry/README.md
charts/                 hnq-common (library) + webservice + datastore
env/{dev,prod}.yaml     khác biệt dev ↔ prod, nạp cho MỌI service
gitops/                 root.yaml · 2 AppProject · 1 ApplicationSet · 9 Application platform
secrets/{dev,prod}/     SealedSecret — secrets/README.md
nodes/                  bản mẫu /etc/rancher/k3s/config.yaml của 3 máy
ci/                     policy conftest + script kiểm và promote
scripts/                status · drift · backup · dr/ (⭐ nơi đi tới khi đang sự cố)
docs/                   PLAN · OPERATIONS · RECOVERY · RESEARCH_BEST_PRACTICES
infra/                  cây CŨ, giữ để tra cứu cho tới khi migrate xong
```

## Bắt đầu

```bash
make help          # danh sách lệnh
make validate      # chạy đúng các cửa mà CI sẽ chạy, ngay trên máy
```

Dựng cluster lần đầu: [docs/OPERATIONS.md](./docs/OPERATIONS.md) → `make bootstrap`.

## Thêm một service

```bash
make new-service NAME=abc-clinic CHART=webservice
# sửa CHANGEME → niêm phong secret → make validate → commit → PR
```

Không viết file ArgoCD nào: ApplicationSet đọc `registry/apps/` và tự sinh
Application.

## Bốn lệnh đáng thuộc nằm lòng

| Lệnh | Khi nào |
|---|---|
| `make drift` | hằng tuần — cái gì lệch Git, **và đường dữ liệu còn 2 replica trên 2 node không** |
| `make snapshot` | trước mọi thao tác có `delete`, `reset`, `rm`, `--force`. Mất 10 giây |
| `make kit-check` | hằng tháng — recovery kit còn đủ **4 món** và còn dùng được không |
| `make dr` | lúc sự cố, khi không nhớ nổi phải làm gì |

## Ba thứ nhớ nằm lòng

1. **Recovery kit có 4 món**: etcd snapshot · k3s token · sealing key ·
   `encryption-config.json`. Thiếu token thì snapshot vô dụng; thiếu
   encryption config thì restore xong không đọc được Secret nào.
2. **Master chết ≠ khách hàng chết.** Traefik, cloudflared và mọi pod đều ở 2
   máy nhà. Kiểm `curl .../health` trước, rồi mới quyết định gấp hay không.
3. **Không bật prod trước khi P5 xong.** Không có Velero + dump hằng giờ thì
   service prod không có đường lùi (PLAN §16, cửa chặn 2).
