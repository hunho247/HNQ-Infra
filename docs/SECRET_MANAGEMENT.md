# Quản lý Secret

| | |
|---|---|
| **Trạng thái** | Bản nháp, chờ duyệt |
| **Ngày** | 12/09/2026 |
| **Bối cảnh** | Hệ thống mới, **1 người vận hành**, repo GitHub, 1 branch `main` |
| **Liên quan** | [REFACTOR_PLAN.md](./REFACTOR_PLAN.md) · [K3S_OPERATIONS.md](./K3S_OPERATIONS.md) · [DISASTER_RECOVERY.md](./DISASTER_RECOVERY.md) |

---

## Tóm tắt

**Sealed Secrets.** Secret được mã hoá bằng public key của controller trước khi commit. Chỉ controller trong cluster giải mã được. File mã hoá an toàn để đẩy lên GitHub, kể cả repo public.

Với 1 người vận hành có quyền vào cluster, quy trình gọn nhất là **dùng `kubeseal` ở máy mình** — bản rõ không đi qua hệ thống nào khác. Không cần backend, không cần UI, không có bề mặt tấn công mới.

Không có UI quản lý secret, và đó là quyết định có chủ ý: thêm một đường cho secret đi qua là thêm một chỗ có thể rò rỉ, đổi lại tiện lợi mà 1 người không thật sự cần.

> ⚠️ **Sealing key là món #3 của [recovery kit](./DISASTER_RECOVERY.md#2-recovery-kit--ba-thứ-phải-luôn-có).** Mất nó thì mọi file trong `secrets/` thành vô nghĩa và phải tạo lại **toàn bộ** secret bằng tay. Với 1 người, đây là một trong hai rủi ro 🔴 cao nhất của cả hệ thống.

---

## Mục lục

- [1. Sealed Secrets hoạt động thế nào](#1-sealed-secrets-hoạt-động-thế-nào)
- [2. Quy trình hằng ngày](#2-quy-trình-hằng-ngày)
- [3. Sao lưu sealing key](#3-sao-lưu-sealing-key--phần-quan-trọng-nhất)
- [4. Khai báo secret trong registry](#4-khai-báo-secret-trong-registry)
- [5. Xoay vòng secret](#5-xoay-vòng-secret)
- [6. Khi nghi ngờ bị lộ](#6-khi-nghi-ngờ-bị-lộ)
- [7. Danh sách kiểm tra](#7-danh-sách-kiểm-tra)

---

## 1. Sealed Secrets hoạt động thế nào

```mermaid
flowchart LR
  subgraph M["Máy của bạn"]
    P["Secret bản rõ"]
    K["kubeseal"]
    SS["SealedSecret<br/>đã mã hoá"]
  end

  subgraph C["Trong cluster"]
    PUB["🔓 Public key<br/>(công khai)"]
    CTRL["sealed-secrets<br/>controller"]
    PRIV["🔑 Private key<br/>không bao giờ rời cluster"]
    SEC["Secret<br/>Kubernetes"]
  end

  GH[(GitHub)]

  P --> K --> SS
  PUB -.->|kubeseal lấy về| K
  SS -->|commit| GH
  GH -->|ArgoCD sync| CTRL
  PRIV -.-> CTRL
  CTRL --> SEC
```

Mã hoá chỉ cần **public key**, mà public key thì không phải bí mật — controller công khai nó. Giải mã cần private key, và key đó không bao giờ rời cluster.

### Phạm vi (scope) — chi tiết bảo mật quan trọng

Mỗi giá trị được mã hoá kèm một "nhãn" quyết định nó dùng được ở đâu:

| Phạm vi | Nhãn | Nghĩa |
|---|---|---|
| **`strict`** (mặc định) | `<namespace>/<tên secret>` | Chỉ giải mã được đúng namespace đó, đúng tên đó |
| `namespace-wide` | `<namespace>` | Đổi tên được, không đổi namespace |
| `cluster-wide` | `""` | Dùng ở đâu cũng được |

> **Quy định:** hệ thống chỉ dùng `strict` — cũng là mặc định của `kubeseal`, nên chỉ cần **không thêm cờ nào**. Nhờ đó nếu ai lấy được file secret của prod, họ vẫn không thể áp nó vào namespace dev để đọc giá trị.

---

## 2. Quy trình hằng ngày

### Tạo secret mới

```bash
kubectl create secret generic lotus-clinic-backend \
  --namespace lotus-clinic-prod \
  --from-literal=DB_PASSWORD='...' \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml \
| kubeseal --format yaml > secrets/prod/lotus-clinic/backend.yaml

git add secrets/prod/lotus-clinic/backend.yaml    # ✅ an toàn, đã mã hoá
```

Bản rõ chỉ tồn tại trong đường ống lệnh, không ghi ra file bao giờ.

### Từ file (keystore, certificate, service-account JSON)

```bash
kubectl create secret generic lotus-clinic-keystore \
  --namespace lotus-clinic-prod \
  --from-file=keystore.jks=/đường/dẫn/keystore.jks \
  --dry-run=client -o yaml \
| kubeseal --format yaml > secrets/prod/lotus-clinic/keystore.yaml
```

### Script gói lại cho gọn

```bash
#!/usr/bin/env bash
# ci/scripts/seal-secret.sh <service> <env> <KEY>
# Đọc giá trị từ stdin, không hiện trên màn hình, không vào ~/.bash_history
set -euo pipefail
SVC="$1"; ENV="$2"; KEY="$3"
OUT="secrets/$ENV/$SVC/$(echo "$KEY" | tr 'A-Z_' 'a-z-').yaml"

read -rsp "Giá trị cho $KEY: " VALUE; echo
mkdir -p "$(dirname "$OUT")"

kubectl create secret generic "$SVC" \
  --namespace "$SVC-$ENV" \
  --from-literal="$KEY=$VALUE" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --merge-into "$OUT" 2>/dev/null \
  || kubectl create secret generic "$SVC" \
       --namespace "$SVC-$ENV" --from-literal="$KEY=$VALUE" \
       --dry-run=client -o yaml | kubeseal --format yaml > "$OUT"

unset VALUE
echo "✅ $OUT — commit được rồi"
```

Dùng: `make secret SVC=lotus-clinic ENV=prod KEY=DB_PASSWORD`

> `--merge-into` cho phép thêm key vào file đã có mà không phải nhập lại các key cũ — rất tiện khi chỉ đổi một giá trị.

### Ba thói quen cần giữ

| Nên | Không nên |
|---|---|
| Nhập giá trị qua `read -rs` hoặc pipe | Gõ giá trị thẳng trên dòng lệnh (vào `~/.bash_history`) |
| Sinh giá trị ngẫu nhiên: `openssl rand -hex 32` | Đặt mật khẩu tự nghĩ |
| Dùng `--dry-run=client` | `kubectl create secret` thật rồi mới seal — secret bản rõ nằm lại trong cluster |

---

## 3. Sao lưu sealing key — phần quan trọng nhất

Đây là điểm yếu duy nhất của Sealed Secrets: **mất private key là mất khả năng giải mã toàn bộ secret trong repo.**

### Làm ngay sau khi cài controller

```bash
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > ~/sealing-key-$(date +%Y%m%d).yaml
```

File này **là bí mật cấp cao nhất của hệ thống**. Ai có nó thì giải mã được mọi secret trong repo.

### Cất ở đâu

| Nơi | Ghi chú |
|---|---|
| ✅ Password manager (1Password / Bitwarden) | Cùng mục với [recovery kit](./DISASTER_RECOVERY.md#2-recovery-kit--ba-thứ-phải-luôn-có) — snapshot, k3s token, sealing key nằm chung một chỗ |
| ✅ USB mã hoá, cất nơi an toàn | Bản offline, phòng khi mất password manager |
| ✅ **Emergency access cho 1 người thứ hai** | Bắt buộc khi chỉ có 1 người vận hành — xem dưới |
| ❌ Trong repo Git | Vô nghĩa — vòng lặp |
| ❌ Trong chính cluster | Cluster chết là mất cả hai |
| ❌ Chỉ một người giữ, không có đường dự phòng | **Đây là mặc định khi chỉ có 1 người, và phải chủ động phá bỏ nó** |

⚠️ **Với 1 người, "cất 2 nơi" chưa đủ — cả 2 nơi đó đều chỉ mình bạn vào được.** Nếu bạn mất thiết bị, mất khả năng đăng nhập, hoặc đơn giản là không liên lạc được, thì sealing key coi như mất. Bật **emergency access** (1Password Emergency Kit / Bitwarden Emergency Access) cho một người bạn tin — người đó không cần biết Kubernetes, chỉ cần mở được mục đó khi cần. Đây là việc của P6 trong [lộ trình](./REFACTOR_PLAN.md#p6--prod-3-ngày), cùng với `docs/BREAK_GLASS.md`.

Sau khi cất xong: `shred -u ~/sealing-key-*.yaml`

### Controller tự xoay key mỗi 30 ngày

Sealed Secrets tạo key mới định kỳ và **giữ lại key cũ** để giải mã secret đã seal trước đó. Nghĩa là backup cần cập nhật lại.

**Khuyến nghị:** giữ tự xoay key, và **đặt lịch nhắc backup lại mỗi quý**. Một sự kiện lặp trong calendar là đủ.

### Kiểm tra khôi phục — bắt buộc một lần ở P5

```bash
k3d cluster create test-restore
kubectl apply -f ~/sealing-key-backup.yaml
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
kubectl apply -f secrets/prod/lotus-clinic/backend.yaml
kubectl -n lotus-clinic-prod get secret lotus-clinic-backend -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
# → phải ra đúng giá trị gốc
k3d cluster delete test-restore
```

Ghi kết quả vào `docs/RUNBOOK.md`. **Backup chưa từng khôi phục thử thì chưa phải backup.**

---

## 4. Khai báo secret trong registry

Registry khai báo service **cần** secret nào, nhưng không chứa giá trị:

```yaml
# registry/apps/lotus-clinic/service.yaml
spec:
  requiredSecrets:
    - name: lotus-clinic-backend
      keys: [DB_PASSWORD, JWT_SECRET, MINIO_SECRET_KEY]
    - name: lotus-clinic-keystore
      keys: [keystore.jks]
      type: binary
```

Ba tác dụng:

1. **CI phát hiện thiếu** trước khi deploy hỏng
2. **Người mới** nhìn một file là biết cần chuẩn bị gì
3. **Kiểm tra trước khi bật môi trường mới** — chưa đủ secret thì chưa cho bật prod

```bash
#!/usr/bin/env bash
# ci/scripts/check-secrets.sh — chạy trong CI
set -euo pipefail
FAIL=0
for svc in registry/apps/*/service.yaml; do
  name=$(basename "$(dirname "$svc")")
  for env in $(yq -r '.spec.environments[].env' "$svc"); do
    for sec in $(yq -r '.spec.requiredSecrets[]?.name' "$svc"); do
      ls "secrets/$env/$name/"*.yaml >/dev/null 2>&1 \
        || { echo "❌ $name/$env: thiếu secret '$sec'"; FAIL=1; }
    done
  done
done
exit $FAIL
```

---

## 5. Xoay vòng secret

### Vấn đề dễ quên: pod không tự nhận giá trị mới

Kubernetes **không restart pod** khi Secret đổi. Với secret nạp qua `envFrom`, pod cũ giữ giá trị cũ cho tới khi được tạo lại. Triệu chứng: *"đổi mật khẩu rồi mà app vẫn báo sai"*.

Xử lý sẵn trong `charts/hnq-common` — gắn annotation checksum vào pod template:

```yaml
spec:
  template:
    metadata:
      annotations:
        # Secret đổi → checksum đổi → pod template đổi → rolling restart
        hnq.dev/secret-checksum: {{ .Values.app.secretChecksum | default "none" | quote }}
```

Script `seal-secret.sh` cập nhật `secretChecksum` trong `values-<env>.yaml` cùng lúc. Một PR vừa đổi secret vừa kích hoạt restart.

### Lịch khuyến nghị

| Loại | Chu kỳ |
|---|---|
| Mật khẩu database | 6 tháng, hoặc ngay khi nghi lộ |
| Khoá ký JWT | 3 tháng |
| Access key MinIO | 6 tháng |
| Token GitHub / registry | 12 tháng, hoặc dùng token có hạn |
| **Bất kỳ secret nào nghi lộ** | **Ngay lập tức** |

> Với 1 người, một lịch nhắc hằng quý để rà lại toàn bộ là thực tế hơn là đặt lịch riêng cho từng secret — và nó đã nằm trong [lịch vận hành hằng quý](./K3S_OPERATIONS.md#11-lịch-vận-hành), không phải một lịch riêng phải tự nhớ.

---

## 6. Khi nghi ngờ bị lộ

### Bước 1 — Vô hiệu hoá ngay, đừng chờ điều tra

```bash
# Ví dụ: lộ mật khẩu MariaDB
kubectl exec -n mariadb-prod mariadb-0 -- \
  mysql -uroot -p -e "ALTER USER 'app'@'%' IDENTIFIED BY 'mật-khẩu-mới';"
```

Đổi trước, điều tra sau.

### Bước 2 — Seal lại và mở PR

Theo Phần 2. Nhớ cập nhật `secretChecksum` để pod restart.

### Bước 3 — Nếu bản rõ đã bị commit

```bash
git filter-repo --path secrets/prod/lotus-clinic/leaked.yaml --invert-paths
git push --force-with-lease origin main
```

Nhưng phải hiểu rõ: **xoá khỏi lịch sử Git không làm secret an toàn trở lại.** Repo đã được clone, GitHub Actions có thể còn artifact, GitHub có thể còn cache. Coi như đã lộ vĩnh viễn — **bắt buộc đổi giá trị**, xoá lịch sử chỉ là dọn dẹp.

### Bước 4 — Rà phạm vi

- Secret đó còn dùng ở đâu nữa? (`grep` tên secret trong `registry/`)
- Ai đã dùng nó truy cập gì? (log database, log MinIO)
- Lộ từ bao giờ? (`git log` của file)

### Bước 5 — Ghi lại

Vào `docs/RUNBOOK.md`: lộ thế nào, phát hiện ra sao, và **đổi gì để lần sau không lặp lại**.

---

## 7. Danh sách kiểm tra

### Khi dựng hệ thống (P1)

- [ ] Sealed Secrets controller đã chạy
- [ ] **Sealing key đã backup ra ngoài cluster, cất ở 2 nơi**
- [ ] **Emergency access của password manager đã bật cho 1 người thứ hai**
- [ ] `gitleaks` chạy trong GitHub Actions
- [ ] `secrets/README.md` liệt kê mọi secret hệ thống cần
- [ ] `check-secrets.sh` chạy trong CI
- [ ] `make secret` hoạt động, đã thử qua trên **cả máy phụ** ([K3S_OPERATIONS §4.3](./K3S_OPERATIONS.md#43-máy-phụ--bắt-buộc-không-phải-tuỳ-chọn))

### P5 — trước khi có dữ liệu thật

- [ ] **Đã kiểm tra khôi phục sealing key thành công một lần** — quy trình ở [R8 bước 4](./DISASTER_RECOVERY.md#r8--mất-toàn-bộ-cluster-dựng-lại-từ-số-không), là chỗ dễ làm sai nhất khi dựng lại cluster
- [ ] Kết quả ghi vào `docs/RUNBOOK.md`
- [ ] Đã đặt lịch nhắc backup lại key hằng quý

### Nếu sau này thêm bất kỳ tự động hoá nào chạm tới secret

Ba ràng buộc không được phá, bất kể công cụ gì:

- [ ] ServiceAccount của nó **không có** quyền nào trên `secrets` — kiểm bằng `kubectl auth can-i get secrets --as=<SA> -A` (phải là `no`)
- [ ] Token Git của nó **không push được** vào `main` — đã thử thật
- [ ] Nó **không bao giờ** nhận secret bản rõ — chỉ nhận dữ liệu đã seal

---

## Tham khảo

- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) · [Scopes](https://github.com/bitnami-labs/sealed-secrets#scopes)
- [gitleaks](https://github.com/gitleaks/gitleaks) · [git-filter-repo](https://github.com/newren/git-filter-repo)
- [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
