#!/usr/bin/env bash
# Cài đặt OpenVPN + cấu hình TUN device
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

apt update -y
apt install -y openvpn openvpn-systemd-resolved resolvconf net-tools iptables iproute2
systemctl enable openvpn

ls -la /dev/net/tun && echo "TUN device exists" || echo "⚠️  TUN device not found"
echo "✅ openvpn installed"
