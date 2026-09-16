#!/usr/bin/env bash
# Cài bộ công cụ hằng ngày (OPERATIONS.md — phần có tỷ lệ giá trị/công sức cao
# nhất). ⚠️ Chạy trên CẢ MÁY PHỤ: với 1 người, "laptop chết" và "hệ thống không
# ai vận hành được" là cùng một sự cố nếu chỉ một máy được cấu hình sẵn.
set -euo pipefail

HELM_VERSION="${HELM_VERSION:-v3.16.4}"
K9S_VERSION="${K9S_VERSION:-v0.32.7}"
STERN_VERSION="${STERN_VERSION:-1.34.0}"
YQ_VERSION="${YQ_VERSION:-v4.44.5}"
# kubeseal phải cùng minor version với controller (chart sealed-secrets ghim
# appVersion 0.40.x — xem gitops/bootstrap/platform/sealed-secrets.yaml).
KUBESEAL_VERSION="${KUBESEAL_VERSION:-0.40.0}"
BIN="${BIN:-$HOME/.local/bin}"

mkdir -p "$BIN"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }

install_kubectl() {
  have kubectl && return
  local v; v="$(curl -sfL https://dl.k8s.io/release/stable.txt)"
  curl -sfL "https://dl.k8s.io/release/$v/bin/linux/amd64/kubectl" -o "$BIN/kubectl"
  chmod +x "$BIN/kubectl"
}

install_tar() {  # tên | url | đường-dẫn-trong-tar
  have "$1" && return
  curl -sfL "$2" | tar xz -C "$TMP"
  mv "$TMP/$3" "$BIN/$1"
  chmod +x "$BIN/$1"
}

install_kubectl
install_tar helm  "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" linux-amd64/helm
# k9s: thay ~80% lệnh kubectl gõ hằng ngày. Thứ mở đầu tiên trong mọi sự cố.
install_tar k9s   "https://github.com/derailed/k9s/releases/download/$K9S_VERSION/k9s_Linux_amd64.tar.gz" k9s
install_tar stern "https://github.com/stern/stern/releases/download/v$STERN_VERSION/stern_${STERN_VERSION}_linux_amd64.tar.gz" stern
# bitnami-labs/sealed-secrets đã đổi thành bitnami/sealed-secrets.
install_tar kubeseal "https://github.com/bitnami/sealed-secrets/releases/download/v$KUBESEAL_VERSION/kubeseal-$KUBESEAL_VERSION-linux-amd64.tar.gz" kubeseal

have yq || { curl -sfL "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_amd64" -o "$BIN/yq"; chmod +x "$BIN/yq"; }

# krew + 4 plugin đáng có: tree (thấy chuỗi cha–con lúc Degraded), neat, df-pv,
# resource-capacity.
if ! kubectl krew version >/dev/null 2>&1; then
  (
    cd "$TMP"
    curl -sfL "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-linux_amd64.tar.gz" | tar xz
    ./krew-linux_amd64 install krew
  )
  export PATH="$HOME/.krew/bin:$PATH"
fi
kubectl krew install tree neat df-pv resource-capacity 2>/dev/null || true

cat <<EOF

✅ xong. Thêm vào ~/.bashrc nếu chưa có:

  export PATH="$BIN:\$HOME/.krew/bin:\$PATH"
  export KUBECONFIG="\$HOME/.kube/config-hnq"

Còn 3 việc cho MÁY PHỤ (OPERATIONS.md):
  [ ] Tailscale đã join tailnet, SSH key vào cả 3 node
  [ ] ~/.kube/config-hnq chmod 600, server trỏ tên MagicDNS (KHÔNG phải IP)
  [ ] Đăng nhập được password manager có recovery kit

10 phím k9s đủ 90% việc: :pod :svc :ing :app · 0-9 lọc ns · / tìm · l log ·
d describe · y yaml · s shell · Shift-c/Shift-m sắp xếp CPU/RAM · :pulse
EOF
