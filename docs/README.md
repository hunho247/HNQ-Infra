# Tài liệu hạ tầng HNQ

Hệ thống: **k3s + ArgoCD**, 1 VPS thuê (master) + 2 máy ở nhà (node), join qua Tailscale, 1 người vận hành.

| Đọc file nào | Khi nào |
|---|---|
| **[PLAN.md](./PLAN.md)** | Đọc **1 lần** để hiểu hệ thống. Quay lại khi thêm service, đổi thiết kế, hoặc quên vì sao một thứ được làm như vậy. |
| **[OPERATIONS.md](./OPERATIONS.md)** | Dựng cluster lần đầu. Sau đó mở hằng tuần — lệnh, giám sát, nâng cấp, lịch vận hành, checklist. |
| **[RECOVERY.md](./RECOVERY.md)** | **Đang có sự cố.** Bắt đầu ở "60 giây đầu tiên", nhảy tới đúng một quy trình. Đọc trước một lần lúc bình thường. |
| [RESEARCH_BEST_PRACTICES.md](./RESEARCH_BEST_PRACTICES.md) | Hồ sơ tra cứu best practice cộng đồng — cơ sở cho các quyết định trong PLAN. Không cần đọc để triển khai. |
| `RUNBOOK.md` | Chưa có — viết ở P6, và bổ sung **mỗi lần gặp sự cố thật** |
| `BREAK_GLASS.md` | Chưa có — viết ở P6, một trang cho người **không** biết Kubernetes |

## Ba thứ nhớ nằm lòng

1. **`make snapshot` trước mọi thao tác có `delete`, `reset`, `rm`, `--force`.** Mất 10 giây.
2. **Recovery kit có 3 món**: etcd snapshot + **k3s token** + sealing key. Thiếu token thì snapshot vô dụng. `make kit-check` hằng tháng.
3. **Master chết ≠ khách hàng chết.** Kiểm `curl .../healthz` trước, rồi mới quyết định gấp hay không.
