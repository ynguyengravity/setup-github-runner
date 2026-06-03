#!/usr/bin/env bash
# =============================================================================
# lxc-test-runner.sh
# Test full cycle cho 1 container: deregister GitHub → destroy → clone → verify
#
# Cách dùng:
#   ./lxc-test-runner.sh                     # hỏi container ID
#   ./lxc-test-runner.sh <VMID>              # chỉ định container ID
#   ./lxc-test-runner.sh <VMID> --dry-run    # mô phỏng, không thật
#   ./lxc-test-runner.sh --help
# =============================================================================

set -euo pipefail

# ── Parse args ────────────────────────────────────────────────────────────────
TARGET_VMID=""
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [VMID] [--dry-run]"
            echo ""
            echo "  VMID       Container ID cần test (nếu không truyền sẽ hỏi)"
            echo "  --dry-run  Mô phỏng, không xóa/tạo container thật"
            exit 0
            ;;
        [0-9]*)  TARGET_VMID="$arg" ;;
    esac
done

# ── Load .env ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Thử INSTALL_DIR trước, fallback về SCRIPT_DIR
ENV_FILE="/opt/lxc-monitor/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Không tìm thấy .env tại $ENV_FILE"
    echo "   Hãy tạo: cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
    exit 1
fi

set -o allexport
# shellcheck source=.env
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | sed 's/[[:space:]]*#.*//')
set +o allexport

: "${GITHUB_TOKEN:?'GITHUB_TOKEN chưa được đặt trong .env'}"
: "${ORGNAME:?'ORGNAME chưa được đặt trong .env'}"

SOURCE_CONTAINER_ID="${SOURCE_CONTAINER_ID:-100}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
GITHUB_RUNNER_URL="${GITHUB_RUNNER_URL:-https://github.com/actions/runner/releases/download/v2.334.0/actions-runner-linux-x64-2.334.0.tar.gz}"
LOG_DIR="${LOG_DIR:-/var/log/lxc-monitor}"
CLONE_SCRIPT="${SCRIPT_DIR}/lxc_create_github_actions_runner.clone.sh"

# ── Màu & log ─────────────────────────────────────────────────────────────────
R='\033[0m'; BOLD='\033[1m'
GRN='\033[32m'; YLW='\033[33m'; RED='\033[31m'; CYN='\033[36m'; BLU='\033[34m'

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/lxc-test-$(date +%Y%m%d-%H%M%S).log"

log() {
    local level="$1" msg="$2"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$ts] [$level] $msg"
    case "$level" in
        INFO)  echo -e "${GRN}${line}${R}" ;;
        WARN)  echo -e "${YLW}${line}${R}" ;;
        ERROR) echo -e "${RED}${line}${R}" ;;
        STEP)  echo -e "\n${BOLD}${CYN}${line}${R}" ;;
        OK)    echo -e "${GRN}${BOLD}${line}${R}" ;;
    esac
    echo "$line" >> "$LOG_FILE"
}

info()  { log "INFO"  "$1"; }
warn()  { log "WARN"  "$1"; }
error() { log "ERROR" "$1"; }
step()  { log "STEP"  "$1"; }
ok()    { log "OK"    "$1"; }

separator() {
    local line="================================================================"
    echo -e "${BLU}${line}${R}"
    echo "$line" >> "$LOG_FILE"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Load shared library (dùng chung remove/destroy/clone/verify với monitor)
# shellcheck source=lxc-runner-lib.sh
source "${SCRIPT_DIR}/lxc-runner-lib.sh"

# Liệt kê các container github-runner đang chạy
list_runners() {
    pvesh get /nodes/localhost/lxc --output-format json 2>/dev/null \
        | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' \
        | while read -r vmid; do
            local hn
            hn=$(pct config "$vmid" 2>/dev/null | grep '^hostname:' | awk '{print $2}' || echo "")
            if echo "$hn" | grep -q "github-runner"; then
                local st
                st=$(pct status "$vmid" 2>/dev/null | awk '{print $2}' || echo "?")
                printf "  %-6s %-40s %s\n" "$vmid" "$hn" "$st"
            fi
          done
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    separator
    info "🧪 LXC Test Runner — Full Cycle Test"
    info "   Org   : ${ORGNAME}"
    info "   Source: container ID ${SOURCE_CONTAINER_ID}"
    $DRY_RUN && warn "   ⚠️  CHẾ ĐỘ DRY-RUN — không thực hiện thay đổi thật"
    separator

    # Chọn container cần test
    if [ -z "$TARGET_VMID" ]; then
        echo ""
        echo -e "  ${BOLD}Danh sách GitHub Runner containers đang có:${R}"
        list_runners || echo "  (không tìm thấy, hoặc chưa có quyền)"
        echo ""
        echo -ne "  ${BOLD}Nhập Container ID cần test (0 để huỷ): ${R}"
        read -r TARGET_VMID
        [ "$TARGET_VMID" = "0" ] && { info "Đã huỷ."; exit 0; }
    fi

    # Validate VMID
    if ! [[ "$TARGET_VMID" =~ ^[0-9]+$ ]]; then
        error "VMID không hợp lệ: '$TARGET_VMID'"
        exit 1
    fi

    if ! pct status "$TARGET_VMID" &>/dev/null; then
        error "Container $TARGET_VMID không tồn tại trên Proxmox"
        exit 1
    fi

    local hostname
    hostname=$(lxc_get_hostname "$TARGET_VMID")

    separator
    info "Container đích  : $TARGET_VMID ($hostname)"
    info "Template source : $SOURCE_CONTAINER_ID"
    info "Log file        : $LOG_FILE"
    separator

    echo ""
    echo -e "  ${YLW}${BOLD}⚠️  CẢNH BÁO: Thao tác này sẽ XÓA container $TARGET_VMID và tạo mới!${R}"
    $DRY_RUN && echo -e "  ${GRN}(DRY-RUN — không xóa thật)${R}"
    echo ""
    echo -ne "  Xác nhận tiến hành? (y/N): "
    read -r confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && { info "Đã huỷ."; exit 0; }

    local start_time
    start_time=$(date +%s)

    # ── 4 bước ────────────────────────────────────────────────────────────────

    # Step 1: Deregister
    step "STEP 1/4 — Hủy đăng ký runner '$hostname' khỏi GitHub"
    lxc_deregister_runner "$hostname"

    # Step 2: Destroy
    step "STEP 2/4 — Xóa container $TARGET_VMID ($hostname)"
    lxc_destroy_container "$TARGET_VMID" "$hostname"

    # Step 3: Clone
    local new_vmid=""
    step "STEP 3/4 — Clone container mới từ template ID: $SOURCE_CONTAINER_ID"
    new_vmid=$(lxc_create_runner) || { error "❌ Clone thất bại — dừng test"; exit 1; }

    # Step 4: Verify (tên runner được đặt bởi clone script)
    local current_date
    current_date=$(date +%Y%m%d)-27
    local new_hostname="github-runner-${new_vmid}-${current_date}"

    step "STEP 4/4 — Xác minh runner '$new_hostname' đã online trên GitHub"
    lxc_verify_runner_online "$new_hostname" 90

    # ── Tóm tắt ───────────────────────────────────────────────────────────────
    local elapsed=$(( $(date +%s) - start_time ))
    separator
    ok "🎉 TEST HOÀN TẤT"
    info "   Container cũ  : $TARGET_VMID ($hostname) → đã xóa"
    $DRY_RUN || info "   Container mới : $new_vmid ($new_hostname)"
    info "   Thời gian      : ${elapsed}s"
    info "   Log            : $LOG_FILE"
    separator
}

main "$@"
