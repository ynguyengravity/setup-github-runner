#!/usr/bin/env bash
# join-worker.sh – Đưa một VM worker (đã tạo bằng pve-create-vms.sh) vào cụm k3s.
# Chạy bằng root trên Proxmox host, trong /root/selfhost-auto-scale (cần node-prep.sh ở cùng thư mục).
#
#   bash join-worker.sh <ip> [runner-image]
#   bash join-worker.sh 192.168.8.6 192.168.8.5:5001/vn-gaqc-runner:2.338.1-202610230904
#
# Các bước: node-prep.sh -> registries.yaml -> config + cài k3s agent (đúng version của server,
# token /root/k3s-token) -> chờ node Ready -> kéo sẵn image runner + docker:dind.

main() (
set -euo pipefail

IP=${1:-}
RUNNER_IMAGE=${2:-}
SERVER_IP=${SERVER_IP:-192.168.8.2}
MIRROR_IP=${MIRROR_IP:-192.168.8.5}
TOKEN_FILE=${TOKEN_FILE:-/root/k3s-token}
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { echo "[FAIL] $*" >&2; exit 1; }
s() { ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "ubuntu@$1" "${@:2}"; }

[[ -n $IP ]] || die "Cách dùng: bash join-worker.sh <ip> [runner-image]"
[[ -f $TOKEN_FILE ]] || die "Không có $TOKEN_FILE (token của cụm)"
[[ -f $DIR/node-prep.sh ]] || die "Không có $DIR/node-prep.sh"
s "$IP" true || die "Không SSH được ubuntu@$IP"

# Cùng version với server, để agent không lệch version
K3S_VERSION=$(s "$SERVER_IP" 'k3s --version' | awk '/^k3s version/ { print $3 }')
[[ -n $K3S_VERSION ]] || die "Không lấy được version k3s của server $SERVER_IP"
K3S_TOKEN=$(cat "$TOKEN_FILE")
NODE=$(s "$IP" hostname)
echo "== Node $NODE ($IP), k3s $K3S_VERSION"

echo "== node-prep.sh"
s "$IP" 'bash -s' < "$DIR/node-prep.sh"

echo "== registries.yaml (docker.io qua mirror :5000, registry nội bộ :5001)"
s "$IP" "sudo mkdir -p /etc/rancher/k3s && sudo tee /etc/rancher/k3s/registries.yaml >/dev/null" <<EOF
mirrors:
  docker.io:
    endpoint:
      - "http://$MIRROR_IP:5000"
  "$MIRROR_IP:5001":
    endpoint:
      - "http://$MIRROR_IP:5001"
EOF

echo "== Config + cài k3s agent"
s "$IP" "sudo tee /etc/rancher/k3s/config.yaml >/dev/null && sudo chmod 600 /etc/rancher/k3s/config.yaml" <<EOF
server: "https://$SERVER_IP:6443"
token: "$K3S_TOKEN"
node-label:
  - "gha-runner=true"
kubelet-arg:
  - "system-reserved=cpu=500m,memory=1Gi,ephemeral-storage=10Gi"
  - "kube-reserved=cpu=500m,memory=1Gi,ephemeral-storage=5Gi"
  - "eviction-hard=memory.available<500Mi,nodefs.available<10%,nodefs.inodesFree<5%,imagefs.available<10%"
  - "max-pods=110"
  - "image-gc-high-threshold=75"
  - "image-gc-low-threshold=60"
EOF
s "$IP" "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION='$K3S_VERSION' sh -s - agent >/dev/null"

echo "== Chờ $NODE Ready"
for _ in $(seq 1 60); do
  st=$(s "$SERVER_IP" "kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || true)
  [[ $st == True ]] && break
  sleep 5
done
[[ $st == True ]] || die "$NODE chưa Ready sau 5 phút: xem 'sudo journalctl -u k3s-agent' trên $IP"

echo "== Kéo sẵn image"
s "$IP" "sudo k3s crictl pull docker.io/library/docker:dind >/dev/null"
[[ -n $RUNNER_IMAGE ]] && s "$IP" "sudo k3s crictl pull $RUNNER_IMAGE >/dev/null"

s "$SERVER_IP" "kubectl get node $NODE -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,LABEL:.metadata.labels.gha-runner"
echo "== Xong: $NODE đã vào cụm"
)

main "$@"
