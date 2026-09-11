# Issues Log

## 2026-06-18 — Monitoring Alerts Firing

### Issue 1: PrometheusRuleFailures + KubeDaemonSetRolloutStuck + KubePodNotReady

**Nguyên nhân:** Hai helm release chạy song song trong namespace `monitoring`:
- Release `monitoring` (ArgoCD, ServerSideApply) → DaemonSet `monitoring-prometheus-node-exporter`
- Release `kube-prometheus-stack` (manual helm) → DaemonSet `kube-prometheus-stack-prometheus-node-exporter`

Cả hai dùng `hostNetwork: true` + port 9100 → xung đột → DaemonSet mới Pending 30h → Prometheus không lấy được kubelet metrics → rule evaluation failures.

**Giải quyết:**
- Đổi ArgoCD `releaseName: monitoring` → `releaseName: kube-prometheus-stack` trong `infra/argocd/apps/dev/platform/monitoring.yaml`
- Trigger ArgoCD sync với Prune → xóa toàn bộ `monitoring-*` resources thừa

**Kết quả:** Node-exporter READY=2/2, không còn duplicate, Prometheus evaluate rules bình thường.

---

### Issue 2: KubeSchedulerDown / KubeControllerManagerDown / KubeProxyDown (false positive)

**Nguyên nhân:** k3s nhúng scheduler, controller-manager, proxy, etcd vào 1 binary (`k3s server`). Không có pod riêng → không có Prometheus scrape target → alert bắn liên tục dù cluster hoạt động bình thường.

**Giải quyết:** Disable trong `infra/helm/monitoring/kube-prometheus-stack/values.yaml`:
```yaml
kubeScheduler.enabled: false
kubeControllerManager.enabled: false
kubeProxy.enabled: false
kubeEtcd.enabled: false
```

**Kết quả:** Alert giả không còn bắn.

---

### Issue 3: KubeDaemonSetRolloutStuck (traefik-worker)

**Nguyên nhân:** DaemonSet `traefik-worker` dùng `hostNetwork: true`, xung đột 4 tầng trên `server01`:
1. Port 9100 bị chiếm bởi node-exporter
2. Port 80/443 bị chiếm bởi `svclb-traefik` (k3s LoadBalancer DaemonSet)
3. Image `rancher/mirrored-library-traefik:v3.5.1` không tồn tại (sai format tag, thiếu `v` prefix trên rancher mirror)
4. Process non-root thiếu quyền bind port < 1024

**Giải quyết** (file: `infra/argocd/manifests/platform/cloudflared-dev-worker/traefik-worker-helmchart.yaml`):
- Label `server01` với `svccontroller.k3s.cattle.io/enablelb=false` → svclb-traefik không chạy trên worker, giải phóng port 80/443
- Label control-plane với `svccontroller.k3s.cattle.io/enablelb=true` → svclb-traefik tiếp tục chạy ở đó
- Đổi metrics port 9100 → 9200
- Pin image tag `3.6.7` (bỏ `v` prefix)
- Thêm `runAsUser: 0` + `NET_BIND_SERVICE` capability để bind port 80/443

**Kết quả:** traefik-worker READY=1/1, svclb-traefik vẫn chạy trên control-plane, không mất traffic.

---

### Tổng thể

| Trước | Sau |
|-------|-----|
| 11 alerts firing (5 critical, 6 warning) | Watchdog (bình thường) + CPU/Memory Overcommit (cần xem xét resource requests) |

**Còn lại cần theo dõi:** KubeCPUOvercommit + KubeMemoryOvercommit — cluster overcommit CPU 0.71 cores và Memory 450MB, không tolerate node failure. Cân nhắc giảm resource requests hoặc thêm node.
