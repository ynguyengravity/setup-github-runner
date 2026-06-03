#!/usr/bin/env bash
# =============================================================================
# monitor-menu.sh  —  Menu quản lý LXC Disk Monitor
# Chạy: bash monitor-menu.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/lxc-monitor"

# ── Màu ──────────────────────────────────────────────────────────────────────
R='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[31m'; GRN='\033[32m'; YLW='\033[33m'
BLU='\033[34m'; CYN='\033[36m'; WHT='\033[37m'
BG_BLU='\033[44m'; BG_GRN='\033[42m'; BG_RED='\033[41m'

# ── Helpers ───────────────────────────────────────────────────────────────────
clear_screen() { clear; }

pause() {
    echo ""
    echo -e "  ${DIM}Nhấn Enter để quay lại menu...${R}"
    read -r
}

header() {
    clear_screen
    echo -e "${BOLD}${BG_BLU}${WHT}"
    printf "  %-76s\n" "🖥️  LXC Disk Monitor — Menu Quản Lý"
    echo -e "${R}"
    echo -e "  ${DIM}Script dir : ${SCRIPT_DIR}${R}"
    echo -e "  ${DIM}Install dir: ${INSTALL_DIR}${R}"
    echo ""
}

# Lấy trạng thái timer
timer_status_badge() {
    if systemctl is-active --quiet lxc-disk-monitor.timer 2>/dev/null; then
        echo -e "${BG_GRN}${BOLD} RUNNING ${R}"
    elif systemctl is-enabled --quiet lxc-disk-monitor.timer 2>/dev/null; then
        echo -e "${YLW}${BOLD} ENABLED (stopped) ${R}"
    else
        echo -e "${BG_RED}${BOLD} NOT INSTALLED ${R}"
    fi
}

# Lấy lần chạy kế tiếp
next_run() {
    systemctl list-timers lxc-disk-monitor.timer --no-pager 2>/dev/null \
        | grep lxc-disk-monitor \
        | awk '{print $1, $2}' || echo "N/A"
}

# Kiểm tra đã cài chưa
is_installed() {
    [ -f /etc/systemd/system/lxc-disk-monitor.timer ]
}

is_env_configured() {
    [ -f "${INSTALL_DIR}/.env" ] && \
    ! grep -q 'your_token_here' "${INSTALL_DIR}/.env" 2>/dev/null
}

# ── Màn hình chính ────────────────────────────────────────────────────────────
show_menu() {
    header

    local status_badge
    status_badge=$(timer_status_badge)

    echo -e "  Status  : ${status_badge}"

    if is_installed; then
        echo -e "  Next run: ${CYN}$(next_run)${R}"
    fi

    if is_env_configured; then
        echo -e "  Config  : ${GRN}✅ .env đã cấu hình${R}"
    else
        echo -e "  Config  : ${YLW}⚠️  .env chưa cấu hình (cần điền GITHUB_TOKEN)${R}"
    fi

    echo ""
    echo -e "  ${BOLD}─── Cài đặt ───────────────────────────────────${R}"
    echo -e "  ${CYN}1${R}  📦 Cài đặt schedule (install)"
    echo -e "  ${CYN}2${R}  🗑️  Gỡ cài đặt (uninstall)"
    echo -e "  ${CYN}3${R}  🗑️  Gỡ toàn bộ kể cả .env và log (--purge)"
    echo ""
    echo -e "  ${BOLD}─── Vận hành ──────────────────────────────────${R}"
    echo -e "  ${CYN}4${R}  🔍 Xem trạng thái timer & service"
    echo -e "  ${CYN}5${R}  🖥️  Mở live dashboard (UI)"
    echo -e "  ${CYN}6${R}  📋 Check disk ngay (check-only, không action)"
    echo -e "  ${CYN}7${R}  🧪 Dry-run (mô phỏng xóa/tạo, không thật)"
    echo -e "  ${CYN}8${R}  ▶️  Chạy monitor ngay (thật)"
    echo ""
    echo -e "  ${BOLD}─── Timer ─────────────────────────────────────${R}"
    echo -e "  ${CYN}9${R}  ▶️  Start timer"
    echo -e "  ${CYN}10${R} ⏹️  Stop timer (tạm dừng)"
    echo -e "  ${CYN}11${R} 🔄 Restart timer"
    echo ""
    echo -e "  ${BOLD}─── Cấu hình & Log ────────────────────────────${R}"
    echo -e "  ${CYN}12${R} ✏️  Chỉnh sửa .env"
    echo -e "  ${CYN}13${R} 📄 Xem log hôm nay"
    echo -e "  ${CYN}14${R} 📄 Xem log realtime (tail -f)"
    echo -e "  ${CYN}15${R} 📖 Xem hướng dẫn setup"
    echo ""
    echo -e "  ${BOLD}─── Testing ───────────────────────────────────${R}"
    echo -e "  ${CYN}16${R} 🧪 Test full cycle: deregister → destroy → clone → verify"
    echo ""
    echo -e "  ${RED}0${R}  ❌ Thoát"
    echo ""
    echo -ne "  ${BOLD}Chọn: ${R}"
}

# ── Các action ────────────────────────────────────────────────────────────────

do_install() {
    header
    echo -e "  ${BOLD}📦 Cài đặt schedule${R}\n"

    if is_installed; then
        echo -e "  ${YLW}⚠️  Schedule đã được cài đặt rồi.${R}"
        echo -e "  Muốn cài lại? Gỡ trước bằng option 2, sau đó cài lại."
        pause; return
    fi

    local install_script="${SCRIPT_DIR}/install-monitor.sh"
    if [ ! -f "$install_script" ]; then
        echo -e "  ${RED}❌ Không tìm thấy install-monitor.sh${R}"
        pause; return
    fi

    bash "$install_script"
    pause
}

do_uninstall() {
    local purge="${1:-}"
    header
    if [ "$purge" = "--purge" ]; then
        echo -e "  ${BOLD}${RED}🗑️  Gỡ toàn bộ (--purge)${R}\n"
    else
        echo -e "  ${BOLD}🗑️  Gỡ cài đặt${R}\n"
    fi

    if ! is_installed; then
        echo -e "  ${YLW}ℹ️  Schedule chưa được cài đặt.${R}"
        pause; return
    fi

    echo -ne "  ${YLW}Xác nhận? (y/N): ${R}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "  Đã huỷ."; pause; return
    fi

    local uninstall_script="${SCRIPT_DIR}/uninstall-monitor.sh"
    if [ ! -f "$uninstall_script" ]; then
        echo -e "  ${RED}❌ Không tìm thấy uninstall-monitor.sh${R}"
        pause; return
    fi

    bash "$uninstall_script" $purge
    pause
}

do_status() {
    header
    echo -e "  ${BOLD}🔍 Trạng thái timer & service${R}\n"

    echo -e "  ${CYN}── Timer ──${R}"
    systemctl status lxc-disk-monitor.timer --no-pager 2>/dev/null \
        || echo "  (chưa cài đặt)"

    echo ""
    echo -e "  ${CYN}── Service ──${R}"
    systemctl status lxc-disk-monitor.service --no-pager 2>/dev/null \
        || echo "  (chưa cài đặt)"

    echo ""
    echo -e "  ${CYN}── Lịch chạy kế tiếp ──${R}"
    systemctl list-timers lxc-disk-monitor.timer --no-pager 2>/dev/null \
        || echo "  (chưa cài đặt)"

    pause
}

do_ui() {
    local ui="${INSTALL_DIR}/lxc-monitor-ui.sh"
    if [ ! -f "$ui" ]; then
        ui="${SCRIPT_DIR}/lxc-monitor-ui.sh"
    fi
    if [ ! -f "$ui" ]; then
        header
        echo -e "  ${RED}❌ Không tìm thấy lxc-monitor-ui.sh${R}"
        pause; return
    fi
    bash "$ui"
}

do_check() {
    local mode="$1"
    header
    case "$mode" in
        check-only) echo -e "  ${BOLD}📋 Check disk (check-only)${R}\n" ;;
        dry-run)    echo -e "  ${BOLD}🧪 Dry-run${R}\n" ;;
        run)        echo -e "  ${BOLD}▶️  Chạy monitor thật${R}\n"
                    echo -ne "  ${YLW}Xác nhận chạy thật? (y/N): ${R}"
                    read -r confirm
                    [[ ! "$confirm" =~ ^[yY]$ ]] && { echo "  Đã huỷ."; pause; return; }
                    ;;
    esac

    local script="${INSTALL_DIR}/lxc-disk-monitor.sh"
    if [ ! -f "$script" ]; then
        script="${SCRIPT_DIR}/lxc-disk-monitor.sh"
    fi

    case "$mode" in
        check-only) bash "$script" --check-only ;;
        dry-run)    bash "$script" --dry-run ;;
        run)        bash "$script" ;;
    esac

    pause
}

do_timer_action() {
    local action="$1"
    header
    case "$action" in
        start)   echo -e "  ${BOLD}▶️  Start timer${R}\n"
                 systemctl start lxc-disk-monitor.timer && \
                     echo -e "  ${GRN}✅ Timer đã start${R}" || \
                     echo -e "  ${RED}❌ Thất bại — timer chưa cài?${R}" ;;
        stop)    echo -e "  ${BOLD}⏹️  Stop timer${R}\n"
                 systemctl stop lxc-disk-monitor.timer && \
                     echo -e "  ${YLW}⏹️  Timer đã stop${R}" || \
                     echo -e "  ${RED}❌ Thất bại${R}" ;;
        restart) echo -e "  ${BOLD}🔄 Restart timer${R}\n"
                 systemctl restart lxc-disk-monitor.timer && \
                     echo -e "  ${GRN}✅ Timer đã restart${R}" || \
                     echo -e "  ${RED}❌ Thất bại${R}" ;;
    esac
    pause
}

do_edit_env() {
    header
    echo -e "  ${BOLD}✏️  Chỉnh sửa .env${R}\n"

    local env_file="${INSTALL_DIR}/.env"
    if [ ! -f "$env_file" ]; then
        echo -e "  ${YLW}⚠️  Chưa có file .env tại ${env_file}${R}"
        echo -ne "  Tạo từ .env.example? (y/N): "
        read -r confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            mkdir -p "$INSTALL_DIR"
            cp "${SCRIPT_DIR}/.env.example" "$env_file"
            chmod 600 "$env_file"
            echo -e "  ${GRN}✅ Đã tạo ${env_file}${R}"
        else
            pause; return
        fi
    fi

    # Dùng editor có sẵn
    local editor="${EDITOR:-nano}"
    command -v "$editor" &>/dev/null || editor="vi"
    $editor "$env_file"
}

do_log() {
    local mode="$1"
    header
    local log_file="/var/log/lxc-monitor/lxc-monitor-$(date +%Y%m%d).log"

    if [ ! -f "$log_file" ]; then
        echo -e "  ${YLW}⚠️  Chưa có log hôm nay: ${log_file}${R}"
        echo -e "  ${DIM}(Chạy monitor ít nhất 1 lần để tạo log)${R}"
        pause; return
    fi

    case "$mode" in
        view) less +G "$log_file" ;;
        tail) echo -e "  ${DIM}Ctrl+C để thoát...${R}\n"
              tail -f "$log_file" ;;
    esac
}

do_guide() {
    local guide="${SCRIPT_DIR}/MONITOR-SETUP.md"
    if [ ! -f "$guide" ]; then
        header
        echo -e "  ${RED}❌ Không tìm thấy MONITOR-SETUP.md${R}"
        pause; return
    fi
    # Dùng less nếu có, fallback cat
    if command -v less &>/dev/null; then
        less "$guide"
    else
        clear_screen
        cat "$guide"
        pause
    fi
}

do_test_runner() {
    header
    echo -e "  ${BOLD}🧪 Test Full Cycle — Deregister → Destroy → Clone → Verify${R}\n"

    local test_script="${SCRIPT_DIR}/lxc-test-runner.sh"
    if [ ! -f "$test_script" ]; then
        echo -e "  ${RED}❌ Không tìm thấy lxc-test-runner.sh${R}"
        pause; return
    fi

    echo -e "  ${YLW}Chọn chế độ chạy:${R}"
    echo -e "  ${CYN}1${R}  Thật   — xóa và tạo lại container"
    echo -e "  ${CYN}2${R}  Dry-run — mô phỏng, không thay đổi thật"
    echo -e "  ${CYN}0${R}  Huỷ"
    echo ""
    echo -ne "  ${BOLD}Chọn: ${R}"
    read -r mode_choice

    case "$mode_choice" in
        1) bash "$test_script" ;;
        2) bash "$test_script" --dry-run ;;
        0) return ;;
        *) echo -e "  ${RED}Lựa chọn không hợp lệ.${R}"; sleep 1; return ;;
    esac

    pause
}

# ── Main loop ─────────────────────────────────────────────────────────────────
main() {
    # Kiểm tra root (một số action cần root)
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${YLW}⚠️  Một số chức năng cần quyền root (install, uninstall, timer control).${R}"
        echo -e "   Chạy lại bằng: ${BOLD}sudo bash $0${R}"
        echo ""
        sleep 2
    fi

    while true; do
        show_menu
        read -r choice

        case "$choice" in
            1)  do_install ;;
            2)  do_uninstall ;;
            3)  do_uninstall "--purge" ;;
            4)  do_status ;;
            5)  do_ui ;;
            6)  do_check "check-only" ;;
            7)  do_check "dry-run" ;;
            8)  do_check "run" ;;
            9)  do_timer_action "start" ;;
            10) do_timer_action "stop" ;;
            11) do_timer_action "restart" ;;
            12) do_edit_env ;;
            13) do_log "view" ;;
            14) do_log "tail" ;;
            15) do_guide ;;
            16) do_test_runner ;;
            0)  clear_screen; echo -e "  ${DIM}Thoát.${R}\n"; exit 0 ;;
            *)  echo -e "\n  ${RED}❌ Lựa chọn không hợp lệ.${R}"; sleep 1 ;;
        esac
    done
}

main "$@"
