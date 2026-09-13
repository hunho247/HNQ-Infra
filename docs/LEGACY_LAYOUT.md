# 📘 README – Quy ước tổ chức thư mục `/home/server01/srv`

Tài liệu này mô tả **chuẩn tổ chức hệ thống** tại:

```text
/home/server01/srv
```

Layout được thiết kế cho:

- Nhiều môi trường: **dev**, **prod**
- Nhiều khách hàng: **multi-tenant** (giaan_clinic, foody_restaurant, tvs,…)
- Chạy trên **k3s/Kubernetes** với **Helm**, **GitLab CI**
- Tách rõ:
  - Runtime (apps, config, data, logs)
  - Hạ tầng triển khai (infra, helm, k3s, scripts)
  - Secret template (không chứa secret thật)

---

## 🗂 1. Tổng quan cấu trúc

```text
/home/server01/srv
├── envs/           # Mỗi environment chạy độc lập: dev, prod
└── infra/          # Hạ tầng, deploy, DevOps tools, IaC
```

- `envs/` = nơi chứa **mọi thứ runtime** (ứng dụng chạy thật, data, logs, backup)
- `infra/` = nơi chứa **mọi thứ hạ tầng & automation** (Helm, k3s manifest, script, CI/CD, secrets template)

---

## 🧩 2. Thư mục `/envs` – Runtime theo môi trường

```text
envs/
├── dev/
└── prod/
```

Mỗi environment có cấu trúc chung:

```text
envs/<env>/
├── apps/      # Code & workspace
├── config/    # Config theo env
├── data/      # Persistent data (hostPath/PV)
├── logs/      # Log runtime
└── backup/    # Backup / dump / snapshot
```

### 2.1. `/envs/dev/apps` – Code & workspace (dev)

```text
envs/dev/apps/
├── common/
└── clients/
```

#### 2.1.1. `envs/dev/apps/common` – Service dùng chung

Các service “nền tảng”, dùng cho nhiều khách hàng:

```text
envs/dev/apps/common
├── auth/
│   ├── src/
│   ├── Dockerfile
│   └── README.md
├── gateway/
│   ├── src/
│   ├── Dockerfile
│   └── README.md
├── message/
│   ├── mqtt/
│   │   ├── src/
│   │   ├── Dockerfile
│   │   └── README.md
│   └── push-service/
│       ├── src/
│       ├── Dockerfile
│       └── README.md
├── storage/
│   ├── mariadb/
│   ├── minio/
│   └── redis/
├── search/
│   ├── api/
│   └── dashboard/
└── webserver/
    ├── caddy/
    ├── nginx/
    └── traefik/
```

- Mỗi service có:
  - `src/`: mã nguồn hoặc template
  - `Dockerfile`: build image riêng
  - `README.md`: mô tả ngắn về service & cách build/run
- Các thư mục như `storage/mariadb`, `storage/minio`, …:
  - Có thể chứa Dockerfile riêng, script migration, tools quản lý database/object storage nếu cần.

> **Lưu ý:** Data thật của MariaDB/MinIO/Redis không nằm trong `apps`, mà nằm ở `envs/dev/data/common/storage/...`.

#### 2.1.2. `envs/dev/apps/clients` – Code cho từng khách hàng

Ví dụ cho khách hàng `giaan_clinic`:

```text
envs/dev/apps/clients/giaan_clinic
├── backend/
│   ├── src/
│   ├── tests/
│   ├── Dockerfile
│   ├── requirements.txt    # hoặc package.json/pom.xml...
│   ├── .env.example        # mẫu env, KHÔNG chứa secret thật
│   └── README.md
├── frontend/
│   ├── src/
│   ├── public/
│   ├── Dockerfile
│   ├── package.json
│   ├── .env.example
│   └── README.md
├── worker/
│   ├── src/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── .env.example
└── dev-tools/
    ├── docker-compose.yml  # chỉ dùng cho dev local, không phải k3s
    └── mock-data/
```

- Đây là **workspace dev** cho client:
  - Dev chỉnh code → commit → GitLab CI build image → Helm deploy lên k3s.
- Không chứa data runtime, logs, hay helm chart **chính thức**.

Các khách còn lại (vd: `foody_restaurant`) sẽ theo pattern tương tự.

---

### 2.2. `/envs/dev/config` – Config theo môi trường dev

```text
envs/dev/config
├── common/
└── clients/
```

#### 2.2.1. `config/common`

```text
envs/dev/config/common
├── notify/
│   └── config.yml
├── webserver/
│   ├── Caddyfile
│   ├── traefik.yml
│   └── nginx.conf
├── gateway/
│   └── config.yml
└── monitoring/
    └── datasources.yml
```

- Chứa config cho các service chung:
  - Notify (MQTT/push)
  - Webserver (Caddy / Traefik / Nginx)
  - Gateway
  - Monitoring (Grafana, Prometheus,…)

#### 2.2.2. `config/clients`

```text
envs/dev/config/clients/giaan_clinic
├── backend.env
├── frontend.env
└── worker.env
```

- Có thể dùng:
  - Làm **input** để sinh Kubernetes Secret (qua CI)  
  - Hoặc mount trực tiếp trong dev (không khuyến khích cho prod).
- Không commit secret thật vào Git nếu không được mã hóa / bảo vệ.

---

### 2.3. `/envs/dev/data` – Data (HostPath/PV k3s mount vào Pod)

```text
envs/dev/data
├── common/
└── clients/
```

#### 2.3.1. `data/common`

```text
envs/dev/data/common
├── monitoring/
│   └── portainer/
├── notify/
│   └── mqtt/
├── opensearch/
│   └── nodes/
├── storage/
│   ├── mariadb/
│   ├── minio/
│   └── redis/
└── webserver/
    └── caddy/
```

- Đây là nơi chứa **persistent data** của các service:
  - `mariadb/` → `/var/lib/mysql`
  - `minio/` → `/data`
  - `redis/` → `/data`
  - `opensearch/nodes/` → data node
  - `webserver/caddy/` → certs, state do Caddy generate
- Các Pod trong k3s mount vào đây qua `hostPath` hoặc PV/PVC.

Ví dụ snippet trong Helm (deployment):

```yaml
volumeMounts:
  - name: mariadb-data
    mountPath: /var/lib/mysql
volumes:
  - name: mariadb-data
    hostPath:
      path: /home/server01/srv/envs/dev/data/common/storage/mariadb
      type: DirectoryOrCreate
```

#### 2.3.2. `data/clients`

```text
envs/dev/data/clients/giaan_clinic
```

- Chứa data riêng cho client `giaan_clinic`:
  - Upload file
  - Export/report
  - App-specific data

---

### 2.4. `/envs/dev/logs` – Logs của container

```text
envs/dev/logs
├── common/
│   ├── storage/
│   ├── gateway/
│   ├── webserver/
│   └── message/
└── clients/
    └── giaan_clinic/
```

- Pod/container mount log vào đây:
  - Ví dụ: `/var/log/app.log` → hostPath → `envs/dev/logs/...`
- Thuận tiện cho:
  - Tail trực tiếp trên host
  - Thu thập log bằng Loki/Promtail/Filebeat

---

### 2.5. `/envs/dev/backup` – Backup theo env

- Chứa:
  - Dump DB (mysqldump)
  - Snapshot MinIO
  - Archive data (tar.gz)
- Tuỳ chiến lược backup của bạn (cron, script trong `infra/scripts`,…).

---

### 2.6. `/envs/prod` – Môi trường production

Cấu trúc tương tự `dev`, nhưng production:

```text
envs/prod/
├── apps/
├── config/
├── data/
├── logs/
└── backup/
```

- Có thể đơn giản hơn hoặc chi tiết hơn dev, tùy mức độ tách bạch bạn cần.
- Thông thường:
  - Nhiều replica hơn
  - Config khác (domain, endpoint, secret, resource limit)

---

## 🏗 3. Thư mục `/infra` – Hạ tầng, Helm, CI/CD, script

```text
infra/
├── argocd/
├── ci/
├── helm/
└── scripts/
```

Đây là **Infrastructure-as-Code** – không chứa runtime, data, log.

### 3.1. `/infra/ci` – CI/CD scripts

```text
infra/ci
├── deploy_dev.sh
├── deploy_prod.sh
├── build_images.sh
└── runner_setup.sh
```

- Dùng trong GitLab CI/Jenkins/...:
  - `build_images.sh`: build/push image
  - `deploy_dev.sh`: apply ArgoCD root app cho env dev (App-of-Apps)
  - `deploy_prod.sh`: apply ArgoCD root app cho env prod (App-of-Apps)
  - `runner_setup.sh`: setup GitLab runner

---

### 3.2. `/infra/helm` – Helm charts deploy lên k3s

```text
infra/helm
├── cicd/{argocd,gitlab-runner}/
├── clients/obgyn-clinic-service/
├── platform/storage/{mariadb,minio,opensearch,postgres,redis}/
├── platform/message/push-notify/
├── webserver/
├── monitoring/
└── opensearch/
```

Ví dụ chart clients dùng chung:

```text
infra/helm/clients/obgyn-clinic-service
├── Chart.yaml
├── lotus-clinic/
│   ├── values-dev.yaml
│   └── values-prod.yaml
├── giaan-clinic/
│   ├── values-dev.yaml
│   └── values-prod.yaml
└── templates/
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── configmap.yaml
    └── serviceaccount.yaml
```

Helm sẽ:

- Sử dụng image từ CI build (ví dụ `registry/.../backend:<tag>`)
- Mount volume tới `envs/<env>/data/...`
- Đọc config (ConfigMap, Secret) tương ứng env.

Triển khai dev (ví dụ):

```bash
helm upgrade --install giaan-clinic \
  infra/helm/clients/obgyn-clinic-service \
  --namespace giaan-clinic-dev \
  --create-namespace \
  -f infra/helm/clients/obgyn-clinic-service/giaan-clinic/values-dev.yaml \
  --set backend.image=registry.example.com/giaan/backend:<tag>
```

---

### 3.3. `/infra/argocd` – GitOps (ArgoCD Applications)

```text
infra/argocd/
├── bootstrap/{dev,prod}/root-app.yaml   # App-of-Apps cho từng env
├── apps/{dev,prod}/                    # Application per tenant/platform
└── manifests/{dev,prod}/               # (tuỳ chọn) YAML thuần
```

- Flow chuẩn: CI build image → cập nhật `values-*.yaml`/manifests trong repo GitOps → ArgoCD sync vào cluster.
- Bootstrap nhanh:
  - dev: `kubectl -n argocd apply -f infra/argocd/bootstrap/dev/root-app.yaml`
  - prod: `kubectl -n argocd apply -f infra/argocd/bootstrap/prod/root-app.yaml`

---

### 3.4. `/infra/scripts` – Script DevOps / SRE

```text
infra/scripts
├── cleanup-terminating-pods.sh
├── nuke-namespace.sh
├── backup_mysql.sh
├── backup_minio.sh
├── restore_mysql.sh
├── restore_minio.sh
└── rotate_logs.sh
```

Ví dụ sử dụng:

- `backup_mysql.sh`:
  - dump DB → lưu vào `envs/<env>/backup/...`
- `backup_minio.sh`:
  - export bucket → archive → `envs/<env>/backup/...`
- `cleanup-terminating-pods.sh`:
  - chữa k3s bị stuck pod.

---

### 3.5. Secrets management

- Repo này **không lưu secrets/templates**.
- Secrets được quản lý ngoài repo (Vault / External Secrets / SOPS repo riêng).

---

## 📌 4. Bản đồ nhanh: Cái gì nằm ở đâu?

| Loại tài nguyên                           | Vị trí                                                |
|-------------------------------------------|-------------------------------------------------------|
| Code backend/frontend/worker              | `envs/dev/apps/clients/...`                          |
| Service dùng chung (auth, gateway, …)     | `envs/dev/apps/common/...`                           |
| Config không nhạy cảm                     | `envs/<env>/config/...`                              |
| Data MariaDB/MinIO/Redis/Opensearch      | `envs/<env>/data/common/storage/...`                 |
| Data riêng cho client                     | `envs/<env>/data/clients/<client>/`                  |
| Logs runtime                              | `envs/<env>/logs/...`                                |
| Backup (dump, snapshot)                   | `envs/<env>/backup/`                                 |
| Helm chart deploy app / storage / infra   | `infra/helm/...`                                     |
| ArgoCD GitOps (bootstrap/apps)            | `infra/argocd/...`                                   |
| CI/CD script                              | `infra/ci/...`                                       |
| DevOps scripts (backup, cleanup, ...)     | `infra/scripts/...`                                  |

---

## 🎯 5. Quy tắc thiết kế & vận hành

1. **Runtime vs Infra**
   - Runtime → `envs/<env>/...`
   - Infra → `infra/...`
2. **Không để data/log vào infra**
3. **Không để secret thật trong repo / infra**
   - Dùng: k3s Secret, Vault, SOPS, hoặc file env được quản lý chặt.
4. **Helm chart dùng chung cho dev/prod**
   - Khác nhau bằng `values-dev.yaml` / `values-prod.yaml`.
5. **HostPath/PV phải trỏ vào `envs/<env>/data/...`**
   - Dễ backup, dễ clean, dễ tách env.

---

## ✅ 6. Kết luận

Cấu trúc `/home/server01/srv` này:

- Chuẩn hoá cho **k3s + Helm + GitLab CI**
- Hỗ trợ scale nhiều client, nhiều env
- Dễ backup/restore
- Dễ phân quyền/team (app team vs infra team)
- Dễ on-board người mới vào team DevOps/SRE

> Khi cần mở rộng (thêm client, thêm service), hãy **copy pattern sẵn có** của `giaan_clinic` trong `apps`, `config`, `data`, `logs`, `helm`.
