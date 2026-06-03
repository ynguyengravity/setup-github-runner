#!/usr/bin/env bash
# Cài đặt Docker + cấu hình overlay2 cho LXC
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

curl -fsSL https://get.docker.com | sh

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{"storage-driver":"overlay2","iptables":false}
EOF

mkdir -p /etc/systemd/system/docker.service.d/
cat > /etc/systemd/system/docker.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
EOF

apt-get update -qq && apt-get install -y apparmor-utils
systemctl disable apparmor || true
systemctl stop apparmor    || true

systemctl daemon-reload
systemctl restart docker
docker run --rm hello-world || echo "⚠️  Docker test failed — continuing"
echo "✅ docker installed"
