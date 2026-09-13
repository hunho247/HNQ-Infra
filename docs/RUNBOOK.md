# Runbook

> Đang có sự cố và muốn quy trình đầy đủ → [RECOVERY.md](./RECOVERY.md).
> File này là **bước đầu tiên** cho từng triệu chứng, và **nhật ký** sự cố đã gặp.

Đây là tài liệu quan trọng nhất khi chỉ có 1 người vận hành. Không phải vì nội
dung kỹ thuật — mà vì **bạn sẽ không nhớ**. Sự cố gặp 4 tháng trước, lúc 2 giờ
sáng, bạn sẽ điều tra lại từ đầu, trừ khi lúc đó đã viết 5 dòng.

---

## ⚠️ Trạng thái bất thường đang bật

**Mục này phải trống khi mọi thứ bình thường.** Mỗi lần tắt một cơ chế an toàn
— `automated` của ArgoCD, `scale 0` môi trường dev, cắm tay một Ingress — ghi
một dòng vào đây **ngay lúc làm**, không phải lúc xong việc.

Không ghi thì rủi ro không phải là quên bật lại trong hôm nay. Rủi ro là ba
tuần sau phát hiện dev vẫn đang tắt, và không ai nhớ vì sao.

| Từ ngày | Cái gì đang tắt / khác thường | Vì sao | Bật lại bằng |
|---|---|---|---|
| _(trống)_ | | | |

<details>
<summary>Mẫu một dòng</summary>

| 2026-09-20 14:30 | `automated` của mọi app `*-dev` đang tắt, dev `scale 0` | R4 — dời prod sang hnq-03 | `kubectl -n argocd patch app <tên> --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}'` rồi `scale` lại |

</details>

---

## Bước đầu tiên theo triệu chứng

| Triệu chứng | Bước đầu tiên |
|---|---|
| Pod `CrashLoopBackOff` | `make logs SVC=x ENV=y` → `kubectl describe pod` phần Events |
| Pod `Pending` mãi | `kubectl describe pod` → hết tài nguyên, hoặc PV không gắn được node |
| ArgoCD `OutOfSync` không tự hết | [R2](./RECOVERY.md#r2--cluster-lệch-khỏi-git) |
| Ingress 404 / 502 | Service có endpoint không → `kubectl get endpointslice -n <ns>` |
| Chứng chỉ không cấp được | `kubectl describe certificate` → DNS chưa trỏ, hoặc rate limit LE |
| Node `NotReady` | ⚠️ **Máy sống hay chết?** Sống → [R9](./RECOVERY.md#r9--tailnet-sự-cố), **không** `delete node`. Chết → [R4](./RECOVERY.md#r4--node-prod-chết) / [R3](./RECOVERY.md#r3--node-dev-chết) |
| Đĩa đầy | [R10](./RECOVERY.md#r10--đĩa-đầy) |
| `kubectl` timeout | [R5](./RECOVERY.md#r5--etcd-hỏng-hoặc-apiserver-không-lên) — kiểm trước: khách hàng có bị ảnh hưởng không? Thường là **không** |
| **Request nhỏ chạy, request lớn / TLS treo** | **MTU pod network qua Tailscale** — xem mục riêng bên dưới |
| Pod `Pending` với `volume node affinity conflict` | PVC bind vào PV trên node khác. Sau [R4](./RECOVERY.md#r4--node-prod-chết) là đúng dự kiến; ngoài ra là `nodeSelector` sai |
| Agent không join lại sau restore etcd | `Node password rejected` → [R5 bước 3](./RECOVERY.md#r5--etcd-hỏng-hoặc-apiserver-không-lên) |
| Pod chạy nhưng dùng mật khẩu cũ sau khi đổi Secret | `kubectl rollout restart` — xem mục riêng bên dưới |
| SealedSecret không giải mã được | Controller từ chối vì **namespace hoặc tên** đã đổi — xem `secrets/README.md`. Log nằm ở controller, không ở Application |

Bốn dòng in đậm ở trên là **đặc trưng của topology 3 node qua Tailscale**.
Không có trong runbook mẫu nào trên mạng, và đều là loại sự cố mất hàng giờ nếu
gặp lần đầu mà không biết trước.

---

## Ba cái bẫy đáng đọc trước khi gặp

### 1. MTU — triệu chứng không giống lỗi mạng

`tailscale0` có MTU 1280, flannel vxlan chạy trên đó còn ~1230. Nếu MTU sai:
request nhỏ chạy bình thường, request lớn hoặc TLS handshake **treo vô thời
hạn**. Bạn sẽ đi tìm bug ở tầng ứng dụng trước, và mất vài giờ ở đó.

```bash
ssh hnq-02 'cat /run/flannel/subnet.env'        # FLANNEL_MTU phải ~1230
kubectl run nettest --image=nicolaka/netshoot -it --rm -- \
  sh -c 'ping -M do -s 1400 <IP pod node khác>; ping -M do -s 1180 <IP pod node khác>'
# ĐÚNG: -s 1400 báo "message too long", -s 1180 chạy được.
# SAI:  -s 1400 cũng chạy → MTU sai.
```

### 2. Đổi Secret mà pod không restart

Kubernetes **không** tự restart pod khi Secret đổi. Pod cũ giữ giá trị cũ cho
tới lần restart tiếp theo — log chỉ nói "access denied", không nói vì sao.

```bash
kubectl -n <service>-<env> rollout restart deploy/<service>
```

Chart đã gắn `checksum/config` cho ConfigMap nên đổi **cấu hình** thì pod tự
restart. Secret thì không — đó là chỗ khác nhau dễ quên.

### 3. `scale --replicas=0` một mình không đủ

`selfHeal` của ArgoCD kéo lại sau ≤ 3 phút. Muốn dừng thật thì tắt `automated`
**trước**, rồi mới scale — và ghi ngay một dòng vào mục "Trạng thái bất thường
đang bật" ở đầu file này.

---

## Nhật ký sự cố

Mới nhất ở trên. Năm dòng, viết ngay lúc còn nhớ, quan trọng hơn một bài viết
đầy đủ viết ba ngày sau.

Bốn trường bắt buộc — thiếu **Phòng ngừa** thì lần sau gặp lại y hệt:

```markdown
## YYYY-MM-DD — <một dòng mô tả>
**Triệu chứng:**
**Nguyên nhân:**
**Xử lý:**
**Phòng ngừa:**
**Thời gian:** ... phút
```

<details>
<summary>Ví dụ (chưa xảy ra — để đây làm mẫu, xoá khi có mục thật đầu tiên)</summary>

## 2026-09-20 — Pod backend CrashLoopBackOff sau khi đổi secret

**Triệu chứng:** `lotus-clinic-prod` restart liên tục, log `access denied for user`
**Nguyên nhân:** đổi `DB_PASSWORD` trong SealedSecret nhưng pod chưa restart → vẫn dùng giá trị cũ
**Xử lý:** `kubectl -n lotus-clinic-prod rollout restart deploy/lotus-clinic`
**Phòng ngừa:** Secret không có checksum như ConfigMap — thêm bước "rollout restart" vào quy trình đổi secret
**Thời gian:** 25 phút

</details>

---

## Break-glass đã dùng lần nào chưa

Branch protection cho phép admin bypass — đó là đường thoát hiểm khi CI hỏng mà
prod đang cần vá. **Mỗi lần dùng ghi một dòng ở đây.** Dòng thứ ba xuất hiện
nghĩa là CI đang cản trở chứ không còn bảo vệ, và phải sửa CI.

| Ngày | Bypass cái gì | Vì sao không đợi CI được | Sau đó đã sửa gì |
|---|---|---|---|
| _(trống)_ | | | |
