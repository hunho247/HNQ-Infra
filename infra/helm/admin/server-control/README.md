# server-control

Self-hosted web dashboard for managing LAN servers — Wake-on-LAN, SSH shutdown/restart, and TCP-based status monitoring.

## Overview

| Feature | Details |
|---------|---------|
| Runtime | Node.js + Express backend, React + Vite frontend |
| Storage | SQLite via PersistentVolumeClaim |
| Auth | bcrypt-hashed password, JWT in httpOnly cookie |
| Wake-on-LAN | UDP magic packet, configurable broadcast address and port |
| SSH actions | Shutdown / restart via SSH private key auth |
| Status polling | TCP check on SSH port every 30s (configurable) |

---

## Prerequisites

- k3s cluster running
- `kubectl` and `helm` configured
- Container registry accessible from the cluster
- Node.js 20+ installed on the build machine (to build the image)

---

## 1. Build and push the container image

```bash
cd apps/server-control

# Build
docker build -t registry.example.com/server-control:1.0.0 .

# Push
docker push registry.example.com/server-control:1.0.0
```

---

## 2. Generate credentials

```bash
# Generate bcrypt password hash (rounds=12)
docker run --rm node:20-alpine \
  node -e "require('bcryptjs').hash('your-strong-password', 12).then(console.log)"

# Generate JWT secret
openssl rand -hex 32
```

---

## 3. Create Kubernetes namespace and Secret

```bash
kubectl create namespace server-control-dev

# Create credentials secret (copy secret.example.yaml and fill in values)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: server-control-dev-credentials
  namespace: server-control-dev
type: Opaque
stringData:
  ADMIN_USERNAME: "admin"
  ADMIN_PASSWORD_HASH: "\$2a\$12\$your-bcrypt-hash-here"
  JWT_SECRET: "your-jwt-secret-here"
EOF
```

---

## 4. Mount SSH keys (optional, required for shutdown/restart)

```bash
kubectl create secret generic server-control-dev-ssh-keys \
  --namespace server-control-dev \
  --from-file=id_rsa=/path/to/your/private/key
```

In the server config UI, set `SSH Private Key Path` to `/ssh-keys/id_rsa`.

Enable in values:
```yaml
sshKeys:
  enabled: true
  secretName: server-control-dev-ssh-keys
  mountPath: /ssh-keys
```

---

## 5. Install with Helm

```bash
# Dev
helm upgrade --install server-control \
  infra/helm/admin/server-control \
  --namespace server-control-dev \
  --create-namespace \
  -f infra/helm/admin/server-control/values.yaml \
  -f infra/helm/admin/server-control/values-dev.yaml

# Prod
helm upgrade --install server-control \
  infra/helm/admin/server-control \
  --namespace server-control-prod \
  --create-namespace \
  -f infra/helm/admin/server-control/values.yaml \
  -f infra/helm/admin/server-control/values-prod.yaml
```

---

## 6. Wake-on-LAN and hostNetwork

**Why hostNetwork is required:**

Wake-on-LAN sends a UDP broadcast packet to the LAN broadcast address (e.g. `192.168.1.255`).
Inside a normal Kubernetes pod, UDP broadcasts are confined to the pod network overlay and
**cannot reach physical LAN hosts**.

Enabling `hostNetwork: true` makes the pod share the node's network namespace, allowing
the UDP broadcast to leave the physical NIC and reach target servers.

**Requirements when using hostNetwork:**

1. The pod must be scheduled on a node **connected to the same LAN/VLAN as the target servers**.
2. Use `nodeSelector` to pin the pod to the correct node.
3. The chart automatically sets `dnsPolicy: ClusterFirstWithHostNet` when hostNetwork is enabled.

**Example values for hostNetwork mode:**

```yaml
hostNetwork:
  enabled: true

nodeSelector:
  kubernetes.io/hostname: server01   # node on the target LAN

env:
  # Use the LAN broadcast address, not 255.255.255.255
  # (configure per-server in the UI)
  []
```

**Configure per-server broadcast in the UI:**

When adding a server, set `Broadcast Address` to the subnet broadcast of your LAN, e.g.:
- `192.168.1.255` for `192.168.1.0/24`
- `10.0.0.255` for `10.0.0.0/24`

Using `255.255.255.255` may work but is less reliable on routed networks.

**Troubleshooting Wake-on-LAN:**

```bash
# Verify the pod is using the host network
kubectl exec -n server-control-dev deploy/server-control -- ip addr

# Test WoL manually from the node
wakeonlan AA:BB:CC:DD:EE:FF

# Check that the UDP packet leaves the NIC (run on the node, then click Wake in UI)
tcpdump -i eth0 udp port 9
```

If WoL packets are sent but the server does not wake:
1. Verify Wake-on-LAN is enabled in the server's BIOS/UEFI
2. Verify the NIC supports WoL (`ethtool eth0 | grep Wake-on`)
3. Enable WoL on the NIC: `ethtool -s eth0 wol g`
4. Make sure the target server is on the same broadcast domain (not behind a router)

---

## 7. Cloudflare Tunnel

### Option A — External tunnel (recommended)

Run `cloudflared` separately (as a DaemonSet or standalone) and point it at the Kubernetes Service:

```yaml
# cloudflared config.yaml
ingress:
  - hostname: server-control.example.com
    service: http://server-control.server-control-prod.svc.cluster.local:3000
  - service: http_status:404
```

### Option B — Sidecar (built-in)

Enable the cloudflared sidecar in values:

```yaml
cloudflareTunnel:
  enabled: true
  tokenSecretName: server-control-cloudflare-tunnel
```

Create the token secret:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: server-control-cloudflare-tunnel
  namespace: server-control-prod
type: Opaque
stringData:
  token: "your-cloudflare-tunnel-token"
EOF
```

Get your tunnel token from the Cloudflare Zero Trust dashboard → Networks → Tunnels.

---

## 8. Key values reference

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `registry.example.com/server-control` | Image registry path |
| `image.tag` | `latest` | Image tag |
| `hostNetwork.enabled` | `false` | Enable host network (required for WoL) |
| `persistence.enabled` | `true` | Enable PVC for SQLite |
| `persistence.size` | `1Gi` | PVC size |
| `envFromSecret.enabled` | `false` | Load env from Secret |
| `envFromSecret.secretName` | `""` | Name of the credentials Secret |
| `sshKeys.enabled` | `false` | Mount SSH keys Secret |
| `sshKeys.secretName` | `""` | Name of the SSH keys Secret |
| `sshKeys.mountPath` | `/ssh-keys` | Mount path inside container |
| `cloudflareTunnel.enabled` | `false` | Deploy cloudflared sidecar |
| `cloudflareTunnel.tokenSecretName` | `""` | Secret containing `token` key |

---

## 9. Local development

```bash
cd apps/server-control

# Install deps
cd backend && npm install && cd ..
cd frontend && npm install && cd ..

# Generate a password hash
node -e "require('bcryptjs').hash('admin', 12).then(console.log)"

# Create .env from template
cp .env.example backend/.env
# Edit backend/.env with your hash and secrets

# Start backend (watches for changes)
cd backend && npm run dev &

# Start frontend dev server (proxies /api to localhost:3000)
cd frontend && npm run dev
```
