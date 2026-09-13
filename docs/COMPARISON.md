# So sánh hạ tầng HNQ với các hệ thống tương tự của cộng đồng

> **Tài liệu tra cứu, không phải quyết định.** Quyết định đang có hiệu lực luôn
> đọc ở [PLAN §1](./PLAN.md#1-bảng-quyết-định-đã-chốt).
>
> Khác với [RESEARCH_BEST_PRACTICES.md](./RESEARCH_BEST_PRACTICES.md): file đó so
> hạ tầng này với **khuyến nghị** của cộng đồng. File này so với **hệ thống thật**
> mà cộng đồng đang chạy và công khai mã nguồn.
>
> Ngày tra cứu: **13/09/2026**. Mô tả hệ quy chiếu lấy từ README/tài liệu công khai
> của chính dự án tại thời điểm đó — các dự án này thay đổi nhanh, đọc lại nguồn ở
> [cuối trang](#nguồn) trước khi dùng làm căn cứ.

---

## 0. Năm hệ quy chiếu

| Ký hiệu | Hệ thống | Quy mô điển hình | Vì sao chọn làm mốc |
|---|---|---|---|
| **A** | [`onedr0p/cluster-template`](https://github.com/onedr0p/cluster-template) + [`home-ops`](https://github.com/onedr0p/home-ops) | 1–6 node cùng LAN | Bản mẫu homelab GitOps được nhân bản nhiều nhất hiện nay (Talos + Flux) |
| **B** | [`techno-tim/k3s-ansible`](https://github.com/techno-tim/k3s-ansible) | 3–6 node cùng LAN | Cách dựng **k3s HA** phổ biến nhất trong giới homelab |
| **C** | [`khuedoan/homelab`](https://github.com/khuedoan/homelab) (9.6k ★) | 3+ node cùng LAN | Cùng chọn **k3s + ArgoCD** như HNQ — hệ quy chiếu gần nhất về công cụ |
| **D** | Platform team doanh nghiệp: ArgoCD + ApplicationSet + [Kargo](https://akuity.io/guides/continuous-promotion-with-kargo) + ESO | chục–trăm node, nhiều cluster | Đích đến nếu hệ thống này lớn lên |
| **E** | Mặc định [tài liệu k3s/Rancher](https://docs.k3s.io/networking/distributed-multicloud) | 1–n node | "Không quyết gì cả thì được cái gì" — mốc để thấy HNQ đã đi lệch chỗ nào |

Cột **HNQ** dưới đây = hệ thống mô tả trong [PLAN.md](./PLAN.md) (đích đến), không phải
cây `infra/` cũ trong [LEGACY_LAYOUT.md](./LEGACY_LAYOUT.md).

---

## 1. Nền tảng và topology

| Hạng mục | **HNQ** | A · onedr0p | B · techno-tim | C · khuedoan | D · doanh nghiệp | E · mặc định k3s |
|---|---|---|---|---|---|---|
| Distro | k3s | **Talos** | k3s | k3s | EKS/GKE/RKE2 | k3s |
| Số node | 3 | 1–6 | 3–6 | 3+ | chục–trăm | 1–n |
| Control-plane | **1 server, không HA** | 1 hoặc 3 | **3 server + kube-vip VIP** | 3 server | managed HA | 1 hoặc 3 (embedded etcd) |
| Vị trí node | ⭐ **2 nơi, nối qua WAN** | một nhà | một nhà | một nhà | một/nhiều vùng cloud | "server nên ở **cùng một nơi**" |
| Workload trên master | ⭐ **Cấm bằng taint** | thường có | thường có | thường có | không (managed) | cho phép |
| Cách dựng node | Tay, theo mẫu `nodes/*.yaml` | talhelper (khai báo) | Ansible playbook | **PXE + Ansible, "một lệnh"** | Terraform/IaC | `install.sh` |
| Dựng lại 1 node mất | ~30 phút, có checklist | vài phút | vài phút | vài phút | tự động | — |

Hai dòng ⭐ là chỗ HNQ đứng một mình. Tài liệu k3s nói thẳng: **agent** được phép
rải nhiều mạng, nhưng **server nên ở cùng một chỗ**. HNQ có 1 server nên không
vi phạm chữ, nhưng vẫn đi ngược tinh thần: control-plane cách 2 node còn lại một
đường internet.

---

## 2. Mạng và đường vào

| Hạng mục | **HNQ** | A · onedr0p | B · techno-tim | C · khuedoan | D · doanh nghiệp | E · mặc định k3s |
|---|---|---|---|---|---|---|
| CNI | ⭐ flannel **chạy trên `tailscale0`** | Cilium (eBPF) | flannel | Cilium | Cilium / VPC CNI | flannel (host NIC) |
| Vào cluster | **Cloudflare Tunnel ×2 in-cluster** | cloudflared | **MetalLB + kube-vip** | NGINX + ExternalDNS | Cloud LB + WAF | **ServiceLB** |
| Ingress controller | Traefik ×2, `ClusterIP` | envoy-gateway | Traefik / NGINX | NGINX | NGINX / Istio / Gateway API | Traefik `LoadBalancer` |
| Port mở ra internet | ⭐ **0** | 0 | 80/443 forward | 80/443 forward | LB công khai | 80/443 |
| TLS | cert-manager DNS-01, wildcard mỗi env | cert-manager DNS-01 | cert-manager | cert-manager | ACM / cert-manager | tự lo |
| Bản ghi DNS | **sửa tay ở Cloudflare** | external-dns tự đồng bộ | tay | external-dns | external-dns | tay |
| Truy cập quản trị | Tailscale + kubeconfig, ⭐ **không** Tailscale Operator | Tailscale/VPN | LAN/VPN | Tailscale/Wireguard | SSO + bastion + audit log | tuỳ |

**Chỗ đắt nhất của HNQ nằm ở dòng đầu.** Đặt `flannel-iface: tailscale0` nghĩa là
gói tin đi qua VXLAN lồng trong WireGuard — hai lớp đóng gói, MTU tụt xuống ~1230.
Cộng đồng tách đôi: Tailscale **chỉ** cho quản trị, còn dữ liệu pod đi qua NIC thật.
HNQ chấp nhận cái giá này để đổi lấy một thứ mà cách tách đôi không cho: node ở
nhà, sau NAT, không cần IP tĩnh hay port forward vẫn join được cluster.

Hệ quả đã được ghi nhận và có quy trình riêng: MTU sai là lỗi hay gặp nhất lúc dựng
([OPERATIONS §4](./OPERATIONS.md)), và tailnet trở thành một phụ thuộc ngoài phải có
kịch bản sự cố ([RECOVERY R9](./RECOVERY.md)).

---

## 3. GitOps và cách khai báo service

| Hạng mục | **HNQ** | A · onedr0p | B · techno-tim | C · khuedoan | D · doanh nghiệp |
|---|---|---|---|---|---|
| Công cụ | ArgoCD | **Flux** | không bắt buộc | ArgoCD | ArgoCD (+ Kargo) |
| Thêm 1 service = | ⭐ **1 thư mục `registry/apps/<svc>/`** (3–4 file) | 1 thư mục Kustomization + HelmRelease | — | 1 thư mục app | 1 thư mục + 1 Kargo Stage |
| Sinh `Application` | **ApplicationSet** (git-file generator) + 8 App tường minh | Kustomization lồng nhau | — | app-of-apps | ApplicationSet + app-of-apps |
| Chart | ⭐ **1 library + 2 chart tự viết** (`webservice`, `datastore`) | `bjw-s/app-template` dùng chung | — | Helm upstream | chart nội bộ |
| Tách môi trường | **1 branch + thư mục + `values-<env>.yaml`** | thường chỉ 1 env (prod) | — | 1 env | nhiều cluster |
| Promote dev→prod | ⭐ `make promote` — **3 cửa kiểm trạng thái live** | Renovate bump, phần lớn auto | — | tay | Kargo |
| Sync ở prod | ⭐ auto + `selfHeal`, **`prune: false`** | auto + prune | — | auto | thường có cửa duyệt |
| Kiểm khai báo | ⭐ **JSON Schema + `values.schema.json` + 9 rule conftest** | schema của chart | — | — | OPA/Kyverno |
| Quay lui | Image tag = git SHA, `Retain`, revert 1 commit | revert commit | — | revert commit | Kargo rollback / Rollouts |

Ba dòng ⭐ đầu là thứ khiến HNQ giống **một IDP thu nhỏ** hơn là một homelab: có
lược đồ (schema) cho khai báo service, có sinh tự động, có generator, có cửa kiểm.
Cái mà D làm bằng Backstage + Kargo + Kyverno, HNQ làm bằng ~200 dòng bash + rego.

Dòng `prune: false` ở prod là một lựa chọn hiếm: A prune, D thường prune. HNQ chấp
nhận rác tồn lại ở prod để đổi lấy việc **một generator hỏng không thể xoá dữ liệu
khách hàng** — cùng logic với `applicationsSync: create-update` (D15).

---

## 4. Secret · lưu trữ · backup

| Hạng mục | **HNQ** | A · onedr0p | B · techno-tim | C · khuedoan | D · doanh nghiệp | E · mặc định k3s |
|---|---|---|---|---|---|---|
| Secret | **Sealed Secrets** | **SOPS + age** | tự lo | SOPS/Vault | **ESO** + Vault/KMS | tự lo |
| Mã hoá Secret trong etcd | ⭐ **bật** (`secrets-encryption`) | Talos mã hoá đĩa sẵn | thường không | thường không | luôn có (KMS) | **tắt** |
| StorageClass | local-path **tự quản**, `volumeType: local`, `Retain` | local-path / Rook | **Longhorn** | **Rook Ceph** | CSI cloud | local-path (hostPath) |
| Dữ liệu nhân bản giữa node | ⭐ **Không** — cố ý | thường không | 2–3 bản (Longhorn) | 3 bản (Ceph) | CSI / cloud | không |
| Backup trạng thái k8s | etcd snapshot 6h → R2 | dựng lại từ Git | etcd snapshot | etcd snapshot | Velero + managed | etcd snapshot (tắt mặc định) |
| Backup dữ liệu | Velero FSB (kopia) + ⭐ **dump DB hằng giờ** | Velero / VolSync | Longhorn → S3 | Ceph / Velero | Velero + CSI snapshot | tự lo |
| Khoá để phục hồi | ⭐ **Recovery kit 4 món, `make kit-check` hằng tháng** | age key trong password manager | — | — | KMS + IAM | — |
| RPO/RTO thành số | ⭐ **Có bảng, có diễn tập bấm giờ** | hiếm khi viết ra | hiếm | hiếm | có (SLA) | — |

Đây là nhóm HNQ **vượt** hệ quy chiếu homelab rõ nhất, và lý do rất đơn giản: A, B,
C chạy Plex và Home Assistant, hỏng thì mất buổi tối; HNQ chạy phòng khám của khách
hàng, hỏng thì mất dữ liệu bệnh nhân.

Đổi lại, HNQ **chọn thua** ở dòng "nhân bản giữa node". B và C bỏ tiền mua độ sẵn
sàng bằng Longhorn/Ceph; HNQ bỏ tiền mua **khả năng phục hồi** bằng dump hằng giờ +
diễn tập. Với 1 người vận hành thì lập luận là: Ceph hỏng lúc 2 giờ sáng khó sửa hơn
`mysqldump` mất 1 giờ dữ liệu.

**Món thứ 4 của recovery kit — `encryption-config.json` — là chỗ gần như không hệ
thống cộng đồng nào nhắc tới.** Bật `secrets-encryption` mà không cất file này thì
restore xong cluster lên bình thường nhưng không đọc được một Secret nào.

---

## 5. CI, policy, giám sát, nâng cấp

| Hạng mục | **HNQ** | A · onedr0p | B · techno-tim | C · khuedoan | D · doanh nghiệp |
|---|---|---|---|---|---|
| Cửa CI trên mỗi PR | ⭐ 8 bước: yamllint → schema → helm lint/unittest → check-secrets → render-all → kubeconform → conftest → gitleaks/trivy | kubeconform + flux diff | molecule/CI của Ansible | Woodpecker CI | tương đương + SBOM/cosign |
| Policy-as-code | ⭐ **conftest/rego, 9 rule chặn merge** | hiếm | không | không | OPA / Kyverno / Gatekeeper |
| Unit test cho chart | ⭐ **helm-unittest bắt buộc** | ít gặp | — | — | có ở đội lớn |
| Renovate | có, pin version tuyệt đối | **có — đặc trưng của A** | — | có | có |
| Số approval trên PR | ⭐ **0** (CI là cửa duyệt duy nhất) | 0 (repo cá nhân) | 0 | 0 | ≥1, bắt buộc |
| Giám sát | kube-prometheus-stack, ⭐ **chỉ 8 alert, tắt hết phần còn lại** | Prom + Grafana, alert mặc định | Prom/Grafana | Prom + Grafana + Loki | Prom/Datadog + SLO |
| Dead man's switch | ⭐ **Có** (Watchdog → healthchecks.io) | hiếm | hiếm | hiếm | có (→ PagerDuty) |
| Progressive delivery | **không** | không | không | không | Argo Rollouts (**63%** người dùng Argo CD) |
| Nâng k3s/OS | system-upgrade-controller, `concurrency: 1` | Talos upgrade + Renovate | chạy lại playbook | chạy lại | rolling node pool |
| Tài liệu sự cố | ⭐ **R1–R10 + BREAK_GLASS + nhật ký** | README | README | trang docs | runbook nội bộ |

"Chỉ 8 alert" là một quyết định đi ngược cả 5 hệ quy chiếu. Cộng đồng cài
kube-prometheus-stack rồi để nguyên vài trăm rule mặc định — kết quả là alert bị
ngó lơ sau hai tuần. HNQ tắt hết, giữ 8 cái, **mỗi cái bắt buộc có trường `action`**.
Với 1 người trực thì một alert bị bỏ qua tệ hơn một alert không tồn tại.

---

## 6. Chín điểm HNQ thật sự khác

| # | Điểm khác | Cộng đồng làm gì | HNQ làm gì | Đổi được gì / mất gì |
|---|---|---|---|---|
| 1 | **Cluster trải qua WAN** | Node cùng một LAN | VPS + 2 máy nhà nối qua Tailscale | ➕ Không cần IP tĩnh, không mở port, dùng được máy sẵn có ➖ Băng thông pod-to-pod tụt, thêm phụ thuộc tailnet |
| 2 | **Đường dữ liệu sống độc lập control-plane** | Master chết = cả cluster đứng | Taint master + Traefik/cloudflared/CoreDNS ×2 **ở máy nhà** | ➕ `systemctl stop k3s` trên master mà khách hàng vẫn 200 ➖ Master thành "máy chỉ để đổi cấu hình", tốn 1 VPS |
| 3 | **Tắt 2 add-on mặc định của k3s** | Giữ ServiceLB + local-storage | `disable: servicelb, local-storage`, tự quản local-path | ➕ Velero backup được PV (hostPath thì không), master không cấp volume ➖ Thêm 1 chart phải tự bảo trì |
| 4 | **Thêm service = sửa một thư mục** | Chép thư mục app cũ rồi sửa tay | `make new-service` → `registry/apps/<svc>/` → ApplicationSet tự sinh | ➕ Không ai chạm file ArgoCD; sai lược đồ là CI chặn ➖ Generator tự viết, không Google được khi hỏng |
| 5 | **Recovery kit 4 món** | age/SOPS key là hết | snapshot · token · sealing key · `encryption-config.json`, `kit-check` hằng tháng | ➕ Bịt đúng 2 chỗ hay chết người: thiếu token / thiếu encryption config ➖ Một việc thủ công hằng tháng |
| 6 | **Tám alert + dead man's switch** | Bật alert mặc định rồi bỏ qua | Tắt hết, giữ 8, mỗi cái có `action`, thiếu ping 12 phút thì báo | ➕ Alert nào kêu cũng đáng dậy ➖ Có loại sự cố không ai báo |
| 7 | **Cố ý đi ngược 7 best practice** | SSO, ≥1 approval, manual sync ở prod, HA, Longhorn, Kargo, replica 2 | Giữ `admin`, 0 approval, auto-sync prod, 1 server, 1 replica app | ➕ Ít thứ phải sống thì mới đăng nhập/sửa được lúc sự cố ➖ Mọi lập luận sụp đổ ngay khi có người vận hành thứ hai |
| 8 | **Sealed Secrets + mã hoá etcd** | SOPS/age (homelab) hoặc ESO (doanh nghiệp) | Sealed Secrets trong Git + `secrets-encryption: true` | ➕ Không cần hệ thống secret ngoài; snapshot rời máy vẫn an toàn ➖ Xoay key phải nhớ backup lại hằng quý |
| 9 | **Policy-as-code ở quy mô 3 node** | Không có ở homelab; có ở doanh nghiệp | 9 rule rego chặn merge (cấm `latest`, bắt `resources`, chặn lách taint…) | ➕ Sai quy ước bị chặn trước khi vào `main` ➖ Thêm một lớp phải sửa mỗi khi đổi quy ước |

---

## 7. Chỗ HNQ đi sau cộng đồng

Liệt kê để biết mình đang nợ gì, không phải để sửa ngay.

| Rủi ro | Ai làm tốt hơn | Hệ quả thật | Đang bù bằng | Còn hở |
|---|---|---|---|---|
| apiserver là điểm hỏng đơn | B (3 server + kube-vip), D | Master chết → không deploy/sửa được gì | Đường dữ liệu vẫn sống (điểm 2); [R5](./RECOVERY.md), [R6](./RECOVERY.md) có bấm giờ | 10–45 phút không thay đổi được cấu hình |
| Đóng gói hai lớp trên tailnet | A, C (Cilium trên NIC thật) | Băng thông thấp, MTU 1230, TLS handshake treo nếu MTU sai | Bước kiểm MTU bắt buộc lúc dựng | Không đo throughput thường xuyên |
| 1 replica cho app prod | B, C, D | Mỗi lần deploy có vài giây gián đoạn | Deploy ngoài giờ, rollback 1 commit | Không có rolling thật, không Rollouts |
| Dữ liệu không nhân bản | B (Longhorn), C (Ceph) | Node prod chết → mất tối đa 1 giờ + thao tác tay | Dump hằng giờ + [R4](./RECOVERY.md) diễn tập | RPO 1 giờ là sàn cứng |
| Không NetworkPolicy | A, C (Cilium), D | Pod namespace này gọi thẳng DB namespace khác được | AppProject chặn ở lớp ArgoCD | Không có gì chặn ở lớp mạng |
| Không SSO / audit theo người | D | Không biết ai làm gì trong cluster | 1 người vận hành nên không cần | Sập ngay khi có người thứ hai |
| Không cache image trong cluster | A (spegel) | Mọi pull đi qua WAN tới ghcr | Không có | Nghẽn lúc dựng lại hàng loạt |
| DNS sửa tay | A, C (external-dns) | Thêm service phải nhớ thêm bản ghi | Checklist | Dễ lệch giữa Git và Cloudflare |
| Sinh Application tự viết | A (Flux chuẩn), D | Hỏng thì không có câu trả lời trên mạng | `render-all.sh` bắt lỗi trước | Bus factor = 1 |
| Không progressive delivery | D (63% dùng Rollouts) | Lỗi chỉ lộ ra sau khi 100% traffic đã vào | Dev chạy ≥30 phút mới cho promote | Không có canary thật |

---

## 8. Khi nào nên quay về hướng cộng đồng

| Ngưỡng kích hoạt | Đổi cái gì | Theo hướng của |
|---|---|---|
| Có máy thứ 4 **cùng LAN** với 2 máy nhà | Chuyển control-plane về nhà, xét HA 3 server, xét Longhorn | B, E |
| Có **người vận hành thứ hai** | SSO/Dex · `require approvals ≥ 1` · chuyển sang ESO | D |
| Có **môi trường thứ ba** (staging) | Kargo — giá trị của nó bắt đầu từ 3 stage | D |
| Quá **20 service** | Progressive Sync · cổng self-service | D |
| DB prod lớn hơn vài chục GB **hoặc** cần RPO < 1 giờ | Operator có WAL archiving (CloudNativePG) thay `datastore` chart | D |
| Bắt đầu chạy workload của bên thứ ba | NetworkPolicy (Cilium) · quota theo namespace | A, D |
| Băng thông pod-to-pod thành nút thắt | Tách Tailscale khỏi đường dữ liệu, flannel về NIC thật | A |

Sáu dòng đầu **đã nằm trong [PLAN D25](./PLAN.md#1-bảng-quyết-định-đã-chốt)** ("không
làm trong v1") — bảng này chỉ ghi rõ *cái gì kích hoạt việc xét lại*.

---

## 9. Một câu tổng kết

> Homelab của cộng đồng tối ưu cho **MTBF** — dựng thật nhiều lớp dự phòng để hỏng
> ít đi. HNQ tối ưu cho **MTTR** — chấp nhận hỏng, nhưng mọi đường hỏng đều có
> quy trình đã bấm giờ, và đường dữ liệu của khách hàng không nằm trên đường hỏng đó.

Hệ quả: HNQ **nghèo hơn** hệ quy chiếu ở lớp hạ tầng (không HA, không storage phân
tán, 1 replica) và **giàu hơn** rõ rệt ở lớp quy trình (policy-as-code, recovery kit,
RPO/RTO có số, diễn tập, runbook 10 kịch bản). Đó là đánh đổi đúng cho **1 người vận
hành chạy hệ thống có khách hàng thật** — và là đánh đổi sai ngay khi một trong hai vế
đó thay đổi.

---

## Nguồn

| Nguồn | Dùng cho |
|---|---|
| [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template) · [home-ops](https://github.com/onedr0p/home-ops) · [Home Operations docs](https://onedr0p.github.io/home-ops/) | Hệ quy chiếu A — Talos, Flux, Cilium, cloudflared, SOPS, spegel, external-dns |
| [techno-tim/k3s-ansible](https://github.com/techno-tim/k3s-ansible) · [Techno Tim, k3s etcd HA](https://technotim.com/posts/k3s-etcd-ansible/) | Hệ quy chiếu B — k3s HA, kube-vip, MetalLB, Longhorn |
| [khuedoan/homelab](https://github.com/khuedoan/homelab) | Hệ quy chiếu C — k3s + ArgoCD, PXE, Rook Ceph, Woodpecker |
| [Akuity — Continuous Promotion with Kargo](https://akuity.io/guides/continuous-promotion-with-kargo) · [Argo CD Application Dependencies](https://akuity.io/blog/application-dependencies-with-argo-cd) | Hệ quy chiếu D — promotion, ApplicationSet, Progressive Sync |
| [Khảo sát người dùng Argo CD](https://blog.argoproj.io/argo-cd-2026-user-survey-results-dcffc9a8e48e) | Số liệu app-of-apps ~82%, Argo Rollouts 63% |
| [k3s — Distributed hybrid or multicloud cluster](https://docs.k3s.io/networking/distributed-multicloud) · [Basic Network Options](https://docs.k3s.io/networking/basic-network-options) | "Server nên ở cùng một nơi", tích hợp Tailscale, `flannel-iface` |
| [Tailscale + k3s: chỉ dùng Tailscale cho control plane](https://dev.to/hellomichka_78vls/tailscale-k3s-in-a-2-node-homelab-why-i-use-tailscale-only-for-the-control-plane-1khj) · [k3s#8372](https://github.com/k3s-io/k3s/issues/8372) | Đóng gói hai lớp, MTU, cách cộng đồng tách Tailscale khỏi đường dữ liệu |
| [RESEARCH_BEST_PRACTICES.md](./RESEARCH_BEST_PRACTICES.md) | Khuyến nghị cộng đồng (khác với *hệ thống thật* so ở đây) |
