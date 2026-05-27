#!/usr/bin/env bash
# =============================================================================
# install-monitor.sh
# Cài đặt lxc-disk-monitor vào Proxmox host
#
# Chạy trên Proxmox host với quyền root:
#   bash install-monitor.sh
# =============================================================================

set -euo pipefail

INSTALL_DIR="/opt/lxc-monitor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "\033[34m=== Cài đặt LXC Disk Monitor ===\033[0m"

# Kiểm tra root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Script này cần chạy với quyền root!"
    exit 1
fi

# Kiểm tra đang chạy trên Proxmox
if ! command -v pct &>/dev/null; then
    echo "❌ Không tìm thấy lệnh 'pct'. Script này chỉ chạy trên Proxmox VE!"
    exit 1
fi

# Tạo thư mục cài đặt
echo "📁 Tạo thư mục $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Copy files
echo "📋 Copy script và config..."
cp "${SCRIPT_DIR}/lxc-disk-monitor.sh" "${INSTALL_DIR}/lxc-disk-monitor.sh"
cp "${SCRIPT_DIR}/lxc-monitor-ui.sh"  "${INSTALL_DIR}/lxc-monitor-ui.sh"
chmod +x "${INSTALL_DIR}/lxc-disk-monitor.sh"
chmod +x "${INSTALL_DIR}/lxc-monitor-ui.sh"

# Copy .env nếu chưa có
if [ ! -f "${INSTALL_DIR}/.env" ]; then
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        cp "${SCRIPT_DIR}/.env" "${INSTALL_DIR}/.env"
        echo "✅ Đã copy file .env"
    else
        cp "${SCRIPT_DIR}/.env.example" "${INSTALL_DIR}/.env"
        echo "⚠️  Đã copy .env.example thành .env - Hãy chỉnh sửa file này!"
    fi
    chmod 600 "${INSTALL_DIR}/.env"  # bảo mật token
else
    echo "ℹ️  File .env đã tồn tại, giữ nguyên."
fi

# Cài systemd service và timer
echo "⚙️  Cài đặt systemd service và timer..."
cp "${SCRIPT_DIR}/lxc-disk-monitor.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/lxc-disk-monitor.timer" /etc/systemd/system/

# Cập nhật đường dẫn trong service file
sed -i "s|ExecStart=.*lxc-disk-monitor.sh|ExecStart=${INSTALL_DIR}/lxc-disk-monitor.sh|g" \
    /etc/systemd/system/lxc-disk-monitor.service
sed -i "s|WorkingDirectory=.*|WorkingDirectory=${INSTALL_DIR}|g" \
    /etc/systemd/system/lxc-disk-monitor.service

# Reload và enable
systemctl daemon-reload
systemctl enable lxc-disk-monitor.timer
systemctl start lxc-disk-monitor.timer

echo ""
echo -e "\033[32m✅ Cài đặt hoàn tất!\033[0m"
echo ""
echo "📌 Bước tiếp theo:"
echo "   1. Chỉnh sửa file cấu hình:"
echo "      nano ${INSTALL_DIR}/.env"
echo ""
echo "   2. Test chạy thủ công (check-only, không xóa):"
echo "      ${INSTALL_DIR}/lxc-disk-monitor.sh --check-only"
echo ""
echo "   3. Xem trạng thái timer:"
echo "      systemctl status lxc-disk-monitor.timer"
echo "      systemctl list-timers lxc-disk-monitor.timer"
echo ""
echo "   4. Xem log:"
echo "      journalctl -u lxc-disk-monitor.service -f"
echo "      tail -f /var/log/lxc-monitor/lxc-monitor-\$(date +%Y%m%d).log"
echo ""
echo "   5. Mở live dashboard UI:"
echo "      ${INSTALL_DIR}/lxc-monitor-ui.sh"
echo "      ${INSTALL_DIR}/lxc-monitor-ui.sh -i 60   # refresh mỗi 60 giây"
echo ""
echo "   6. Chạy thủ công ngay:"
echo "      systemctl start lxc-disk-monitor.service"
echo "      # hoặc:"
echo "      ${INSTALL_DIR}/lxc-disk-monitor.sh --dry-run"
echo ""

# Nhắc cấu hình .env nếu chưa có token
if grep -q 'your_token_here' "${INSTALL_DIR}/.env" 2>/dev/null; then
    echo -e "\033[33m⚠️  QUAN TRỌNG: Hãy cập nhật GITHUB_TOKEN trong ${INSTALL_DIR}/.env trước khi dùng!\033[0m"
fi
