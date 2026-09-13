# Hồ sơ nghiên cứu: best practice cộng đồng về k3s + ArgoCD

> **Đây là hồ sơ tra cứu, không phải kế hoạch.** Kế hoạch đang dùng là [PLAN.md](./PLAN.md) — mọi quyết định ở đó đều lấy cơ sở từ tài liệu này.
>
> Tra cứu ngày 11/09/2026. Các cột *"Plan hiện tại"* trong tài liệu so với **bản nháp đầu tiên** (đội 3 người, chưa chốt topology) nên có chỗ đã lỗi thời — quyết định hiện hành luôn đọc ở [PLAN §13 Cố tình không làm](./PLAN.md#13-cố-tình-không-làm).

## Bảy chỗ kế hoạch hiện tại đi khác tài liệu này — và vì sao

Đều cùng một lý do: tài liệu này viết cho đội có nhiều người, kế hoạch viết cho **1 người vận hành**.

| Cộng đồng khuyến nghị | PLAN.md làm gì | Vì sao |
|---|---|---|
| Tắt tài khoản `admin` của ArgoCD, dùng SSO | **Giữ `admin`** | Dex/GitHub OIDC = 4 phụ thuộc phải sống mới đăng nhập được, đúng lúc đang sự cố. Bù bằng: không ingress public, chỉ vào qua tailnet, `policy.default: ""` |
| Tailscale K8s Operator thay vì phát tán kubeconfig | **kubeconfig qua tailnet** | Bài toán Operator giải (nhiều người, nhiều máy, RBAC theo người) không tồn tại với 1 người; cái giá (một thành phần giữa bạn và apiserver) thì vẫn nguyên |
| Backup namespace `argocd` | **Không cần** | ArgoCD ở cấu hình này không có PV — toàn bộ trạng thái là CR trong etcd, snapshot etcd đã phủ hết |
| Longhorn cho multi-node production | **Không dùng** | Master là VPS xa nối qua WAN. Và khi Longhorn hỏng, 1 người sửa nó lâu hơn restore từ dump → tăng MTBF nhưng tăng cả MTTR |
| HA control-plane (3 server) | **1 server** | Quorum etcd qua WAN tệ hơn 1 server: mất một đường mạng là cluster read-only dù cả 3 máy đều sống |
| `replicas: 2` cho prod | **1 replica** cho app; 2 replica chỉ cho Traefik/cloudflared/CoreDNS | Mọi pod prod nằm cùng một node → replica thứ hai không chống được sự cố node, chỉ nhân đôi kết nối DB |
| Require approvals trên PR | **0 approval**, CI là cửa duyệt | GitHub không cho tự approve PR của mình |

Ba chủ đề **không có trong tài liệu này**, được tra cứu riêng và viết thẳng vào kế hoạch: MTTR có đo, dead man's switch, và đường dữ liệu độc lập control-plane. Xem [RECOVERY.md](./RECOVERY.md) và [OPERATIONS.md](./OPERATIONS.md).


---

## Cách đọc tài liệu này

Mỗi phát hiện được gắn nhãn:

| Nhãn | Nghĩa |
|---|---|
| ✅ **KHỚP** | Kế hoạch hiện tại đã làm đúng |
| ⚠️ **LỆCH** | Kế hoạch hiện tại làm khác — cần bạn quyết định |
| ➕ **THIẾU** | Cộng đồng dùng nhưng kế hoạch chưa có |

Và mức độ tin cậy của nguồn:

| Mức | Nguồn |
|---|---|
| 🟢 **Cao** | CNCF, tài liệu chính thức Argo/k3s, khảo sát người dùng Argo CD, Red Hat |
| 🟡 **Trung bình** | Blog của công ty trong ngành (Akuity — chính là công ty làm ArgoCD, Stakater, Cloudogu) |
| 🟠 **Tham khảo** | Blog kỹ thuật cá nhân / trang tổng hợp SEO — dùng để thấy xu hướng, không dùng làm căn cứ duy nhất |

---

## TÓM TẮT: 3 điều cần bạn quyết định

| # | Vấn đề | Kế hoạch hiện tại | Cộng đồng khuyến nghị |
|---|---|---|---|
| **1** | Tách môi trường bằng gì | 2 branch (`develop`/`main`) | **Thư mục, cùng một branch.** Branch-per-environment được nêu tên là anti-pattern. |
| **2** | Auto-sync ở prod | Bật auto-sync + selfHeal | **Sync thủ công ở prod**, auto-sync chỉ ở dev/staging |
| **3** | Có dùng công cụ promotion riêng không | Script + MR thủ công | **Kargo** (của chính Akuity) sinh ra để giải đúng bài toán "test dev rồi mới lên prod" |

Chi tiết ở [Phần 1](#1--tách-môi-trường-branch-hay-thư-mục), [Phần 3](#3--chính-sách-sync) và [Phần 6](#6--công-cụ-promotion).

---

## 1 — Tách môi trường: branch hay thư mục?

> ⚠️ **LỆCH** · 🟡 Độ tin cậy trung bình–cao (nhiều nguồn độc lập nói giống nhau)

### Cộng đồng nói gì

Đây là điểm được nhắc lại nhiều nhất và nhất quán nhất trong toàn bộ tra cứu:

> *"Using dev, staging, production branches sounds clean but creates merge hell and makes promotion difficult. Use directory-per-environment instead."*
> — [Stakater, GitOps Repository Structure](https://www.stakater.com/post/gitops-repository-structure/)

> *"Environment-specific configuration belongs in separate folders, not long-lived branches, since promotion isn't a simple merge. Secrets and ConfigMaps differ fundamentally between environments and shouldn't get merged."*
> — [Cloudogu, GitOps Promotion Patterns](https://platform.cloudogu.com/en/blog/gitops-repository-patterns-part-4-promotion-patterns/)

> *"The promotion mechanism should be updating artifact versions, not merging branches. Both environments track the same branch, but they reference different artifact versions."*
> — [OneUptime, Git Branching Strategy for GitOps](https://oneuptime.com/blog/post/2026-02-26-argocd-git-branching-strategy-gitops/view)

Còn có hẳn một bài viết kinh điển tên là *"Stop using branches for deploying to different GitOps environments"* ([Medium / Containers 101](https://medium.com/containers-101/stop-using-branches-for-deploying-to-different-gitops-environments-7111d0632402)).

### Nhưng — mô hình của bạn không phải trường hợp xấu nhất

Cần công bằng: cảnh báo ở trên nhắm vào mô hình mà **nội dung file khác nhau giữa các branch**, dẫn tới cherry-pick và drift. Thiết kế trong kế hoạch hiện tại đã tránh được phần lớn:

- Cùng một cấu trúc `registry/` trên cả hai branch
- `main` **chỉ nhận merge** từ `develop`, không cherry-pick
- Khác biệt giữa môi trường nằm ở **thư mục** (`env/dev/`, `values-dev.yaml`), không nằm ở branch

Nên nó là mô hình lai: thư mục để tách cấu hình + branch làm cổng kiểm soát.

### Cái giá thật sự phải trả

Dù vậy vẫn còn 4 chi phí có thật:

| # | Chi phí | Mức độ |
|---|---|---|
| **1** | **Không promote chọn lọc được.** Nếu `develop` đang có thay đổi của service A và service B, merge lên `main` là đưa **cả hai** lên prod. Không thể chỉ đưa A. | 🔴 Nặng |
| 2 | Phải tham số hoá `targetRevision` bằng Helm chart bootstrap (mục 3.5 của plan) — thêm một lớp phức tạp và một class lỗi mới (quên escape `{{ }}`) | 🟡 Vừa |
| 3 | Không nhìn một branch mà biết được "cái gì đang chạy ở đâu" — phải so hai branch | 🟡 Vừa |
| 4 | Hai root app đọc hai revision → hai lần cache repo-server, hai đường debug | 🟢 Nhẹ |

**Chi phí #1 là cái đáng cân nhắc nhất.** Ví dụ thực tế: `lotus-clinic` đã test xong muốn lên prod, nhưng `giaan-clinic` đang dở dang cũng nằm trên `develop`. Merge là đưa cả hai lên. Muốn tách thì phải cherry-pick — mà cherry-pick chính là thứ gây drift mà mô hình 2 branch định tránh.

### Cách thư mục đạt được cùng mục tiêu của bạn

Mục tiêu bạn nêu — *"test dev trước rồi mới deploy prod"* — hoàn toàn đạt được **không cần branch**:

```text
Cùng branch main:
  registry/tenants/lotus-clinic/values-dev.yaml    → image.tag: 7bcd1234   (mới, đang test)
  registry/tenants/lotus-clinic/values-prod.yaml   → image.tag: f1eb557d   (cũ, ổn định)

Test xong ở dev → 1 MR đổi values-prod.yaml: f1eb557d → 7bcd1234
  → chỉ service này lên prod, không kéo theo ai khác
```

Prod vẫn chạy phiên bản cũ cho tới khi bạn chủ động đổi. Vẫn có MR, vẫn có người duyệt, vẫn có audit — nhưng **promote được từng service một**.

### Ba lựa chọn

| | A. Giữ 2 branch | B. Chuyển sang 1 branch + thư mục | C. Lai |
|---|---|---|---|
| Cách làm | Như plan hiện tại | `main` duy nhất, promote = sửa `values-prod.yaml` | `main` duy nhất + [Kargo](#6--công-cụ-promotion) quản lý stage |
| Promote chọn lọc | ❌ | ✅ | ✅ |
| Khớp best practice | ❌ | ✅ | ✅ |
| Độ phức tạp | Vừa (bootstrap chart) | **Thấp nhất** | Cao (thêm 1 hệ thống) |
| Công sức đổi plan | 0 | ~1 ngày sửa tài liệu | ~1 ngày + 1 tuần triển khai Kargo |
| Cảm giác an toàn cho prod | Cao (rào chắn rõ ràng) | Vừa (dựa vào protected branch + MR) | Cao |

**Ý kiến của tôi:** phương án **B**. Lý do chính không phải vì "cộng đồng bảo thế", mà vì **chi phí #1** là hạn chế vận hành thật sự — càng nhiều service thì càng đau. Bạn đang có 4 khách hàng; con số này chỉ tăng.

Nhưng đây là quyết định của bạn. Nếu bạn muốn một rào chắn vật lý giữa dev và prod thì phương án A vẫn chạy được, plan hiện tại đã viết đầy đủ cho nó.

---

## 2 — App-of-Apps hay ApplicationSet?

> ✅ **KHỚP một phần** · ➕ **THIẾU một phần** · 🟢–🟡 Độ tin cậy cao

### Số liệu

Từ [Khảo sát người dùng Argo CD 2026](https://blog.argoproj.io/argo-cd-2026-user-survey-results-dcffc9a8e48e) (269 người trả lời):

| Chỉ số | Giá trị |
|---|---|
| Dùng App-of-Apps trong production | **~82%** |
| Quản lý >500 Application trên 1 instance | 42% (năm 2023 chỉ 15%) |
| Dùng Argo Rollouts | 63% |

Argo CD cũng là giải pháp GitOps được áp dụng nhiều nhất theo [khảo sát end-user của CNCF](https://www.cncf.io/announcements/2025/07/24/cncf-end-user-survey-finds-argo-cd-as-majority-adopted-gitops-solution-for-kubernetes/).

### Khuyến nghị: dùng CẢ HAI, không phải chọn một

Đây là điểm tôi nêu chưa rõ trong plan. Cộng đồng phân vai như sau:

> *"App-of-Apps is good for a curated platform bundle — the set of addons every cluster gets (cert-manager, external-secrets, ingress, monitoring), where the list is small, intentional, and changes deliberately."*
>
> *"An ApplicationSet is an Application factory... For repetitive patterns, don't create individual Application manifests, but use ApplicationSets within your App-of-Apps."*
> — [DevOpsil, ArgoCD Application Patterns](https://devopsil.com/articles/2026-03-21-gitops-argocd-application-patterns) · [Coding Protocols](https://codingprotocols.com/blog/argocd-app-of-apps-vs-applicationset)

Áp vào hệ thống của bạn:

| Nhóm | Đặc điểm | Nên dùng |
|---|---|---|
| Nền tảng (cert-manager, traefik, monitoring, coredns-ha) | Danh sách ngắn, cố định, thay đổi có chủ đích | **App-of-Apps** |
| Khách hàng (4 clinic, sẽ tăng) | Lặp lại cùng một khuôn | **ApplicationSet** |
| Storage (mariadb, postgres, redis, minio, opensearch) | Lặp lại nhưng ít thay đổi | **ApplicationSet** |

> **Thực tế:** `gitops/bootstrap/` trong plan hiện tại *đã là* một App-of-Apps rồi (một Application sinh ra các AppProject + ApplicationSet). Nên kế hoạch về cơ bản đã đúng — chỉ cần diễn đạt lại cho rõ và cân nhắc để nhóm nền tảng ở dạng Application tường minh thay vì ép hết vào ApplicationSet.

### Git file generator — đúng là pattern chuẩn

> ✅ **KHỚP** · 🟡

Thiết kế `registry/<loại>/<tên>/service.yaml` + ApplicationSet quét bằng glob là **pattern được cộng đồng công nhận**, không phải sáng tạo riêng:

> *"The Git file generator pattern enables a self-service workflow where developers create a config file to onboard their application... This pattern is particularly useful for GitOps workflows where teams copy a template file when onboarding new applications, and each file should describe one application."*
> — [OneUptime, Git File Generator with YAML Config Files](https://oneuptime.com/blog/post/2026-02-26-argocd-applicationset-git-file-yaml/view)

Đúng y hệt thiết kế trong plan. Yên tâm về hướng này.

### ➕ Tính năng ApplicationSet mà plan chưa dùng: Progressive Sync

> *"For careful, ordered rollouts across the fleet, ApplicationSet has progressive syncs (`spec.strategy.type: RollingSync`), so you can update canary clusters before production ones — something App-of-Apps cannot express at all."*

Với 1 cluster thì chưa cần. Ghi lại để dành khi có cluster thứ hai.

---

## 3 — Chính sách sync

> ⚠️ **LỆCH** · 🟠 Tham khảo (nhiều blog nói giống nhau nhưng không có nguồn chính thức)

### Cộng đồng nói gì

> *"A graduated approach is recommended: auto-sync for dev/staging and manual sync for production."*
> — [OneUptime, ArgoCD Best Practices for Enterprise](https://oneuptime.com/blog/post/2026-02-26-argocd-best-practices-enterprise/view)

Kế hoạch hiện tại đang bật `automated: { prune: true, selfHeal: true }` cho **cả hai** môi trường.

### Đánh giá

Đây là đánh đổi thật, không có câu trả lời đúng tuyệt đối:

| | Auto-sync prod (plan hiện tại) | Manual sync prod (cộng đồng) |
|---|---|---|
| Merge xong là chạy | ✅ Nhanh | ❌ Phải bấm thêm |
| Chống drift thủ công (`selfHeal`) | ✅ Có | ⚠️ Chỉ khi bấm sync |
| Kiểm soát thời điểm thay đổi vào prod | ❌ Không | ✅ Có |
| Hợp với đội nhỏ | ✅ | ⚠️ Dễ quên bấm |

**Đề xuất dung hoà** — giữ `selfHeal` nhưng tắt `prune` tự động ở prod:

```yaml
# prod
syncPolicy:
  automated:
    selfHeal: true      # tự sửa khi có người chỉnh tay vào cluster
    prune: false        # KHÔNG tự xoá — xoá phải do người bấm
```

Lý do: `selfHeal` bảo vệ khỏi việc ai đó `kubectl edit` vào prod (đúng vấn đề đã gây ra sự cố node-exporter 30 giờ). Còn `prune: true` mới là cái nguy hiểm — một lỗi trong ApplicationSet có thể khiến ArgoCD xoá hàng loạt resource prod.

Ngoài ra, cộng đồng còn dùng **sync window** để chặn deploy ngoài giờ làm việc:

```yaml
# AppProject
syncWindows:
  - kind: deny
    schedule: "0 18 * * 1-5"     # 18h–8h các ngày trong tuần
    duration: 14h
    applications: ["*-prod"]
    manualSync: true              # vẫn cho sync tay khi có sự cố
```

---

## 4 — Cấu trúc repo

> ✅ **KHỚP** phần lớn · 🟡–🟢

Tổng hợp từ [Red Hat](https://developers.redhat.com/articles/2022/09/07/how-set-your-gitops-directory-structure), [Stakater](https://www.stakater.com/post/gitops-repository-structure/), [Cloudogu gitops-patterns](https://github.com/cloudogu/gitops-patterns) và [OneUptime](https://oneuptime.com/blog/post/2026-02-26-argocd-best-practices-repository-structure/view):

| Nguyên tắc | Kế hoạch hiện tại |
|---|---|
| Tách mã nguồn ứng dụng khỏi cấu hình deploy | ✅ Đã tách sẵn từ đầu |
| Monorepo cho đội nhỏ, multi-repo cho tổ chức lớn | ✅ Monorepo — đúng quy mô |
| **Không lồng quá 4 cấp thư mục** | ⚠️ `registry/tenants/lotus-clinic/config/config_dev.yaml` = 4 cấp — vừa chạm giới hạn |
| **Không trộn Helm và Kustomize trong cùng một Application** | ✅ Chỉ dùng Helm |
| Giữ khác biệt giữa các môi trường ở mức tối thiểu | ✅ Chính là mục đích của `env/<env>/defaults.yaml` |
| Repo manifest do đội platform/SRE giữ quyền ghi chặt | ✅ Protected branch + MR |

> Cấu trúc cũ `infra/helm/platform/storage/mariadb/templates/` là **5 cấp** — vượt khuyến nghị. Cấu trúc mới đã cải thiện việc này.

---

## 5 — Secret

> ✅ **KHỚP** · 🟡 Nhiều nguồn độc lập nhất quán

### Ba lựa chọn thống trị

> *"Three approaches dominate GitOps secret management: Bitnami Sealed Secrets, Mozilla SOPS with age/KMS, and External Secrets Operator."*
> — [sanj.dev, Kubernetes Secrets Management in 2026](https://sanj.dev/post/kubernetes-secrets-management-comparison/)

### Lộ trình khuyến nghị — khớp đúng với plan

> *"Recommended progression: Start with **Sealed Secrets** — lowest barrier to entry, graduate to **External Secrets** — when you have a vault and need rotation, and use **SOPS** — for non-Kubernetes config or multi-tool environments."*
>
> *"Most teams start with Sealed Secrets and graduate to ESO when they hit the multi-cluster or rotation wall."*
> — [DevOpsBoys](https://devopsboys.com/blog/sops-vs-sealed-secrets-vs-external-secrets-gitops-2026)

Quyết định chọn Sealed Secrets ([PLAN §9](./PLAN.md#9-secret)) **khớp chính xác** với khuyến nghị này. Và hạn chế của nó cũng đúng với những gì cộng đồng nêu:

> *"The encryption/decryption mechanism is tied to the specific Kubernetes cluster, meaning migrating secrets between clusters can be a challenge."*

ESO có mặt ở khoảng **1/3 cluster production** báo cáo stack của họ — nhưng chủ yếu ở nơi đã có sẵn Vault hoặc cloud secret manager. Bạn chưa có, nên chưa cần.

### ➕ Điểm plan nêu chưa đủ rõ: khi nào thì nên chuyển sang ESO

Ba dấu hiệu:

1. Có cluster thứ hai (sealing key không dùng chung được)
2. Cần xoay vòng secret tự động, không qua người
3. Có Vault hoặc cloud secret manager rồi

Chưa có dấu hiệu nào thì Sealed Secrets là đúng.

---

## 6 — Công cụ promotion

> ➕ **THIẾU** · 🟡 Nguồn từ chính Akuity (công ty làm ArgoCD)

### Kargo là gì

Đây là phát hiện liên quan trực tiếp nhất tới nhu cầu "test dev rồi mới lên prod" của bạn.

> *"Kargo is a continuous promotion platform built by Akuity, the company behind ArgoCD, and it complements rather than replaces ArgoCD. Kargo handles promotion (Git state gets updated when new artifacts appear), while ArgoCD handles deployment (cluster state matches Git)."*
> — [Akuity, How Kargo Fixes GitOps with Promotion](https://akuity.io/blog/how-kargo-fixes-gitops-with-promotion)

Điểm quan trọng nhất:

> *"Kargo fills a similar niche to that of Argo CD Image Updater. One advantage of approaching this with Kargo is that updates are rolled out stage by stage, with **a failure in a 'test' stage preventing the same update from progressing to other stages, including production**."*
> — [Kargo Docs, Patterns](https://docs.kargo.io/user-guide/patterns)

Nghĩa là Kargo **ép buộc bằng công cụ** đúng cái quy trình bạn muốn: không qua được dev thì không lên prod được. Không phụ thuộc vào kỷ luật của con người hay protected branch.

### Có nên dùng không?

> *"If you're managing **three or more environments**, running multiple services, and finding that your promotion process is either manual and error-prone or automated with fragile scripts — Kargo is worth adopting."*
> — [DevOpsBoys, Kargo Review](https://devopsboys.com/blog/kargo-gitops-promotion-tool-review-2026)

Bạn có **2 môi trường**. Theo tiêu chí này thì **chưa tới ngưỡng**.

**Đề xuất:** chưa dùng bây giờ. Nhưng thiết kế registry nên để mở đường — Kargo đọc/ghi chính `values-<env>.yaml` mà plan đã dùng, nên sau này gắn vào không phải làm lại. Ghi vào plan như một hướng mở rộng.

> Nếu bạn thêm môi trường `staging` giữa dev và prod thì cân nhắc lại ngay — đó là lúc script thủ công bắt đầu gãy.

---

## 7 — Bảo mật và multi-tenancy

> ✅ **KHỚP** phần lớn · ➕ **THIẾU** vài thứ · 🟠 Tham khảo

### Điều quan trọng nhất — RBAC mặc định quá rộng

> *"Default ArgoCD RBAC is too permissive, as by default, ArgoCD service accounts get cluster-admin."*
> — [OneUptime, Security Hardening](https://oneuptime.com/blog/post/2026-02-26-argocd-best-practices-security-hardening/view)

Đáng kiểm tra ngay trên cluster của bạn — hiện tại mọi Application đang dùng `project: default`, nghĩa là **chưa có ranh giới nào cả**.

### Đối chiếu

| Thực hành | Plan hiện tại |
|---|---|
| AppProject giới hạn repo nguồn, namespace đích, cluster resource | ✅ Có (Phần 9) |
| RBAC deny-by-default, map sang nhóm SSO | ✅ Có |
| Tắt tài khoản mặc định (`admin`) | 🔄 **Cố tình không làm ở v3** — với 1 người thì đổi lại bằng: không ingress public + chỉ vào qua tailnet + `policy.default: ""`. Lý do đầy đủ ở [plan §8](./PLAN.md) |
| NetworkPolicy giới hạn truy cập mạng | ➕ **Thiếu** |
| HA cho ArgoCD | ❌ **Chốt không** — 1 replica, và vì không có PV nên restore etcd là ArgoCD trở lại nguyên trạng |
| **Sync window** cho quản lý thay đổi | ➕ **Thiếu** — xem [Phần 3](#3--chính-sách-sync) |
| Backup ArgoCD tự động | ✅ **Đã có, theo cách khác** — etcd snapshot đã chứa toàn bộ CR của ArgoCD; không cần Velero cho namespace này vì không có PV |
| Audit log | ✅ Lịch sử Git + audit log của ArgoCD |

### ➕ Sync waves — thiếu hẳn trong plan

> *"Sync waves eliminate the 'Chart deployed but readiness check hung forever' scenario by orchestrating dependency order."*

Quy ước thường dùng:

```yaml
# annotation: argocd.argoproj.io/sync-wave
-1  → Namespace, CRD
 0  → ConfigMap, Secret, ServiceAccount
 1  → Deployment, StatefulSet
 2  → HPA, ServiceMonitor, Ingress
```

Với hệ thống của bạn, cái này giải quyết một vấn đề cụ thể: **client backend khởi động trước khi MariaDB sẵn sàng**. Nên thêm vào library chart `hnq-common` ở Phase 2.

---

## 8 — Lưu trữ trên k3s

> ✅ **KHỚP** · 🟢 Tài liệu chính thức k3s

### Hạn chế của local-path — đúng như plan đã nêu

> *"K3s comes with Rancher's Local Path Provisioner... However, while this is great for development, it has a critical limitation for production: data is node-local. If that node or disk becomes unavailable, the pod also becomes unavailable."*
> — [Tài liệu chính thức k3s](https://docs.k3s.io/add-ons/storage)

### Khuyến nghị production

| Thực hành cộng đồng | Plan hiện tại |
|---|---|
| Longhorn cho multi-node production | ❌ **Chốt không ở v3** — master ở VPS xa, nối 2 node local qua Tailscale. Thêm: khi Longhorn hỏng thì 1 người sửa nó lâu hơn là restore từ dump, tức là tăng MTBF nhưng tăng cả MTTR |
| `reclaimPolicy: Retain` cho data production | ✅ Có — khai trong StorageClass `hnq-local` ([plan §10.4](./PLAN.md)) |
| Longhorn replica count = số node (tối đa 3) | Ghi lại cho sau này |
| **Kết hợp hợp lệ**: local-path cho cache/ít quan trọng, Longhorn cho stateful quan trọng | ⚠️ v3 chọn **local-path cho tất cả**, và bù bằng lớp dump logic hằng giờ (RPO 1 giờ) + quy trình [R4](./RECOVERY.md) đã diễn tập |

> *"A production K3s environment may legitimately combine: local-path → caches and low-criticality local state, Longhorn / CSI storage → selected stateful cluster workloads."*

Quyết định hoãn Longhorn trong plan là **hợp lý và có cơ sở** — replication khối qua WAN (Tailscale) sẽ chậm và dễ gây ra chính sự cố nó định phòng. Cộng đồng không phản đối cách tiếp cận lai này.

> **v3 đi xa hơn một bước và chốt là không dùng Longhorn.** Lý do thêm vào không nằm trong tài liệu nghiên cứu này mà nằm ở quy mô đội: cộng đồng khuyến nghị Longhorn cho *"selected stateful cluster workloads"*, nhưng ngầm giả định có người vận hành được nó. Với 1 người, thời gian sửa Longhorn khi nó hỏng dài hơn thời gian restore từ dump — nên nó **tăng MTBF mà cũng tăng MTTR**, ngược với mục tiêu đã chọn. Xét lại khi có node local thứ ba chung LAN **và** có người thứ hai biết vận hành nó.

---

## 9 — Bộ công cụ CI

> ✅ **KHỚP** phần lớn · ➕ **THIẾU 3 thứ** · 🟠 Tham khảo

### Bộ chuẩn cộng đồng

> *"A multi-layer approach includes linting with `helm lint` and `yamllint`, validation with `kubeconform`, unit tests with `helm-unittest`, security scanning with `Trivy` and `Conftest` for custom policies, and integration testing with `chart-testing (ct)`."*
> — [Helm Chart Testing Best Practices](https://alexandre-vazquez.com/helm-chart-testing-best-practices/)

### Đối chiếu

| Công cụ | Mục đích | Plan hiện tại |
|---|---|---|
| `yamllint` | Cú pháp YAML | ✅ |
| `helm lint` | Cú pháp chart | ✅ |
| `kubeconform` | Schema Kubernetes (kế thừa `kubeval` đã ngừng phát triển) | ✅ |
| `conftest` / OPA | Policy tổ chức | ✅ |
| `gitleaks` | Chặn secret lọt repo | ✅ |
| `helm-unittest` | Unit test cho template chart | ⚠️ Có nhắc nhưng chưa đưa vào CI |
| **`trivy`** | Quét lỗ hổng image | ➕ **Thiếu** |
| **`kube-score`** | Phân tích best-practice manifest | ➕ **Thiếu** |
| **`Renovate`** | Tự động cập nhật phiên bản chart bên thứ ba | ➕ **Thiếu** |

### ➕ Renovate — đáng bổ sung nhất

> *"Renovate handles Helm chart versions while Flux handles image tags, and Renovate PRs should trigger the same validation CI as developer PRs."*

Repo của bạn đang ghim cứng: `argo-cd-8.6.4.tgz`, `gitlab-runner-0.84.1.tgz`, `kube-prometheus-stack`. Không có gì nhắc khi có bản vá bảo mật. Renovate sẽ tự mở MR nâng phiên bản, và MR đó chạy qua đúng bộ CI như MR của người.

Công sức: ~2 giờ cấu hình. Giá trị: cao.

---

## 10 — Cổng self-service cho lập trình viên

> ✅ **KHỚP** · 🟢 Red Hat + nhiều nguồn

### Backstage là lựa chọn mặc định của thị trường

> *"Backstage remains the dominant IDP portal framework in 2026... the default starting point for teams that want to build their own internal developer portal and own the roadmap."*
> — [Red Hat Developer](https://developers.redhat.com/articles/2025/06/25/how-implement-developer-self-service-backstage)

### Nhưng quan trọng hơn: pattern mà Backstage dùng chính là pattern trong plan

> *"Backstage's Software Templates (scaffolder) allows platform teams to define wizard-style templates in YAML that collect parameters from developers (service name, language, team owner) and execute a sequence of actions: fetching a repository skeleton, rendering it with the provided values, creating a repository, registering the component in the catalog, and **optionally opening a pull request**."*

Đây đúng là luồng mà `make new-service` làm: khuôn mẫu → render → mở PR. Nghĩa là **hướng đi đúng chuẩn ngành** — chỉ khác là bằng script thay vì bằng portal.

### Tự viết portal, dùng Backstage, hay không làm gì cả?

| | Không làm gì (script + ArgoCD UI) | Tự viết portal | Backstage |
|---|---|---|---|
| Công sức | **2 ngày** | 3,5 tuần | 2–3 tuần cấu hình |
| Phải nuôi thêm | Không | 1 app Node + token Git + SQLite | Backstage + Postgres |
| Xem trạng thái | ArgoCD UI (đã có sẵn) | Tự viết lại | Có plugin |
| Phù hợp 1 người | ✅ **Khuyến nghị** | Khi có người ngoài cần deploy | >10 đội |

**Quyết định: không xây portal.** ArgoCD UI đã có danh sách Application, sync/health, cây resource, log pod, diff và nút sync — tức là phần lớn thứ một portal tự viết sẽ làm lại. Khoảng trống thật duy nhất là bảng so tag dev ↔ prod, và đó là [một script 30 dòng](./OPERATIONS.md).

Thứ đáng mượn từ Backstage không phải phần mềm, mà là khái niệm **"golden path"**:

> *"A golden path is an opinionated, well-maintained workflow that encodes platform team best practices... A Golden Path isn't a mandate. It's the path of least resistance to doing the right thing."*

Nghĩa là khuôn mẫu của `make new-service` phải tạo ra thứ **đã đúng sẵn** — có resource limits, có probe, có ServiceMonitor, có khai báo secret. Làm đúng phải dễ hơn làm sai.

---

## 11 — Bảng tổng hợp tất cả phát hiện

| # | Phát hiện | Nhãn | Nguồn | Việc cần làm |
|---|---|---|---|---|
| 1 | Branch-per-environment là anti-pattern | ⚠️ LỆCH | 🟡 | **Bạn quyết định** — xem [Phần 1](#1--tách-môi-trường-branch-hay-thư-mục) |
| 2 | App-of-Apps + ApplicationSet dùng chung, không chọn một | ✅/➕ | 🟢 | Diễn đạt lại trong plan |
| 3 | Git file generator = pattern self-service chuẩn | ✅ | 🟡 | Không đổi |
| 4 | Progressive Sync cho nhiều cluster | ➕ | 🟡 | Ghi lại cho tương lai |
| 5 | Manual sync ở prod | ⚠️ LỆCH | 🟠 | **Bạn quyết định** — đề xuất `prune: false` |
| 6 | Sync window chặn deploy ngoài giờ | ➕ | 🟠 | Cân nhắc |
| 7 | Không lồng quá 4 cấp thư mục | ✅ | 🟡 | Đã đạt |
| 8 | Không trộn Helm + Kustomize | ✅ | 🟡 | Đã đạt |
| 9 | Sealed Secrets → ESO là lộ trình chuẩn | ✅ | 🟡 | Đã đúng |
| 10 | Kargo cho promotion nhiều môi trường | ➕ | 🟡 | Chưa cần (2 env), ghi vào plan |
| 11 | RBAC mặc định ArgoCD quá rộng | ✅ | 🟠 | Đã có AppProject |
| 12 | Tắt tài khoản `admin` mặc định | ➕ | 🟠 | 🔄 **v3 không làm** — giữ `admin`, bù bằng không-ingress-public + tailnet-only ([plan §8](./PLAN.md)) |
| 13 | NetworkPolicy cho ArgoCD | ➕ | 🟠 | Thêm vào Phase 3 |
| 14 | Backup namespace `argocd` | ➕ | 🟠 | 🔄 **v3 không cần** — ArgoCD không có PV, etcd snapshot đã phủ hết |
| 15 | Sync waves theo thứ tự phụ thuộc | ➕ | 🟠 | **Thêm vào Phase 2** (library chart) |
| 16 | local-path chỉ hợp dev; Longhorn cho prod | ✅ | 🟢 | 🔄 **v3 chốt không Longhorn** — bù bằng dump hằng giờ + [R4](./RECOVERY.md) đã diễn tập |
| 17 | `reclaimPolicy: Retain` cho prod | ✅ | 🟢 | Đã có |
| 18 | `helm-unittest` trong CI | ⚠️ | 🟠 | Đưa hẳn vào `.github/workflows/validate.yml` |
| 19 | `trivy` quét image | ➕ | 🟠 | Thêm vào Phase 0 |
| 20 | `kube-score` | ➕ | 🟠 | Tuỳ chọn |
| 21 | **Renovate tự nâng phiên bản chart** | ➕ | 🟠 | **Thêm vào Phase 0** — giá trị cao, công sức thấp |
| 22 | Backstage = chuẩn thị trường | ❌ **Bỏ** | 🟢 | Không xây portal — ArgoCD UI + script đã đủ |
| 23 | Khái niệm "golden path" | ➕ | 🟢 | Đưa vào thiết kế scaffold |

---

## 12 — Đề xuất bổ sung vào plan (nếu bạn đồng ý)

Sắp theo tỷ lệ **giá trị / công sức**:

| Ưu tiên | Việc | Công sức | Vào Phase |
|---|---|---|---|
| 🥇 | **Renovate** tự nâng phiên bản chart | 2 giờ | 0 |
| 🥇 | **Tắt tài khoản `admin`** mặc định của ArgoCD | 30 phút | 0 |
| 🥇 | **`trivy`** quét image trong CI | 1 giờ | 0 |
| 🥈 | **Sync waves** trong library chart | 2 giờ | 2 |
| 🥈 | **`helm-unittest`** đưa vào CI | 3 giờ | 2 |
| 🥈 | **Backup namespace `argocd`** vào Velero | 1 giờ | 4 |
| 🥉 | **`prune: false`** cho prod | 15 phút | 1 |
| 🥉 | **Sync window** chặn deploy ngoài giờ | 1 giờ | 3 |
| 🥉 | **NetworkPolicy** cho ArgoCD | 2 giờ | 3 |
| 🥉 | **`kube-score`** | 1 giờ | 0 |
| ⏳ | **Kargo** — khi có môi trường thứ ba | 1 tuần | Sau |

---

## Nguồn tham khảo

### Độ tin cậy cao 🟢

- [CNCF — Argo CD là giải pháp GitOps được áp dụng nhiều nhất](https://www.cncf.io/announcements/2025/07/24/cncf-end-user-survey-finds-argo-cd-as-majority-adopted-gitops-solution-for-kubernetes/)
- [Khảo sát người dùng Argo CD 2026](https://blog.argoproj.io/argo-cd-2026-user-survey-results-dcffc9a8e48e)
- [Tài liệu chính thức k3s — Volumes and Storage](https://docs.k3s.io/add-ons/storage)
- [Red Hat — Cấu trúc thư mục GitOps](https://developers.redhat.com/articles/2022/09/07/how-set-your-gitops-directory-structure)
- [Red Hat — Developer self-service với Backstage](https://developers.redhat.com/articles/2025/06/25/how-implement-developer-self-service-backstage)

### Độ tin cậy trung bình 🟡

- [Akuity — Kargo và bài toán promotion](https://akuity.io/blog/how-kargo-fixes-gitops-with-promotion) *(Akuity là công ty đứng sau ArgoCD)*
- [Akuity — Application Dependencies: 4 Patterns for 2026](https://akuity.io/blog/application-dependencies-with-argo-cd)
- [Kargo Docs — Patterns](https://docs.kargo.io/user-guide/patterns)
- [Stakater — GitOps Repository Structure](https://www.stakater.com/post/gitops-repository-structure/)
- [Cloudogu — GitOps Promotion Patterns (Part 4)](https://platform.cloudogu.com/en/blog/gitops-repository-patterns-part-4-promotion-patterns/)
- [Cloudogu — gitops-patterns (GitHub)](https://github.com/cloudogu/gitops-patterns)
- [DevOpsil — ArgoCD Application Patterns](https://devopsil.com/articles/2026-03-21-gitops-argocd-application-patterns)
- [Coding Protocols — App-of-Apps vs ApplicationSet](https://codingprotocols.com/blog/argocd-app-of-apps-vs-applicationset)
- [sanj.dev — Kubernetes Secrets Management 2026](https://sanj.dev/post/kubernetes-secrets-management-comparison/)
- [DevOpsBoys — SOPS vs Sealed Secrets vs ESO](https://devopsboys.com/blog/sops-vs-sealed-secrets-vs-external-secrets-gitops-2026)
- [DevOpsBoys — Kargo Review](https://devopsboys.com/blog/kargo-gitops-promotion-tool-review-2026)

### Tham khảo 🟠

- [Medium — Stop using branches for GitOps environments](https://medium.com/containers-101/stop-using-branches-for-deploying-to-different-gitops-environments-7111d0632402)
- [Platform Engineering — GitOps patterns và anti-patterns](https://platformengineering.org/blog/gitops-architecture-patterns-and-anti-patterns)
- [OneUptime — Git Branching Strategy for GitOps](https://oneuptime.com/blog/post/2026-02-26-argocd-git-branching-strategy-gitops/view)
- [OneUptime — Repository Structure Best Practices](https://oneuptime.com/blog/post/2026-02-26-argocd-best-practices-repository-structure/view)
- [OneUptime — Security Hardening](https://oneuptime.com/blog/post/2026-02-26-argocd-best-practices-security-hardening/view)
- [OneUptime — Enterprise Best Practices](https://oneuptime.com/blog/post/2026-02-26-argocd-best-practices-enterprise/view)
- [OneUptime — Git File Generator với YAML config](https://oneuptime.com/blog/post/2026-02-26-argocd-applicationset-git-file-yaml/view)
- [Alexandre Vazquez — Helm Chart Testing: 5 Layers](https://alexandre-vazquez.com/helm-chart-testing-best-practices/)
- [OneUptime — Renovate + GitOps dependency updates](https://oneuptime.com/blog/post/2026-03-13-gitops-dependency-update-renovate-flux/view)

> **Lưu ý về nguồn 🟠:** nhóm này gồm blog kỹ thuật và trang tổng hợp. Chúng phản ánh xu hướng phổ biến và thường nhất quán với nhau, nhưng không phải tài liệu chuẩn. Các khuyến nghị lấy từ nhóm này (manual sync prod, sync window, tắt tài khoản admin) nên được kiểm chứng lại trên tài liệu chính thức của Argo CD trước khi áp dụng vào production.
