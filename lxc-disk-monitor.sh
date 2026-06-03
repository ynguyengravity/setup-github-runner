#!/usr/bin/env bash
# =============================================================================
# lxc-disk-monitor.sh
# Tự động kiểm tra disk LXC GitHub runner, xóa và tạo lại khi disk đầy
#
# Cách dùng:
#   ./lxc-disk-monitor.sh                # chạy thủ công
#   ./lxc-disk-monitor.sh --dry-run      # mô phỏng, không xóa/tạo thật
#   ./lxc-disk-monitor.sh --check-only   # chỉ check và in kết quả, không action
#
# Setup lần đầu:
#   cp .env.example .env
#   nano .env
#   chmod +x lxc-disk-monitor.sh
# =============================================================================

set -euo pipefail

# --- Parse Arguments ---
DRY_RUN=false
CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --check-only) CHECK_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--check-only]"
            echo "  --dry-run    : Mô phỏng, không thực hiện xóa/tạo container"
            echo "  --check-only : Chỉ kiểm tra và in trạng thái, không action"
            exit 0
            ;;
    esac
done

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ ERROR: File .env không tìm thấy tại $ENV_FILE"
    echo "   Hãy copy .env.example thành .env và điền giá trị:"
    echo "   cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
    exit 1
fi

# Load .env (bỏ qua comment và dòng trống)
set -o allexport
# shellcheck source=.env
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | sed 's/[[:space:]]*#.*//')
set +o allexport

# --- Validate bắt buộc ---
: "${GITHUB_TOKEN:?'GITHUB_TOKEN chưa được đặt trong .env'}"
: "${ORGNAME:?'ORGNAME chưa được đặt trong .env'}"

# --- Default values ---
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
LXC_IDS="${LXC_IDS:-auto}"
LXC_NAME_PATTERN="${LXC_NAME_PATTERN:-github-runner-}"
LXC_COUNT="${LXC_COUNT:-35}"
SOURCE_CONTAINER_ID="${SOURCE_CONTAINER_ID:-100}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted}"
GITHUB_RUNNER_URL="${GITHUB_RUNNER_URL:-https://github.com/actions/runner/releases/download/v2.334.0/actions-runner-linux-x64-2.334.0.tar.gz}"
LOG_DIR="${LOG_DIR:-/var/log/lxc-monitor}"
LOG_RETAIN_DAYS="${LOG_RETAIN_DAYS:-30}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# Maintenance window: chỉ rebuild trong khoảng giờ này (giờ thấp điểm)
# Ngoài window → chỉ cảnh báo, không rebuild (tránh gián đoạn CI/CD đang chạy)
MAINTENANCE_START="${MAINTENANCE_START:-1}"   # 1 AM
MAINTENANCE_END="${MAINTENANCE_END:-6}"       # 6 AM

CLONE_SCRIPT="${SCRIPT_DIR}/lxc_create_github_actions_runner.clone.sh"

# =============================================================================
# SHARED LIBRARY
# =============================================================================

# shellcheck source=lxc-runner-lib.sh
# (sourced sau khi định nghĩa xong logging để lib dùng được info/warn/error)

# =============================================================================
# LOGGING
# =============================================================================

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/lxc-monitor-$(date +%Y%m%d).log"

log() {
    local level="$1"
    local msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$ts] [$level] $msg"

    # In màu ra terminal
    case "$level" in
        INFO)  echo -e "\033[32m$line\033[0m" ;;
        WARN)  echo -e "\033[33m$line\033[0m" ;;
        ERROR) echo -e "\033[31m$line\033[0m" ;;
        *)     echo "$line" ;;
    esac

    # Ghi vào file log
    echo "$line" >> "$LOG_FILE"
}

info()  { log "INFO"  "$1"; }
warn()  { log "WARN"  "$1"; }
error() { log "ERROR" "$1"; }

separator() {
    local line="================================================================"
    echo -e "\033[34m$line\033[0m"
    echo "$line" >> "$LOG_FILE"
}

# =============================================================================
# NOTIFICATION
# =============================================================================

notify() {
    local msg="$1"
    # Telegram
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${msg}" \
            -d "parse_mode=Markdown" > /dev/null 2>&1 || true
    fi
    # Slack
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        curl -s -X POST \
            -H 'Content-type: application/json' \
            --data "{\"text\":\"${msg}\"}" \
            "$SLACK_WEBHOOK_URL" > /dev/null 2>&1 || true
    fi
}

# =============================================================================
# HELPERS
# =============================================================================

# Lấy danh sách LXC IDs cần monitor
get_lxc_ids() {
    if [ "$LXC_IDS" = "auto" ]; then
        # Tự động tìm container theo pattern tên
        pvesh get /nodes/localhost/lxc --output-format json 2>/dev/null \
            | grep -o '"vmid":[0-9]*' \
            | grep -o '[0-9]*' \
            | while read -r vmid; do
                local hostname
                hostname=$(pct config "$vmid" 2>/dev/null | grep '^hostname:' | awk '{print $2}' || echo "")
                if echo "$hostname" | grep -q "$LXC_NAME_PATTERN"; then
                    echo "$vmid"
                fi
              done
    else
        # Dùng danh sách cố định từ .env
        echo "$LXC_IDS" | tr ',' '\n' | tr -d ' '
    fi
}

# Kiểm tra có đang trong maintenance window không
in_maintenance_window() {
    local hour
    hour=$(date +%-H)  # giờ hiện tại, không có leading zero
    if [ "$MAINTENANCE_START" -le "$MAINTENANCE_END" ]; then
        # Window không qua nửa đêm, ví dụ: 1–6
        [ "$hour" -ge "$MAINTENANCE_START" ] && [ "$hour" -lt "$MAINTENANCE_END" ]
    else
        # Window qua nửa đêm, ví dụ: 22–4
        [ "$hour" -ge "$MAINTENANCE_START" ] || [ "$hour" -lt "$MAINTENANCE_END" ]
    fi
}

# Kiểm tra disk usage (%) của container  (monitor-specific, không vào lib)
get_disk_usage() {
    local vmid="$1"
    pct exec "$vmid" -- bash -c "df / --output=pcent | tail -1 | tr -d ' %'" 2>/dev/null || echo "0"
}

# Load shared library (sau khi logging đã được định nghĩa)
# shellcheck source=lxc-runner-lib.sh
source "${SCRIPT_DIR}/lxc-runner-lib.sh"

# =============================================================================
# MAIN LOGIC
# =============================================================================

main() {
    separator
    info "🚀 LXC Disk Monitor - Bắt đầu kiểm tra"
    info "   Threshold : ${DISK_THRESHOLD}% | Org: ${ORGNAME} | Max LXC: ${LXC_COUNT}"
    info "   Window    : ${MAINTENANCE_START}h–${MAINTENANCE_END}h | Giờ hiện tại: $(date +%-H)h ($(in_maintenance_window && echo 'TRONG window → rebuild ON' || echo 'NGOÀI window → chỉ cảnh báo'))"
    $DRY_RUN    && warn "   ⚠️  CHẾ ĐỘ DRY-RUN - không thực hiện thay đổi thật"
    $CHECK_ONLY && warn "   ⚠️  CHẾ ĐỘ CHECK-ONLY - chỉ in kết quả"
    separator

    # Dọn log cũ
    find "$LOG_DIR" -name "lxc-monitor-*.log" -mtime +"$LOG_RETAIN_DAYS" -delete 2>/dev/null || true

    # Lấy danh sách LXC IDs
    local ids=()
    while IFS= read -r id; do
        [ -n "$id" ] && ids+=("$id")
    done < <(get_lxc_ids)

    if [ ${#ids[@]} -eq 0 ]; then
        warn "Không tìm thấy LXC container nào match với pattern '$LXC_NAME_PATTERN'"
        warn "Kiểm tra lại LXC_IDS hoặc LXC_NAME_PATTERN trong .env"
        exit 0
    fi

    info "Tìm thấy ${#ids[@]} container(s): ${ids[*]}"

    local rebuilt=0
    local skipped=0
    local failed=0

    for vmid in "${ids[@]}"; do
        separator
        local hostname
        hostname=$(lxc_get_hostname "$vmid")
        info "🔍 Kiểm tra container [$vmid] - $hostname"

        # Kiểm tra container có đang chạy không
        if ! lxc_is_running "$vmid"; then
            warn "   Container $vmid không đang chạy (trạng thái: $(pct status "$vmid" 2>/dev/null || echo 'unknown'))"
            warn "   Bỏ qua container này."
            (( skipped++ )) || true
            continue
        fi

        # Lấy disk usage
        local usage
        usage=$(get_disk_usage "$vmid")

        if ! [[ "$usage" =~ ^[0-9]+$ ]]; then
            warn "   Không đọc được disk usage của container $vmid (trả về: '$usage')"
            (( skipped++ )) || true
            continue
        fi

        info "   Disk usage: ${usage}% (ngưỡng: ${DISK_THRESHOLD}%)"

        if [ "$usage" -ge "$DISK_THRESHOLD" ]; then
            warn "   ⚠️  DISK ĐẦY! ${usage}% >= ${DISK_THRESHOLD}%"

            if $CHECK_ONLY; then
                warn "   [CHECK-ONLY] Bỏ qua hành động"
                continue
            fi

            # Kiểm tra maintenance window trước khi rebuild
            if in_maintenance_window; then
                warn "   🔧 Trong maintenance window (${MAINTENANCE_START}h–${MAINTENANCE_END}h) → Tiến hành rebuild"
                notify "⚠️ *LXC Disk Full* | \`$vmid\` ($hostname) | ${usage}% | Đang rebuild..."

                # Hủy đăng ký runner
                lxc_deregister_runner "$hostname"

                # Xóa container cũ
                lxc_destroy_container "$vmid" "$hostname"

                # Tạo container mới bằng clone script
                local new_id=""
                if new_id=$(lxc_create_runner); then
                    info "   ✅ Rebuild xong! Container mới: $new_id"
                    notify "✅ *LXC Rebuilt* | Cũ: \`$vmid\` → Mới: \`$new_id\`"
                    (( rebuilt++ )) || true
                else
                    error "   ❌ Rebuild thất bại! Cần kiểm tra thủ công."
                    notify "❌ *LXC Rebuild FAILED* | \`$vmid\` ($hostname) | Kiểm tra thủ công!"
                    (( failed++ )) || true
                fi
            else
                local current_hour
                current_hour=$(date +%-H)
                warn "   ⏳ Ngoài maintenance window (hiện tại: ${current_hour}h, window: ${MAINTENANCE_START}h–${MAINTENANCE_END}h)"
                warn "   → Chỉ cảnh báo, sẽ rebuild lúc ${MAINTENANCE_START}h"
                notify "⚠️ *LXC Disk Full* | \`$vmid\` ($hostname) | ${usage}% | Chờ maintenance window ${MAINTENANCE_START}h–${MAINTENANCE_END}h để rebuild"
                (( skipped++ )) || true
            fi
        else
            info "   ✅ Disk OK (${usage}% < ${DISK_THRESHOLD}%) - không cần action"
            (( skipped++ )) || true
        fi
    done

    # =========================================================================
    # AUTO SCALE UP: tạo thêm container nếu số lượng hiện tại < LXC_COUNT
    # =========================================================================
    separator
    local current_count=${#ids[@]}
    local needed=$(( LXC_COUNT - current_count ))

    info "📊 Số lượng LXC: ${current_count}/${LXC_COUNT}"

    if [ "$needed" -gt 0 ]; then
        warn "⚠️  Thiếu ${needed} container — cần tạo thêm để đủ ${LXC_COUNT}"

        if $CHECK_ONLY; then
            warn "   [CHECK-ONLY] Bỏ qua tạo mới"
        elif in_maintenance_window; then
            info "   🔧 Trong maintenance window → Tạo thêm ${needed} container..."
            notify "🔧 *LXC Scale Up* | Hiện có: ${current_count}/${LXC_COUNT} | Đang tạo thêm ${needed}..."

            local created=0
            for (( i=1; i<=needed; i++ )); do
                info "   Tạo container mới ${i}/${needed}..."
                local new_id=""
                if new_id=$(lxc_create_runner); then
                    info "   ✅ Tạo xong container mới: $new_id (${i}/${needed})"
                    (( created++ )) || true
                    (( rebuilt++ )) || true
                else
                    error "   ❌ Tạo container ${i}/${needed} thất bại!"
                    notify "❌ *LXC Scale Up FAILED* | Tạo container ${i}/${needed} thất bại"
                    (( failed++ )) || true
                    break  # dừng nếu một lần tạo thất bại
                fi
            done

            info "   Tạo thêm xong: ${created}/${needed} container"
            notify "✅ *LXC Scale Up Done* | Đã tạo thêm ${created}/${needed} | Tổng: $(( current_count + created ))/${LXC_COUNT}"
        else
            local current_hour
            current_hour=$(date +%-H)
            warn "   ⏳ Ngoài maintenance window (${current_hour}h) → Sẽ tạo thêm lúc ${MAINTENANCE_START}h"
            notify "⚠️ *LXC thiếu* | ${current_count}/${LXC_COUNT} | Sẽ tạo thêm trong window ${MAINTENANCE_START}h–${MAINTENANCE_END}h"
        fi
    else
        info "   ✅ Đủ số lượng (${current_count}/${LXC_COUNT}) — không cần tạo thêm"
    fi

    separator
    info "📊 Kết quả:"
    info "   LXC hiện có         : ${current_count}/${LXC_COUNT}"
    info "   ✅ Tạo/tái tạo xong : $rebuilt container(s)"
    info "   ⏭️  Bỏ qua (OK/ngoài window): $skipped container(s)"
    [ "$failed" -gt 0 ] && error "   ❌ Thất bại          : $failed container(s)"
    info "   Log file: $LOG_FILE"
    separator
}

main "$@"
