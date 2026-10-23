#!/usr/bin/env bash
# build.sh – Build image runner vn-gaqc-runner trên VM registry-mirror, push vào registry nội bộ
# 192.168.8.5:5001, rồi kéo sẵn về các worker. Không dùng ghcr hay registry bên ngoài.
# Chạy bằng root trên Proxmox host, cùng thư mục với Dockerfile:
#
#   bash build.sh                 # RUNNER_VERSION mặc định bên dưới
#   bash build.sh 2.339.0         # build cho runner version khác
#
# Mỗi lần build có tag riêng <runner-version>-<YYYYmmddHHMM>, để node không dùng nhầm bản cũ đã cache
# (pod dùng imagePullPolicy IfNotPresent). Script in ra tag; sửa 2 dòng image: trong
# k8s/runner-values.yaml thành tag đó rồi helm upgrade.

main() (
set -euo pipefail

RUNNER_VERSION=${1:-${RUNNER_VERSION:-2.338.1}}
MIRROR=${MIRROR:-ubuntu@192.168.8.5}
SERVER=${SERVER:-ubuntu@192.168.8.2}
# Mặc định lấy IP mọi worker (label gha-runner=true) từ cụm, để worker mới cũng được kéo sẵn image
WORKERS=${WORKERS:-$(ssh -o BatchMode=yes "$SERVER" "kubectl get nodes -l gha-runner=true -o jsonpath='{.items[*].status.addresses[?(@.type==\"InternalIP\")].address}'" 2>/dev/null)}
REGISTRY=${REGISTRY:-192.168.8.5:5001}
NAME=vn-gaqc-runner
TAG="${RUNNER_VERSION}-$(date +%Y%m%d%H%M)"
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[[ -f $DIR/Dockerfile ]] || { echo "Không thấy $DIR/Dockerfile" >&2; exit 2; }

[[ -n $WORKERS ]] || { echo "Không lấy được danh sách worker từ $SERVER (đặt WORKERS=\"ip1 ip2 ...\")" >&2; exit 2; }
echo "== Worker sẽ kéo sẵn image: $WORKERS"

echo "== Kiểm tra registry nội bộ trên mirror"
ssh -o BatchMode=yes "$MIRROR" 'curl -fsS http://localhost:5001/v2/ >/dev/null' \
  || { echo "Registry localhost:5001 trên mirror chưa chạy (cd /opt/mirror && sudo docker compose up -d)" >&2; exit 1; }

echo "== Chép Dockerfile lên mirror"
ssh -o BatchMode=yes "$MIRROR" 'mkdir -p ~/runner-image'
scp -q "$DIR/Dockerfile" "$MIRROR:runner-image/Dockerfile"

echo "== Build $NAME:$TAG (runner $RUNNER_VERSION), mất khoảng 10–25 phút"
ssh -o BatchMode=yes "$MIRROR" "cd ~/runner-image && sudo docker build --pull \
  --build-arg RUNNER_VERSION=$RUNNER_VERSION -t localhost:5001/$NAME:$TAG . \
  && sudo docker push localhost:5001/$NAME:$TAG \
  && sudo docker image rm localhost:5001/$NAME:$TAG >/dev/null \
  && sudo docker builder prune -f --filter until=168h >/dev/null"

echo "== Kéo sẵn image về worker"
for ip in $WORKERS; do
  echo "   $ip"
  ssh -o BatchMode=yes "ubuntu@$ip" "sudo k3s crictl pull $REGISTRY/$NAME:$TAG >/dev/null"
done

echo
echo "Xong. Image: $REGISTRY/$NAME:$TAG"
echo "Bước tiếp theo (trên k3s-server-1):"
echo "  sed -i 's#image: .*actions-runner:[^ ]*#image: $REGISTRY/$NAME:$TAG#; s#image: $REGISTRY/$NAME:[^ ]*#image: $REGISTRY/$NAME:$TAG#' ~/runner-values.yaml"
echo "  grep -n 'image:' ~/runner-values.yaml"
echo "  helm upgrade vn-gaqc-docker -n arc-runners -f ~/runner-values.yaml --version \"\$ARC_VERSION\" oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
)

main "$@"
