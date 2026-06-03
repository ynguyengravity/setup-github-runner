#!/usr/bin/env bash
# =============================================================================
# lxc-runner-lib.sh — Shared library cho LXC GitHub Runner
#
# Source file này SAU KHI đã định nghĩa:
#   - Biến môi trường : GITHUB_TOKEN, ORGNAME, DRY_RUN,
#                       SOURCE_CONTAINER_ID, CLONE_SCRIPT,
#                       RUNNER_LABELS, RUNNER_GROUP, GITHUB_RUNNER_URL, LOG_FILE
#   - Logging funcs   : info, warn, error  (và tùy chọn: ok)
#
# Các hàm được export:
#   lxc_is_running        <vmid>
#   lxc_get_hostname      <vmid>
#   lxc_deregister_runner <runner_name>
#   lxc_destroy_container <vmid> <hostname>
#   lxc_create_runner                           → in new_vmid ra stdout
#   lxc_verify_runner_online <runner_name> [max_wait_seconds]
# =============================================================================

# Fallback cho 'ok' nếu caller không định nghĩa (lxc-disk-monitor dùng info)
declare -f ok &>/dev/null || ok() { info "$1"; }

# -----------------------------------------------------------------------------
# Kiểm tra container có đang chạy không
# -----------------------------------------------------------------------------
lxc_is_running() {
    local vmid="$1"
    pct status "$vmid" 2>/dev/null | grep -q "status: running"
}

# -----------------------------------------------------------------------------
# Lấy hostname của container
# -----------------------------------------------------------------------------
lxc_get_hostname() {
    local vmid="$1"
    pct config "$vmid" 2>/dev/null | grep '^hostname:' | awk '{print $2}' || echo "unknown-$vmid"
}

# -----------------------------------------------------------------------------
# [Internal] Tìm runner ID trên GitHub theo tên (có phân trang)
# Print runner_id ra stdout; return 1 nếu không tìm thấy
# -----------------------------------------------------------------------------
_lxc_find_runner_id() {
    local runner_name="$1"
    local runner_id="" page=1

    while true; do
        local response
        response=$(curl -s -L \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/orgs/${ORGNAME}/actions/runners?per_page=100&page=${page}")

        if command -v python3 &>/dev/null; then
            runner_id=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if r.get('name') == '${runner_name}':
        print(r['id'])
        break
" 2>/dev/null || echo "")
        else
            runner_id=$(echo "$response" | grep -A2 "\"name\":\"${runner_name}\"" \
                | grep '"id":' | head -1 | grep -o '[0-9]*' || echo "")
        fi

        [ -n "$runner_id" ] && { echo "$runner_id"; return 0; }

        local count
        count=$(echo "$response" | grep -o '"id":[0-9]*' | wc -l)
        [ "$count" -lt 100 ] && break
        (( page++ ))
    done

    return 1
}

# -----------------------------------------------------------------------------
# Hủy đăng ký runner khỏi GitHub
# -----------------------------------------------------------------------------
lxc_deregister_runner() {
    local runner_name="$1"
    info "Hủy đăng ký runner '$runner_name' khỏi GitHub..."

    if $DRY_RUN; then
        warn "[DRY-RUN] Bỏ qua deregister"
        return 0
    fi

    local runner_id
    if ! runner_id=$(_lxc_find_runner_id "$runner_name"); then
        warn "Không tìm thấy runner '$runner_name' trên GitHub (đã offline hoặc chưa đăng ký)"
        return 0
    fi

    info "Tìm thấy runner ID: $runner_id — Đang xóa khỏi GitHub..."

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L \
        -X DELETE \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/orgs/${ORGNAME}/actions/runners/${runner_id}")

    if [ "$http_code" = "204" ]; then
        ok "✅ Đã hủy đăng ký runner '$runner_name' (ID: $runner_id)"
    else
        warn "DELETE trả về HTTP $http_code — runner sẽ tự offline sau khi container bị xóa"
    fi
}

# -----------------------------------------------------------------------------
# Dừng và xóa LXC container
# -----------------------------------------------------------------------------
lxc_destroy_container() {
    local vmid="$1"
    local hostname="$2"

    if $DRY_RUN; then
        warn "[DRY-RUN] Sẽ xóa container $vmid ($hostname)"
        return 0
    fi

    info "Dừng container $vmid ($hostname)..."
    pct stop "$vmid" --timeout 30 2>/dev/null || true

    # Chờ container thật sự dừng để tránh race-condition khi destroy.
    local waited=0
    while lxc_is_running "$vmid" && [ "$waited" -lt 30 ]; do
        sleep 2
        waited=$(( waited + 2 ))
    done

    if lxc_is_running "$vmid"; then
        warn "Container $vmid vẫn đang chạy sau stop thường, thử force-stop..."
        pct stop "$vmid" --timeout 10 --overrule-shutdown 1 2>/dev/null || true

        waited=0
        while lxc_is_running "$vmid" && [ "$waited" -lt 20 ]; do
            sleep 2
            waited=$(( waited + 2 ))
        done
    fi

    if lxc_is_running "$vmid"; then
        error "Không thể dừng container $vmid, hủy thao tác destroy để đảm bảo an toàn"
        return 1
    fi

    info "Xóa container $vmid ($hostname)..."
    local destroy_output=""
    if ! destroy_output=$(pct destroy "$vmid" --destroy-unreferenced-disks 1 --purge 1 2>&1); then
        if echo "$destroy_output" | grep -qi "container is running"; then
            warn "Destroy báo container đang chạy, thử stop + destroy lần nữa..."
            pct stop "$vmid" --timeout 10 --overrule-shutdown 1 2>/dev/null || true
            sleep 2

            if lxc_is_running "$vmid"; then
                error "Container $vmid vẫn running sau retry, cần xử lý thủ công"
                return 1
            fi

            pct destroy "$vmid" --destroy-unreferenced-disks 1 --purge 1
        else
            error "Destroy container $vmid thất bại: $destroy_output"
            return 1
        fi
    fi

    ok "✅ Đã xóa container $vmid"
}

# -----------------------------------------------------------------------------
# Clone container mới từ template (qua clone script)
# Print new VMID ra stdout khi thành công
# -----------------------------------------------------------------------------
lxc_create_runner() {
    if $DRY_RUN; then
        warn "[DRY-RUN] Sẽ clone container mới từ template ID: ${SOURCE_CONTAINER_ID}"
        warn "[DRY-RUN] Script: ${CLONE_SCRIPT}"
        return 0
    fi

    if [ ! -f "$CLONE_SCRIPT" ]; then
        error "Không tìm thấy clone script: $CLONE_SCRIPT"
        return 1
    fi

    if [ -z "$GITHUB_TOKEN" ]; then
        error "GITHUB_TOKEN chưa được đặt — không thể tạo runner"
        return 1
    fi

    info "Gọi clone script: $CLONE_SCRIPT"
    info "Template source container ID: ${SOURCE_CONTAINER_ID}"

    local exit_code=0
    env \
        GITHUB_TOKEN="$GITHUB_TOKEN" \
        SOURCE_CONTAINER_ID="$SOURCE_CONTAINER_ID" \
        ORGNAME="$ORGNAME" \
        RUNNER_LABELS="$RUNNER_LABELS" \
        RUNNER_GROUP="$RUNNER_GROUP" \
        GITHUB_RUNNER_URL="$GITHUB_RUNNER_URL" \
        bash "$CLONE_SCRIPT" 2>&1 | tee -a "$LOG_FILE" || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        error "❌ Clone script thất bại (exit code: $exit_code)"
        return 1
    fi

    ok "✅ Clone script hoàn tất thành công"

    # Trả về VMID mới nhất (container vừa được tạo)
    pvesh get /nodes/localhost/lxc --output-format json 2>/dev/null \
        | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' \
        | sort -n | tail -1
}

# -----------------------------------------------------------------------------
# Xác minh runner đã online trên GitHub (poll)
# Usage: lxc_verify_runner_online <runner_name> [max_wait_seconds=90]
# -----------------------------------------------------------------------------
lxc_verify_runner_online() {
    local expected_name="$1"
    local max_wait="${2:-90}"

    info "Xác minh runner '$expected_name' online trên GitHub (tối đa ${max_wait}s)..."

    if $DRY_RUN; then
        warn "[DRY-RUN] Bỏ qua verify"
        return 0
    fi

    local attempts=$(( max_wait / 10 ))
    [ "$attempts" -lt 1 ] && attempts=1

    local found=false
    local runner_status=""

    for attempt in $(seq 1 "$attempts"); do
        info "  Lần kiểm tra ${attempt}/${attempts}..."
        sleep 10

        local response
        response=$(curl -s -L \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/orgs/${ORGNAME}/actions/runners?per_page=100")

        if command -v python3 &>/dev/null; then
            runner_status=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if r.get('name') == '${expected_name}':
        print(r.get('status', 'unknown'))
        break
" 2>/dev/null || echo "")
        else
            runner_status=$(echo "$response" | grep -A5 "\"name\":\"${expected_name}\"" \
                | grep '"status"' | head -1 | grep -o '"[a-z]*"$' | tr -d '"' || echo "")
        fi

        if [ -n "$runner_status" ]; then
            found=true
            break
        fi
    done

    if $found; then
        ok "✅ Runner '$expected_name' đã online — Status: $runner_status"
    else
        warn "⚠️  Không tìm thấy runner '$expected_name' sau ${max_wait}s"
        warn "   Kiểm tra log trong container hoặc chạy lại sau."
        return 1
    fi
}
