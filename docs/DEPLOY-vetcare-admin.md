# Deploy vetcare-admin + mở ra internet qua Cloudflare Tunnel

Áp dụng cho **dev** (`https://vetcare-admin-dev.l2cteam.work`). Prod làm sau, theo `make promote`.

## 1. Vì sao chọn cách này

vetcare-admin là **Next.js chạy server** (SSR + Server Action + middleware, cookie phiên JWE,
gọi backend từ phía server — `docs/architecture.md` §8 của repo đó). Nên:

| Lựa chọn | Kết luận |
|---|---|
| Static export / Cloudflare Pages | ✗ App cần server runtime (Server Action, middleware, cookie mã hoá) |
| systemd/pm2 chạy `pnpm start` trên host | ✗ Lệch hẳn mô hình GitOps của HNQ-Infra, không rollback/sync được |
| **Image Docker → ghcr.io → `registry/apps/` + chart `webservice` → ArgoCD** | ✓ Đúng pattern mọi service khác (vetcare-backend là mẫu), chỉ cấu hình bằng env |

Cấu hình runtime chỉ có 2 biến: `API_BASE_URL` (không nhạy cảm, khai trong `values-dev.yaml`)
và `AUTH_SECRET` (SealedSecret). Backend được gọi qua Service trong cluster
(`http://vetcare-backend.vetcare-backend-dev.svc.cluster.local`) — không đi vòng ra Cloudflare.

## 2. Trạng thái: ĐÃ CHẠY (dev), 2026-09-19

`https://vetcare-admin-dev.l2cteam.work/login` trả **200**. Image đang chạy:
`ghcr.io/hunho247/vetcare-admin:aef6099`.

Đã kiểm chứng bằng lệnh thật, không phải suy đoán:

| Kiểm chứng | Kết quả |
|---|---|
| Pod | `Running 1/1`, log Next.js `✓ Ready` |
| Qua Traefik (`--resolve` ClusterIP) | `/login` 200, `/` 307 → `/login` |
| Qua Cloudflare (public) | `/login` 200, HTTP/2 |
| Pod → backend trong cluster | `GET /healthz` 200 |
| Server Action qua proxy | Origin hợp lệ **đi lọt**; origin giả bị chặn đúng (`x-forwarded-host` khớp) |

Nghĩa là **không cần** thêm host vào `serverActions.allowedOrigins` — Cloudflare và Traefik
truyền `x-forwarded-host` đúng.

Thay đổi đã commit:
- Repo vetcare-admin (`aef6099`): `output: 'standalone'` + `Dockerfile` + `.dockerignore` +
  `.github/workflows/build-push.yml`.
- HNQ-Infra (`48648d0`, `3c66a7a`): `registry/apps/vetcare-admin/`, 2 SealedSecret, tài liệu này.

## 3. Các bước, theo đúng thứ tự

### Bước 1 — Build image
Commit các file ở repo vetcare-admin lên `main` (nhớ commit cả `pnpm-lock.yaml` hiện có). GitHub Actions
build và đẩy `ghcr.io/hunho247/vetcare-admin:<sha7>`. Ghi lại `<sha7>` (7 ký tự đầu của commit).

> Nếu build lỗi ở `pnpm install`: lockfile có `dotenv@18.0.1`, pnpm 10 không chặn bản mới nhưng
> pnpm ≥ 11 mặc định chặn gói < 24 giờ tuổi — bản này đã đủ tuổi nên chỉ gặp nếu build sớm.

### Bước 2 — Niêm phong 2 secret (chạy trên máy có `kubectl` + `kubeseal`)

```bash
cd ~/hnq-workspace/HNQ-Infra
mkdir -p secrets/dev/vetcare-admin

# (a) Khoá mã hoá cookie phiên — sinh mới, không ai phải biết giá trị.
kubectl create secret generic vetcare-admin-app -n vetcare-admin-dev \
  --from-literal=AUTH_SECRET="$(openssl rand -base64 32)" --dry-run=client -o yaml \
| kubeseal --format yaml > secrets/dev/vetcare-admin/app.yaml

# (b) Credential kéo image từ ghcr — dùng lại của vetcare-backend (cùng chủ sở hữu ghcr.io/hunho247),
#     chuyển sang namespace/tên mới. Giá trị không hiện ra màn hình.
kubectl -n vetcare-backend-dev get secret vetcare-backend-registry -o json \
| jq '{apiVersion,kind,type,data,metadata:{name:"vetcare-admin-registry",namespace:"vetcare-admin-dev"}}' \
| kubeseal --format yaml > secrets/dev/vetcare-admin/registry.yaml
```
(Cách khác cho (b): đặt package `vetcare-admin` trên ghcr thành *public* rồi bỏ `imagePullSecrets` +
secret `vetcare-admin-registry`.)

> ⚠️ **ArgoCD KHÔNG áp thư mục `secrets/`** (Application chỉ render chart). SealedSecret phải áp tay
> vào cluster — giống cách secret của vetcare-backend đã được đưa vào. Thiếu bước này pod sẽ
> `ImagePullBackOff` với sự kiện `FailedToRetrieveImagePullSecret`. Namespace do ArgoCD tạo
> (`CreateNamespace=true`) nên áp sau khi Application đã sync lần đầu:
>
> ```bash
> kubectl apply -f secrets/dev/vetcare-admin/
> ```

### Bước 3 — Chốt tag rồi merge HNQ-Infra
1. Sửa `registry/apps/vetcare-admin/values-dev.yaml`: `tag: "0000000"` → `<sha7>` ở bước 1.
2. Xoá dòng `vetcare-admin/dev` khỏi `secrets/PENDING`.
3. `make validate` (nếu yamllint kêu vì `node_modules` trong `.repo/`, chạy từng cửa như ở §2 hoặc xoá `.repo/vetcare-admin/node_modules`).
4. Commit + PR + merge vào `main`. ApplicationSet tự sinh Application `vetcare-admin-dev`
   (git generator poll vài phút một lần, không có webhook). Sau đó áp SealedSecret (khung ⚠️ ở trên).

```bash
kubectl -n argocd get app vetcare-admin-dev          # Synced / Healthy
kubectl -n vetcare-admin-dev get pods,ingress
kubectl -n vetcare-admin-dev logs deploy/vetcare-admin --tail=20
```

Kiểm tra trong cluster trước khi đụng Cloudflare (Ingress dùng entrypoint `websecure` nên phải qua 443):

```bash
curl -sk -o /dev/null -w '%{http_code}\n' --resolve vetcare-admin-dev.l2cteam.work:443:10.43.158.55 \
  https://vetcare-admin-dev.l2cteam.work/login        # kỳ vọng 200
```

### Bước 4 — Cloudflare Tunnel

Tunnel `tunnel-server01` chạy bằng **token**, nên toàn bộ route nằm trên dashboard (không có trong Git —
xem commit `3e599a8`). Mỗi hostname mới phải thêm tay.

1. Vào **Cloudflare Zero Trust** (one.dash.cloudflare.com) → **Networks → Tunnels** → `tunnel-server01`
   → **Configure** → tab **Published application routes** (bản cũ: *Public Hostname*) → **Add**.
2. Điền:

   | Ô | Giá trị |
   |---|---|
   | Subdomain | `vetcare-admin-dev` |
   | Domain | `l2cteam.work` |
   | Path | *(để trống)* |
   | Service type | `HTTPS` |
   | URL | `10.43.158.55:443` |

3. **Additional application settings → TLS → No TLS Verify: BẬT.** (Traefik dùng cert của nó, không
   khớp với địa chỉ IP.) **HTTP Host Header: để trống** — phải giữ nguyên Host gốc để Traefik khớp
   Ingress `vetcare-admin-dev.l2cteam.work`.
4. **Save**. Cloudflare tự tạo bản ghi DNS `vetcare-admin-dev` (CNAME → `<tunnel-id>.cfargotunnel.com`,
   proxied). Hostname này hiện chưa có DNS; nếu dashboard báo "record already exists", xoá bản ghi cũ ở
   DNS → Records rồi lưu lại.

**Vì sao URL là ClusterIP `10.43.158.55:443` mà không phải `traefik.kube-system.svc.cluster.local`:**
tunnel này có **2 nhóm connector** cùng chạy (systemd trên host + pod `cloudflared` trong cluster) và
Cloudflare chia request cho cả hai. Tên `*.svc.cluster.local` chỉ phân giải trong cluster → request rơi
vào connector trên host sẽ **502**. ClusterIP truy cập được từ cả hai. Cách chắc nhất: mở route
`vetcare-backend-dev` đang chạy tốt trên dashboard và **sao y** Service type / URL / TLS sang route mới.
(ClusterIP đổi nếu Service `traefik` bị tạo lại — kiểm bằng `kubectl -n kube-system get svc traefik`.)

Kiểm tra: `curl -sI https://vetcare-admin-dev.l2cteam.work/login` → `200`; mở trên trình duyệt sẽ
thấy form đăng nhập.

### Nếu lỗi

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| **502** (lúc được lúc không) | URL route dùng tên chỉ phân giải trong cluster → sửa thành ClusterIP |
| **404** từ Traefik | Ingress chưa có (Application chưa sync) hoặc ô *HTTP Host Header* bị ghi đè |
| **1016 / không phân giải DNS** | Route chưa lưu, hoặc bản ghi DNS chưa tạo |
| Pod `ImagePullBackOff` + sự kiện `FailedToRetrieveImagePullSecret` | **Chưa áp SealedSecret** (Bước 2) — đây là lỗi đã gặp thật lần đầu deploy |
| Pod `ImagePullBackOff`, log nói `manifest unknown` | Tag chưa có trên ghcr (CI chưa build xong / build lỗi) |
| Application `OutOfSync`, chỉ có Deployment mà **chưa có Service/Ingress** | ArgoCD dừng ở "waiting for healthy state of Deployment" vì pod chưa chạy. Sửa được gốc (pull secret) là Service/Ingress tự được tạo — không phải lỗi riêng |
| Trang trả `404 page not found` nền đen | 404 của **Traefik**: request đã qua Cloudflare + tunnel nhưng chưa có Ingress nào khớp Host |
| Pod `CrashLoop`, log "Thiếu biến môi trường AUTH_SECRET" | Secret `vetcare-admin-app` chưa được giải mã (sai namespace/tên khi seal) |
| Đăng nhập xong bị đá về `/login` liên tục | Cookie phiên `Secure` (production) cần HTTPS — chỉ vào qua `https://`, không qua HTTP/IP |
| Bấm nút báo `Invalid Server Actions request` | Origin ≠ Host phía app; thêm host vào `serverActions.allowedOrigins` ở `next.config.ts` (hiện chưa cần, chỉ thêm nếu gặp lỗi) |

## 4. Khuyến nghị bảo mật (nên làm trước khi cho người khác biết URL)

Đây là **console quản trị nền tảng** (tạo/khoá tenant, tài khoản vận hành). Mở thẳng ra internet chỉ
với mật khẩu + 2FA là chấp nhận được nhưng nên thêm một lớp:

**Zero Trust → Access → Applications → Add → Self-hosted**: Application domain
`vetcare-admin-dev.l2cteam.work`, policy *Allow* theo email của bạn (hoặc domain công ty).
Lưu ý: khi bật Access, bộ Playwright e2e chạy vào URL công khai sẽ bị chặn — chạy e2e bằng
`pnpm dev` cục bộ (`baseURL` localhost) hoặc dùng Service Token.

## 5. Promote lên prod (sau này)

Thêm `- env: prod` vào `service.yaml`, `make promote NAME=vetcare-admin`, niêm phong secret cho
`vetcare-admin-prod` (namespace khác ⇒ phải seal lại), rồi thêm route `vetcare-admin.l2cteam.work` trên
dashboard tunnel. `API_BASE_URL` ở `values-prod.yaml` đã trỏ `vetcare-backend-prod`.
