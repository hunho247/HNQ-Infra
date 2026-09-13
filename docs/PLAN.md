# Kế hoạch triển khai k3s + ArgoCD

> **Bản thực thi.** Mọi quyết định đã chốt ở [§1](#1-bảng-quyết-định-đã-chốt) — không còn mục nào chờ quyết.
> Vận hành hằng ngày → [OPERATIONS.md](./OPERATIONS.md) · Đang có sự cố → [RECOVERY.md](./RECOVERY.md)

| | |
|---|---|
| **Xuất phát** | Cluster mới, repo mới, không migrate dữ liệu cũ |
| **Phần cứng** | `hnq-01` VPS thuê (control-plane) · `hnq-02`, `hnq-03` máy ở nhà (agent) |
| **Mạng** | 3 máy join qua Tailscale, flannel chạy trên `tailscale0` |
| **Vào từ internet** | Cloudflare Tunnel chạy in-cluster |
| **Người vận hành** | 1 |

---

## 1. Bảng quyết định đã chốt

Dòng 🔄 là **đổi so với bản kế hoạch trước** — lý do ở cột cuối, chi tiết thi công ở mục được trỏ tới.

| # | Hạng mục | Chốt | Ghi chú |
|---|---|---|---|
| D1 | Control-plane | **1 server, không HA** | etcd embedded (`cluster-init`) để có snapshot/restore chính thống |
| D2 | Môi trường | **1 branch `main`**, tách bằng thư mục + values | Branch-per-env là anti-pattern; 1 branch mới promote từng service được |
| D3 | Sinh Application | **ApplicationSet** cho service mình, **Application tường minh** cho chart bên thứ ba | [§7](#7-gitops) |
| D4 | Sync prod | **`selfHeal: true`, `prune: false`, `automated` bật** | Dev bật cả hai. Không dùng manual sync — MTTR của 1 người quan trọng hơn |
| D5 | Promotion | **`make promote`** (script + PR), **không dùng Kargo** | Kargo có giá trị từ 3 môi trường trở lên |
| D6 | Secret | **Sealed Secrets** | ESO khi nào có cluster thứ hai |
| D7 | Chart | **1 library + 2 chart chung** (`hnq-common`, `webservice`, `datastore`) | [§6](#6-chart) |
| D8 | Quay lui | Image tag = **git SHA** (cấm `latest`), `prune: false` ở prod, PV `Retain` | Mọi thay đổi phải revert được bằng 1 commit |
| D9 🔄 | Giữ workload khỏi master | **Taint `hnq.dev/dedicated=control-plane:NoSchedule`** trên `hnq-01` | Trước: chỉ dựa vào policy CI. Taint là scheduler ép, CI chỉ bắt lúc review — giữ cả hai |
| D10 🔄 | ServiceLB | **Tắt** (`disable: servicelb`), Traefik Service = `ClusterIP` | Mọi traffic vào qua Cloudflare Tunnel → không cần LoadBalancer, bỏ luôn nhãn `enablelb` |
| D11 🔄 | local-path | **Tắt gói sẵn** (`disable: local-storage`), tự quản bằng Helm chart | Bắt buộc: `volumeType: local` — **Velero không backup được `hostPath`** ([§9](#9-backup)) |
| D12 🔄 | CoreDNS | Giữ bản gói sẵn, **`scale --replicas=2`** | Manifest k3s **không khai `replicas`** nên scale không bị ghi đè khi k3s restart/upgrade; D9 giữ 2 pod ở 2 máy nhà |
| D13 🔄 | Khoá R2 cho etcd snapshot | **`etcd-s3-config-secret`** | Không để access key thô trong `/etc/rancher/k3s/config.yaml` |
| D14 🔄 | Secret trong etcd | **`secrets-encryption: true`** | Snapshot rời khỏi máy (R2 + laptop) → phải mã hoá. Thêm 1 món vào recovery kit ([§11](#11-secret)) |
| D15 🔄 | ApplicationSet an toàn | **`applicationsSync: create-update`** + `preserveResourcesOnDeletion: true` | Generator hỏng **không thể** xoá hàng loạt Application; xoá service là thao tác tay có chủ ý |
| D16 🔄 | Thứ tự sync | **sync-wave** khai trong `hnq-common` | [§6](#6-chart) |
| D17 🔄 | Velero | **File System Backup (kopia)**, `defaultVolumesToFsBackup: true`, không CSI | local-path không có CSI snapshot |
| D18 🔄 | cloudflared → Traefik | `https://traefik.kube-system:443` + `noTLSVerify: true`, **1 rule catch-all** | Catch-all không khớp SNI được; hop nằm trong cluster và link giữa node đã là WireGuard |
| D19 | TLS | **cert-manager + DNS-01 Cloudflare**, wildcard mỗi env | Giữ cert thật ở origin thay vì chỉ TLS ở edge |
| D20 | ArgoCD | Giữ tài khoản `admin`, **không ingress**, vào bằng `port-forward` qua tailnet | Dex/OIDC thêm 4 phụ thuộc phải sống mới đăng nhập được |
| D21 | AppProject | **2 cái**: `app` và `platform` | [§7](#7-gitops) |
| D22 | CI | `yamllint → schema → helm lint/unittest → render-all → kubeconform → conftest → gitleaks → trivy` | [§13](#13-ci) |
| D23 | Nâng version chart | **Renovate** tự mở PR | Pin version tuyệt đối ở mọi `Application`/`Chart.yaml` |
| D24 | Nâng k3s | **system-upgrade-controller**, `concurrency: 1` | [§15](#15-nâng-cấp) |
| D25 | Không làm trong v1 | Longhorn · HA 3 server · Dex/OIDC · Tailscale Operator · Kargo · NetworkPolicy · sync window · Backstage · `replicas: 2` cho app | Xét lại khi có máy thứ 4 chung LAN **hoặc** người vận hành thứ hai |

---

## 2. Topology và cấu hình node

| Node | Vai trò | Nhãn | Taint | Chạy gì |
|---|---|---|---|---|
| **hnq-01** VPS | control-plane + etcd | `hnq.dev/role=control-plane` | `hnq.dev/dedicated=control-plane:NoSchedule` | apiserver, etcd, ArgoCD, cert-manager, sealed-secrets, Velero server, system-upgrade-controller |
| **hnq-02** nhà | agent | `hnq.dev/env-prod=true`<br>`hnq.dev/storage=true`<br>`hnq.dev/edge=true` | — | mọi `*-prod`, 1 Traefik, 1 cloudflared, 1 CoreDNS |
| **hnq-03** nhà | agent | `hnq.dev/env-dev=true`<br>`hnq.dev/storage=true`<br>`hnq.dev/edge=true` | — | mọi `*-dev`, 1 Traefik, 1 cloudflared, 1 CoreDNS, monitoring |

Chỉ 5 thành phần dưới đây được phép mang toleration cho taint của `hnq-01` — CI chặn mọi chart khác khai nó:

```
argocd · cert-manager · sealed-secrets · velero (server) · system-upgrade-controller
```

**Thư mục trên đĩa** (tạo trước khi cài k3s, đặt ở partition riêng nếu được):

| Đường dẫn | Máy | Dùng cho |
|---|---|---|
| `/srv/k3s/data/` | hnq-02, hnq-03 | local-path cấp volume |
| `/srv/k3s/dump/` | hnq-02, hnq-03 | dump database hằng giờ |
| `/srv/k3s/snapshots/` | hnq-01 | etcd snapshot cục bộ trước khi lên R2 |

> Nhãn khai trong `config.yaml` **chỉ áp dụng lúc node đăng ký lần đầu**. Sau đó nguồn sự thật là `kubectl label` — đây là cơ chế [R4](./RECOVERY.md#r4--node-prod-chết) dựa vào để dời cả môi trường prod bằng một lệnh.

### `hnq-01` — `/etc/rancher/k3s/config.yaml`

```yaml
cluster-init: true
node-name: hnq-01
node-ip: 100.x.y.z                       # IP Tailscale
node-external-ip: <IP public VPS>
flannel-iface: tailscale0
write-kubeconfig-mode: "600"
secrets-encryption: true                 # D14

node-label:
  - "hnq.dev/role=control-plane"
node-taint:
  - "hnq.dev/dedicated=control-plane:NoSchedule"

disable:
  - servicelb                            # D10
  - local-storage                        # D11

tls-san:
  - hnq-01.<tailnet>.ts.net              # tên MagicDNS — chìa khoá để thay VPS nhanh
  - 100.x.y.z
  - <IP public VPS>

etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 20
etcd-snapshot-dir: /srv/k3s/snapshots
etcd-s3: true
etcd-s3-config-secret: k3s-etcd-s3       # D13 — Secret ở namespace kube-system
```

### `hnq-02` / `hnq-03` — `/etc/rancher/k3s/config.yaml`

```yaml
server: https://hnq-01.<tailnet>.ts.net:6443    # tên MagicDNS, KHÔNG phải IP
token: <token của hnq-01>
node-name: hnq-02                               # hnq-03 trên máy còn lại
node-ip: 100.x.y.z
flannel-iface: tailscale0
node-label:
  - "hnq.dev/env-prod=true"                     # hnq-03: hnq.dev/env-dev=true
  - "hnq.dev/storage=true"
  - "hnq.dev/edge=true"
```

### Ba thứ không sửa được sau này mà không cài lại

1. `cluster-init: true` (etcd thay vì SQLite)
2. `flannel-iface: tailscale0`
3. `--hostname` của Tailscale → đi vào TLS SAN và vào `server:` của 2 agent

---

## 3. Add-on gói sẵn của k3s

| Add-on | Quyết định | Cách thi công |
|---|---|---|
| **Traefik** | Giữ, cấu hình lại | `HelmChartConfig` trong `kube-system` → [§10](#10-đường-dữ-liệu-vào) |
| **CoreDNS** | Giữ, scale 2 | `kubectl -n kube-system scale deploy coredns --replicas=2` (nằm trong `make bootstrap`). Taint D9 đẩy pod xuống 2 máy nhà; `topologySpreadConstraints` có sẵn trong manifest k3s tách chúng ra 2 node |
| **metrics-server** | Giữ nguyên | Tự chuyển xuống máy nhà do taint |
| **ServiceLB** | **Tắt** | `disable: servicelb` |
| **local-storage** | **Tắt**, thay bằng chart tự quản | `disable: local-storage` → [§8](#8-lưu-trữ) |

⚠️ Không sửa file trong `/var/lib/rancher/k3s/server/manifests/` — k3s ghi đè lại mỗi lần khởi động. Chỉ dùng `disable:`, `HelmChartConfig`, hoặc trường **không** có trong manifest gốc (đó là lý do `replicas` của CoreDNS đổi được bền).

---

## 4. Cấu trúc repo

```text
HNQ-Infra/                     (branch main duy nhất)
│
├── registry/apps/             ⭐ NƠI DUY NHẤT sửa khi thêm service
│   └── <tên-service>/
│       ├── service.yaml              # chart nào, bật env nào, cần secret gì
│       ├── values-dev.yaml           # chỉ ghi phần KHÁC mặc định
│       ├── values-prod.yaml
│       └── config/
│
├── charts/
│   ├── hnq-common/                   # library: labels, probes, ingress, sync-wave
│   ├── webservice/                   # mọi HTTP service
│   └── datastore/                    # mọi database một node + CronJob dump
│
├── env/{dev,prod}.yaml               # khác biệt dev ↔ prod
│
├── gitops/
│   ├── root.yaml                     # ⭐ FILE DUY NHẤT apply tay, đúng 1 lần
│   ├── install/argocd-values.yaml
│   └── bootstrap/
│       ├── projects.yaml             # 2 AppProject
│       ├── appset-apps.yaml          # ApplicationSet
│       └── platform/*.yaml           # 7 Application bên thứ ba
│
├── secrets/{dev,prod}/               # SealedSecret đã mã hoá
│
├── ci/
│   ├── policy/*.rego
│   └── scripts/{new-service,render-all,promote,check-secrets}.sh
│
├── scripts/
│   ├── status.sh  drift.sh  backup/
│   └── dr/                           ⭐ NƠI ĐI TỚI KHI ĐANG SỰ CỐ
│       ├── kit-check.sh      restore-etcd.sh    rebuild-master.sh
│       └── failover-prod.sh  restore-db.sh
│
├── .github/{workflows/validate.yml,CODEOWNERS,renovate.json}
├── docs/
└── Makefile
```

**Quy ước cứng** (CI kiểm):

| Thứ | Quy ước |
|---|---|
| Namespace | `<tên-service>-<env>` — suy ra, không khai trong values |
| Release name Helm | `<tên-service>` |
| Application | `<tên-service>-<env>` |
| Secret | `<tên-service>-<thành-phần>`, file ở `secrets/<env>/<tên-service>/<thành-phần>.yaml` |
| Image tag | 7 ký tự git SHA |

---

## 5. Khai báo service

`registry/apps/lotus-clinic/service.yaml`:

```yaml
apiVersion: hnq.dev/v1
kind: ServiceRelease
metadata:
  name: lotus-clinic
spec:
  category: app                  # app | platform → quyết định AppProject
  chart: webservice              # webservice | datastore
  environments:                  # chưa liệt kê "prod" → chưa có Application prod
    - env: dev
    - env: prod
  requiredSecrets:               # CI đối chiếu với secrets/<env>/
    - name: lotus-clinic-backend
      keys: [DB_PASSWORD, JWT_SECRET]
```

`values-dev.yaml` chỉ ghi phần khác mặc định:

```yaml
image: { repository: ghcr.io/hnq-tech/lotus-backend, tag: 6aebe24 }
ingress: { host: lotus-dev.l2cteam.work }
app: { configFile: config/config_dev.yaml, secretName: lotus-clinic-backend }
```

Port, probe, resources, `nodeSelector`, issuer, `imagePullSecrets`, `serviceMonitor`, `storageClass` đến từ `env/<env>.yaml` + `charts/<chart>/values.yaml`.

**Thêm service mới:** `make new-service NAME=abc-clinic CHART=webservice` → commit → PR → CI xanh → merge. Không viết file ArgoCD nào.

---

## 6. Chart

### `charts/hnq-common` (library)

Hàm bắt buộc, mọi chart khác gọi qua:

| Helper | Sinh ra |
|---|---|
| `hnq.labels` | `app.kubernetes.io/*` + `hnq.dev/env` + `hnq.dev/service` |
| `hnq.nodeSelector` | Nạp từ `env.nodeSelector`, **fail template nếu rỗng** |
| `hnq.probes` | readiness + liveness, chặn deploy nếu chart không khai `probePath` |
| `hnq.resources` | Bắt buộc có `requests` + `limits` |
| `hnq.ingress` | Thêm annotation `cert-manager.io/cluster-issuer` từ `env` |
| `hnq.syncWave` | Trả wave theo bảng dưới |

**Sync wave (D16):**

| Wave | Tài nguyên |
|---|---|
| `-3` | Namespace, ResourceQuota, LimitRange |
| `-2` | SealedSecret, ConfigMap |
| `-1` | PVC |
| `0` | Workload của `datastore` |
| `1` | Workload của `webservice` |
| `2` | Service, Ingress, ServiceMonitor |

### `charts/webservice`

Deployment (1 replica) · Service · Ingress · ServiceMonitor · ConfigMap từ `config/` · tham chiếu Secret theo tên.

### `charts/datastore`

StatefulSet 1 replica · PVC `storageClassName: hnq-local` · Service headless · ServiceMonitor · **CronJob dump hằng giờ** (`backup.enabled`, `backup.command`) ghi vào PVC dump rồi `rclone copy` lên R2.

### Kiểm chart

- `values.schema.json` cho cả 2 chart → `helm lint` bắt sai trường ngay.
- `helm-unittest` bắt buộc cho `hnq-common`: có `nodeSelector`, có `resources`, có `sync-wave`, không `latest`.

---

## 7. GitOps

### AppProject — 2 cái

| Project | Namespace đích | `clusterResourceWhitelist` |
|---|---|---|
| **app** | `*-dev`, `*-prod` | `[]` — chặn hoàn toàn ClusterRole, CRD… |
| **platform** | `*` | `[{group: "*", kind: "*"}]` |

### ApplicationSet — `gitops/bootstrap/appset-apps.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  syncPolicy:
    applicationsSync: create-update        # D15 — generator hỏng không xoá được Application
    preserveResourcesOnDeletion: true
  generators:
    - matrix:
        generators:
          - git:
              repoURL: &repo https://github.com/hunho247/HNQ-Infra.git
              revision: main
              files: [{ path: "registry/apps/*/service.yaml" }]
          - list:
              elements: []                 # bắt buộc để trống trước elementsYaml
              elementsYaml: "{{ .spec.environments | toJson }}"
  template:
    metadata:
      name: "{{ .metadata.name }}-{{ .env }}"
    spec:
      project: "{{ .spec.category }}"
      source:
        repoURL: *repo
        targetRevision: main
        path: "charts/{{ .spec.chart }}"
        helm:
          releaseName: "{{ .metadata.name }}"
          valueFiles:                      # "/" = tính từ gốc repo
            - values.yaml
            - "/env/{{ .env }}.yaml"
            - "/registry/apps/{{ .metadata.name }}/values-{{ .env }}.yaml"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{ .metadata.name }}-{{ .env }}"
      syncPolicy:
        automated:
          selfHeal: true
          prune: {{ if eq .env "dev" }}true{{ else }}false{{ end }}
        syncOptions: [CreateNamespace=true, PruneLast=true, ServerSideApply=true]
        retry: { limit: 5, backoff: { duration: 10s, factor: 2, maxDuration: 5m } }
```

> `elements: []` đứng trước `elementsYaml` là workaround đã biết của tổ hợp matrix + git file generator — bỏ đi thì generator im lặng không sinh gì.

### 7 Application tường minh cho chart bên thứ ba

`gitops/bootstrap/platform/`, mỗi file ~20 dòng, **pin version tuyệt đối**, Renovate tự mở PR:

| Application | Wave | Chạy ở |
|---|---|---|
| `sealed-secrets` | -3 | hnq-01 |
| `local-path-provisioner` | -3 | hnq-01 (controller) |
| `cert-manager` + ClusterIssuer | -2 | hnq-01 |
| `traefik-config` (HelmChartConfig) | -1 | — |
| `cloudflared` | 0 | edge |
| `kube-prometheus-stack` | 1 | hnq-03 |
| `velero` | 1 | hnq-01 server + node-agent ở 2 máy nhà |
| `system-upgrade-controller` | 2 | hnq-01 |

### Bootstrap — lệnh duy nhất trong đời cluster

```bash
helm install argocd argo/argo-cd -n argocd --create-namespace -f gitops/install/argocd-values.yaml
kubectl -n argocd apply -f gitops/root.yaml
```

`gitops/install/argocd-values.yaml` tối thiểu:

```yaml
configs:
  cm:   { admin.enabled: "true", timeout.reconciliation: 180s }
  rbac: { policy.default: "" }              # deny-by-default
server:
  ingress: { enabled: false }               # ⚠️ KHÔNG BAO GIỜ lộ ra internet
redis-ha: { enabled: false }
global:
  nodeSelector: { hnq.dev/role: control-plane }
  tolerations:
    - { key: hnq.dev/dedicated, operator: Equal, value: control-plane, effect: NoSchedule }
```

---

## 8. Lưu trữ

### local-path-provisioner tự quản (D11)

`gitops/bootstrap/platform/local-path-provisioner.yaml` → chart `rancher/local-path-provisioner`, values:

```yaml
storageClass:
  create: false                    # không tạo class mặc định
storageClassConfigs:
  hnq-local:
    storageClass:
      create: true
      defaultClass: true
      defaultVolumeType: local     # ⚠️ BẮT BUỘC — Velero KHÔNG backup được hostPath
      reclaimPolicy: Retain        # D8 — xoá PVC không mất dữ liệu
      volumeBindingMode: WaitForFirstConsumer
      pathPattern: "{{ .PVC.Namespace }}-{{ .PVC.Name }}"
      permPattern: '0777'          # tránh lỗi 755 của StorageClass phụ
    nodePathMap:
      - node: hnq-02
        paths: ["/srv/k3s/data"]
      - node: hnq-03
        paths: ["/srv/k3s/data"]
      - node: hnq-01
        paths: []                  # từ chối cấp volume trên master
nodeSelector: { hnq.dev/role: control-plane }
tolerations:
  - { key: hnq.dev/dedicated, operator: Equal, value: control-plane, effect: NoSchedule }
```

**Không viết PV bằng tay.** Lúc node prod chết ([R4](./RECOVERY.md#r4--node-prod-chết)), PV viết tay thêm một bước sửa path lúc đang gấp; với provisioner thì PVC tạo lại là volume tự sinh trên node mới.

---

## 9. Backup

| Lớp | Cái gì | Đi đâu | Tần suất | Mất tối đa |
|---|---|---|---|---|
| **1 · etcd snapshot** | Toàn bộ trạng thái k8s | R2 (`etcd-s3-config-secret`) | 6 giờ | 6 giờ |
| **2a · Velero FSB** | Dữ liệu trong PV | R2 | prod 1 ngày, giữ 30 ngày | 24 giờ |
| **2b · Dump database** | `mysqldump` / `pg_dump` từng DB | `/srv/k3s/dump/` → R2 | **1 giờ** | **1 giờ** |
| **3 · Git** | Toàn bộ cấu hình | GitHub | mỗi commit | 0 |

Không để backup trong cluster (không dùng MinIO của chính cluster).

### Velero values (D17)

```yaml
credentials: { existingSecret: velero-r2 }
configuration:
  uploaderType: kopia
  defaultVolumesToFsBackup: true          # opt-out: backup hết, loại trừ bằng annotation
  volumeSnapshotLocation: []              # local-path không có CSI snapshot
  backupStorageLocation:
    - name: r2
      provider: aws
      bucket: hnq-velero
      config:
        region: auto
        s3Url: https://<account>.r2.cloudflarestorage.com
        s3ForcePathStyle: "true"
        checksumAlgorithm: ""             # ⚠️ bắt buộc với R2, thiếu là backup lỗi
deployNodeAgent: true
nodeAgent:
  nodeSelector: { hnq.dev/storage: "true" }
nodeSelector: { hnq.dev/role: control-plane }
tolerations:
  - { key: hnq.dev/dedicated, operator: Equal, value: control-plane, effect: NoSchedule }
schedules:
  prod-daily:
    schedule: "0 2 * * *"
    template: { ttl: 720h, includedNamespaces: ["*-prod"] }
```

Dev không có schedule — dựng lại từ Git.

---

## 10. Đường dữ liệu vào

Mục tiêu: `hnq-01` chết thì **traffic khách hàng không đứt**. Cả 3 thành phần dưới đây đều 2 replica, `requiredDuringScheduling` antiAffinity theo `kubernetes.io/hostname`, `nodeSelector: hnq.dev/edge`.

```
Cloudflare → Tunnel → cloudflared (×2, máy nhà) → Traefik (×2, máy nhà) → pod (máy nhà)
```

### Traefik — `HelmChartConfig`

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata: { name: traefik, namespace: kube-system }
spec:
  valuesContent: |-
    service:
      type: ClusterIP                     # D10 — không còn ServiceLB
    deployment:
      replicas: 2
    nodeSelector:
      hnq.dev/edge: "true"
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels: { app.kubernetes.io/name: traefik }
    providers:
      kubernetesIngress:
        publishedService: { enabled: true }
```

### cloudflared — in-cluster, 2 replica

Chuyển khỏi systemd trên VPS. Một rule catch-all (D18):

```yaml
ingress:
  - service: https://traefik.kube-system.svc.cluster.local:443
    originRequest:
      noTLSVerify: true
      httpHostHeader: ""                  # giữ Host gốc để Traefik route đúng
```

Token tunnel là SealedSecret. Cloudflare tự chia traffic giữa các replica và tự chuyển khi một replica mất.

### CoreDNS

`kubectl -n kube-system scale deploy coredns --replicas=2` — nằm trong `make bootstrap` và được `drift.sh` kiểm hằng tuần.

### Nghiệm thu đường dữ liệu (cửa chặn của P3)

```bash
ssh hnq-01 'sudo systemctl stop k3s'      # 5 phút
curl -sS -o /dev/null -w '%{http_code}\n' https://lotus-dev.l2cteam.work/healthz   # phải 200
ssh hnq-01 'sudo systemctl start k3s'
```

---

## 11. Secret

### Sealed Secrets

```bash
kubectl create secret generic lotus-clinic-backend -n lotus-clinic-prod \
  --from-literal=DB_PASSWORD='...' --dry-run=client -o yaml \
| kubeseal --format yaml > secrets/prod/lotus-clinic/backend.yaml
```

### Recovery kit — **4 món** (D14 thêm món 4)

| # | Món | Lấy ở đâu | Mất nó thì |
|---|---|---|---|
| 1 | etcd snapshot | R2 + 1 bản trên laptop | Không dựng lại được cluster |
| 2 | k3s token | `/var/lib/rancher/k3s/server/token` | Snapshot vô dụng |
| 3 | Sealing key của Sealed Secrets | `kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml` | Mọi file trong `secrets/` thành vô nghĩa |
| 4 | `encryption-config.json` | `/var/lib/rancher/k3s/server/cred/encryption-config.json` | Restore được cluster nhưng **không đọc được Secret nào** |

Cả 4 vào password manager (2 nơi) + USB mã hoá, rồi `shred -u` bản tạm. Bật **emergency access** cho một người tin được — với 1 người vận hành, "cất 2 nơi" mà cả 2 chỉ mình bạn mở được thì vẫn là một điểm hỏng.

`make kit-check` hằng tháng đối chiếu cả 4 (so bằng sha256, không so giá trị). Controller Sealed Secrets xoay key mỗi 30 ngày → backup lại hằng quý.

### Secret `k3s-etcd-s3` (D13)

```yaml
apiVersion: v1
kind: Secret
metadata: { name: k3s-etcd-s3, namespace: kube-system }
type: etcd.k3s.cattle.io/s3-config-secret
stringData:
  etcd-s3-endpoint: "<account>.r2.cloudflarestorage.com"
  etcd-s3-bucket: "hnq-etcd-snapshots"
  etcd-s3-region: "auto"
  etcd-s3-access-key: "..."
  etcd-s3-secret-key: "..."
```

Commit dưới dạng SealedSecret. Khi restore trên máy mới ([R6](./RECOVERY.md#r6--vps-mất-hoàn-toàn)) thì truyền thẳng bằng cờ CLI lấy từ recovery kit — lúc đó chưa có cluster để đọc Secret.

---

## 12. Giám sát

Monitoring đặt ở `hnq-03`: ở master thì mất master là mất luôn khả năng biết; ở node prod thì node prod chết là mất monitoring đúng lúc cần nó nhất.

### Tám alert — tắt hết alert mặc định còn lại của kube-prometheus-stack

| # | Alert | Ngưỡng |
|---|---|---|
| 1 | Node NotReady | > 5 phút |
| 2 | **Đường dữ liệu suy giảm** — Traefik/cloudflared/CoreDNS < 2 pod Ready, hoặc 2 pod cùng một node | > 10 phút |
| 3 | Đĩa node | > 80% |
| 4 | PVC | > 85% |
| 5 | Pod `*-prod` CrashLoop hoặc không Ready | > 15 phút |
| 6 | **Backup quá hạn** — etcd > 12h, dump > 2h, Velero > 26h | ngay |
| 7 | Certificate hết hạn | < 14 ngày |
| 8 | **Dead man's switch** (Watchdog → healthchecks.io) | thiếu ping 12 phút |

Mỗi alert phải có trường `action` ghi việc cần làm. Alert đi tới điện thoại, ở kênh riêng không lẫn chat thường.

ArgoCD OutOfSync **không** phải alert gọi đêm — nằm trong `make drift` hằng tuần.

---

## 13. CI

Một workflow `.github/workflows/validate.yml` chạy trên mọi PR:

```
yamllint → JSON Schema (service.yaml) → helm lint + helm-unittest
        → check-secrets.sh → render-all.sh → kubeconform → conftest
        → gitleaks + trivy
```

`render-all.sh` render **mọi service × mọi môi trường** rồi kiểm — ApplicationSet sinh sai tên hay values thiếu trường đều bị bắt trước khi vào `main`.

### Policy `ci/policy/*.rego`

| Rule | Ngăn được |
|---|---|
| Mọi container có `resources.limits` + `requests` | Một pod ăn hết CPU node |
| Cấm `image: *:latest`, tag phải khớp `^[0-9a-f]{7}$` | Không tái tạo được → không quay lui được |
| Bắt buộc `readinessProbe` | Traffic vào pod chưa sẵn sàng |
| Cấm `hostNetwork`, `privileged`, `hostPath` | Thoát container; và `hostPath` thì Velero không backup được |
| Ingress phải có `cert-manager.io/cluster-issuer` | Domain chạy không TLS |
| Mọi workload khai `nodeSelector` | Pod rơi nhầm môi trường |
| Mọi PVC dùng `storageClassName: hnq-local` | Rơi về class khác, mất `Retain` |
| **Chỉ 5 chart platform ở [§2](#2-topology-và-cấu-hình-node) được khai toleration `hnq.dev/dedicated`** | Workload lách taint lên master |
| Mọi `Application`/`Chart.yaml` pin version tuyệt đối | Sync ra phiên bản khác lần trước |

### Branch protection

| Thiết lập | Giá trị |
|---|---|
| Require pull request | ✅ |
| **Require approvals** | **0** — GitHub không cho tự approve PR của mình |
| Require status checks | ✅ — đây là cửa duyệt duy nhất |
| Force push / xoá `main` | ❌ |
| Admin bypass | ✅ — đường break-glass; mỗi lần dùng ghi 1 dòng vào `RUNBOOK.md` |

`CODEOWNERS` dùng để **nhắc dừng lại 10 giây** khi PR đụng `values-prod.yaml`, `env/prod.yaml`, `gitops/`, `charts/`, `secrets/prod/`.

---

## 14. Promotion dev → prod

```text
registry/apps/lotus-clinic/values-dev.yaml    → tag: 7bcd123   (mới, đang test)
registry/apps/lotus-clinic/values-prod.yaml   → tag: f1eb557   (ổn định)
```

| Môi trường | Luồng |
|---|---|
| **Dev** | push code → CI build ghcr → CI mở PR đổi `image.tag` → CI xanh → tự merge → ArgoCD sync |
| **Prod** | `make promote NAME=lotus-clinic` → 3 cửa → PR → đọc diff → merge → sync |

`ci/scripts/promote.sh` chạy trên máy có quyền vào cluster nên kiểm được thứ CI trên GitHub không thấy:

```bash
# 1. dev phải Synced + Healthy
[ "$SYNC/$HEALTH" = "Synced/Healthy" ] || exit 1
# 2. pod dev sống liên tục ≥ 30 phút và 0 restart
[ "$AGE_MIN" -ge 30 ] && [ "$RESTARTS" -eq 0 ] || echo "⚠️ dùng --force nếu chắc"
# 3. commit ghi rõ đường quay lui
git commit -m "release($SVC): prod $CUR → $TAG

Quay lui: git revert <commit này> → prod về $CUR
dev đã chạy $TAG liên tục ${AGE_MIN} phút, 0 restart."
```

---

## 15. Nâng cấp

| Thứ | Cách |
|---|---|
| **k3s** | `system-upgrade-controller`, 2 Plan (server → agent), `concurrency: 1`. Nâng cấp = PR đổi một dòng version |
| **Chart bên thứ ba** | Renovate mở PR, duyệt hằng tuần |
| **Image ứng dụng** | Luồng promotion ở [§14](#14-promotion-dev--prod) |

⚠️ `concurrency: 1` bắt buộc: nâng cả 2 máy nhà cùng lúc = cả 2 replica Traefik và cloudflared cùng xuống = mất toàn bộ traffic.

---

## 16. Lộ trình

Đơn vị là **ngày công của 1 người** (~26 ngày công). Mỗi phase xong khi **toàn bộ DoD** đúng.

| Phase | Việc | Ngày | Definition of Done |
|---|---|---|---|
| **P0** · Cluster + đường lùi | 3 node, nhãn, taint, `disable`, thư mục đĩa · `secrets-encryption` · etcd snapshot → R2 · recovery kit 4 món · **diễn tập restore lúc cluster còn trống** | 4 | `kubectl get node` đủ 3, `hnq-01` có taint · MTU đúng (`ping -M do -s 1400` giữa 2 node **phải lỗi**) · `tailscale ping` là `direct` · snapshot có mặt trên R2 · `make kit-check` xanh · đã restore etcd thành công 1 lần, có số phút ghi lại |
| **P1** · GitOps nền | ArgoCD + sealed-secrets + `root.yaml` · CI + Renovate + branch protection | 3 | `gitops/root.yaml` apply 1 lần dựng được toàn bộ · `kubectl -n argocd get ingress` **trống** · PR sai policy bị CI chặn thật · sealing key + encryption-config đã vào kit |
| **P2** · Chart | `hnq-common` + unittest · `webservice` + `datastore` + schema + sync-wave | 4 | `helm unittest` xanh · `render-all.sh` render đủ mọi service × env · chart thiếu `nodeSelector`/`resources` thì **fail template**, không chỉ cảnh báo |
| **P3** · Đường dữ liệu | local-path-provisioner · Traefik ×2 · cloudflared in-cluster ×2 · CoreDNS ×2 · cert-manager + issuer | 2 | 🚧 **`systemctl stop k3s` trên `hnq-01` 5 phút mà domain public vẫn trả 200** · không còn `cloudflared` systemd trên VPS · PVC thử nghiệm bound vào `/srv/k3s/data` với `volumeType: local` |
| **P4** · Service ở dev | 5 storage + push-notify · 4 clinic + outline | 4 | Mọi Application dev `Synced/Healthy` · không pod nào nằm trên `hnq-01` |
| **P5** · Lưới an toàn | Velero → R2 · dump hằng giờ · monitoring + 8 alert + dead man's switch | 4 | Velero backup prod **restore thử thành công 1 lần** · dump có mặt trên R2 · tắt Alertmanager thì điện thoại có thông báo trong 12 phút |
| **P6** · Prod | Bật prod từng service · `promote.sh` · **diễn tập dời node prod** · `RUNBOOK.md` + `BREAK_GLASS.md` | 3 | Đã dời prod sang node khác thành công 1 lần, có số phút · `BREAK_GLASS.md` đã có người khác đọc 1 lần · người đó truy cập được recovery kit |
| **P7** · Tuỳ chọn | `make new-service` · `status.sh` · system-upgrade-controller | 2 | Nâng k3s là PR đổi một dòng |

### 🚧 Hai cửa chặn

> **Cửa 1 — không đi tiếp P1 trước khi P0 xong.** Diễn tập restore lúc cluster còn trống là lúc rẻ nhất trong cả đời cluster: sai thì `k3s-uninstall.sh` rồi làm lại.
>
> **Cửa 2 — không bật prod (P6) trước khi P5 xong.** Không có Velero + dump hằng giờ thì service prod không có đường lùi.

### Mục tiêu phục hồi (số phải đo được sau P6)

| Sự cố | Phục hồi trong | Mất dữ liệu tối đa |
|---|---|---|
| Deploy sai | 5 phút | 0 |
| Node prod chết | 30 phút | 1 giờ |
| etcd hỏng (VPS còn) | 10 phút | 6 giờ |
| VPS mất hẳn | 45 phút | 6 giờ |
| Mất cả 3 máy | 3 giờ | 1 giờ |
