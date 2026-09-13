# nodes/ — cấu hình k3s của 3 máy

Ba file dưới đây là **bản mẫu** của `/etc/rancher/k3s/config.yaml` trên từng
máy. Chúng nằm trong Git vì [R6](../docs/RECOVERY.md#r6--vps-mất-hoàn-toàn)
cần dựng lại `hnq-01` y hệt bản cũ — lúc đó không có thời gian nhớ lại từng
dòng.

Chép lên máy, thay `<...>`, rồi mới cài k3s.

⚠️ **Ba thứ không sửa được sau này mà không cài lại** (PLAN §2):

1. `cluster-init: true` — etcd thay vì SQLite
2. `flannel-iface: tailscale0`
3. `--hostname` của Tailscale — nó đi vào TLS SAN và vào `server:` của 2 agent

> Nhãn khai ở đây **chỉ áp dụng lúc node đăng ký lần đầu**. Sau đó nguồn sự
> thật là `kubectl label` — đó là cơ chế R4 dựa vào để dời cả môi trường prod
> bằng một lệnh.
