#!/usr/bin/env bash
# Cài đặt lxc-runner vào Proxmox host tại /opt/lxc-monitor
set -euo pipefail

INSTALL_DIR="/opt/lxc-monitor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Cài đặt LXC Runner (Python) ==="

[ "$(id -u)" -ne 0 ] && { echo "❌ Cần chạy với quyền root!"; exit 1; }
command -v pct &>/dev/null || { echo "❌ Không phải Proxmox VE!"; exit 1; }
command -v python3 &>/dev/null || { echo "❌ python3 chưa được cài!"; exit 1; }

# Cài python3-venv nếu chưa có (Debian/Ubuntu không có sẵn)
if ! python3 -m venv --help &>/dev/null; then
    PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    echo "📦 Cài python${PY_VER}-venv..."
    apt-get install -y "python${PY_VER}-venv"
fi

mkdir -p "$INSTALL_DIR"

# Copy toàn bộ project
echo "📋 Copy files..."
rsync -a --exclude='.git' --exclude='*.pyc' --exclude='__pycache__' \
    "${SCRIPT_DIR}/" "${INSTALL_DIR}/"

# Tạo virtualenv và cài dependencies
echo "🐍 Tạo virtualenv và cài packages..."
python3 -m venv "${INSTALL_DIR}/venv"
"${INSTALL_DIR}/venv/bin/pip" install -q --upgrade pip
"${INSTALL_DIR}/venv/bin/pip" install -q -r "${INSTALL_DIR}/requirements.txt"
"${INSTALL_DIR}/venv/bin/pip" install -q -e "${INSTALL_DIR}"

# Cấu hình .env
if [ ! -f "${INSTALL_DIR}/.env" ]; then
    cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
    chmod 600 "${INSTALL_DIR}/.env"
    echo "⚠️  Đã tạo .env — hãy điền GITHUB_TOKEN và ORGNAME!"
else
    echo "ℹ️  .env đã tồn tại, giữ nguyên."
fi

# Cài systemd
echo "⚙️  Cài systemd service và timer..."
cp "${INSTALL_DIR}/systemd/lxc-disk-monitor.service" /etc/systemd/system/
cp "${INSTALL_DIR}/systemd/lxc-disk-monitor.timer"   /etc/systemd/system/

systemctl daemon-reload
systemctl enable lxc-disk-monitor.timer
systemctl start  lxc-disk-monitor.timer

echo ""
echo "✅ Cài đặt hoàn tất!"
echo ""
echo "📌 Bước tiếp theo:"
echo "   1. Điền config:  nano ${INSTALL_DIR}/.env"
echo "   2. Test:         ${INSTALL_DIR}/venv/bin/lxc-runner monitor --check-only"
echo "   3. Dashboard:    ${INSTALL_DIR}/venv/bin/lxc-runner ui"
echo "   4. Xem log:      journalctl -u lxc-disk-monitor.service -f"
echo "   5. Timer status: systemctl list-timers lxc-disk-monitor.timer"
