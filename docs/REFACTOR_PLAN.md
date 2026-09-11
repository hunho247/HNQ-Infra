# Kế hoạch tái cấu trúc hạ tầng k3s + ArgoCD

| | |
|---|---|
| **Trạng thái** | Bản nháp, chờ duyệt |
| **Ngày** | 11/09/2026 |
| **Phạm vi** | Toàn bộ `infra/argocd/**` và `infra/helm/**` |
| **Tài liệu liên quan** | [Kế hoạch backend Platform API](./PLATFORM_API_PLAN.md) · [Thiết kế quản lý secret](./SECRET_MANAGEMENT.md) |

---

## Tóm tắt cho người bận

Repo hiện tại có 3 vấn đề gốc:

1. **Mọi thứ đều phải copy tay.** Thêm một khách hàng mới phải tạo 6–8 file, trong đó 2 file ArgoCD giống hệt nhau chỉ khác 5 dòng. Copy tay thì sớm muộn cũng sót — và thực tế đã sót: **production hiện không có monitoring**.
2. **Chart viết lại từ đầu cho từng service.** 11 chart, mỗi chart tự viết `_helpers.tpl`, `service.yaml`, `namespace.yaml` gần như giống hệt nhau. Sửa một quy ước phải sửa 11 chỗ.
3. **Cluster chứa thứ không có trong Git.** Outline, gitlab-runner, coredns-ha đang chạy nhưng không có ArgoCD Application. Secret thì apply tay hoàn toàn. Cluster chết là mất.

Hướng giải quyết:

- **Khai báo một lần, sinh ra nhiều lần.** Mỗi service có đúng 1 file khai báo. ArgoCD `ApplicationSet` tự sinh ra Application cho mọi môi trường. 24 file Application biến mất.
- **Chart dùng chung.** 1 library chart + 2 chart tổng quát thay cho 11 chart riêng. Service mới chỉ cần viết values.
- **Mọi thứ vào Git, kể cả secret** (mã hoá bằng Sealed Secrets).
- **Có CI chặn lỗi trước khi vào cluster.**

Sau đó xây backend API để thao tác toàn bộ quy trình này qua HTTP — bạn dựng UI lên trên.

---

## Mục lục

- [Phần 1 — Hiện trạng](#phần-1--hiện-trạng)
- [Phần 2 — Nguyên tắc thiết kế](#phần-2--nguyên-tắc-thiết-kế)
- [Phần 3 — Mô hình 2 branch](#phần-3--mô-hình-2-branch-develop--main)
- [Phần 4 — Cấu trúc thư mục mới](#phần-4--cấu-trúc-thư-mục-mới)
- [Phần 5 — Service Registry + ApplicationSet](#phần-5--service-registry--applicationset)
- [Phần 6 — Library chart và chart tổng quát](#phần-6--library-chart-và-chart-tổng-quát)
- [Phần 7 — Secret](#phần-7--secret)
- [Phần 8 — Tự động cập nhật image tag](#phần-8--tự-động-cập-nhật-image-tag)
- [Phần 9 — AppProject và phân quyền](#phần-9--appproject-và-phân-quyền)
- [Phần 10 — CI kiểm tra](#phần-10--ci-kiểm-tra)
- [Phần 11 — Lưu trữ và backup](#phần-11--lưu-trữ-và-backup)
- [Phần 12 — Lộ trình](#phần-12--lộ-trình)
- [Phần 13 — Rủi ro](#phần-13--rủi-ro)
- [Phần 14 — Việc làm ngay được](#phần-14--việc-làm-ngay-được)
- [Phụ lục](#phụ-lục-a--ánh-xạ-file-cũ-sang-mới)

---

## Phần 1 — Hiện trạng

### 1.1. Con số

| Hạng mục | Hiện tại |
|---|---|
| File ArgoCD `Application` | 24 (12 cặp dev/prod gần như y hệt) |
| Số dòng trong `apps/**` | ~745 |
| Số dòng Helm template | ~2.713 |
| Số dòng Helm values | ~2.170 |
| Chart tự viết | 11 |
| File phải tạo khi thêm 1 khách hàng | 6–8 |
| File CI | 0 |
| Cơ chế quản lý secret | Không có |

### 1.2. Lỗi đang có trên production

#### 🔴 Lỗi 1 — Production không có monitoring

Đếm file:

```
apps/dev/platform/   → 10 Application
apps/prod/platform/  →  7 Application
```

Prod đang thiếu 3 cái:

| File thiếu | Hậu quả |
|---|---|
| `monitoring.yaml` | **Prod không có Prometheus, Grafana, alerting.** Sự cố xảy ra thì không ai biết cho tới khi khách hàng gọi. |
| `storage-postgres.yaml` | Không quản lý qua GitOps |
| `storage-redis.yaml` | Không quản lý qua GitOps |

Đây không phải quyết định thiết kế. Đây là hệ quả trực tiếp của việc `apps/dev/` và `apps/prod/` là **hai thư mục riêng biệt**: ai đó thêm file vào dev rồi quên prod, và không có gì phát hiện ra.

#### 🔴 Lỗi 2 — Có service chạy ngoài GitOps

`ARCHITECTURE.md` ghi Outline đang chạy ở namespace `admin-workspace-dev`. Nhưng tìm khắp `infra/argocd/apps/**` không có Application nào cho Outline. Tương tự `gitlab-runner` và `coredns-ha`: có chart trong repo, không có Application.

Nghĩa là những service này **chỉ tồn tại trong cluster**. Không ai biết chính xác chúng được deploy bằng lệnh gì, với values nào. Cluster chết là dựng lại bằng trí nhớ.

#### 🔴 Lỗi 3 — Tất cả khách hàng dùng chung một imagePullSecret sai tên

```
biboo-clinic/values-dev.yaml:41:    - name: lotus-clinic-registry
giaan-clinic/values-dev.yaml:53:    - name: lotus-clinic-registry
hocmon-clinic/values-dev.yaml:41:   - name: lotus-clinic-registry
lotus-clinic/values-dev.yaml:41:    - name: lotus-clinic-registry
```

Cả 4 khách hàng đều trỏ vào `lotus-clinic-registry`. Chỉ có 2 khả năng, và cả hai đều cần sửa:

- Đây là secret dùng chung nhưng bị đặt tên theo một khách hàng cụ thể → gây hiểu nhầm, cần đổi tên thành `gitlab-registry`
- Hoặc 3 khách hàng đang pull image bằng credential của khách hàng khác → sai về phân quyền

#### 🟠 Lỗi 4 — dev và prod trỏ vào repo bằng 2 giao thức khác nhau

```
dev:   git@gitlab.com:hnq-tech/hnq-infra.git      (SSH)
prod:  https://gitlab.com/hnq-tech/hnq-infra.git  (HTTPS)
```

ArgoCD coi đây là **hai repository khác nhau**. Nghĩa là hai bộ credential, hai cache ở repo-server. Hôm nào đổi credential mà chỉ nhớ một bên thì nửa hệ thống ngừng sync, và triệu chứng sẽ rất khó hiểu.

#### 🟠 Lỗi 5 — Từng có sự cố 30 giờ vì helm thủ công chạy song song ArgoCD

File `infra/helm/monitoring/issues.md` trong repo ghi lại sự cố ngày 18/06/2026:

> Hai helm release chạy song song trong namespace `monitoring` → hai DaemonSet node-exporter cùng dùng `hostNetwork: true` port 9100 → xung đột → DaemonSet mới Pending 30 giờ → Prometheus không lấy được kubelet metrics.

Nguyên nhân gốc: không có ranh giới rõ ràng giữa "cái gì ArgoCD quản" và "cái gì apply tay". Đây chính là lý do nguyên tắc **Git là nguồn sự thật duy nhất** phải được áp dụng triệt để, không có ngoại lệ.

### 1.3. Nợ kỹ thuật

#### 24 file Application chỉ khác nhau 5 dòng

Diff giữa **mọi** cặp dev/prod đều đúng khuôn này:

```diff
-  name: lotus-clinic-dev                            +  name: lotus-clinic-prod
-  repoURL: git@gitlab.com:hnq-tech/hnq-infra.git    +  repoURL: https://gitlab.com/...
-  targetRevision: develop                           +  targetRevision: main
-  - lotus-clinic/values-dev.yaml                    +  - lotus-clinic/values-prod.yaml
-  namespace: lotus-clinic-dev                       +  namespace: lotus-clinic-prod
```

Không có gì khác. 745 dòng YAML để diễn đạt 5 biến số.

#### Values của khách hàng trùng nhau ~90%

File `values-dev.yaml` của lotus dài ~60 dòng. So với giaan, chỉ khác 6 chỗ (tên, host, tên secret, đường dẫn config, resources, tolerations). 54 dòng còn lại giống hệt.

Và đã có dấu hiệu copy sót: `giaan-clinic/values-dev.yaml` để `tolerations: []` trong khi 3 khách hàng kia đều có toleration cho control-plane. Không rõ cố ý hay quên.

#### Chart nào cũng viết lại từ đầu

`mariadb/_helpers.tpl` và `postgres/_helpers.tpl` khác nhau **đúng một chuỗi** — `mariadb` đổi thành `postgres`:

```diff
- {{- define "mariadb.fullname" -}}      + {{- define "postgres.fullname" -}}
- {{- define "mariadb.labels" -}}        + {{- define "postgres.labels" -}}
- {{- define "mariadb.secretName" -}}    + {{- define "postgres.secretName" -}}
```

Chuyện này lặp lại với `namespace.yaml`, `service.yaml`, `nodeport-service.yaml`, `secret.yaml` trên 5 chart storage. Muốn đổi quy ước label? Sửa 11 chỗ.

#### Namespace bị tạo 2 lần

Chart có `templates/namespace.yaml`, đồng thời Application có `syncOptions: CreateNamespace=true`. Hai cơ chế cùng sở hữu một resource. Khi prune sẽ tranh chấp, và namespace không nhận được label thống nhất.

#### Image tag ghi cứng trong values

```yaml
image: registry.gitlab.com/hnq-tech/clients/lotus-clinic/lotus-backend:6aebe241
```

Mỗi lần deploy phải mở file, sửa tag, commit, push bằng tay. Không có liên kết tự động giữa CI build image và GitOps.

#### Không có CI

Không có `.gitlab-ci.yml`. Không `helm lint`, không kiểm tra schema, không policy. YAML sai cú pháp hoặc thiếu resource limit đi thẳng vào cluster, chỉ biết khi ArgoCD báo lỗi.

#### hostPath với 3 quy ước đường dẫn khác nhau

| Nơi khai báo | Đường dẫn |
|---|---|
| `values-dev.yaml` | `/data/k3s/dev/platform/storage/...` |
| `values-prod.yaml` | `/home/hnq/hnq_data/prod/platform/storage/...` |
| `README.md` (tài liệu chính thức) | `/home/server01/srv/envs/<env>/data/...` |

Cộng thêm `nodeSelector: kubernetes.io/hostname: server02` ghim pod vào một node cụ thể. Node chết → pod không chuyển sang node khác được, data cũng không truy cập được.

#### Tài liệu lệch thực tế

- `README.md` mô tả cấu trúc `envs/` với apps, config, data, logs, backup — **thư mục này không tồn tại trong repo**. Nó mô tả layout trên server, bị đặt nhầm chỗ.
- `README.md` mô tả `infra/ci/` với 4 script — cũng không tồn tại.
- `ARCHITECTURE.md` liệt kê 3 node: `hnq-server-vietnix-01-hjnu`, `hnq`, `server01`. Nhưng values dev ghim vào `server02` — node không có trong tài liệu.

#### Mọi Application dùng `project: default`

Không có ranh giới phân quyền nào. Về mặt kỹ thuật, một chart của khách hàng có thể tạo `ClusterRole` hoặc deploy vào `kube-system`.

#### File rác

`hnq_svc.json` ở thư mục gốc là output rỗng của `kubectl get -o json`: `{"items": []}`.

---

## Phần 2 — Nguyên tắc thiết kế

Bảy nguyên tắc dưới đây là cơ sở cho mọi quyết định trong tài liệu này.

| # | Nguyên tắc | Nghĩa là gì trong thực tế |
|---|---|---|
| **P1** | Git là nguồn sự thật duy nhất | Không `kubectl apply` tay, không `helm install` tay. Kể cả backend API cũng phải ghi vào Git chứ không ghi thẳng vào cluster. |
| **P2** | Khai báo một lần, sinh ra nhiều lần | Một file khai báo service → ArgoCD tự sinh Application cho mọi môi trường. Không bao giờ copy file giữa dev và prod. |
| **P3** | Môi trường là tham số, không phải bản sao | dev và prod khác nhau bằng file override nhỏ, không phải bằng hai cây thư mục song song. |
| **P4** | Chart dùng chung, values riêng | Logic template nằm ở library chart. Thêm service mới chỉ viết values, không viết template. |
| **P5** | Schema là hợp đồng | Mỗi khai báo service có JSON Schema. Schema đó vừa dùng validate trong CI, vừa sinh form cho UI. Một nguồn, không lệch. |
| **P6** | Không gì vào cluster mà không qua CI | Lint, render, kiểm tra schema, policy — tất cả chạy trước khi merge. |
| **P7** | Quay lui = `git revert` | Không có trạng thái nào chỉ tồn tại trong cluster mà không có trong Git. |

---

## Phần 3 — Mô hình 2 branch: `develop` → `main`

Bạn đã chốt giữ 2 branch để test ở dev trước rồi mới lên prod. Đây là mô hình đúng, nhưng cần thiết kế cẩn thận để không lặp lại Lỗi 1 (prod thiếu app).

### 3.1. Vì sao Lỗi 1 xảy ra — và vì sao nó sẽ không tái diễn

Điều quan trọng cần hiểu: **Lỗi 1 không phải do có 2 branch.** Nó xảy ra vì `apps/dev/` và `apps/prod/` là **hai thư mục riêng biệt trong cùng một branch**. Thêm file vào thư mục này không hề liên quan gì tới thư mục kia, và Git cũng không có lý do gì để báo.

Ở cấu trúc mới, dev và prod dùng **chung một thư mục `registry/`**. Sự khác biệt duy nhất là branch nào đang được ArgoCD đọc. Kèm theo một quy tắc:

> **`main` chỉ nhận thay đổi qua merge từ `develop`. Không bao giờ commit thẳng vào `main`.**

Hệ quả: mọi thứ có ở dev thì **chắc chắn** sẽ có ở prod sau khi merge. Câu hỏi duy nhất còn lại là *khi nào*, và cái đó thì nhìn thấy được (xem mục 3.4).

```mermaid
flowchart LR
  subgraph Cu["❌ Cũ — 2 thư mục, cùng 1 branch"]
    direction TB
    D1["apps/dev/platform/<br/>10 file"]
    P1["apps/prod/platform/<br/>7 file"]
    D1 -.->|"copy tay<br/>quên là mất"| P1
  end

  subgraph Moi["✅ Mới — 1 thư mục, 2 branch"]
    direction TB
    R1["registry/<br/>(trên develop)"]
    R2["registry/<br/>(trên main)"]
    R1 -->|"git merge<br/>không thể sót"| R2
  end
```

### 3.2. Luồng làm việc

```mermaid
sequenceDiagram
  participant Dev as Lập trình viên
  participant DB as branch develop
  participant AD as ArgoCD (dev)
  participant MB as branch main
  participant AP as ArgoCD (prod)

  Note over Dev,AD: 1. Phát triển và test ở dev
  Dev->>DB: commit thay đổi
  DB->>AD: webhook
  AD->>AD: sync môi trường dev
  Dev->>AD: kiểm tra, test

  Note over Dev,AP: 2. Đưa lên prod
  Dev->>MB: mở MR develop → main
  Note over MB: CI chạy đủ bộ kiểm tra<br/>Reviewer duyệt
  Dev->>MB: merge
  MB->>AP: webhook
  AP->>AP: sync môi trường prod
```

### 3.3. Bảng quy tắc branch

| | `develop` | `main` |
|---|---|---|
| Môi trường | dev | prod |
| ArgoCD root app | `apps-dev` | `apps-prod` |
| Ai được commit thẳng | CI (bump image tag dev) + lập trình viên | **Không ai** |
| Cách thay đổi | Commit trực tiếp hoặc MR | **Chỉ merge từ `develop`** |
| Bảo vệ branch trên GitLab | Cho phép push | Protected: chỉ MR từ `develop`, bắt buộc ≥1 approval, bắt buộc CI xanh |
| Auto-sync của ArgoCD | Bật, có `selfHeal` | Bật `selfHeal`, nhưng chỉ nhận thay đổi đã qua MR |

### 3.4. Theo dõi "hàng chờ lên prod"

Vì `main` đi sau `develop`, cần nhìn thấy khoảng cách đó. Hai cách:

**Cách 1 — Job CI chạy hằng ngày**, đăng vào kênh chat:

```bash
# ci/scripts/promotion-status.sh
git fetch origin develop main
echo "Các commit đang chờ lên prod:"
git log --oneline origin/main..origin/develop

echo
echo "Các service có ở dev nhưng chưa bật prod:"
for f in $(git ls-tree -r --name-only origin/develop -- 'registry/*/*/service.yaml'); do
  name=$(basename $(dirname "$f"))
  git show "origin/develop:$f" | yq -e '.spec.environments[] | select(.env=="prod")' >/dev/null 2>&1 \
    || echo "  - $name (chưa khai báo môi trường prod)"
done
```

**Cách 2 — Endpoint `GET /api/v1/promotions`** của Platform API (xem [PLATFORM_API_PLAN.md](./PLATFORM_API_PLAN.md)), hiển thị ngay trên UI: service nào đang ở dev bao lâu rồi mà chưa lên prod.

### 3.5. Một chi tiết kỹ thuật quan trọng

ApplicationSet cần biết nó đang đọc branch nào (`develop` hay `main`). Nhưng file ApplicationSet nằm trong repo và **giống hệt nhau trên cả hai branch** — không thể ghi cứng `targetRevision`.

Cách giải quyết: biến `gitops/bootstrap/` thành một **Helm chart**, trong đó ApplicationSet là template và `targetRevision` là tham số:

```text
gitops/bootstrap/
├── Chart.yaml
├── values.yaml
├── values-dev.yaml       # env: dev,  targetRevision: develop
├── values-prod.yaml      # env: prod, targetRevision: main
└── templates/
    ├── project-tenants.yaml
    ├── project-platform.yaml
    ├── project-admin.yaml
    ├── appset-tenants.yaml
    ├── appset-platform.yaml
    └── appset-vendor.yaml
```

Nhờ đó, **cả hệ thống chỉ còn 2 file phải apply bằng tay**, và chỉ apply đúng một lần:

```bash
kubectl -n argocd apply -f gitops/root/dev.yaml
kubectl -n argocd apply -f gitops/root/prod.yaml
```

> ⚠️ **Cảnh báo cú pháp:** Helm và ApplicationSet đều dùng `{{ }}`. Khi viết ApplicationSet bên trong một Helm chart, phải escape phần của ApplicationSet bằng backtick:
>
> ```yaml
> name: {{ `{{ .metadata.name }}` }}-{{ .Values.env }}
> #      ↑ ApplicationSet xử lý lúc sync    ↑ Helm xử lý lúc render
> ```
>
> Quên escape là ApplicationSet nhận được chuỗi rỗng. Lỗi này rất hay gặp và triệu chứng khó đoán — CI phải có bước `helm template` để bắt.

---

## Phần 4 — Cấu trúc thư mục mới

```text
HNQ-Infra/
│
├── registry/                    ⭐ NƠI DUY NHẤT phải sửa khi thêm service
│   ├── schema/
│   │   └── service.schema.json         # JSON Schema — vừa validate CI, vừa sinh form UI
│   ├── tenants/                        # Khách hàng
│   │   ├── lotus-clinic/
│   │   │   ├── service.yaml            # Khai báo: chart nào, chủ sở hữu, bật env nào
│   │   │   ├── values-dev.yaml         # Chỉ ghi phần KHÁC mặc định
│   │   │   ├── values-prod.yaml
│   │   │   └── config/                 # File config của app
│   │   ├── giaan-clinic/
│   │   ├── biboo-clinic/
│   │   └── hocmon-clinic/
│   └── platform/                       # Service nền tảng
│       ├── storage-mariadb/
│       ├── storage-postgres/
│       ├── storage-redis/
│       ├── storage-minio/
│       ├── storage-opensearch/
│       ├── push-notify/
│       ├── push-notify-v2/
│       ├── monitoring/
│       ├── outline/                    # ← kéo về GitOps
│       ├── gitlab-runner/              # ← kéo về GitOps
│       ├── server-control/
│       └── platform-api/               # ← backend mới
│
├── charts/                      ⭐ Hiếm khi phải sửa
│   ├── library/
│   │   └── hnq-common/                 # library chart: labels, service, ingress, probes...
│   ├── apps/
│   │   ├── webservice/                 # chart chung cho mọi HTTP service
│   │   └── datastore/                  # chart chung cho datastore
│   └── vendor/                         # bọc chart của bên thứ ba
│       ├── argo-cd/
│       ├── kube-prometheus-stack/
│       └── gitlab-runner/
│
├── env/                         ⭐ Khác biệt giữa dev và prod
│   ├── dev/defaults.yaml               # nodeSelector, issuer, resources nhỏ...
│   └── prod/defaults.yaml
│
├── gitops/
│   ├── root/
│   │   ├── dev.yaml                    # 1 trong 2 file apply tay
│   │   └── prod.yaml                   # file còn lại
│   ├── bootstrap/                      # Helm chart sinh AppProject + ApplicationSet
│   │   ├── values-dev.yaml
│   │   ├── values-prod.yaml
│   │   └── templates/
│   └── manifests/                      # YAML thuần (ClusterIssuer, HelmChartConfig)
│
├── secrets/                     # SealedSecret — đã mã hoá, an toàn để commit
│   ├── README.md                       # Danh mục secret hệ thống cần
│   ├── dev/
│   └── prod/
│
├── ci/
│   ├── policy/                         # Rego: bắt buộc limits, cấm tag latest...
│   ├── scripts/
│   │   ├── validate.sh
│   │   ├── render-all.sh
│   │   ├── new-service.sh
│   │   └── promotion-status.sh
│   └── templates/                      # khuôn scaffold service mới
│
├── apps/
│   └── platform-api/                   # Mã nguồn backend (xem PLATFORM_API_PLAN.md)
│
├── scripts/                            # script vận hành (chuyển từ infra/scripts)
├── docs/
│   ├── REFACTOR_PLAN.md                # file này
│   ├── PLATFORM_API_PLAN.md
│   ├── SECRET_MANAGEMENT.md
│   ├── ARCHITECTURE.md
│   ├── RUNBOOK.md                      # xử lý sự cố
│   └── ONBOARDING.md
├── .gitlab-ci.yml
└── Makefile
```

### Chi phí thêm 1 khách hàng mới — trước và sau

| | Hiện tại | Sau khi refactor |
|---|---|---|
| File phải tạo | 6–8 | 3 (hoặc 1 lệnh `make new-service`) |
| File ArgoCD phải viết | 2 | **0** |
| Dòng values phải viết | ~120 | ~20 |
| Nguy cơ copy sót | Cao | Thấp — có scaffold và schema kiểm tra |
| Làm được qua API/UI | Không | Có |

---

## Phần 5 — Service Registry + ApplicationSet

Đây là thay đổi có tác động lớn nhất: **xoá 24 file Application, thay bằng 3 ApplicationSet.**

### 5.1. File khai báo service

`registry/tenants/lotus-clinic/service.yaml` — đây là toàn bộ những gì cần viết để ArgoCD biết về một service:

```yaml
apiVersion: hnq.dev/v1
kind: ServiceRelease

metadata:
  name: lotus-clinic
  owner: team-clinic
  description: Backend hệ thống phòng khám Lotus

spec:
  category: tenant                # tenant | platform | admin
  chart: apps/webservice          # trỏ tới charts/apps/webservice
  project: tenants                # AppProject nào quản

  # Danh sách môi trường được bật.
  # Chưa có "prod" ở đây thì ArgoCD prod sẽ không tạo Application.
  environments:
    - env: dev
      namespace: lotus-clinic-dev
    - env: prod
      namespace: lotus-clinic-prod

  # Khai báo TÊN các secret mà service cần (không phải giá trị).
  # Dùng để sinh form nhập secret trên UI và để kiểm tra thiếu sót.
  requiredSecrets:
    - name: lotus-clinic-backend-secrets
      keys: [DB_PASSWORD, JWT_SECRET, MINIO_SECRET_KEY]
    - name: lotus-clinic-keystore
      keys: [keystore.jks]
```

`registry/tenants/lotus-clinic/values-dev.yaml` — **chỉ ghi phần khác mặc định**:

```yaml
image:
  repository: registry.gitlab.com/hnq-tech/clients/lotus-clinic/lotus-backend
  tag: 6aebe241

ingress:
  host: client-lotus-clinic-dev.l2cteam.work

app:
  configFile: config/config_dev.yaml
  secretName: lotus-clinic-backend-secrets
  extraSecrets:
    keystore: lotus-clinic-keystore
    firebase: hnq-obgyn-clinic-service
```

Từ ~60 dòng xuống ~12 dòng. Tất cả phần còn lại — `containerPort: 1001`, probes, resources, `nodeSelector`, `tolerations`, cert-manager issuer, `imagePullSecrets`, `serviceMonitor` — đến từ `env/dev/defaults.yaml` và `charts/apps/webservice/values.yaml`.

### 5.2. File mặc định theo môi trường

`env/dev/defaults.yaml` — nơi hút hết phần trùng lặp:

```yaml
global:
  env: dev
  domainSuffix: l2cteam.work

image:
  pullPolicy: IfNotPresent

ingress:
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    cert-manager.io/cluster-issuer: letsencrypt-dns01-dev
  tls:
    enabled: true

serviceAccount:
  imagePullSecrets:
    - name: gitlab-registry        # ← đổi tên, hết dính vào lotus (Lỗi 3)

# Dev chạy trên node worker
nodeSelector:
  kubernetes.io/hostname: server02
tolerations: []

resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 500m, memory: 512Mi }

serviceMonitor:
  enabled: true
  interval: 15s
```

`env/prod/defaults.yaml` tương tự, khác node, khác issuer, resources lớn hơn.

**Đây chính là chỗ giải quyết Lỗi 3 một cách triệt để:** `imagePullSecrets` khai báo đúng một lần cho cả môi trường, không còn cơ hội để mỗi khách hàng ghi một kiểu.

### 5.3. ApplicationSet

`gitops/bootstrap/templates/appset-tenants.yaml` (đã escape cho Helm):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenants-{{ .Values.env }}
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]

  generators:
    - matrix:
        generators:
          # (1) Quét mọi file khai báo khách hàng trên branch tương ứng
          - git:
              repoURL: {{ .Values.repoURL | quote }}
              revision: {{ .Values.targetRevision | quote }}
              files:
                - path: "registry/tenants/*/service.yaml"

          # (2) Bung theo danh sách môi trường khai báo trong chính file đó
          - list:
              elementsYaml: {{ `"{{ toJson .spec.environments }}"` }}

  template:
    metadata:
      # ⚠️ GIỮ NGUYÊN tên Application cũ để ArgoCD nhận (adopt) resource
      #    đang chạy thay vì xoá đi tạo lại. Xem mục 13.1.
      name: {{ `"{{ .metadata.name }}-{{ .env }}"` }}
      namespace: argocd
      labels:
        hnq.dev/owner: {{ `"{{ .metadata.owner }}"` }}
        hnq.dev/env: {{ `"{{ .env }}"` }}
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: {{ `"{{ .spec.project }}"` }}-{{ .Values.env }}
      source:
        repoURL: {{ .Values.repoURL | quote }}
        targetRevision: {{ .Values.targetRevision | quote }}
        path: {{ `"charts/{{ .spec.chart }}"` }}
        helm:
          releaseName: {{ `"{{ .metadata.name }}"` }}
          valueFiles:
            - values.yaml
            - "/env/{{ .Values.env }}/defaults.yaml"
            - {{ `"/registry/tenants/{{ .metadata.name }}/values-{{ .env }}.yaml"` }}
          parameters:
            - name: global.serviceName
              value: {{ `"{{ .metadata.name }}"` }}
      destination:
        server: https://kubernetes.default.svc
        namespace: {{ `"{{ .namespace }}"` }}
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - PruneLast=true
          - ServerSideApply=true
        managedNamespaceMetadata:
          labels:
            hnq.dev/env: {{ `"{{ .env }}"` }}
            hnq.dev/owner: {{ `"{{ .metadata.owner }}"` }}
```

### 5.4. Ba chi tiết kỹ thuật đáng lưu ý

**`elementsYaml` — generator thứ hai đọc được kết quả của generator thứ nhất.**
Tính năng này có từ ArgoCD 2.5. Nhờ nó, việc bật/tắt môi trường nằm ngay trong file khai báo service. Không khai `prod` trong `spec.environments` thì không có Application prod — không cần thêm cơ chế lọc nào khác. Đây chính là thứ khiến Lỗi 1 không thể lặp lại.

**`valueFiles` bắt đầu bằng `/` = tính từ gốc repo.**
Nhờ đó chart nằm ở `charts/`, values nằm ở `registry/`, và vẫn dùng chung được.

**`ServerSideApply=true`.**
Cần thiết cho các chart có CRD lớn (như kube-prometheus-stack) vượt quá giới hạn 262KB của annotation `last-applied-configuration`.

### 5.5. Kết quả

```mermaid
flowchart LR
  subgraph T["Trước — 24 file Application"]
    A1["apps/dev/clients/ (4)"]
    A2["apps/prod/clients/ (4)"]
    A3["apps/dev/platform/ (10)"]
    A4["apps/prod/platform/ (7)"]
    A5["apps/*/admin/ (2)"]
  end

  subgraph S["Sau — 3 ApplicationSet + N file khai báo"]
    B1[appset-tenants]
    B2[appset-platform]
    B3[appset-vendor]
    R["registry/**/service.yaml<br/>1 file cho 1 service"]
  end

  T ==>|tái cấu trúc| S
```

---

## Phần 6 — Library chart và chart tổng quát

### 6.1. Vấn đề

11 chart, mỗi chart tự viết lại cùng một bộ template. Như đã chứng minh ở Phần 1: `mariadb/_helpers.tpl` và `postgres/_helpers.tpl` khác nhau đúng một chuỗi.

### 6.2. Thiết kế

```mermaid
flowchart TD
  LIB["charts/library/hnq-common<br/>(type: library)"]

  WS["charts/apps/webservice<br/>HTTP service không giữ trạng thái"]
  DS["charts/apps/datastore<br/>datastore một node"]

  LIB --> WS
  LIB --> DS

  WS --> T1[lotus-clinic]
  WS --> T2[giaan-clinic]
  WS --> T3[biboo-clinic]
  WS --> T4[hocmon-clinic]
  WS --> T5[push-notify]
  WS --> T6[push-notify-v2]
  WS --> T7[outline]
  WS --> T8[server-control]
  WS --> T9[platform-api]

  DS --> D1[mariadb]
  DS --> D2[postgres]
  DS --> D3[redis]
  DS --> D4[minio]
  DS --> D5[opensearch]
```

**`charts/library/hnq-common`** cung cấp các helper dùng chung:

| Helper | Thay thế cho |
|---|---|
| `hnq.fullname`, `hnq.name`, `hnq.chart` | 11 bản `_helpers.tpl` |
| `hnq.labels`, `hnq.selectorLabels` | 11 bản |
| `hnq.service` | 11 bản `service.yaml` |
| `hnq.nodePortService` | 3 bản `nodeport-service.yaml` |
| `hnq.ingress` | 7 bản `ingress.yaml` |
| `hnq.probes`, `hnq.resources`, `hnq.securityContext` | rải rác trong deployment |
| `hnq.image`, `hnq.imagePullSecrets` | rải rác |
| `hnq.persistence` | xử lý cả hostPath / PVC / existingClaim |

**`charts/apps/webservice/values.yaml`** (rút gọn) — một chart phủ hết mọi HTTP service:

```yaml
global:
  env: ""
  serviceName: ""

image:
  repository: ""
  tag: ""
  pullPolicy: IfNotPresent

replicas: 1
containerPort: 8080

service:
  type: ClusterIP
  port: 80
  nodePort:
    enabled: false

ingress:
  enabled: true
  host: ""
  path: /
  tls: { enabled: true }

app:
  configFile: ""        # render thành ConfigMap
  secretName: ""        # nạp vào env bằng envFrom
  extraSecrets: {}      # mount thêm (keystore, firebase credentials...)
  env: []

probes:
  readiness: { enabled: true, path: /health }
  liveness:  { enabled: true, path: /health }

resources: {}           # lấy từ env/<env>/defaults.yaml
serviceMonitor:
  enabled: false
```

**`charts/apps/datastore`** phủ mariadb/postgres/redis/minio/opensearch bằng các cờ bật tắt:

```yaml
workload:
  kind: StatefulSet        # hoặc Deployment
service:
  headless: { enabled: true }
  nodePort:  { enabled: false, port: 0 }
persistence:
  mode: localPV            # hostPath | pvc | localPV
config:
  files: {}                # render thành ConfigMap
```

### 6.3. Dự kiến giảm

| | Trước | Sau |
|---|---:|---:|
| Số dòng template | ~2.713 | ~700 |
| Chart tự viết | 11 | 3 |
| Số chỗ phải sửa khi đổi quy ước label | 11 | 1 |

### 6.4. Bỏ `templates/namespace.yaml`

Namespace do ArgoCD tạo qua `CreateNamespace=true`, còn label/annotation gắn qua `managedNamespaceMetadata` (đã có trong ApplicationSet ở mục 5.3). Xoá `namespace.yaml` khỏi mọi chart → hết tranh chấp ownership.

---

## Phần 7 — Secret

Chi tiết đầy đủ ở [SECRET_MANAGEMENT.md](./SECRET_MANAGEMENT.md). Tóm tắt phần liên quan tới hạ tầng:

**Chọn Sealed Secrets** (như đã thống nhất). Lý do:

- `SealedSecret` chỉ là một CRD bình thường → ArgoCD sync được ngay, **không cần build lại image repo-server** (SOPS thì cần)
- Không phải dựng thêm hệ thống nào (Vault thì phải)
- Cài đúng một controller là xong

Đánh đổi: sealing key gắn với cluster, nên **bắt buộc phải backup key ra ngoài cluster**. Mất key = phải tạo lại toàn bộ secret từ đầu.

Quy trình thủ công (trước khi có Platform API):

```bash
# 1. Tạo secret bình thường — KHÔNG commit file này
kubectl create secret generic lotus-clinic-backend-secrets \
  --namespace lotus-clinic-dev \
  --from-literal=DB_PASSWORD='...' \
  --dry-run=client -o yaml > /tmp/s.yaml

# 2. Mã hoá — output an toàn để commit
kubeseal --format yaml --controller-namespace kube-system \
  < /tmp/s.yaml > secrets/dev/lotus-clinic/backend-secrets.yaml

# 3. Xoá file tạm, commit file đã mã hoá
shred -u /tmp/s.yaml
git add secrets/dev/lotus-clinic/backend-secrets.yaml
```

Bắt buộc kèm theo:

- **Backup sealing key ngay khi cài**, cất ở password manager hoặc offline:
  ```bash
  kubectl -n kube-system get secret \
    -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
    > sealed-secrets-key-backup.yaml
  ```
- **`gitleaks` trong CI** để chặn secret thô lọt vào repo
- **`secrets/README.md`** liệt kê mọi secret hệ thống cần, để người mới biết phải chuẩn bị gì

---

## Phần 8 — Tự động cập nhật image tag

### 8.1. Nguyên tắc: dev tự động, prod qua MR

```mermaid
sequenceDiagram
  participant D as Lập trình viên
  participant CI as CI của repo app
  participant R as Container Registry
  participant I as HNQ-Infra
  participant A as ArgoCD

  D->>CI: push code
  CI->>R: build & push image:<sha>

  rect rgb(232, 245, 233)
  Note over CI,I: DEV — tự động, không cần duyệt
  CI->>I: commit thẳng vào develop<br/>values-dev.yaml: tag = <sha>
  I->>A: webhook
  A->>A: sync dev
  end

  rect rgb(255, 243, 224)
  Note over D,I: PROD — cần người duyệt
  D->>I: MR develop → main<br/>(kèm bump values-prod.yaml)
  Note over I: CI kiểm tra + reviewer duyệt
  D->>I: merge
  I->>A: webhook
  A->>A: sync prod
  end
```

### 8.2. Cách triển khai

**Job cuối pipeline của repo ứng dụng:**

```yaml
update-infra-dev:
  stage: deploy
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop"'
  script:
    - git clone --branch develop https://oauth2:$INFRA_TOKEN@gitlab.com/hnq-tech/hnq-infra.git
    - cd hnq-infra
    - yq -i ".image.tag = \"$CI_COMMIT_SHORT_SHA\"" registry/tenants/$SERVICE/values-dev.yaml
    - git commit -am "chore($SERVICE): dev image → $CI_COMMIT_SHORT_SHA"
    - git push origin develop
```

**Đưa lên prod** — dùng script (hoặc sau này là API `POST /services/{name}/promote`):

```bash
# ci/scripts/promote.sh lotus-clinic
TAG=$(yq '.image.tag' registry/tenants/$1/values-dev.yaml)
git checkout -b promote/$1-$TAG develop
yq -i ".image.tag = \"$TAG\"" registry/tenants/$1/values-prod.yaml
git commit -am "release($1): prod image → $TAG"
git push -u origin promote/$1-$TAG
# → mở MR vào main
```

Điểm hay của cách này: **`values-prod.yaml` được sửa trên nhánh xuất phát từ `develop`**, nên khi merge vào `main` không bao giờ có conflict, và `develop` cũng luôn biết prod đang chạy tag nào.

### 8.3. Vì sao không dùng ArgoCD Image Updater

Image Updater tự quét registry và ghi ngược vào Git. Ít phải viết CI hơn, nhưng thêm một thành phần phải vận hành và log khó lần hơn khi có sự cố. Ở quy mô dưới ~20 service, job CI rõ ràng hơn và dễ debug hơn. Cân nhắc lại khi số service tăng.

---

## Phần 9 — AppProject và phân quyền

Thay `project: default` bằng project có ranh giới rõ ràng. Vì một cluster chạy cả dev lẫn prod, tên project phải có hậu tố môi trường.

`gitops/bootstrap/templates/project-tenants.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenants-{{ .Values.env }}
  namespace: argocd
spec:
  description: Ứng dụng khách hàng — không được đụng resource cấp cluster

  sourceRepos:
    - {{ .Values.repoURL | quote }}

  destinations:
    - server: https://kubernetes.default.svc
      namespace: "*-{{ .Values.env }}"

  # Khách hàng KHÔNG được tạo resource cấp cluster
  clusterResourceWhitelist: []

  namespaceResourceBlacklist:
    - { group: "", kind: ResourceQuota }
    - { group: "", kind: LimitRange }

  roles:
    - name: developer
      policies:
        - p, proj:tenants-{{ .Values.env }}:developer, applications, get,  tenants-{{ .Values.env }}/*, allow
        {{- if eq .Values.env "dev" }}
        # Chỉ dev mới cho phép developer tự sync
        - p, proj:tenants-dev:developer, applications, sync, tenants-dev/*, allow
        {{- end }}
      groups:
        - hnq-developers
```

Ba project mỗi môi trường: `platform-*` (được tạo resource cluster), `tenants-*` (bị chặn), `admin-*`.

Giá trị thực tế:

- Lập trình viên tự sync được app dev của mình, **không sync được prod**
- Chart của khách hàng không tạo được `ClusterRole`
- Đây là điều kiện tiên quyết để mở Platform API cho người ngoài team hạ tầng dùng

---

## Phần 10 — CI kiểm tra

`.gitlab-ci.yml`:

```yaml
stages: [validate, render, policy, security, report]

yaml-lint:
  stage: validate
  script: [yamllint -c ci/yamllint.yaml registry/ env/ gitops/]

schema-validate:
  stage: validate
  script:
    # Mọi service.yaml phải khớp JSON Schema — đúng cái schema mà UI dùng
    - |
      for f in registry/*/*/service.yaml; do
        ajv validate -s registry/schema/service.schema.json -d "$f" --spec=draft2020
      done

helm-lint:
  stage: validate
  script: [for c in charts/apps/*; do helm lint "$c"; done]

bootstrap-template:
  stage: validate
  script:
    # Bắt lỗi quên escape {{ }} giữa Helm và ApplicationSet (mục 3.5)
    - helm template gitops/bootstrap -f gitops/bootstrap/values-dev.yaml  | grep -q 'metadata.name' || exit 1
    - helm template gitops/bootstrap -f gitops/bootstrap/values-prod.yaml | grep -q 'metadata.name' || exit 1

render-all:
  stage: render
  script: [ci/scripts/render-all.sh > rendered.yaml]
  artifacts: { paths: [rendered.yaml] }

kubeconform:
  stage: render
  needs: [render-all]
  script:
    - kubeconform -strict -summary -kubernetes-version 1.31.0
        -schema-location default
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
        rendered.yaml

policy:
  stage: policy
  needs: [render-all]
  script: [conftest test --policy ci/policy rendered.yaml]

gitleaks:
  stage: security
  script: [gitleaks detect --no-git --redact]

promotion-status:
  stage: report
  rules: [{ if: '$CI_COMMIT_BRANCH == "develop"' }]
  script: [ci/scripts/promotion-status.sh]
  allow_failure: true
```

`ci/policy/` là nơi biến "quy ước" thành "ràng buộc bắt buộc":

| Rule | Ngăn được chuyện gì |
|---|---|
| Container phải có `resources.limits` và `requests` | Một pod ăn hết CPU của node |
| Cấm `image: *:latest` | Deploy không tái tạo được, rollback không biết về đâu |
| Bắt buộc có `readinessProbe` | Traffic vào pod chưa sẵn sàng |
| Cấm `hostNetwork` trừ danh sách cho phép | **Đúng sự cố node-exporter 30 giờ trong `issues.md`** |
| Cấm `privileged: true` | Thoát container |
| `Ingress` phải có annotation `cert-manager.io/cluster-issuer` | Domain chạy không TLS |
| Namespace phải khớp `<service>-<env>` | Deploy nhầm môi trường |
| Service prod phải có `replicas >= 2` (trừ datastore) | Downtime khi restart pod |

---

## Phần 11 — Lưu trữ và backup

### 11.1. Thống nhất đường dẫn

Chốt **một** quy ước cho mọi node, mọi môi trường:

```text
/srv/k3s/<env>/<nhóm>/<service>/

ví dụ:  /srv/k3s/prod/storage/mariadb/
        /srv/k3s/dev/storage/minio/
```

Cách chuyển không downtime: tạo symlink từ đường dẫn cũ sang mới → đổi values → kiểm tra chạy ổn → chuyển data thật trong cửa sổ bảo trì → xoá symlink.

### 11.2. Thay `hostPath` bằng `local` PersistentVolume

`hostPath` thô không cho scheduler biết ràng buộc gì, nên phải `nodeSelector` bằng tay. Dùng `local` PV thì ràng buộc node nằm ngay trong PV:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mariadb-prod
spec:
  capacity: { storage: 50Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain     # ← bảo vệ data khi lỡ xoá PVC
  storageClassName: local-storage
  local:
    path: /srv/k3s/prod/storage/mariadb
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [hnq-server-vietnix-01-hjnu]
```

Lợi ích:

- Bỏ được `nodeSelector` khỏi values của từng service — scheduler tự biết đặt pod ở đâu
- `Retain` giữ lại data khi PVC bị xoá nhầm
- Nhìn `kubectl get pv` là biết ngay data nằm ở node nào

### 11.3. Backup

Thêm `registry/platform/velero/`, backup vào MinIO đã có sẵn:

| Môi trường | Tần suất | Giữ lại |
|---|---|---|
| dev | 1 lần/ngày | 7 ngày |
| prod | 6 giờ/lần | 30 ngày |

Phạm vi: PersistentVolume + manifest của namespace.

**Thêm job kiểm tra restore hằng tháng.** Backup chưa từng restore thử thì chưa phải là backup — nó chỉ là một thư mục chiếm dung lượng.

### 11.4. Về chuyện HA — ghi nhận, chưa làm

Longhorn hoặc Mayastor cho volume có bản sao là hướng đúng về lâu dài. **Nhưng** cụm hiện đang chạy flannel qua interface `tailscale0`. Replication khối qua WAN sẽ rất chậm, và nhiều khả năng gây ra đúng loại sự cố mà nó định phòng ngừa.

Khuyến nghị: **giữ local storage, nhưng backup cho chắc chắn**. Chỉ xét storage phân tán khi các node nằm chung một LAN.

---

## Phần 12 — Lộ trình

Bạn để tôi tự quyết timeline. Tôi đề xuất **11 tuần**, chia 6 phase. Nguyên tắc: **mỗi phase kết thúc ở trạng thái chạy được** — dừng lại ở bất kỳ phase nào cũng không để hệ thống nửa vời.

```mermaid
gantt
  title Lộ trình tái cấu trúc
  dateFormat YYYY-MM-DD
  axisFormat %d/%m

  section P0 · An toàn
  Kiểm kê & backup              :p0a, 2026-09-15, 3d
  CI cơ bản trên cấu trúc cũ    :p0b, after p0a, 2d
  Sửa lỗi làm ngay được         :p0c, after p0a, 2d

  section P1 · GitOps
  Cấu trúc thư mục + env        :p1a, after p0b, 3d
  AppProject + bootstrap chart  :p1b, after p1a, 2d
  Registry + ApplicationSet     :p1c, after p1b, 5d
  Chuyển đổi + kiểm chứng       :p1d, after p1c, 3d

  section P2 · Chart
  Library chart hnq-common      :p2a, after p1d, 4d
  webservice + chuyển 9 service :p2b, after p2a, 6d
  datastore + chuyển 5 storage  :p2c, after p2b, 5d

  section P3 · Vận hành
  Sealed Secrets                :p3a, after p2c, 3d
  Tự động image tag             :p3b, after p3a, 2d
  Kéo service lạc về GitOps     :p3c, after p3a, 2d

  section P4 · Lưu trữ
  Chuẩn hoá path + local PV     :p4a, after p3b, 5d
  Velero + test restore         :p4b, after p4a, 3d

  section P5 · Backend API
  Nền tảng + Git layer          :p5a, after p3c, 5d
  Catalog + Preview API         :p5b, after p5a, 5d
  Deploy + Promote API          :p5c, after p5b, 5d
  Secret API + RBAC + audit     :p5d, after p5c, 5d
```

### Phase 0 — An toàn trước (1 tuần)

**Không đổi kiến trúc gì cả.** Mục tiêu là có lưới an toàn trước khi động vào.

- [ ] Dump toàn bộ state hiện tại: `kubectl get all,ing,pvc,secret,cm -A -o yaml` → lưu ngoài repo
- [ ] Backup mọi secret đang có trong cluster
- [ ] Backup data MariaDB / Postgres / MinIO / OpenSearch (dùng script sẵn có trong `scripts/`)
- [ ] Thêm `.gitlab-ci.yml` tối thiểu (`yamllint` + `helm lint`) **trên cấu trúc hiện tại**
- [ ] Sửa các lỗi ở [Phần 14](#phần-14--việc-làm-ngay-được)
- [ ] **Ghi lại `helm template` của mọi chart hiện tại** → đây là **baseline** để so sánh ở mọi phase sau

> Baseline là thứ quan trọng nhất của phase này. Mọi thay đổi chart về sau đều phải chứng minh được: "render ra kết quả giống hệt baseline, trừ những chỗ tôi cố ý sửa".

**Xong khi:** CI chạy xanh, có file baseline, backup đã test restore được.

### Phase 1 — Lớp GitOps (2 tuần)

- [ ] Dựng cấu trúc thư mục mới, **để song song** với cấu trúc cũ
- [ ] Viết `env/dev/defaults.yaml` và `env/prod/defaults.yaml` — hút hết phần trùng ra khỏi values khách hàng
- [ ] Viết `registry/**/service.yaml` + `values-<env>.yaml` cho **mọi** service, kể cả những cái đang thiếu ở prod
- [ ] Biến `gitops/bootstrap/` thành Helm chart, viết 3 AppProject + 3 ApplicationSet
- [ ] **Kiểm chứng trước khi chuyển:** render từ đường mới → `dyff` với baseline Phase 0 → khác biệt phải đúng bằng những gì mình chủ ý sửa
- [ ] Chuyển đổi theo quy trình ở [mục 13.1](#131--rủi-ro-lớn-nhất-applicationset-xoá-mất-workload-đang-chạy)
- [ ] Xoá `infra/argocd/apps/**` cũ

**Xong khi:** `kubectl get app -n argocd` cho ra đúng danh sách tên như cũ, tất cả `Synced` + `Healthy`, và không có pod nào restart trong quá trình chuyển.

### Phase 2 — Gom chart (2,5 tuần)

- [ ] `charts/library/hnq-common` + test bằng `helm unittest`
- [ ] `charts/apps/webservice`
- [ ] Chuyển **từng service một, mỗi service một MR**: render → `dyff` với baseline → chỉ merge khi diff rỗng hoặc giải thích được từng dòng
- [ ] Thứ tự: `server-control` (dev, ít rủi ro nhất) → `push-notify-v2` → 4 khách hàng → `outline`
- [ ] `charts/apps/datastore`
- [ ] Chuyển storage theo thứ tự rủi ro tăng dần: `redis` → `postgres` → `opensearch` → `minio` → `mariadb`
- [ ] Xoá `templates/namespace.yaml` khỏi mọi chart

**Xong khi:** chỉ còn 3 chart tự viết, template ~700 dòng, `dyff` rỗng với mọi service.

### Phase 3 — Vận hành (1,5 tuần)

- [ ] Cài Sealed Secrets controller, **backup sealing key ngay**
- [ ] Chuyển toàn bộ secret sang SealedSecret
- [ ] Thêm `gitleaks` vào CI
- [ ] Tự động bump image tag cho dev
- [ ] **Kéo `outline`, `gitlab-runner`, `coredns-ha` về GitOps** → xử lý Lỗi 2
- [ ] **Bật monitoring + postgres + redis cho prod** → xử lý Lỗi 1
- [ ] Viết `docs/RUNBOOK.md`, chuyển nội dung `helm/monitoring/issues.md` vào đó

### Phase 4 — Lưu trữ (1,5 tuần)

- [ ] Chuẩn hoá `/srv/k3s/<env>/...` trên mọi node
- [ ] Chuyển `hostPath` sang `local` PV + StorageClass
- [ ] Velero + lịch backup + **test restore thật một lần**

### Phase 5 — Backend API (4 tuần, chạy song song từ Phase 3)

Chi tiết ở [PLATFORM_API_PLAN.md](./PLATFORM_API_PLAN.md).

> **Nếu gấp:** Phase 0 + Phase 1 (3 tuần) đã xử lý được khoảng 70% vấn đề — hết copy tay, hết drift dev/prod, hết lỗi thiếu app ở prod. Phase 2–4 là tối ưu và giảm nợ kỹ thuật. Phase 5 là tính năng mới.

---

## Phần 13 — Rủi ro

### 13.1. 🔴 Rủi ro lớn nhất: ApplicationSet xoá mất workload đang chạy

**Chuyện gì xảy ra.** Khi bạn xoá một `Application` có `resources-finalizer`, ArgoCD sẽ **xoá luôn mọi resource** mà nó quản: Deployment, Service, Ingress, và cả PVC nếu chart tạo PVC. Nếu ApplicationSet sau đó tạo lại Application cùng tên, bạn vẫn bị downtime — và với datastore thì có thể **mất data**.

**Quy trình chuyển đổi an toàn** — làm đúng theo thứ tự này:

```bash
# ─── Bước 1: Gỡ finalizer khỏi TẤT CẢ Application cũ ───
# Sau bước này, xoá Application sẽ KHÔNG xoá resource bên dưới
kubectl -n argocd get applications.argoproj.io -o name | while read app; do
  kubectl -n argocd patch "$app" --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done

# ─── Bước 2: Tắt auto-sync ở root app cũ ───
# Tránh nó prune giữa chừng khi ta đang thao tác
kubectl -n argocd patch app apps-dev  --type=merge -p '{"spec":{"syncPolicy":null}}'
kubectl -n argocd patch app apps-prod --type=merge -p '{"spec":{"syncPolicy":null}}'

# ─── Bước 3: Xoá root app cũ, KHÔNG cascade ───
kubectl -n argocd delete app apps-dev  --cascade=orphan
kubectl -n argocd delete app apps-prod --cascade=orphan

# ─── Bước 4: Xoá Application con (finalizer đã gỡ → resource ở lại) ───
kubectl -n argocd delete app --all

# ─── Bước 5: XÁC NHẬN workload VẪN ĐANG CHẠY trước khi đi tiếp ───
kubectl get pods -A | grep -v Running | grep -v Completed
# Không có gì bất thường → mới sang bước 6

# ─── Bước 6: Apply root app mới ───
kubectl -n argocd apply -f gitops/root/dev.yaml
kubectl -n argocd apply -f gitops/root/prod.yaml

# ─── Bước 7: Kiểm tra ArgoCD ĐÃ NHẬN (adopt) resource cũ, không tạo mới ───
kubectl get pods -A --sort-by=.status.startTime | tail -20
# Pod không được restart → thành công
```

**Ba điều kiện bắt buộc để ArgoCD "nhận" được resource đang chạy:**

| Điều kiện | Vì sao |
|---|---|
| **Tên Application mới phải trùng tên cũ** (`lotus-clinic-dev`, không thêm prefix) | ArgoCD định danh resource qua label `app.kubernetes.io/instance` |
| **`releaseName` phải trùng** | Helm nhận diện release qua Secret `sh.helm.release.v1.<releaseName>.*` |
| **`destination.namespace` phải trùng** | Khác namespace là resource khác |

ApplicationSet ở mục 5.3 đã giữ đủ cả ba. Đây chính là lý do template dùng `{{ .metadata.name }}-{{ .env }}` chứ không thêm tiền tố gì.

**Bắt buộc diễn tập trước.** Làm toàn bộ quy trình trên ở **dev trước**, xác nhận không có pod nào restart, rồi mới làm prod. Nếu có điều kiện, dựng một cụm k3d tạm để diễn tập lần đầu.

### 13.2. Bảng rủi ro

| Rủi ro | Khả năng | Mức độ | Cách giảm |
|---|---|---|---|
| ApplicationSet xoá workload | Trung bình | 🔴 Rất cao | Quy trình 13.1; diễn tập ở dev; `--cascade=orphan` |
| Mất data khi đổi chart storage | Thấp | 🔴 Rất cao | `Retain` reclaim policy; backup + **test restore** trước; chuyển datastore cuối cùng |
| Chart mới render khác chart cũ ngoài ý muốn | Cao | 🟠 Cao | `dyff` với baseline ở **mọi** MR; chuyển từng service một |
| Mất sealing key Sealed Secrets | Thấp | 🟠 Cao | Backup key offline ngay khi cài; ghi vào runbook; kiểm tra định kỳ |
| Quên escape `{{ }}` giữa Helm và ApplicationSet | Cao | 🟡 Trung bình | Job `bootstrap-template` trong CI (mục 10) |
| `main` tụt lại quá xa `develop` | Trung bình | 🟡 Trung bình | Job `promotion-status` hằng ngày + endpoint `/promotions` |
| Refactor kéo dài, repo nửa vời | Cao | 🟡 Trung bình | Mỗi phase kết thúc ở trạng thái chạy được; cũ/mới song song ở P1–P2 |
| Backend API bị chiếm quyền | Thấp | 🔴 Rất cao | Xem [SECRET_MANAGEMENT.md](./SECRET_MANAGEMENT.md) — token Git chỉ push được nhánh `platform/*`, không đọc được secret trong cluster |

---

## Phần 14 — Việc làm ngay được

Những việc dưới đây **không phụ thuộc refactor**, làm trong Phase 0. Tổng cộng dưới 1 ngày công.

| # | Việc | Vì sao | Thời gian |
|---|---|---|---|
| 1 | **Thêm `monitoring`, `storage-postgres`, `storage-redis` vào `apps/prod/platform/`** | Prod đang **không có monitoring** — sự cố xảy ra không ai biết | 30 phút |
| 2 | **Điều tra `imagePullSecrets: lotus-clinic-registry` ở cả 4 khách hàng** | Hoặc secret bị đặt tên sai, hoặc 3 khách hàng dùng credential của khách hàng khác | 30 phút |
| 3 | **Thống nhất `repoURL`** — chọn HTTPS hoặc SSH cho cả dev lẫn prod | ArgoCD đang coi là 2 repo, 2 bộ credential | 15 phút |
| 4 | **Tạo Application cho `outline`, `gitlab-runner`, `coredns-ha`** | Đang chạy ngoài GitOps, mất cluster là mất luôn | 1 giờ |
| 5 | **Xoá `hnq_svc.json`** | File rác rỗng ở thư mục gốc | 1 phút |
| 6 | **Làm rõ `tolerations: []` ở `giaan-clinic/values-dev.yaml`** | Khác 3 khách hàng còn lại, không rõ cố ý hay quên | 15 phút |
| 7 | **Sửa `README.md`** — bỏ phần `envs/` và `infra/ci/` không tồn tại | Tài liệu sai làm người mới hiểu nhầm hoàn toàn về repo | 1 giờ |
| 8 | **Cập nhật `ARCHITECTURE.md`** — bổ sung node `server02` | Values trỏ vào node không có trong tài liệu | 30 phút |
| 9 | **Thêm `.gitlab-ci.yml` tối thiểu** (`yamllint` + `helm lint`) | Chặn YAML hỏng ngay từ hôm nay | 1 giờ |
| 10 | **Tạo `docs/RUNBOOK.md`**, chuyển `helm/monitoring/issues.md` vào | Kiến thức xử lý sự cố đang nằm rải rác | 1 giờ |

Trong đó **#1 và #2 là vấn đề production thật**, nên làm trước tiên.

---

## Phụ lục A — Ánh xạ file cũ sang mới

| Hiện tại | Sau refactor |
|---|---|
| `infra/argocd/bootstrap/{dev,prod}/root-app.yaml` | `gitops/root/{dev,prod}.yaml` |
| `infra/argocd/apps/{dev,prod}/clients/*.yaml` (8 file) | `gitops/bootstrap/templates/appset-tenants.yaml` (1) + `registry/tenants/*/service.yaml` |
| `infra/argocd/apps/{dev,prod}/platform/*.yaml` (17 file) | `gitops/bootstrap/templates/appset-platform.yaml` (1) + `registry/platform/*/service.yaml` |
| `infra/argocd/apps/{dev,prod}/admin/*.yaml` | gộp vào `appset-platform` + `registry/platform/{outline,server-control}/` |
| `infra/argocd/manifests/platform/**` | `gitops/manifests/**` |
| `infra/helm/clients/obgyn-clinic-service/templates/` | `charts/apps/webservice/` (dùng chung) |
| `infra/helm/clients/obgyn-clinic-service/<tên>/values-*.yaml` | `registry/tenants/<tên>/values-*.yaml` (ngắn hơn ~5 lần) |
| `infra/helm/platform/storage/*/templates/` (5 bộ) | `charts/apps/datastore/` (1 bộ) |
| `infra/helm/platform/storage/*/values-*.yaml` | `registry/platform/storage-*/values-*.yaml` |
| `infra/helm/platform/message/push-notify*/` | `charts/apps/webservice` + `registry/platform/push-notify*/` |
| `infra/helm/admin/{server-control,outline}/` | `charts/apps/webservice` + `registry/platform/{server-control,outline}/` |
| `infra/helm/cicd/{argocd,gitlab-runner}/` | `charts/vendor/{argo-cd,gitlab-runner}/` |
| `infra/helm/monitoring/kube-prometheus-stack/` | `charts/vendor/kube-prometheus-stack/` |
| `infra/helm/*/*/secret.example.yaml` | `secrets/<env>/<service>/*.yaml` (SealedSecret) + `secrets/README.md` |
| `infra/scripts/**` | `scripts/**` |
| `infra/helm/monitoring/issues.md` | `docs/RUNBOOK.md` |
| `hnq_svc.json` | ❌ xoá |
| `README.md` (phần `envs/`) | ❌ bỏ — mô tả layout server, không thuộc repo này |

## Phụ lục B — Makefile

```makefile
.PHONY: help new-service validate render diff lint promote status

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

new-service:  ## Tạo service mới: make new-service NAME=x CHART=apps/webservice
	@ci/scripts/new-service.sh "$(NAME)" "$(CHART)"

validate:     ## Chạy đủ bộ kiểm tra như CI
	@ci/scripts/validate.sh

render:       ## Render mọi service × mọi môi trường
	@ci/scripts/render-all.sh

diff:         ## So sánh render hiện tại với baseline
	@ci/scripts/render-all.sh > /tmp/new.yaml
	@dyff between ci/baseline.yaml /tmp/new.yaml

promote:      ## Đưa image dev lên prod: make promote NAME=lotus-clinic
	@ci/scripts/promote.sh "$(NAME)"

status:       ## Xem hàng chờ lên prod
	@ci/scripts/promotion-status.sh

lint:         ## helm lint mọi chart
	@for c in charts/apps/* charts/vendor/*; do helm lint "$$c"; done
```

## Phụ lục C — Tham khảo

- ApplicationSet, Matrix generator và `elementsYaml` — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Matrix/
- AppProject — https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- Helm library chart — https://helm.sh/docs/topics/library_charts/
- Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets
- kubeconform — https://github.com/yannh/kubeconform
- conftest / OPA — https://www.conftest.dev/
- dyff (so sánh YAML theo ngữ nghĩa) — https://github.com/homeport/dyff
