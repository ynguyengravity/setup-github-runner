#!/usr/bin/env bash
# =============================================================================
# uninstall-monitor.sh
# Gỡ cài đặt lxc-disk-monitor khỏi Proxmox host
#
# Chạy trên Proxmox host với quyền root:
#   bash uninstall-monitor.sh
#   bash uninstall-monitor.sh --purge   # xóa luôn cả .env và log
# =============================================================================

set -euo pipefail

INSTALL_DIR="/opt/lxc-monitor"
PURGE=false

for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=true ;;
        --help|-h)
            echo "Usage: $0 [--purge]"
            echo "  --purge : Xóa luôn cả .env, log, và thư mục cài đặt"
            exit 0
            ;;
    esac
done

echo -e "\033[34m=== Gỡ cài đặt LXC Disk Monitor ===\033[0m"

# Kiểm tra root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Script này cần chạy với quyền root!"
    exit 1
fi

# 1. Dừng và disable timer + service
echo "⏹️  Dừng timer và service..."
systemctl stop  lxc-disk-monitor.timer   2>/dev/null && echo "   ✅ Stopped timer"   || echo "   ℹ️  Timer không đang chạy"
systemctl stop  lxc-disk-monitor.service 2>/dev/null && echo "   ✅ Stopped service" || echo "   ℹ️  Service không đang chạy"
systemctl disable lxc-disk-monitor.timer 2>/dev/null && echo "   ✅ Disabled timer"  || true

# 2. Xóa systemd unit files
echo "🗑️  Xóa systemd unit files..."
rm -f /etc/systemd/system/lxc-disk-monitor.service && echo "   ✅ Removed .service"
rm -f /etc/systemd/system/lxc-disk-monitor.timer   && echo "   ✅ Removed .timer"
systemctl daemon-reload
echo "   ✅ daemon-reload xong"

# 3. Xóa scripts (giữ lại .env và log theo mặc định)
echo "🗑️  Xóa scripts..."
rm -f "${INSTALL_DIR}/lxc-disk-monitor.sh" 2>/dev/null && echo "   ✅ Removed lxc-disk-monitor.sh"  || true
rm -f "${INSTALL_DIR}/lxc-monitor-ui.sh"   2>/dev/null && echo "   ✅ Removed lxc-monitor-ui.sh"    || true

if $PURGE; then
    echo "🗑️  --purge: Xóa .env, log và thư mục..."
    rm -f  "${INSTALL_DIR}/.env"
    rm -rf /var/log/lxc-monitor
    rm -rf "${INSTALL_DIR}"
    echo "   ✅ Đã xóa toàn bộ ${INSTALL_DIR} và /var/log/lxc-monitor"
else
    echo ""
    echo -e "\033[33mℹ️  Giữ lại (dùng --purge để xóa hết):\033[0m"
    [ -f "${INSTALL_DIR}/.env"  ] && echo "   📄 ${INSTALL_DIR}/.env"
    [ -d /var/log/lxc-monitor   ] && echo "   📁 /var/log/lxc-monitor/"
fi

echo ""
echo -e "\033[32m✅ Gỡ cài đặt hoàn tất!\033[0m"

# Xác nhận không còn timer nào chạy
echo ""
echo "📋 Kiểm tra lại:"
systemctl list-timers lxc-disk-monitor.timer 2>/dev/null || echo "   (không còn timer nào)"
