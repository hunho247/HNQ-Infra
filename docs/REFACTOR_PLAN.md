# Kế hoạch Refactor Hạ tầng k3s + ArgoCD

> **Trạng thái:** Draft để review
> **Ngày:** 2026-09-11
> **Phạm vi:** Toàn bộ `infra/argocd/**` và `infra/helm/**`
> **Mục tiêu:** Giảm chi phí thêm service mới, loại bỏ drift giữa Git và cluster, và mở đường cho một UI web để deploy service.

---

## Mục lục

1. [Hiện trạng & các vấn đề đo được](#1-hiện-trạng--các-vấn-đề-đo-được)
2. [Nguyên tắc thiết kế của kiến trúc mới](#2-nguyên-tắc-thiết-kế-của-kiến-trúc-mới)
3. [Kiến trúc đích](#3-kiến-trúc-đích)
4. [Cấu trúc thư mục mới](#4-cấu-trúc-thư-mục-mới)
5. [Cơ chế 1 — Service Registry + ApplicationSet](#5-cơ-chế-1--service-registry--applicationset)
6. [Cơ chế 2 — Library chart + generic charts](#6-cơ-chế-2--library-chart--generic-charts)
7. [Cơ chế 3 — Secrets trong Git](#7-cơ-chế-3--secrets-trong-git)
8. [Cơ chế 4 — Image tag automation](#8-cơ-chế-4--image-tag-automation)
9. [Cơ chế 5 — AppProject & guardrails](#9-cơ-chế-5--appproject--guardrails)
10. [Cơ chế 6 — CI validation](#10-cơ-chế-6--ci-validation)
11. [Cơ chế 7 — Storage & backup](#11-cơ-chế-7--storage--backup)
12. [Hướng phát triển UI web để deploy service](#12-hướng-phát-triển-ui-web-để-deploy-service)
13. [Lộ trình thực thi theo phase](#13-lộ-trình-thực-thi-theo-phase)
14. [Rủi ro & cách giảm thiểu](#14-rủi-ro--cách-giảm-thiểu)
15. [Quick wins — sửa được ngay](#15-quick-wins--sửa-được-ngay)
16. [Các quyết định cần chốt trước khi code](#16-các-quyết-định-cần-chốt-trước-khi-code)

---

## 1. Hiện trạng & các vấn đề đo được

### 1.1. Số liệu

| Chỉ số | Giá trị hiện tại |
|---|---|
| File ArgoCD `Application` | 24 file (12 cặp dev/prod gần như trùng nhau) |
| Tổng dòng trong `apps/**` | ~745 dòng |
| Tổng dòng Helm templates | ~2.713 dòng |
| Tổng dòng Helm values | ~2.170 dòng |
| Helm chart tự viết | 11 chart, mỗi chart có `_helpers.tpl` + `namespace.yaml` + `service.yaml` riêng ~95% giống nhau |
| Số file phải sửa khi thêm 1 tenant mới | 6–8 file |
| File CI | 0 |
| Cơ chế quản lý secret | Không có (apply tay từ `secret.example.yaml`) |

### 1.2. Vấn đề theo mức độ nghiêm trọng

#### 🔴 Nghiêm trọng — ảnh hưởng vận hành

**V1. Prod thiếu monitoring và một phần storage**

`apps/dev/platform/` có 10 Application, `apps/prod/platform/` chỉ có 7. Prod đang thiếu:

- `monitoring.yaml` → **production không có Prometheus/Grafana/alerting**
- `storage-postgres.yaml`
- `storage-redis.yaml`

Đây không phải quyết định thiết kế mà là hệ quả của việc copy file thủ công giữa hai thư mục — ai đó thêm vào dev rồi quên prod.

**V2. Có workload chạy ngoài GitOps**

`ARCHITECTURE.md` ghi nhận `outline` đang chạy ở namespace `admin-workspace-dev`, nhưng `infra/argocd/apps/**` **không có** Application nào cho Outline. Tương tự với `gitlab-runner` và `coredns-ha` — có chart/manifest trong repo nhưng không có Application.

Nghĩa là cluster đang chứa state không tái tạo được từ Git. Nếu cluster chết, những thứ này mất.

**V3. Helm release chạy song song ArgoCD đã từng gây sự cố thật**

`infra/helm/monitoring/issues.md` ghi lại sự cố 2026-06-18: hai release cùng deploy node-exporter với `hostNetwork: true` port 9100 → DaemonSet Pending 30 giờ → Prometheus mất kubelet metrics. Nguyên nhân gốc là không có ranh giới rõ ràng giữa "cái gì do ArgoCD quản" và "cái gì apply tay".

**V4. `repoURL` không nhất quán giữa dev và prod**

```
dev:   git@gitlab.com:hnq-tech/hnq-infra.git      (SSH)
prod:  https://gitlab.com/hnq-tech/hnq-infra.git  (HTTPS)
```

ArgoCD coi đây là **hai repository khác nhau**, cần hai bộ credential, hai cache repo-server. Một lần đổi credential mà quên một bên là nửa hệ thống ngừng sync.

**V5. Secrets không nằm trong GitOps**

Không có SOPS, Sealed Secrets, hay External Secrets. Quy trình hiện tại là copy `secret.example.yaml`, điền tay, `kubectl apply`. Hệ quả:

- Không tái tạo được cluster từ Git
- Không có lịch sử thay đổi / audit
- Không rotate được một cách có kiểm soát
- Người mới không biết cần những secret nào nếu không đọc hết README

#### 🟠 Cao — ảnh hưởng tốc độ phát triển

**V6. 24 file Application chỉ khác nhau 5 dòng**

Diff giữa mọi cặp dev/prod:

```diff
-  name: lotus-clinic-dev                              +  name: lotus-clinic-prod
-  repoURL: git@gitlab.com:hnq-tech/hnq-infra.git      +  repoURL: https://gitlab.com/...
-  targetRevision: develop                             +  targetRevision: main
-  - lotus-clinic/values-dev.yaml                      +  - lotus-clinic/values-prod.yaml
-  namespace: lotus-clinic-dev                         +  namespace: lotus-clinic-prod
```

Đây chính xác là bài toán `ApplicationSet` sinh ra để giải.

**V7. Values của tenant trùng lặp ~90%, đã có bug copy-paste**

Bằng chứng cụ thể tìm được:

```
biboo-clinic/values-dev.yaml:41:    - name: lotus-clinic-registry
giaan-clinic/values-dev.yaml:53:    - name: lotus-clinic-registry
hocmon-clinic/values-dev.yaml:41:   - name: lotus-clinic-registry
lotus-clinic/values-dev.yaml:41:    - name: lotus-clinic-registry
```

**Cả 4 tenant đều dùng `imagePullSecrets: lotus-clinic-registry`.** Hoặc đây là một secret dùng chung bị đặt tên sai, hoặc 3 tenant đang pull image bằng credential của tenant khác. Cả hai trường hợp đều cần sửa.

Thêm nữa, `giaan-clinic/values-dev.yaml` có `tolerations: []` trong khi 3 tenant còn lại có toleration cho control-plane — không rõ là cố ý hay sót.

**V8. Mỗi chart tự viết lại boilerplate**

`mariadb/_helpers.tpl` và `postgres/_helpers.tpl` khác nhau **duy nhất ở chuỗi `mariadb` vs `postgres`**. Điều này lặp lại với `namespace.yaml`, `service.yaml`, `nodeport-service.yaml`, `secret.yaml` trên 5 chart storage.

Hệ quả: sửa một bug về label hay probe phải sửa ở 11 nơi.

**V9. Namespace bị tạo hai lần**

Chart có `templates/namespace.yaml`, đồng thời Application có `syncOptions: CreateNamespace=true`. Hai cơ chế cùng sở hữu một resource → tranh chấp ownership khi prune, và namespace không nhận được label/annotation nhất quán.

**V10. Image tag hardcode trong values**

```yaml
image: registry.gitlab.com/hnq-tech/clients/lotus-clinic/lotus-backend:6aebe241
```

Mỗi lần deploy phải sửa file + commit + push tay. Không có liên kết tự động giữa CI build và GitOps.

**V11. Không có CI validation**

Không có `.gitlab-ci.yml`. Không `helm lint`, không `kubeconform`, không policy check. YAML sai cú pháp hoặc thiếu resource limit sẽ đi thẳng vào cluster và chỉ phát hiện khi ArgoCD báo lỗi sync.

#### 🟡 Trung bình — nợ kỹ thuật

**V12. `hostPath` + `nodeSelector` cứng**

Ba convention đường dẫn cùng tồn tại:

| Nơi | Đường dẫn |
|---|---|
| `values-dev.yaml` (minio, redis, postgres, mariadb) | `/data/k3s/dev/platform/storage/...` |
| `values-prod.yaml` | `/home/hnq/hnq_data/prod/platform/storage/...` |
| `README.md` (tài liệu chính thức) | `/home/server01/srv/envs/<env>/data/...` |

Cộng thêm `nodeSelector: kubernetes.io/hostname: server02` ghim pod vào node cụ thể. Node chết → pod không reschedule được, data không truy cập được.

**V13. Tài liệu lệch thực tế**

- `README.md` mô tả cấu trúc `envs/` (apps, config, data, logs, backup) — **không tồn tại trong repo này**. Nó mô tả layout trên server, đặt nhầm chỗ.
- `ARCHITECTURE.md` liệt kê node: `hnq-server-vietnix-01-hjnu`, `hnq`, `server01`. Nhưng values dev ghim vào `server02` — một node không có trong tài liệu.
- `README.md` mô tả `infra/ci/` với 4 script — thư mục này không tồn tại.

**V14. Mọi Application dùng `project: default`**

Không có ranh giới RBAC. Một chart tenant về mặt kỹ thuật có thể tạo `ClusterRole` hoặc deploy vào `kube-system`.

**V15. File rác**

`hnq_svc.json` ở root là output rỗng của `kubectl get -o json` (`"items": []`).

---

## 2. Nguyên tắc thiết kế của kiến trúc mới

| # | Nguyên tắc | Hệ quả cụ thể |
|---|---|---|
| P1 | **Git là nguồn sự thật duy nhất** | Không có `kubectl apply` / `helm install` thủ công. Kể cả UI cũng phải ghi vào Git, không ghi thẳng vào cluster. |
| P2 | **Khai báo một lần, sinh ra nhiều lần** | Một file khai báo tenant → ApplicationSet sinh Application cho mọi env. Không copy file giữa `dev/` và `prod/`. |
| P3 | **Môi trường là tham số, không phải bản sao** | `dev`/`prod` khác nhau bằng file override nhỏ, không phải cây thư mục song song. |
| P4 | **Chart chung, values riêng** | Logic template nằm ở library chart + 2–3 generic chart. Service mới = values, không phải template mới. |
| P5 | **Schema-driven** | Mỗi khai báo service có JSON Schema. Schema đó vừa dùng để validate trong CI, vừa sinh form cho UI → UI không bao giờ lệch với platform. |
| P6 | **Mọi thứ vào cluster đều đi qua CI** | Lint, template, kubeconform, policy trước khi merge. |
| P7 | **Rollback = `git revert`** | Không có trạng thái nào chỉ tồn tại trong cluster. |

---

## 3. Kiến trúc đích

```mermaid
flowchart TB
  subgraph Dev["Người dùng"]
    ENG[Engineer]
    UI["Platform UI<br/>(server-control mở rộng)"]
  end

  subgraph Git["Git repo — nguồn sự thật"]
    REG["registry/<br/>khai báo service & tenant"]
    CH["charts/<br/>library + generic charts"]
    ENVD["env/<br/>defaults theo môi trường"]
    GOPS["gitops/<br/>AppProject + ApplicationSet"]
    SEC["secrets/<br/>SealedSecret đã mã hoá"]
  end

  subgraph CI["GitLab CI"]
    LINT[helm lint + template]
    CONF[kubeconform]
    POL["conftest / OPA policy"]
    SCH[validate JSON Schema]
    IMG["bump image tag (dev)"]
  end

  subgraph Cluster["k3s cluster"]
    AS[ApplicationSet Controller]
    APP["Applications<br/>tự sinh"]
    WL[Workloads]
    SSC[Sealed Secrets Controller]
  end

  ENG -->|MR| Git
  UI -->|"tạo branch + MR<br/>qua GitLab API"| Git
  UI -.->|"đọc trạng thái (read-only)"| AS

  Git --> CI
  CI -->|merge| Git

  REG --> AS
  GOPS --> AS
  AS --> APP
  APP --> WL
  CH --> APP
  ENVD --> APP
  SEC --> SSC --> WL
```

**Điểm mấu chốt:** mũi tên từ UI đi vào **Git**, không đi vào cluster. UI chỉ đọc trạng thái từ ArgoCD. Nhờ đó mọi tính chất của GitOps (audit, rollback, reproducibility) vẫn giữ nguyên khi thêm UI.

---

## 4. Cấu trúc thư mục mới

```text
HNQ-Infra/
├── registry/                          # ⭐ Khai báo service — nơi duy nhất cần sửa khi thêm service
│   ├── schema/
│   │   ├── service.schema.json        # JSON Schema: validate CI + sinh form UI
│   │   └── tenant.schema.json
│   ├── tenants/
│   │   ├── lotus-clinic/
│   │   │   ├── service.yaml           # metadata: chart, owner, env nào bật
│   │   │   ├── values-dev.yaml        # chỉ chứa phần KHÁC default
│   │   │   ├── values-prod.yaml
│   │   │   └── config/                # config app mount vào ConfigMap
│   │   ├── giaan-clinic/
│   │   ├── biboo-clinic/
│   │   └── hocmon-clinic/
│   └── platform/
│       ├── storage-mariadb/
│       ├── storage-postgres/
│       ├── storage-redis/
│       ├── storage-minio/
│       ├── storage-opensearch/
│       ├── push-notify/
│       ├── push-notify-v2/
│       ├── monitoring/
│       ├── outline/                   # ← đưa workload đang lạc vào GitOps
│       └── gitlab-runner/             # ← đưa workload đang lạc vào GitOps
│
├── charts/                            # ⭐ Helm chart — hiếm khi phải sửa
│   ├── library/
│   │   └── hnq-common/                # library chart: labels, service, ingress, probes...
│   ├── apps/
│   │   ├── webservice/                # chart chung cho mọi HTTP service stateless
│   │   └── datastore/                 # chart chung cho datastore single-node
│   └── vendor/                        # umbrella wrap chart upstream
│       ├── argo-cd/
│       ├── kube-prometheus-stack/
│       └── gitlab-runner/
│
├── env/                               # ⭐ Khác biệt giữa môi trường
│   ├── dev/
│   │   ├── defaults.yaml              # nodeSelector, issuer, domain suffix, resource nhỏ
│   │   └── cluster.yaml
│   └── prod/
│       ├── defaults.yaml
│       └── cluster.yaml
│
├── gitops/
│   ├── bootstrap/
│   │   ├── dev/root.yaml              # 1 Application duy nhất cần apply tay
│   │   └── prod/root.yaml
│   ├── projects/
│   │   ├── platform.yaml              # AppProject + guardrails
│   │   ├── tenants.yaml
│   │   └── admin.yaml
│   ├── appsets/                       # ⭐ 4 file thay cho 24 file Application
│   │   ├── tenants.yaml
│   │   ├── platform.yaml
│   │   ├── admin.yaml
│   │   └── vendor.yaml
│   └── manifests/                     # YAML thuần (ClusterIssuer, HelmChartConfig...)
│       ├── cert-manager/
│       └── traefik/
│
├── secrets/                           # SealedSecret — an toàn để commit
│   ├── dev/
│   └── prod/
│
├── ci/
│   ├── policy/                        # OPA/Rego: bắt buộc limits, cấm tag latest...
│   ├── scripts/
│   │   ├── validate.sh
│   │   ├── render-all.sh
│   │   └── new-service.sh             # scaffold — cùng logic UI sẽ gọi
│   └── templates/                     # template scaffold cho service mới
│
├── scripts/                           # script vận hành (giữ từ infra/scripts)
├── docs/
│   ├── REFACTOR_PLAN.md               # file này
│   ├── ARCHITECTURE.md
│   ├── RUNBOOK.md                     # xử lý sự cố
│   └── ONBOARDING.md
├── .gitlab-ci.yml
└── Makefile
```

### So sánh chi phí thêm 1 tenant mới

| | Hiện tại | Sau refactor |
|---|---|---|
| File phải tạo | 6–8 | 3 (hoặc 1 lệnh `make new-tenant`) |
| File ArgoCD Application phải viết | 2 | **0** |
| Dòng values phải viết | ~120 | ~20 |
| Nguy cơ copy-paste bug | Cao | Thấp (scaffold + schema validate) |
| Làm được qua UI | Không | Có |

---

## 5. Cơ chế 1 — Service Registry + ApplicationSet

Đây là thay đổi có tác động lớn nhất: **xoá 24 file Application, thay bằng 4 ApplicationSet.**

### 5.1. File khai báo tenant

`registry/tenants/lotus-clinic/service.yaml`:

```yaml
apiVersion: hnq.dev/v1
kind: ServiceRelease
metadata:
  name: lotus-clinic
  owner: team-clinic
  description: Backend hệ thống phòng khám Lotus
spec:
  category: tenant
  chart: apps/webservice          # trỏ tới charts/apps/webservice
  project: tenants                # AppProject
  environments:
    - env: dev
      namespace: lotus-clinic-dev
    - env: prod
      namespace: lotus-clinic-prod
```

`registry/tenants/lotus-clinic/values-dev.yaml` — **chỉ phần khác default**:

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

Mọi thứ khác (`containerPort: 1001`, probes, resources, `nodeSelector`, `tolerations`, `cert-manager` issuer, `imagePullSecrets`, `serviceMonitor`) đến từ `env/dev/defaults.yaml` và `charts/apps/webservice/values.yaml`.

Từ ~60 dòng xuống ~12 dòng mỗi env.

### 5.2. ApplicationSet sinh Application

`gitops/appsets/tenants.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenants
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]

  generators:
    - matrix:
        generators:
          # 1) Quét mọi file khai báo tenant
          - git:
              repoURL: https://gitlab.com/hnq-tech/hnq-infra.git
              revision: main
              files:
                - path: "registry/tenants/*/service.yaml"
          # 2) Bung ra theo danh sách env khai báo trong chính file đó
          - list:
              elementsYaml: "{{ toJson .spec.environments }}"

  template:
    metadata:
      # ⚠ Giữ nguyên tên Application cũ để ArgoCD ADOPT resource đang chạy,
      #   không xoá rồi tạo lại. Xem mục 14.1.
      name: "{{ .metadata.name }}-{{ .env }}"
      namespace: argocd
      labels:
        hnq.dev/owner: "{{ .metadata.owner }}"
        hnq.dev/env: "{{ .env }}"
        hnq.dev/category: "{{ .spec.category }}"
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: "{{ .spec.project }}"
      source:
        repoURL: https://gitlab.com/hnq-tech/hnq-infra.git
        targetRevision: main
        path: "charts/{{ .spec.chart }}"
        helm:
          releaseName: "{{ .metadata.name }}"
          valueFiles:
            - values.yaml
            - "/env/{{ .env }}/defaults.yaml"
            - "/registry/tenants/{{ .metadata.name }}/values-{{ .env }}.yaml"
          parameters:
            - name: global.env
              value: "{{ .env }}"
            - name: global.serviceName
              value: "{{ .metadata.name }}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{ .namespace }}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - PruneLast=true
          - ServerSideApply=true
```

Ghi chú kỹ thuật:

- `elementsYaml` (ArgoCD ≥ 2.5) cho phép generator thứ hai đọc từ output của generator thứ nhất. Nhờ đó **bật/tắt môi trường nằm ngay trong file khai báo tenant**: không khai `prod` trong `spec.environments` thì không có Application prod. Đây chính là thứ ngăn lỗi V1 (prod thiếu app) tái diễn.
- `valueFiles` bắt đầu bằng `/` = tính từ gốc repo, không phải từ thư mục chart. Cho phép tách chart và values.
- `ServerSideApply=true` giải quyết vấn đề CRD lớn (kube-prometheus-stack) vượt giới hạn annotation `last-applied-configuration`.

### 5.3. ApplicationSet cho platform

Tương tự, `gitops/appsets/platform.yaml` quét `registry/platform/*/service.yaml`. Cùng một khuôn, khác `project` và thư mục nguồn.

### 5.4. Kết quả

```mermaid
flowchart LR
  subgraph Truoc["Trước — 24 file"]
    A1["apps/dev/clients/*.yaml (4)"]
    A2["apps/prod/clients/*.yaml (4)"]
    A3["apps/dev/platform/*.yaml (10)"]
    A4["apps/prod/platform/*.yaml (7)"]
    A5["apps/*/admin/*.yaml (2)"]
  end

  subgraph Sau["Sau — 4 ApplicationSet + N file registry"]
    B1[appsets/tenants.yaml]
    B2[appsets/platform.yaml]
    B3[appsets/admin.yaml]
    B4[appsets/vendor.yaml]
    R["registry/**/service.yaml<br/>1 file / service"]
  end

  Truoc -->|refactor| Sau
```

---

## 6. Cơ chế 2 — Library chart + generic charts

### 6.1. Vấn đề cần giải

11 chart, mỗi chart tự viết `_helpers.tpl`, `namespace.yaml`, `service.yaml`, `ingress.yaml`, `secret.yaml`. Như đã chứng minh ở V8, `mariadb/_helpers.tpl` và `postgres/_helpers.tpl` khác nhau đúng một chuỗi.

### 6.2. Thiết kế

```mermaid
flowchart TD
  LIB["charts/library/hnq-common<br/>type: library"]

  WS["charts/apps/webservice<br/>HTTP service stateless"]
  DS["charts/apps/datastore<br/>datastore single-node"]

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

  DS --> D1[mariadb]
  DS --> D2[postgres]
  DS --> D3[redis]
  DS --> D4[minio]
  DS --> D5[opensearch]
```

**`charts/library/hnq-common`** cung cấp:

| Helper | Thay thế cho |
|---|---|
| `hnq.fullname`, `hnq.name`, `hnq.chart` | 11 bản `_helpers.tpl` |
| `hnq.labels`, `hnq.selectorLabels` | idem |
| `hnq.service` | 11 bản `service.yaml` |
| `hnq.nodePortService` | 3 bản `nodeport-service.yaml` |
| `hnq.ingress` | 7 bản `ingress.yaml` |
| `hnq.probes`, `hnq.resources`, `hnq.securityContext` | rải rác trong deployment |
| `hnq.imagePullSecrets`, `hnq.image` | rải rác |
| `hnq.persistence` | hostPath vs PVC vs existingClaim |

**`charts/apps/webservice`** — một chart phủ toàn bộ HTTP service:

```yaml
# charts/apps/webservice/values.yaml (rút gọn)
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
  className: traefik
  host: ""
  path: /
  tls:
    enabled: true

app:
  configFile: ""          # render thành ConfigMap
  secretName: ""          # envFrom
  extraSecrets: {}        # mount thêm secret (keystore, firebase...)
  env: []

probes:
  readiness: { enabled: true, path: /health }
  liveness:  { enabled: true, path: /health }

resources: {}             # đến từ env/<env>/defaults.yaml
serviceMonitor:
  enabled: false
```

**`charts/apps/datastore`** — phủ mariadb/postgres/redis/minio/opensearch bằng flag:
`workload.kind: StatefulSet|Deployment`, `service.headless.enabled`, `service.nodePort.enabled`, `persistence.mode: hostPath|pvc|localPV`, `config.files: {}`.

### 6.3. Dự kiến giảm

| | Trước | Sau |
|---|---:|---:|
| Dòng template | ~2.713 | ~700 |
| Số chart tự viết | 11 | 3 (1 library + 2 app) |
| Nơi phải sửa khi đổi convention label | 11 | 1 |

### 6.4. Bỏ `templates/namespace.yaml`

Namespace do ArgoCD tạo qua `CreateNamespace=true` + `managedNamespaceMetadata` (để gắn label/annotation). Xoá `namespace.yaml` khỏi mọi chart → hết tranh chấp ownership (V9).

```yaml
syncPolicy:
  managedNamespaceMetadata:
    labels:
      hnq.dev/env: "{{ .env }}"
      hnq.dev/owner: "{{ .metadata.owner }}"
      pod-security.kubernetes.io/enforce: baseline
```

---

## 7. Cơ chế 3 — Secrets trong Git

### 7.1. So sánh phương án

| Phương án | Ưu | Nhược | Phù hợp |
|---|---|---|---|
| **Sealed Secrets** | Không phụ thuộc hệ thống ngoài; `SealedSecret` là CRD thường → ArgoCD sync không cần plugin; cài 1 controller là xong | Key gắn với cluster (phải backup sealing key); khó share secret giữa nhiều cluster | ⭐ **Giai đoạn 1** |
| **SOPS + age** (KSOPS / helm-secrets) | Mã hoá theo file, review diff được; không phụ thuộc cluster | Phải build custom repo-server image hoặc CMP sidecar | Khi cần nhiều cluster |
| **External Secrets Operator** | Nguồn thật nằm ở Vault/cloud SM; rotate tập trung | Cần backend (Vault) → thêm hệ thống phải vận hành | Khi có Vault |

### 7.2. Đề xuất: Sealed Secrets trước, đường nâng cấp để mở

Lý do: rủi ro thấp nhất, không đụng vào repo-server, không thêm hệ thống mới phải nuôi. Với quy mô 3 node / 4 tenant thì đây là lựa chọn đúng tỷ lệ.

Quy trình:

```bash
# 1. Tạo secret bình thường (KHÔNG commit file này)
kubectl create secret generic lotus-clinic-backend-secrets \
  --namespace lotus-clinic-dev \
  --from-literal=DB_PASSWORD='...' \
  --dry-run=client -o yaml > /tmp/s.yaml

# 2. Mã hoá — output an toàn để commit
kubeseal --format yaml --controller-namespace kube-system \
  < /tmp/s.yaml > secrets/dev/lotus-clinic/backend-secrets.yaml

# 3. Commit + push. ArgoCD sync → controller giải mã trong cluster.
rm /tmp/s.yaml
```

**Bắt buộc kèm theo:**

- Backup sealing key vào nơi an toàn ngoài cluster (mất key = phải tạo lại toàn bộ secret):
  ```bash
  kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o yaml > sealed-secrets-key-backup.yaml   # cất ở password manager / offline
  ```
- Thêm `gitleaks` vào CI để chặn secret thô lọt vào repo.
- `secrets/README.md` liệt kê **mọi secret mà hệ thống cần**, để người mới biết phải chuẩn bị gì.

---

## 8. Cơ chế 4 — Image tag automation

### 8.1. Thiết kế: dev tự động, prod có kiểm soát

```mermaid
sequenceDiagram
  participant Dev as Developer
  participant CI as GitLab CI (repo app)
  participant Reg as Container Registry
  participant Infra as HNQ-Infra repo
  participant Argo as ArgoCD

  Dev->>CI: push code
  CI->>Reg: build & push image:<sha>

  rect rgb(232, 245, 233)
  note over CI,Infra: DEV — tự động
  CI->>Infra: commit trực tiếp<br/>values-dev.yaml: tag=<sha>
  Infra->>Argo: webhook
  Argo->>Argo: sync dev
  end

  rect rgb(255, 243, 224)
  note over CI,Infra: PROD — cần người duyệt
  CI->>Infra: mở MR<br/>values-prod.yaml: tag=<sha>
  Dev->>Infra: review + merge
  Infra->>Argo: webhook
  Argo->>Argo: sync prod
  end
```

### 8.2. Hai cách triển khai

**Cách A — CI của repo app ghi ngược (đề xuất).** Job cuối pipeline:

```yaml
update-infra-dev:
  stage: deploy
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop"'
  script:
    - git clone https://oauth2:$INFRA_TOKEN@gitlab.com/hnq-tech/hnq-infra.git
    - cd hnq-infra
    - yq -i ".image.tag = \"$CI_COMMIT_SHORT_SHA\"" \
        registry/tenants/$SERVICE/values-dev.yaml
    - git commit -am "chore($SERVICE): dev image → $CI_COMMIT_SHORT_SHA"
    - git push
```

Ưu điểm: rõ ràng, dễ debug, lịch sử Git nói đúng cái gì đang chạy.

**Cách B — ArgoCD Image Updater.** Controller tự quét registry và write-back vào Git. Ít phải viết CI hơn nhưng thêm một thành phần phải vận hành, và log khó lần hơn khi có sự cố.

Đề xuất: **Cách A**. Cách B chỉ cân nhắc khi số service vượt ~20.

### 8.3. Bổ sung: một `targetRevision` duy nhất

Hiện tại dev theo branch `develop`, prod theo `main`. Điều này khiến "cùng một cấu hình platform" tồn tại hai phiên bản khác nhau và phải cherry-pick qua lại.

Đề xuất **`main` duy nhất cho cả hai env**, phân biệt bằng `env/dev/` vs `env/prod/`. Khi đó:

- Sửa chart một lần, cả hai env nhận được
- Promotion dev→prod = đổi image tag trong `values-prod.yaml`, không phải merge branch
- Hết hẳn class lỗi V1 (prod thiếu app vì quên merge)

> Nếu muốn giữ "dev đi trước" thì vẫn dùng `main` chung, nhưng cho phép CI auto-commit vào `values-dev.yaml` còn `values-prod.yaml` bắt buộc qua MR. Cùng branch, khác mức kiểm soát.

---

## 9. Cơ chế 5 — AppProject & guardrails

Thay `project: default` bằng project có ranh giới rõ:

`gitops/projects/tenants.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenants
  namespace: argocd
spec:
  description: Ứng dụng của khách hàng — không được đụng cluster-scoped resource
  sourceRepos:
    - https://gitlab.com/hnq-tech/hnq-infra.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "*-dev"
    - server: https://kubernetes.default.svc
      namespace: "*-prod"
  # Tenant KHÔNG được tạo resource cấp cluster
  clusterResourceWhitelist: []
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
  roles:
    - name: developer
      policies:
        - p, proj:tenants:developer, applications, get, tenants/*, allow
        - p, proj:tenants:developer, applications, sync, tenants/*-dev, allow
      groups:
        - hnq-developers
```

Ba project: `platform` (được tạo cluster resource), `tenants` (bị chặn), `admin`.

Giá trị thực tế: developer sync được app dev của mình, không sync được prod, không tạo được `ClusterRole`. Đây là điều kiện tiên quyết để mở UI cho người ngoài team infra dùng.

---

## 10. Cơ chế 6 — CI validation

`.gitlab-ci.yml`:

```yaml
stages: [validate, render, policy, security]

variables:
  HELM_VERSION: "3.16.0"

yaml-lint:
  stage: validate
  script:
    - yamllint -c ci/yamllint.yaml registry/ env/ gitops/

schema-validate:
  stage: validate
  script:
    # Mọi service.yaml phải khớp JSON Schema — chính schema mà UI dùng
    - |
      for f in registry/*/*/service.yaml; do
        ajv validate -s registry/schema/service.schema.json -d "$f" --spec=draft2020
      done

helm-lint:
  stage: validate
  script:
    - for c in charts/apps/*; do helm lint "$c"; done

render-all:
  stage: render
  script:
    # Render MỌI service × MỌI env — phát hiện lỗi template trước khi vào cluster
    - ci/scripts/render-all.sh > rendered.yaml
  artifacts:
    paths: [rendered.yaml]

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
  script:
    - conftest test --policy ci/policy rendered.yaml

gitleaks:
  stage: security
  script:
    - gitleaks detect --no-git --redact
```

`ci/policy/` chứa các rule OPA/Rego — đây là nơi biến "quy ước" thành "ràng buộc":

| Rule | Ngăn chặn |
|---|---|
| Mọi container phải có `resources.limits` và `requests` | Một pod ăn hết CPU node |
| Cấm `image: *:latest` | Deploy không tái tạo được |
| Bắt buộc `readinessProbe` | Traffic vào pod chưa sẵn sàng |
| Cấm `hostNetwork` trừ allowlist | Chính xác sự cố node-exporter trong `issues.md` |
| Cấm `privileged: true` | |
| `Ingress` phải có `cert-manager.io/cluster-issuer` | Domain không TLS |
| Namespace phải khớp `<service>-<env>` | Deploy nhầm namespace |

---

## 11. Cơ chế 7 — Storage & backup

### 11.1. Chuẩn hoá đường dẫn

Chốt **một** convention cho mọi node, mọi env:

```text
/srv/k3s/<env>/<category>/<service>/
  ví dụ: /srv/k3s/prod/storage/mariadb/
```

Cách làm không downtime: tạo symlink từ đường dẫn cũ sang đường dẫn mới, đổi values, verify, rồi mới move data thật trong cửa sổ bảo trì.

### 11.2. Thay `hostPath` bằng `local` PersistentVolume

`hostPath` thô không cho scheduler biết ràng buộc → phải `nodeSelector` tay (V12). Dùng `local` PV thì node affinity nằm trong chính PV:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mariadb-prod
spec:
  capacity: { storage: 50Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
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

Lợi ích: bỏ `nodeSelector` khỏi values của từng service; scheduler tự đặt pod đúng node; `Retain` bảo vệ data khi xoá PVC nhầm.

### 11.3. Backup

Thêm `platform/velero` vào registry, backup vào MinIO đang có sẵn:

- Lịch: dev hằng ngày giữ 7 ngày, prod 6 giờ/lần giữ 30 ngày
- Phạm vi: PV + manifest namespace
- **Thêm job kiểm tra restore hằng tháng** — backup chưa restore thử thì chưa phải backup

### 11.4. Về HA (ghi nhận, chưa làm ngay)

Longhorn/Mayastor cho volume có replica là hướng đúng, **nhưng** cụm hiện chạy flannel qua `tailscale0`. Replication khối qua WAN sẽ rất chậm và dễ gây chính sự cố mà nó định phòng. Khuyến nghị: **giữ local storage + backup chắc chắn**, chỉ xét storage phân tán khi các node nằm chung LAN.

---

## 12. Hướng phát triển UI web để deploy service

### 12.1. Nguyên tắc bất di bất dịch

> **UI ghi vào Git, không ghi vào cluster.**

Nếu UI gọi thẳng Kubernetes API, bạn mất toàn bộ giá trị của GitOps: cluster có state không có trong Git, rollback không còn là `git revert`, và ArgoCD với `selfHeal: true` sẽ **hoàn tác** thay đổi từ UI sau vài phút — một class bug rất khó hiểu cho người dùng.

### 12.2. Ba phương án

| | A. Backstage | B. Mở rộng `server-control` | C. Custom Operator + CRD |
|---|---|---|---|
| Công sức | Thấp–TB (cấu hình) | TB (viết code) | Cao |
| Tuỳ biến | Trung bình | Cao | Rất cao |
| Phải nuôi thêm | Backstage (nặng, Node + Postgres) | Không (đã có app) | Operator |
| Giữ GitOps | Có (Software Template → MR) | Có (nếu ghi Git) | Chỉ khi write-back Git |
| Đã có sẵn trong repo | Không | ✅ Có chart + auth JWT + React | Không |

### 12.3. Đề xuất: Phương án B — mở rộng `server-control`

Repo đã có `infra/helm/admin/server-control`: Node.js + Express + React + SQLite + JWT auth + ingress. Đó là ~70% nền tảng của một platform portal. Thêm module "Services" vào đó rẻ hơn nhiều so với dựng Backstage.

#### Kiến trúc

```mermaid
flowchart TB
  subgraph UI["server-control — Platform Portal"]
    FE["React SPA"]
    FORM["Form tự sinh từ<br/>service.schema.json"]
    BE["Express API"]
    subgraph MOD["Modules"]
      M1["Catalog — liệt kê service"]
      M2["Create — wizard tạo service"]
      M3["Status — sync/health"]
      M4["Deploy — đổi image tag"]
      M5["Logs & Events"]
    end
  end

  GL["GitLab API<br/>branch + commit + MR"]
  AR["ArgoCD API<br/>read-only + sync"]
  K8S["Kubernetes API<br/>read-only"]
  REPO[(HNQ-Infra repo)]
  ARGO[ArgoCD]

  FE --> BE
  FORM --> FE
  BE --> M1 & M2 & M3 & M4 & M5

  M1 --> GL
  M2 -->|"ghi registry/**"| GL
  M4 -->|"bump tag → MR"| GL
  M3 -->|đọc| AR
  M5 -->|đọc| K8S

  GL --> REPO --> ARGO --> K8S
```

#### API bề mặt

| Method | Endpoint | Việc |
|---|---|---|
| `GET` | `/api/services` | Liệt kê từ `registry/**/service.yaml` (GitLab API hoặc clone cache) |
| `GET` | `/api/services/:name` | Chi tiết + values mọi env |
| `GET` | `/api/schema/service` | Trả JSON Schema → frontend dựng form |
| `POST` | `/api/services` | Validate schema → render từ `ci/templates/` → tạo branch → commit → **mở MR** |
| `PATCH` | `/api/services/:name/image` | Bump tag: dev → commit thẳng; prod → MR |
| `GET` | `/api/services/:name/status` | Proxy ArgoCD `/api/v1/applications/<name>-<env>` |
| `POST` | `/api/services/:name/sync` | Proxy ArgoCD sync (có RBAC) |
| `GET` | `/api/services/:name/logs` | Stream log pod (read-only) |
| `POST` | `/api/services/:name/rollback` | Mở MR revert commit tương ứng |

#### Điểm thiết kế quan trọng nhất: form sinh từ schema

`registry/schema/service.schema.json` được dùng ở **hai nơi**:

1. CI validate mọi MR (kể cả MR viết tay)
2. Frontend dựng form bằng `react-jsonschema-form`

```jsonc
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["apiVersion", "kind", "metadata", "spec"],
  "properties": {
    "metadata": {
      "type": "object",
      "required": ["name", "owner"],
      "properties": {
        "name": {
          "type": "string",
          "pattern": "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$",
          "maxLength": 40,
          "title": "Tên service",
          "description": "chữ thường, số, gạch ngang"
        },
        "owner": { "type": "string", "title": "Team sở hữu" }
      }
    },
    "spec": {
      "type": "object",
      "required": ["category", "chart", "environments"],
      "properties": {
        "category": { "enum": ["tenant", "platform", "admin"] },
        "chart": { "enum": ["apps/webservice", "apps/datastore"] },
        "environments": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "object",
            "required": ["env", "namespace"],
            "properties": {
              "env": { "enum": ["dev", "prod"] },
              "namespace": { "type": "string" }
            }
          }
        }
      }
    }
  }
}
```

Hệ quả: **không thể có chuyện UI cho tạo cái mà platform không chấp nhận**, vì cả hai đọc cùng một file. Thêm một trường mới = sửa schema một lần, CI và UI cùng nhận.

#### Luồng "tạo service mới qua UI"

```mermaid
sequenceDiagram
  actor U as Người dùng
  participant UI as server-control
  participant GL as GitLab
  participant CI as CI
  participant AR as ArgoCD
  participant K as k3s

  U->>UI: Điền form (tên, chart, domain, env, resources)
  UI->>UI: Validate theo service.schema.json
  UI->>UI: Render 3 file từ ci/templates/
  UI->>GL: Tạo branch feat/add-<name>
  UI->>GL: Commit registry/tenants/<name>/{service,values-dev,values-prod}.yaml
  UI->>GL: Mở MR + gán reviewer
  UI-->>U: Link MR + preview diff

  CI->>CI: schema + lint + render + kubeconform + policy
  CI-->>GL: ✅ pipeline pass
  U->>GL: Review & merge

  GL->>AR: webhook
  AR->>AR: ApplicationSet sinh <name>-dev, <name>-prod
  AR->>K: sync
  AR-->>UI: status = Synced / Healthy
  UI-->>U: Service đã chạy 🎉
```

Điểm cần nhấn: **UI dừng ở bước mở MR.** Việc merge vẫn là hành động của con người (hoặc auto-merge khi CI xanh, tuỳ chính sách của bạn). Mọi thứ vẫn có audit trail đầy đủ trong Git.

#### Mô hình phân quyền

| Vai trò | Được làm |
|---|---|
| `viewer` | Xem catalog, xem status, xem log |
| `developer` | Tạo MR service mới, bump tag **dev**, sync app **dev** |
| `maintainer` | Bump tag prod (qua MR), sync prod, rollback |
| `admin` | Quản lý platform service, sửa env defaults |

Map trực tiếp sang ArgoCD `AppProject.roles` ở mục 9 — UI không tự định nghĩa quyền riêng mà phản chiếu quyền của ArgoCD, tránh hai nguồn sự thật về RBAC.

### 12.4. Lộ trình UI (chia nhỏ, mỗi bước có giá trị riêng)

| Bước | Nội dung | Công sức | Giá trị độc lập |
|---|---|---|---|
| U1 | `ci/scripts/new-service.sh` — scaffold CLI | 1 ngày | Dùng được ngay, và là backend logic của UI sau này |
| U2 | Viết `service.schema.json` + gắn vào CI | 1 ngày | CI bắt lỗi khai báo sai |
| U3 | Read-only catalog: list service + status từ ArgoCD API | 3–4 ngày | Team thấy được toàn cảnh "cái gì đang chạy ở đâu" |
| U4 | Form tạo service → mở MR | 4–5 ngày | Deploy service mới không cần biết Helm/ArgoCD |
| U5 | Bump image tag + rollback qua UI | 2–3 ngày | Release không cần vào Git |
| U6 | Log viewer + events | 2–3 ngày | Debug không cần `kubectl` |
| U7 | RBAC + audit log | 2–3 ngày | Mở được cho người ngoài team infra |

Tổng ~3 tuần công, nhưng **U1 và U2 làm trước và dùng được ngay** kể cả khi U3–U7 bị hoãn.

---

## 13. Lộ trình thực thi theo phase

### Nguyên tắc: mỗi phase kết thúc ở trạng thái chạy được, có thể dừng lại mà không hỏng gì.

```mermaid
gantt
  title Lộ trình refactor
  dateFormat YYYY-MM-DD
  axisFormat %d/%m

  section P0 An toàn
  Inventory + backup state      :p0a, 2026-09-15, 3d
  CI validation (repo cũ)       :p0b, after p0a, 3d
  Sửa quick wins                :p0c, after p0a, 2d

  section P1 GitOps
  Cấu trúc thư mục mới          :p1a, after p0b, 3d
  AppProject                    :p1b, after p1a, 2d
  ApplicationSet + registry     :p1c, after p1b, 5d
  Cutover + verify              :p1d, after p1c, 3d

  section P2 Charts
  Library chart hnq-common      :p2a, after p1d, 4d
  Chart webservice + migrate    :p2b, after p2a, 5d
  Chart datastore + migrate     :p2c, after p2b, 5d

  section P3 Vận hành
  Sealed Secrets                :p3a, after p2c, 3d
  Image tag automation          :p3b, after p3a, 3d
  Đưa outline/runner vào GitOps :p3c, after p3a, 2d

  section P4 Storage
  Chuẩn hoá path + local PV     :p4a, after p3b, 5d
  Velero backup + test restore  :p4b, after p4a, 3d

  section P5 UI
  Scaffold CLI + schema         :p5a, after p3b, 2d
  Catalog read-only             :p5b, after p5a, 4d
  Form tạo service              :p5c, after p5b, 5d
  Deploy/rollback + RBAC        :p5d, after p5c, 5d
```

### Phase 0 — An toàn trước (1 tuần)

**Không đổi kiến trúc gì cả.** Mục tiêu là có lưới an toàn trước khi động vào.

- [ ] Dump toàn bộ state hiện tại: `kubectl get all,ing,pvc,secret,cm -A -o yaml` → lưu ngoài repo
- [ ] Backup sealing key / mọi secret đang có trong cluster
- [ ] Backup data của MariaDB / Postgres / MinIO / OpenSearch (dùng script sẵn có trong `scripts/`)
- [ ] Thêm `.gitlab-ci.yml` với `yamllint` + `helm lint` + `helm template` **trên cấu trúc hiện tại**
- [ ] Sửa các quick win ở mục 15
- [ ] Ghi lại `helm template` output hiện tại của mọi chart → dùng làm **baseline so sánh** ở các phase sau

**Điều kiện hoàn thành:** CI chạy xanh; có file baseline; có backup verify được.

### Phase 1 — GitOps layer (2 tuần)

- [ ] Tạo cấu trúc thư mục mới (giữ song song cấu trúc cũ)
- [ ] Viết `env/dev/defaults.yaml`, `env/prod/defaults.yaml` — hút toàn bộ phần trùng ra khỏi values tenant
- [ ] Tạo 3 `AppProject`
- [ ] Viết `registry/**/service.yaml` + `values-<env>.yaml` cho **mọi** service (kể cả cái đang thiếu ở prod)
- [ ] Viết 4 `ApplicationSet`
- [ ] **Verify trước cutover:** `helm template` từ đường mới, `dyff` với baseline Phase 0 → phải khác biệt đúng bằng những gì mình chủ ý sửa
- [ ] Cutover (xem 14.1)
- [ ] Xoá `infra/argocd/apps/**` cũ

**Điều kiện hoàn thành:** 24 Application được sinh bởi ApplicationSet; `kubectl get app -n argocd` khớp tên cũ; mọi app `Synced`+`Healthy`.

### Phase 2 — Chart consolidation (2–3 tuần)

- [ ] `charts/library/hnq-common` + unit test bằng `helm unittest`
- [ ] `charts/apps/webservice`
- [ ] Migrate **từng service một**, mỗi service một MR: render → `dyff` với baseline → chỉ merge khi diff rỗng hoặc giải thích được
- [ ] Thứ tự đề xuất: `server-control` (dev, ít rủi ro) → `push-notify-v2` → 4 tenant → `outline`
- [ ] `charts/apps/datastore`
- [ ] Migrate storage: `redis` → `postgres` → `opensearch` → `minio` → `mariadb` (rủi ro tăng dần)
- [ ] Xoá `templates/namespace.yaml` khỏi mọi chart, chuyển sang `managedNamespaceMetadata`

**Điều kiện hoàn thành:** còn 3 chart tự viết; template ~700 dòng; `dyff` rỗng với mọi service.

### Phase 3 — Vận hành (1–2 tuần)

- [ ] Cài Sealed Secrets controller; migrate mọi secret; backup sealing key
- [ ] `gitleaks` vào CI
- [ ] Image tag automation cho dev
- [ ] **Đưa `outline`, `gitlab-runner`, `coredns-ha` vào GitOps** (fix V2)
- [ ] **Thêm monitoring + postgres + redis cho prod** (fix V1)
- [ ] `docs/RUNBOOK.md`

### Phase 4 — Storage (1–2 tuần)

- [ ] Chuẩn hoá `/srv/k3s/<env>/...` trên mọi node
- [ ] Chuyển `hostPath` → `local` PV + StorageClass
- [ ] Velero + backup schedule + **test restore thật**

### Phase 5 — UI (3 tuần)

Theo U1–U7 ở mục 12.4.

---

## 14. Rủi ro & cách giảm thiểu

### 14.1. 🔴 Rủi ro lớn nhất: ApplicationSet xoá mất workload đang chạy

**Vấn đề.** Khi bạn xoá `Application/lotus-clinic-dev` (có `resources-finalizer`), ArgoCD **xoá luôn mọi resource** nó quản: Deployment, Service, Ingress, và PVC nếu chart tạo PVC. Nếu ApplicationSet sau đó tạo lại Application cùng tên, bạn vẫn bị downtime — và với datastore thì có thể mất data.

**Cách xử lý — làm đúng theo thứ tự này:**

```bash
# 1. Gỡ finalizer khỏi TẤT CẢ Application cũ → xoá Application sẽ KHÔNG xoá resource
kubectl -n argocd get applications.argoproj.io -o name | while read app; do
  kubectl -n argocd patch "$app" --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done

# 2. Tắt auto-sync trên root app cũ để nó không prune giữa chừng
kubectl -n argocd patch app apps-dev --type=merge \
  -p '{"spec":{"syncPolicy":null}}'

# 3. Xoá root app cũ (KHÔNG cascade — resource ở lại nguyên vẹn)
kubectl -n argocd delete app apps-dev --cascade=orphan
kubectl -n argocd delete app apps-prod --cascade=orphan

# 4. Xoá các Application con (finalizer đã gỡ ở bước 1 → resource ở lại)
kubectl -n argocd delete app --all

# 5. Xác nhận workload VẪN CHẠY trước khi đi tiếp
kubectl get pods -A | grep -v Running | grep -v Completed

# 6. Apply root app mới → ApplicationSet sinh Application ADOPT resource đang chạy
kubectl -n argocd apply -f gitops/bootstrap/dev/root.yaml
```

**Ba điều kiện bắt buộc để adopt thành công:**

1. **Tên Application mới phải trùng tên cũ** (`lotus-clinic-dev`, không phải `tenant-lotus-clinic-dev`)
2. **`releaseName` phải trùng** — Helm nhận diện release qua Secret `sh.helm.release.v1.<releaseName>.*`
3. **`destination.namespace` phải trùng**

Trong ApplicationSet ở mục 5.2, cả ba điều kiện đều được giữ. Đây là lý do template dùng `{{ .metadata.name }}-{{ .env }}` chứ không thêm prefix.

**Diễn tập bắt buộc:** làm toàn bộ quy trình trên ở **dev trước**, xác nhận zero downtime, rồi mới làm prod. Nếu có thể, dựng một k3s ephemeral (k3d) để diễn tập lần đầu.

### 14.2. Bảng rủi ro

| Rủi ro | Khả năng | Tác động | Giảm thiểu |
|---|---|---|---|
| ApplicationSet xoá workload | Trung bình | 🔴 Rất cao | Quy trình 14.1; diễn tập ở dev; `--cascade=orphan` |
| Mất data khi đổi chart storage | Thấp | 🔴 Rất cao | `Retain` reclaim policy; backup + **test restore** trước; migrate datastore cuối cùng |
| Chart mới render khác chart cũ ngoài ý muốn | Cao | 🟠 Cao | `dyff` với baseline Phase 0 ở **mọi** MR; migrate từng service một |
| Mất sealing key của Sealed Secrets | Thấp | 🟠 Cao | Backup key offline ngay khi cài; ghi vào runbook |
| Refactor kéo dài, repo ở trạng thái nửa vời | Cao | 🟡 TB | Mỗi phase kết thúc ở trạng thái chạy được; cũ/mới song song trong P1–P2 |
| Gộp `develop`+`main` làm mất "vùng đệm" của prod | TB | 🟡 TB | Prod chỉ đổi qua MR có reviewer; policy CI chặn tag `latest` |
| UI mở MR sai/spam | TB | 🟡 Thấp | Validate schema phía server; rate limit; MR luôn cần người merge |

---

## 15. Quick wins — sửa được ngay

Những việc dưới đây **không phụ thuộc refactor**, làm trong Phase 0:

| # | Việc | Lý do | Công sức |
|---|---|---|---|
| 1 | **Thêm `monitoring`, `storage-postgres`, `storage-redis` vào `apps/prod/platform/`** | Prod đang **không có monitoring** | 30 phút |
| 2 | **Điều tra `imagePullSecrets: lotus-clinic-registry` ở cả 4 tenant** | Hoặc secret bị đặt tên sai, hoặc 3 tenant dùng credential của tenant khác | 30 phút |
| 3 | **Thống nhất `repoURL`** — chọn HTTPS hoặc SSH cho cả dev lẫn prod | ArgoCD đang coi là 2 repo, 2 bộ credential | 15 phút |
| 4 | **Tạo Application cho `outline` + `gitlab-runner` + `coredns-ha`** | Đang chạy ngoài GitOps, mất cluster là mất luôn | 1 giờ |
| 5 | **Xoá `hnq_svc.json`** | File rác rỗng ở root | 1 phút |
| 6 | **Làm rõ `tolerations: []` ở `giaan-clinic/values-dev.yaml`** | Khác 3 tenant còn lại, không rõ cố ý | 15 phút |
| 7 | **Sửa `README.md`** — bỏ phần `envs/` và `infra/ci/` không tồn tại trong repo | Tài liệu sai gây hiểu nhầm cho người mới | 1 giờ |
| 8 | **Cập nhật `ARCHITECTURE.md`** — bổ sung node `server02` | Values tham chiếu node không có trong tài liệu | 30 phút |
| 9 | **Thêm `.gitlab-ci.yml` tối thiểu** (`yamllint` + `helm lint`) | Chặn YAML hỏng ngay hôm nay | 1 giờ |
| 10 | **Thêm `docs/RUNBOOK.md`** và move `helm/monitoring/issues.md` vào đó | Kiến thức sự cố đang nằm rải rác | 1 giờ |

Tổng: **dưới 1 ngày công** cho 10 việc, trong đó #1 và #2 là vấn đề production thật.

---

## 16. Các quyết định cần chốt trước khi code

Những điểm sau ảnh hưởng trực tiếp đến thiết kế, cần bạn xác nhận:

| # | Câu hỏi | Đề xuất của tôi | Ảnh hưởng nếu chọn khác |
|---|---|---|---|
| Q1 | **Một branch `main` chung, hay giữ `develop`/`main`?** | Một `main`, phân biệt bằng `env/` | Giữ 2 branch thì vẫn làm được nhưng phải cherry-pick chart, và class lỗi V1 vẫn còn |
| Q2 | **Có flatten `infra/` ra root không?** | Có — tên repo đã là `HNQ-Infra`, `infra/` thừa một cấp | Giữ `infra/` thì mọi đường dẫn trong plan này thêm prefix, không ảnh hưởng thiết kế |
| Q3 | **Secrets: Sealed Secrets, SOPS, hay ESO?** | Sealed Secrets (ít rủi ro nhất ở quy mô này) | SOPS cần custom repo-server image; ESO cần Vault |
| Q4 | **UI: mở rộng `server-control` hay dựng Backstage?** | Mở rộng `server-control` — đã có 70% nền | Backstage mạnh hơn nhưng nặng và phải nuôi thêm Postgres |
| Q5 | **Prod có được auto-sync không?** | Có `selfHeal`, nhưng **không** auto-sync image tag prod (phải qua MR) | Auto hoàn toàn thì nhanh nhưng mất chốt kiểm soát |
| Q6 | **Có giữ Rancher không?** | Cân nhắc bỏ nếu ArgoCD + UI mới phủ hết nhu cầu — Rancher đang chiếm tài nguyên đáng kể trên control-plane | Giữ thì cần đưa vào GitOps luôn |
| Q7 | **Ngân sách thời gian?** | Full plan ~8–10 tuần. Nếu gấp: **P0 + P1 (3 tuần) đã giải quyết 70% pain point** | Quyết định phase nào cắt |
| Q8 | **`nodeSelector: server02` ở dev** — node này có trong kiến trúc chính thức không? | Cần xác nhận, `ARCHITECTURE.md` không liệt kê | Ảnh hưởng thiết kế `local` PV ở Phase 4 |

---

## Phụ lục A — Bảng ánh xạ file cũ → mới

| Hiện tại | Sau refactor |
|---|---|
| `infra/argocd/bootstrap/{dev,prod}/root-app.yaml` | `gitops/bootstrap/{dev,prod}/root.yaml` |
| `infra/argocd/apps/{dev,prod}/clients/*.yaml` (8 file) | `gitops/appsets/tenants.yaml` (1 file) + `registry/tenants/*/service.yaml` |
| `infra/argocd/apps/{dev,prod}/platform/*.yaml` (17 file) | `gitops/appsets/platform.yaml` (1 file) + `registry/platform/*/service.yaml` |
| `infra/argocd/apps/{dev,prod}/admin/*.yaml` | `gitops/appsets/admin.yaml` + `registry/platform/{outline,server-control}/` |
| `infra/argocd/manifests/platform/**` | `gitops/manifests/**` |
| `infra/helm/clients/obgyn-clinic-service/templates/` | `charts/apps/webservice/` (dùng chung) |
| `infra/helm/clients/obgyn-clinic-service/<tenant>/values-*.yaml` | `registry/tenants/<tenant>/values-*.yaml` (ngắn hơn ~5 lần) |
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

## Phụ lục B — Makefile đề xuất

```makefile
.PHONY: help new-service validate render diff lint

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

new-service: ## Scaffold service mới: make new-service NAME=x CHART=apps/webservice
	@ci/scripts/new-service.sh "$(NAME)" "$(CHART)"

validate: ## Chạy đủ bộ validate như CI
	@ci/scripts/validate.sh

render: ## Render mọi service × mọi env ra stdout
	@ci/scripts/render-all.sh

diff: ## So sánh render hiện tại với baseline
	@ci/scripts/render-all.sh > /tmp/new.yaml
	@dyff between ci/baseline.yaml /tmp/new.yaml

lint: ## helm lint mọi chart
	@for c in charts/apps/* charts/vendor/*; do helm lint "$$c"; done
```

## Phụ lục C — Tài liệu tham khảo

- ArgoCD ApplicationSet — Matrix generator & `elementsYaml`: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Matrix/
- ArgoCD AppProject: https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- Helm library chart: https://helm.sh/docs/topics/library_charts/
- Sealed Secrets: https://github.com/bitnami-labs/sealed-secrets
- kubeconform: https://github.com/yannh/kubeconform
- conftest / OPA: https://www.conftest.dev/
- dyff (so sánh YAML ngữ nghĩa): https://github.com/homeport/dyff
- react-jsonschema-form: https://rjsf-team.github.io/react-jsonschema-form/
