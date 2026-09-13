# Vận hành hằng ngày

> Thiết kế hệ thống → [PLAN.md](./PLAN.md). Đang có sự cố → [RECOVERY.md](./RECOVERY.md).

**Nguyên tắc xuyên suốt: tối ưu cho người vận hành, không tối ưu cho hệ thống.** Với 1 người, tài nguyên khan hiếm là thời gian và sự tỉnh táo — không phải CPU. RAM và đĩa mua thêm được; sự tỉnh táo lúc 2 giờ sáng thì không.

---

## Dựng 3 máy từ số không

> Bốn chỗ ⚠️ dưới đây, ba chỗ **không sửa được sau này mà không cài lại**.

### 1. Tailscale trước, k3s sau — cả 3 máy

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --hostname=hnq-01      # hnq-02 / hnq-03 trên 2 máy ở nhà
tailscale ip -4 && tailscale status      # ghi lại IP 100.x, 3 máy phải thấy nhau
```

⚠️ **Đặt `--hostname` đúng ngay từ đầu.** Tên MagicDNS (`hnq-01.<tailnet>.ts.net`) sẽ đi vào TLS SAN của apiserver và vào `server:` của 2 agent. Đổi tên sau = cấp lại cert + sửa cấu hình cả 2 agent.

### 2. `hnq-01` — server

```yaml
# /etc/rancher/k3s/config.yaml — tạo TRƯỚC khi cài
cluster-init: true                 # ⚠️ embedded etcd, xem ghi chú dưới
node-name: hnq-01
node-ip: 100.x.y.z                 # IP Tailscale
node-external-ip: <IP public VPS>
flannel-iface: tailscale0          # ⚠️ pod network đi qua tailnet
write-kubeconfig-mode: "600"       # mặc định k3s là 644 — ai trên máy đó cũng đọc được
secrets-encryption: true           # ⚠️ mã hoá Secret trong etcd — snapshot rời khỏi máy

node-label:
  - "hnq.dev/role=control-plane"
node-taint:
  - "hnq.dev/dedicated=control-plane:NoSchedule"   # ⚠️ giữ workload khỏi master

disable:
  - servicelb                      # mọi traffic vào qua Cloudflare Tunnel
  - local-storage                  # thay bằng chart local-path-provisioner tự quản

tls-san:
  - 100.x.y.z
  - hnq-01.<tailnet>.ts.net        # ⚠️ tên này là chìa khoá để thay máy master nhanh
  - <IP public VPS>

etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 20
etcd-snapshot-dir: /srv/k3s/snapshots
etcd-s3: true
etcd-s3-config-secret: k3s-etcd-s3   # khoá R2 nằm trong Secret ở kube-system, không để thô ở đây
```

```bash
curl -sfL https://get.k3s.io | sh -
sudo cat /var/lib/rancher/k3s/server/token     # ⚠️ CẤT NGAY vào password manager
```

```bash
sudo cat /var/lib/rancher/k3s/server/cred/encryption-config.json   # ⚠️ CẤT NGAY, cùng chỗ với token
```

⚠️ **Token là món #2 và `encryption-config.json` là món #4 của [recovery kit](./RECOVERY.md#recovery-kit).** Thiếu token thì snapshot etcd không restore được lên máy mới; thiếu encryption config thì restore được cluster nhưng **không đọc được Secret nào**.

**Vì sao `cluster-init` (etcd) dù không định làm HA:** không phải để HA, mà vì etcd có sẵn snapshot theo lịch + upload S3 + `--cluster-reset-restore-path` có tài liệu chính thức. Với SQLite thì phải tự viết cron, tự viết upload, tự viết restore — và tự debug chúng lúc đang sự cố. Đổi SQLite → etcd sau này là **cài lại cluster**.

### 3. `hnq-02` / `hnq-03` — agent

```yaml
server: https://hnq-01.<tailnet>.ts.net:6443   # ⚠️ tên MagicDNS, KHÔNG phải IP
token: <token ở bước 2>
node-name: hnq-02                              # hnq-03 trên máy còn lại
node-ip: 100.x.y.z                             # IP Tailscale của chính nó
flannel-iface: tailscale0
node-label:
  - "hnq.dev/env-prod=true"                    # hnq-03: hnq.dev/env-dev=true
  - "hnq.dev/storage=true"
  - "hnq.dev/edge=true"
```

⚠️ **Dùng tên MagicDNS cho `server:`, không dùng IP.** Khi phải dựng VPS mới ([R6](./RECOVERY.md#r6--vps-mất-hoàn-toàn)), IP đổi nhưng tên thì không — 2 agent tự rejoin, không phải SSH sửa từng máy lúc đang gấp.

### 4. Kiểm ngay — 4 việc

```bash
kubectl get nodes -o wide      # đủ 3 node, Internal-IP đều là dải 100.x

# ⚠️ MTU — chỗ hay sai nhất khi flannel đi qua Tailscale.
# tailscale0 có MTU 1280 → flannel vxlan còn ~1230.
ssh hnq-02 'cat /run/flannel/subnet.env'       # FLANNEL_MTU phải ~1230
kubectl run nettest --image=nicolaka/netshoot -it --rm -- \
  sh -c 'ping -M do -s 1400 <IP pod node khác>; ping -M do -s 1180 <IP pod node khác>'
# ĐÚNG: -s 1400 báo "message too long", -s 1180 chạy được.
# SAI:  -s 1400 cũng chạy → MTU sai. Triệu chứng về sau KHÔNG giống lỗi mạng:
#       request nhỏ chạy bình thường, request lớn / TLS handshake treo vô thời hạn.

tailscale ping hnq-02          # phải "direct", không phải "via DERP" (mở UDP 41641 ở nhà)

ssh hnq-02 'sudo mkdir -p /srv/k3s/{data,dump} && sudo chmod 755 /srv/k3s'
ssh hnq-03 'sudo mkdir -p /srv/k3s/{data,dump} && sudo chmod 755 /srv/k3s'
ssh hnq-01 'sudo mkdir -p /srv/k3s/snapshots'
```

### 5. Bootstrap + backup key

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace -f gitops/install/argocd-values.yaml
kubectl -n argocd apply -f gitops/root.yaml    # ⭐ lệnh duy nhất apply tay trong đời cluster

kubectl -n kube-system scale deploy coredns --replicas=2

# Ngay sau khi Sealed Secrets lên:
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > ~/sealing-key.yaml    # → password manager (2 nơi), rồi shred -u ~/sealing-key.yaml
```

Sau bước này recovery kit phải đủ **4 món**: etcd snapshot · k3s token · sealing key · `encryption-config.json`.

### 6. 🚧 Diễn tập restore **ngay bây giờ**, khi cluster còn trống

```bash
make snapshot
ssh hnq-01 'sudo systemctl stop k3s && sudo rm -rf /var/lib/rancher/k3s/server/db'
# → làm theo R5, bấm giờ, ghi số vào bảng diễn tập trong RECOVERY.md
```

Đây là lúc **rẻ nhất trong cả đời cluster** để làm việc này: sai thì `k3s-uninstall.sh` rồi làm lại, không mất gì.

---

## Add-on của k3s — giữ 3, tắt 2

k3s cài sẵn Traefik, ServiceLB, local-path, metrics-server, CoreDNS.

| Add-on | Quyết định | Cách làm |
|---|---|---|
| **Traefik** | Giữ, cấu hình lại | `HelmChartConfig` trong `kube-system`: 2 replica + antiAffinity theo hostname + `nodeSelector: hnq.dev/edge` + `service.type: ClusterIP` |
| **CoreDNS** | Giữ, scale 2 | `kubectl -n kube-system scale deploy coredns --replicas=2`. Manifest k3s **không khai `replicas`** nên scale không bị ghi đè khi k3s khởi động lại; taint của `hnq-01` đẩy pod xuống 2 máy nhà, `topologySpreadConstraints` có sẵn tách chúng ra 2 node |
| **metrics-server** | Giữ nguyên | Tự chuyển xuống máy nhà do taint |
| **ServiceLB** | **Tắt** (`disable: servicelb`) | Không có Service `LoadBalancer` nào — mọi traffic vào qua Cloudflare Tunnel |
| **local-path** | **Tắt** (`disable: local-storage`) | Thay bằng chart `local-path-provisioner` tự quản, StorageClass `hnq-local` (`Retain`, `volumeType: local`, path `/srv/k3s/data`) — xem [PLAN §8](./PLAN.md#8-lưu-trữ) |

⚠️ **Không sửa file trong `/var/lib/rancher/k3s/server/manifests/`** — k3s ghi đè lại mỗi lần khởi động. Chỉ dùng `disable:`, `HelmChartConfig`, hoặc trường không có trong manifest gốc.

`requiredDuringScheduling` (không phải `preferred`) cho antiAffinity là có chủ ý: thà pod thứ hai `Pending` và thấy ngay, hơn là cả 2 replica âm thầm nằm chung một node rồi phát hiện lúc node đó chết.

**cloudflared** chuyển từ systemd trên VPS vào cluster, 2 replica trên `hnq.dev/edge`. Cloudflare Tunnel hỗ trợ nhiều replica cùng chạy: Cloudflare tự chia traffic và tự chuyển khi một replica mất.

---

## Công cụ

Phần có tỷ lệ **giá trị / công sức cao nhất**. Cài một lần, dùng mỗi ngày.

| Công cụ | Làm gì |
|---|---|
| **k9s** | Giao diện terminal cho toàn cluster — pod, log, event, resource trong một màn hình. Thay ~80% lệnh `kubectl` gõ hằng ngày. |
| **stern** | Xem log nhiều pod cùng lúc, tô màu theo pod |
| **kubectx / kubens** | Đổi context và namespace |
| **krew** | Trình quản lý plugin `kubectl` → `tree`, `neat`, `df-pv`, `resource-capacity` |

`scripts/setup-workstation.sh` cài hết. ⚠️ **Chạy trên cả máy phụ** (xem dưới).

**10 phím k9s đủ cho 90% công việc:** `:pod` `:svc` `:ing` `:app` (nhảy loại resource, `:app` = ArgoCD Application) · `0`–`9` lọc namespace · `/` tìm · `l` log · `d` describe · `y` YAML · `s` shell · `Shift-c`/`Shift-m` sắp xếp CPU/RAM · `:pulse` tổng quan.

> Dành 30 phút học k9s ở P0. Đây là thứ bạn mở đầu tiên trong mọi sự cố về sau.

**`kubectl tree`** đáng nhắc riêng — khi ArgoCD báo `Degraded` mà không rõ vì sao, nó cho thấy ngay chuỗi cha–con và chỗ đứt:

```bash
kubectl tree deployment backend -n lotus-clinic-prod
```

---

## Truy cập cluster

### kubeconfig qua tailnet — không dùng Tailscale Operator

k3s đã bind apiserver vào IP Tailscale nên kubeconfig dùng được từ bất cứ máy nào trong tailnet, **không mở port ra internet**:

```bash
ssh hnq-01 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config-hnq
chmod 600 ~/.kube/config-hnq
# ⚠️ Đổi server sang TÊN MagicDNS, không để IP — khi dựng VPS mới (R6) thì IP đổi, tên không.
sed -i 's|server: https://127.0.0.1:6443|server: https://hnq-01.<tailnet>.ts.net:6443|' ~/.kube/config-hnq
```

Tailscale Kubernetes Operator giải bài toán *"nhiều người, nhiều máy, RBAC theo từng người, thu hồi khi có người rời đội"* — không bài toán nào tồn tại ở đây. Cái giá thì vẫn nguyên: nó là một Deployment nằm **giữa bạn và apiserver**. Xét lại khi có người thứ hai (cài mất ~1 giờ).

**Bốn quy tắc, không ngoại lệ:** `--write-kubeconfig-mode=600` trên server · `chmod 600` trên máy bạn · không commit kubeconfig vào repo nào kể cả private · không để kubeconfig trong thư mục đồng bộ cloud.

### Máy phụ — bắt buộc

Với 1 người, *"laptop chết"* và *"hệ thống không ai vận hành được"* là **cùng một sự cố** nếu chỉ có một máy cấu hình sẵn. Máy phụ (máy bàn, hoặc chính một máy ở nhà) phải có đủ:

- [ ] Tailscale đã join tailnet · `~/.kube/config-hnq` `chmod 600` · SSH key vào cả 3 node
- [ ] `git clone` repo · `setup-workstation.sh` đã chạy
- [ ] Đăng nhập được password manager (nơi có recovery kit)

**Kiểm 6 tháng một lần** — máy phụ không dùng thường xuyên là máy phụ âm thầm hết hạn.

### Break-glass khi kubectl không dùng được

| Bậc | Cách | Khi nào |
|---|---|---|
| 1–2 | `kubectl` từ máy chính → máy phụ | Bình thường |
| 3 | `ssh hnq-01` rồi `sudo k3s kubectl ...` | Tailscale trên máy bạn có vấn đề |
| 4 | SSH vào node, `sudo crictl ps` / `crictl logs` | apiserver chết hẳn — vẫn xem và restart container được |
| 5 | Console của nhà cung cấp VPS | Tailscale trên `hnq-01` chết → không SSH được |

⚠️ **Bậc 5 phải thử trước khi cần tới nó.** Nhiều người phát hiện console cần 2FA bằng số điện thoại đã đổi — đúng lúc đang sự cố. Đăng nhập thử một lần ở P0.

---

## Makefile — lệnh hằng ngày

```makefile
status:     ## Bảng service: tag dev ↔ prod ↔ trạng thái ArgoCD
	@scripts/status.sh
pending:    ## Service nào ở dev đang chờ lên prod
	@scripts/status.sh --pending-only
logs:       ## make logs SVC=lotus-clinic ENV=prod
	@stern -n $(SVC)-$(ENV) . --tail 100
sh:         ## make sh SVC=lotus-clinic ENV=dev
	@kubectl -n $(SVC)-$(ENV) exec -it $$(kubectl -n $(SVC)-$(ENV) get pod -o name | head -1) -- sh
top:        ## Node và pod ăn tài nguyên nhất
	@kubectl top nodes && kubectl top pods -A --sort-by=memory | head -15
events:     ## Event bất thường gần đây
	@kubectl get events -A --sort-by=.lastTimestamp --field-selector type!=Normal | tail -30
drift:      ## Cái gì lệch Git + đường dữ liệu còn dự phòng không
	@scripts/drift.sh
sync:       ## make sync SVC=lotus-clinic ENV=dev
	@argocd app sync $(SVC)-$(ENV)
promote:    ## Đưa image dev lên prod: make promote NAME=lotus-clinic
	@ci/scripts/promote.sh "$(NAME)"
snapshot:   ## etcd snapshot ngay — CHẠY TRƯỚC MỌI VIỆC NGUY HIỂM
	@ssh hnq-01 'sudo k3s etcd-snapshot save --name manual-$$(date +%Y%m%d-%H%M)'
kit-check:  ## Recovery kit còn đủ và còn dùng được? (hằng tháng)
	@scripts/dr/kit-check.sh
dr:         ## In phần "60 giây đầu tiên" — gõ khi đang sự cố
	@sed -n '/## 60 giây đầu tiên/,/## Recovery kit/p' docs/RECOVERY.md
```

**Bốn lệnh đáng thuộc nằm lòng:** `make drift` (hằng tuần) · `make snapshot` (trước việc nguy hiểm) · `make kit-check` (hằng tháng) · `make dr` (lúc sự cố, khi không nhớ nổi phải làm gì).

### `scripts/status.sh` — thứ ArgoCD UI không có

```
SERVICE                DEV          PROD         PENDING    ARGOCD
──────────────────────────────────────────────────────────────────
lotus-clinic           7bcd1234     f1eb557d     ⬆ CHỜ      Synced/Healthy
giaan-clinic           a3f9021c     a3f9021c     -          Synced/Healthy
hocmon-clinic          bb17e4d2     -            dev-only   -
```

~30 dòng bash, đọc `image.tag` từ `values-{dev,prod}.yaml` rồi ghép với trạng thái Application. Đây là khoảng trống duy nhất mà một portal tự viết sẽ lấp — và nó chỉ đáng 30 dòng bash.

### `scripts/drift.sh` — kiểm cả dự phòng, không chỉ kiểm lệch Git

Ở topology này, "mọi thứ Healthy" **không** có nghĩa "còn dự phòng": cả 2 replica Traefik có thể đang nằm chung một node mà ArgoCD vẫn báo xanh.

```bash
# 1. Application lệch khỏi Git
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
  | grep -v 'Synced.*Healthy' || echo "  ✅ Mọi thứ khớp Git"

# 2. Đường dữ liệu: mỗi app phải 2 pod, trên 2 node khác nhau, không có hnq-01
for app in traefik cloudflared coredns; do
  NODES=$(kubectl get pod -A -l "app.kubernetes.io/name=$app" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)
  [ "$(echo "$NODES" | grep -c .)" -lt 2 ] && echo "  ❌ $app KHÔNG CÒN DỰ PHÒNG: $NODES"
  echo "$NODES" | grep -q hnq-01 && echo "  ⚠️  $app có replica trên master — sai nodeSelector"
done
```

---

## Giám sát

### Tám alert — không hơn

Với 1 người không có ca trực, **alert bị bỏ qua là alert vô dụng** — và tệ hơn, nó làm bạn bỏ qua cả alert thật. 8 là **trần**, không phải mục tiêu.

| # | Alert | Ngưỡng | Hành động ngay |
|---|---|---|---|
| 1 | Pod restart liên tục | `CrashLoopBackOff` > 5 phút | `make logs SVC=x ENV=y` |
| 2 | Deployment không đủ replica | ready < desired, > 10 phút | Xem event, xem node còn chỗ không |
| 3 | Node không sẵn sàng | `NotReady` > 5 phút | [R9](./RECOVERY.md#r9--tailnet-sự-cố) — máy sống hay chết? |
| 4 | Đĩa sắp đầy | > 85% | [R10](./RECOVERY.md#r10--đĩa-đầy) |
| 5 | PV sắp đầy | > 85% | Mở rộng hoặc dọn dữ liệu |
| 6 | Chứng chỉ TLS sắp hết hạn | < 14 ngày | `kubectl describe certificate` — thường là DNS hoặc rate limit |
| 7 | ArgoCD Application lệch | `OutOfSync` > 30 phút | `make drift` |
| 8 | Backup thất bại | Velero / etcd snapshot lỗi | Xử lý ngay — đây là lưới an toàn cuối |

> **Trường `action` là bắt buộc trong mọi rule.** Nếu không viết nổi một hành động cụ thể thì alert đó không nên tồn tại — hãy để nó là dashboard.

Mọi thứ khác vào Grafana, **không gửi thông báo**. Ba dashboard là đủ: Cluster overview, Service overview, Storage. Dùng dashboard có sẵn của kube-prometheus-stack, đừng tự vẽ.

⚠️ **Monitoring đặt trên `hnq-03`** — không trên master (mất master là mất luôn khả năng biết mình mất master) và không trên node prod (node prod chết là mất monitoring đúng lúc cần nó nhất).

### Dead man's switch

**Quyết định quan trọng nhất trong toàn bộ phần giám sát.**

Tám alert trên có một lỗ hổng chung: **Alertmanager nằm trong cluster**. Cluster chết, node chết, mất điện ở nhà, Prometheus OOM — thì thứ có nhiệm vụ báo cho bạn cũng chết theo, **và bạn không nhận được gì cả**. Đội có ca trực thì sẽ có người phát hiện; với 1 người, sự im lặng đó trông **giống hệt** "mọi thứ đều ổn".

Đảo ngược chiều: bắt hệ thống **báo cáo là nó còn sống**, và để một dịch vụ **bên ngoài** kêu lên khi báo cáo đó ngừng tới. `kube-prometheus-stack` có sẵn alert `Watchdog` — luôn firing, tồn tại đúng cho mục đích này.

```yaml
route:
  receiver: telegram
  routes:
    - receiver: heartbeat              # Watchdog đi riêng, KHÔNG vào kênh chat
      matchers: [ 'alertname="Watchdog"' ]
      repeat_interval: 2m              # ngắn hơn grace period của dịch vụ ngoài
      group_wait: 0s
receivers:
  - name: heartbeat
    webhook_configs:
      - url: https://hc-ping.com/<uuid>    # healthchecks.io / Better Stack / cronitor
        send_resolved: false
```

Phía dịch vụ ngoài: period 2 phút, grace 10 phút → **không nhận được ping trong 12 phút thì đẩy thông báo về điện thoại + email.**

| Cái này bắt được | 8 alert trên có bắt được? |
|---|---|
| Mất điện ở nhà · Mất internet ở nhà | ❌ |
| Node chạy Prometheus chết · Prometheus OOM / đĩa đầy | ❌ |
| Cả cluster chết · Alertmanager cấu hình sai, không gửi được gì | ❌ |

Sáu dòng đó là **chính xác những sự cố tệ nhất có thể xảy ra**. Chi phí: ~15 phút cấu hình, miễn phí ở gói cá nhân.

⚠️ **Phải kiểm thử, không được giả định** (mục bắt buộc của P5):

```bash
kubectl -n monitoring scale deploy/alertmanager-kube-prometheus-stack --replicas=0
# → chờ ~12 phút, xác nhận điện thoại có thông báo, rồi scale lại 1
```

### Thông báo phải tới được điện thoại

Alert chỉ hiện trên màn hình laptop là alert bị bỏ qua mỗi khi bạn không ở trước laptop — tức là phần lớn thời gian.

| Kênh | Dùng cho |
|---|---|
| Telegram (một kênh) | 8 alert + ArgoCD sync thất bại + CI hỏng trên `main` + Velero lỗi |
| Dịch vụ heartbeat | Hệ thống đã chết hoàn toàn |

⚠️ **Kênh alert phải không lẫn tin nhắn thường.** Kênh lẫn chat là kênh bị tắt thông báo sau hai tuần.

**ArgoCD Notifications chỉ báo khi thất bại** — `on-sync-failed` và `on-health-degraded`. Báo mỗi lần sync thành công nghe có vẻ hay, nhưng sau một tuần là không ai đọc nữa.

---

## Nâng cấp k3s

Nâng cấp = **PR đổi một dòng `version`**, có review, có lịch sử, quay lui bằng `git revert`. `system-upgrade-controller` đọc resource `Plan`, mà `Plan` là YAML nên nằm trong repo như mọi thứ khác.

**Hai quy tắc bất di bất dịch:** nâng **1 minor một lần** (1.28 → 1.29 → 1.30, không nhảy cóc), và **snapshot trước khi nâng**.

**Cần hai Plan, thứ tự không được đảo: server trước, agent sau.** Agent chạy version mới hơn server là cấu hình không được hỗ trợ.

```yaml
# Plan agent — phụ thuộc Plan server
spec:
  concurrency: 1                       # ⚠️ từng node một
  cordon: true
  nodeSelector:
    matchExpressions:
      - { key: node-role.kubernetes.io/control-plane, operator: NotIn, values: ["true"] }
  prepare:
    image: rancher/k3s-upgrade
    args: ["prepare", "k3s-server"]     # ⚠️ chờ Plan server xong mới chạy
  version: v1.31.5+k3s1                 # ⚠️ ghim version, KHÔNG dùng channel: stable
```

⚠️ **`concurrency: 1` là bắt buộc ở topology này.** Nâng cả 2 máy ở nhà cùng lúc = **cả 2 replica Traefik và cloudflared cùng xuống** = mất toàn bộ traffic khách hàng trong vài phút.

⚠️ **Ghim version thay vì `channel: stable`:** channel nghĩa là cluster tự nâng lúc nào không biết, có thể đúng giờ cao điểm. Ghim version nghĩa là **bạn chọn thời điểm**.

```bash
make snapshot                          # 1. luôn luôn
# 2. đọc release note, phần breaking changes
# 3. PR đổi version trong CẢ HAI plan.yaml
# 4. merge → controller nâng hnq-01 → hnq-02 → hnq-03
kubectl get nodes && make drift && kubectl get pods -A | grep -v Running    # 5. kiểm
```

> Nâng cấp `hnq-01` có **downtime control-plane vài phút** (apiserver restart). Workload không bị ảnh hưởng, nhưng trong lúc đó không `kubectl` và không sync được → làm lúc rảnh, không phải lúc đang chờ deploy gì.

| Loại | Nhịp |
|---|---|
| Bản vá bảo mật (CVE cao) | Trong 1 tuần |
| Bản vá thường | Hằng quý |
| Minor version | 6 tháng/lần, từng bước một |
| Chart bên thứ ba | Renovate tự mở PR, duyệt hằng tuần |

---

## Runbook

`docs/RUNBOOK.md` là tài liệu **quan trọng nhất** khi chỉ có 1 người. Không phải vì nội dung kỹ thuật, mà vì **bạn sẽ không nhớ**: sự cố gặp cách đây 4 tháng, lúc 2 giờ sáng, bạn sẽ điều tra lại từ đầu — trừ khi lúc đó đã viết 5 dòng.

```markdown
## 2026-09-20 — Pod backend CrashLoopBackOff sau khi đổi secret
**Triệu chứng:** lotus-clinic-prod restart liên tục, log "access denied for user"
**Nguyên nhân:** đổi DB_PASSWORD trong SealedSecret nhưng pod chưa restart → vẫn dùng giá trị cũ
**Xử lý:** kubectl -n lotus-clinic-prod rollout restart deploy/backend
**Phòng ngừa:** annotation hnq.dev/secret-checksum đã có trong chart — lần này quên cập nhật
**Thời gian:** 25 phút
```

### Viết trước những tình huống này ở P6

| Tình huống | Bước đầu tiên |
|---|---|
| Pod `CrashLoopBackOff` | `make logs SVC=x ENV=y` → `kubectl describe pod` phần Events |
| Pod `Pending` mãi | `kubectl describe pod` → hết tài nguyên, hoặc PV không gắn được node |
| ArgoCD `OutOfSync` không tự hết | [R2](./RECOVERY.md#r2--cluster-lệch-khỏi-git) |
| Ingress 404 / 502 | Service có endpoint không → `kubectl get endpointslice -n <ns>` |
| Chứng chỉ không cấp được | `kubectl describe certificate` → DNS chưa trỏ, hoặc rate limit LE |
| Node `NotReady` | ⚠️ **Máy sống hay chết?** Sống → [R9](./RECOVERY.md#r9--tailnet-sự-cố), **không** `delete node`. Chết → [R4](./RECOVERY.md#r4--node-prod-chết)/[R3](./RECOVERY.md#r3--node-dev-chết) |
| Đĩa đầy | [R10](./RECOVERY.md#r10--đĩa-đầy) |
| `kubectl` timeout | [R5](./RECOVERY.md#r5--etcd-hỏng-hoặc-apiserver-không-lên) — kiểm trước: khách hàng có bị ảnh hưởng không? Thường là **không** |
| **Request nhỏ chạy, request lớn / TLS treo** | **MTU pod network qua Tailscale.** Triệu chứng không giống lỗi mạng — nhớ mục này để khỏi mất 3 giờ tìm bug ở tầng ứng dụng |
| Pod `Pending` với `volume node affinity conflict` | PVC bind vào PV trên node khác — sau [R4](./RECOVERY.md#r4--node-prod-chết) là đúng dự kiến; ngoài ra là `nodeSelector` sai |
| Agent không join lại sau restore etcd | `Node password rejected` → [R5 bước 3](./RECOVERY.md#r5--etcd-hỏng-hoặc-apiserver-không-lên) |

Bốn dòng cuối là **đặc trưng của topology 3-node-qua-Tailscale** — không có trong runbook mẫu nào trên mạng, và đều là loại sự cố mất hàng giờ nếu gặp lần đầu mà không biết trước.

### `BREAK_GLASS.md` — viết ở P6

Chưa cần `ONBOARDING.md` — chưa có ai để onboard. Cái cần viết là tài liệu ngược lại: một trang cho người **không** biết Kubernetes, dùng khi không liên lạc được với người vận hành. Mẫu:

```markdown
# Nếu không liên lạc được với người vận hành
Hệ thống: 1 VPS (hnq-01, nhà cung cấp X, tài khoản Y) + 2 máy tại <địa chỉ>.
Khách hàng đang dùng: <danh sách domain>.

## KHÔNG được làm
- Không tắt, không cài lại 2 máy ở nhà — dữ liệu khách hàng nằm ở đó.
- Không xoá VPS. Nếu bị khoá vì chưa trả tiền: <cách trả>.

## Nếu website khách hàng không truy cập được
1. Kiểm 2 máy ở nhà còn điện và mạng không → nguyên nhân phổ biến nhất.
2. Còn thì gọi <người vận hành>, hoặc <người kỹ thuật dự phòng: tên, sđt>.
3. Recovery kit + mật khẩu: mục "HNQ recovery kit" trong <password manager>.

## Toàn bộ hạ tầng mô tả trong Git
github.com/hunho247/HNQ-Infra → docs/RECOVERY.md
Người biết Kubernetes đọc file đó là dựng lại được từ số không.
```

Hai việc đi kèm, cùng ở P6:

- **Một người thứ hai giữ được recovery kit** — không cần biết Kubernetes, chỉ cần emergency access vào password manager (1Password / Bitwarden) và biết rằng nó tồn tại.
- **Một người khác đã đọc `BREAK_GLASS.md` một lần** — tài liệu chưa ai đọc là tài liệu chưa chắc dùng được.

---

## Lịch vận hành

Lịch phải **ngắn tới mức làm được cả lúc đang bận**. Mỗi dòng đã bị cắt cho tới khi chỉ còn thứ không thay thế được bằng tự động hoá.

| Nhịp | Việc | Mất | Bỏ thì sao |
|---|---|---|---|
| **Ngày** | Liếc kênh chat xem có alert không | 1 ph | Sự cố nhỏ thành sự cố lớn |
| **Tuần** | Duyệt PR Renovate | 15 ph | Tích nợ version, nâng cấp sau đau hơn |
| | `make drift` — ai sửa tay không, **và đường dữ liệu còn 2 replica trên 2 node không** | 5 ph | Mất dự phòng mà không biết |
| | Xem dashboard đĩa và PV | 5 ph | [R10](./RECOVERY.md#r10--đĩa-đầy) lúc 2 giờ sáng |
| **Tháng** | `make kit-check` | 5 ph | Có snapshot mà không có token → [R8](./RECOVERY.md#r8--mất-toàn-bộ-cluster) 3 giờ thay vì [R6](./RECOVERY.md#r6--vps-mất-hoàn-toàn) 45 phút |
| | Tải 1 bản etcd snapshot về máy (3-2-1) | 10 ph | Mất cả cluster lẫn R2 là mất hết |
| | Rà `RUNBOOK.md`, bổ sung sự cố trong tháng | 20 ph | Điều tra lại từ đầu khi gặp lại |
| **Quý** | **Diễn tập 1 quy trình**, luân phiên theo [bảng](./RECOVERY.md#diễn-tập) | 1–2 h | Đây là thứ **duy nhất** chứng minh các con số RTO là thật |
| | Nâng cấp k3s bản vá | 1 h | CVE tích tụ |
| | Backup lại sealing key + rà secret quá hạn | 30 ph | — |
| **6 tháng** | Kiểm máy phụ còn dùng được | 15 ph | Máy phụ hết hạn âm thầm = không có máy phụ |
| | Đăng nhập thử console nhà cung cấp VPS | 10 ph | Phát hiện 2FA đã đổi số đúng lúc đang sự cố |

Tổng: **~25 phút mỗi tuần** + **nửa ngày mỗi quý**. Vượt nhiều thì có chỗ nào đó đang quá phức tạp so với nhu cầu — đọc lại [PLAN §1](./PLAN.md#1-bảng-quyết-định-đã-chốt).

---

## Checklist triển khai

**Cluster (P0)**
- [ ] Cài bằng `--cluster-init` — kiểm: `kubectl get node` thấy role `etcd` trên `hnq-01`
- [ ] `hnq-01` có taint `hnq.dev/dedicated=control-plane:NoSchedule`
- [ ] `servicelb` và `local-storage` đã tắt — `kubectl get sc` chỉ còn `hnq-local`
- [ ] `secrets-encryption` bật — `k3s secrets-encrypt status` báo `Encryption Status: Enabled`
- [ ] 3 node đúng nhãn, không values nào tham chiếu hostname
- [ ] MTU đúng — `ping -M do -s 1400` giữa 2 node **phải lỗi**
- [ ] `tailscale ping` giữa 3 node là **direct**, không qua DERP
- [ ] Không workload ứng dụng nào trên `hnq-01`
- [ ] etcd snapshot tự động **và** có mặt trên R2
- [ ] Đã đăng nhập thử console nhà cung cấp VPS một lần

**Đường dữ liệu (P3)**
- [ ] Traefik, cloudflared, CoreDNS: mỗi cái 2 pod, 2 node ở nhà khác nhau
- [ ] PVC thử nghiệm bound vào `/srv/k3s/data`, PV là `volumeType: local` (Velero không backup được `hostPath`)
- [ ] Đã thử `systemctl stop k3s` trên `hnq-01` 5 phút và domain public vẫn trả 200
- [ ] Không còn `cloudflared` chạy bằng systemd trên VPS

**Công cụ**
- [ ] Máy chính **và máy phụ** đều có k9s, stern, kubectx, kubeconfig `chmod 600`
- [ ] `make status`, `logs`, `drift`, `kit-check` chạy được

**Quan sát (P5)**
- [ ] Đúng 8 alert, mỗi cái có `action` cụ thể
- [ ] Monitoring trên `hnq-03`, không trên master, không trên node prod
- [ ] **Dead man's switch đã kiểm thử** — tắt Alertmanager thì điện thoại có thông báo
- [ ] Alert tới điện thoại, ở kênh không lẫn chat thường
- [ ] ArgoCD chỉ báo khi thất bại

**An toàn (P0/P5/P6)**
- [ ] Recovery kit đủ **4 món**, `make kit-check` xanh
- [ ] Đã restore thử etcd snapshot **một lần** ([R5](./RECOVERY.md#r5--etcd-hỏng-hoặc-apiserver-không-lên))
- [ ] Đã dựng thử master mới từ snapshot **một lần** ([R6](./RECOVERY.md#r6--vps-mất-hoàn-toàn))
- [ ] Đã restore thử một database từ dump **một lần** ([R7](./RECOVERY.md#r7--xoá-nhầm-dữ-liệu-trong-database))
- [ ] Đã dời thử prod sang node khác **một lần** ([R4](./RECOVERY.md#r4--node-prod-chết))
- [ ] Mọi ô "đo thực tế" trong [bảng diễn tập](./RECOVERY.md#diễn-tập) đã có số
- [ ] Nâng cấp k3s là PR đổi một dòng

**Con người (P6)**
- [ ] `RUNBOOK.md` có sẵn các tình huống ở trên
- [ ] `BREAK_GLASS.md` viết xong, và **một người khác đã đọc nó một lần**
- [ ] Một người khác truy cập được recovery kit (emergency access password manager)
- [ ] Bản PDF của `RECOVERY.md` có trong điện thoại
