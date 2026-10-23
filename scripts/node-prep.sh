#!/usr/bin/env bash
# node-prep.sh – Bước 2 của docs/proxmox-k3s-arc-guide.md: chuẩn bị OS cho các node k3s
# (server + worker; VM registry-mirror không cần).
#
# Chạy từ Proxmox Shell cho từng node:
#   for ip in 192.168.8.2 192.168.8.3 192.168.8.4 192.168.8.6; do   # worker mới: join-worker.sh tự chạy script này
#     ssh -o StrictHostKeyChecking=accept-new ubuntu@$ip 'bash -s' < node-prep.sh
#   done
set -euo pipefail

# Mọi container dind chạy uid 0 nên DÙNG CHUNG giới hạn inotify của root;
# mặc định 128 instance sẽ cạn khi có khoảng 20 pod
sudo tee /etc/sysctl.d/90-k3s-runners.conf >/dev/null <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 1048576
fs.file-max                   = 2097152
vm.max_map_count              = 262144
EOF
sudo sysctl --system >/dev/null

# Không bao giờ tự reboot; reboot theo quy trình ở phần Vận hành của guide
echo 'Unattended-Upgrade::Automatic-Reboot "false";' | sudo tee /etc/apt/apt.conf.d/52unattended-no-reboot >/dev/null

sudo systemctl enable --now chrony

echo "host=$(hostname) cpu=$(nproc) mem=$(free -g | awk '/Mem/{print $2}')G disk=$(df -h / | awk 'NR==2{print $2}')"
echo "inotify=$(sysctl -n fs.inotify.max_user_instances) $(swapon --show | grep -q . && echo 'WARN: swap đang bật' || echo 'swap: off') $(chronyc tracking | awk -F': ' '/Leap status/{print "time: " $2}')"
