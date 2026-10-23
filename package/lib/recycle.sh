#!/usr/bin/env bash
# lxc-runner recycle: dọn hoặc rebuild runner container khi disk >= DISK_THRESHOLD,
# chỉ khi runner đang rảnh (không có job).
#
# Luồng cho mỗi container:
#   1. disk < DISK_THRESHOLD                → bỏ qua
#   2. runner đang bận (GitHub API / Runner.Worker) → bỏ qua, lần sau thử lại
#   3. drain: gỡ custom labels trên GitHub, chờ, kiểm tra lại, stop runner service
#   4. dọn (docker prune, _work, apt, journal) → disk < CLEAN_TARGET thì trả runner về
#   5. còn đầy → clone runner mới từ template, gỡ đăng ký + xóa container cũ

set -uo pipefail

LXC_RUNNER_LIB="${LXC_RUNNER_LIB:-/usr/lib/lxc-runner}"
# shellcheck source=common.sh
source "$LXC_RUNNER_LIB/common.sh"
load_config

DRY_RUN="${DRY_RUN:-0}"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) err "Tham số không hợp lệ: $arg"; exit 2 ;;
    esac
done

DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
CLEAN_TARGET="${CLEAN_TARGET:-80}"
CLEANUP="${CLEANUP:-1}"
MAX_REBUILDS_PER_RUN="${MAX_REBUILDS_PER_RUN:-1}"
REBUILD_HOURS="${REBUILD_HOURS:-}"          # vd "1-6"; rỗng = bất kỳ lúc nào
LXC_IDS="${LXC_IDS:-}"                      # vd "101,102"; rỗng = tất cả runner
DRAIN_WAIT="${DRAIN_WAIT:-20}"              # giây chờ sau khi gỡ labels
ONLINE_WAIT="${ONLINE_WAIT:-180}"           # giây chờ runner mới online
STORAGE_MARGIN_GB="${STORAGE_MARGIN_GB:-10}"
PCT_STORAGE="${PCT_STORAGE:-local-lvm2}"

REBUILT=0 CLEANED=0 SKIPPED_BUSY=0 FAILED=0
RUNNERS='[]'
SAVED_LABELS='[]'

# ── Helpers ────────────────────────────────────────────────────────────────

in_rebuild_window() {
    [ -z "$REBUILD_HOURS" ] && return 0
    local start="${REBUILD_HOURS%-*}" end="${REBUILD_HOURS#*-}" h
    h=$((10#$(date +%H)))
    if [ "$start" -le "$end" ]; then
        [ "$h" -ge "$start" ] && [ "$h" -lt "$end" ]
    else
        [ "$h" -ge "$start" ] || [ "$h" -lt "$end" ]
    fi
}

# Trả về 0 = bận, 1 = rảnh, 2 = không xác định (coi như bận)
runner_busy() {
    local vmid="$1" name="$2" runner
    runner=$(gh_find_runner "$name") || return 2
    if [ -n "$runner" ] && [ "$(jq -r '.busy' <<< "$runner")" = "true" ]; then
        return 0
    fi
    ct_job_running "$vmid" && return 0
    return 1
}

# Gỡ labels để GitHub không giao job mới, rồi stop runner service.
# Trả về 0 nếu drain thành công, 1 nếu runner nhận job trong lúc drain.
drain() {
    local vmid="$1" name="$2" runner="$3" id
    SAVED_LABELS='[]'
    if [ -n "$runner" ]; then
        id=$(jq -r '.id' <<< "$runner")
        SAVED_LABELS=$(jq -c '[.labels[] | select(.type == "custom") | .name]' <<< "$runner")
        info "  Drain: gỡ labels $SAVED_LABELS khỏi runner $id"
        gh_api DELETE "/orgs/${ORGNAME}/actions/runners/${id}/labels" > /dev/null ||
            warn "  Gỡ labels thất bại"
    fi

    sleep "$DRAIN_WAIT"
    local rc
    runner_busy "$vmid" "$name"; rc=$?
    if [ "$rc" -ne 1 ]; then
        warn "  Runner nhận job trong lúc drain — trả lại labels, bỏ qua"
        undrain "$vmid" "$runner"
        return 1
    fi

    ct_runner_service stop "$vmid" || warn "  Stop runner service thất bại"
    return 0
}

# Khởi động lại runner service và trả lại labels đã gỡ
undrain() {
    local vmid="$1" runner="$2" id
    ct_runner_service start "$vmid" || warn "  Start runner service thất bại"
    if [ -n "$runner" ] && [ "$SAVED_LABELS" != "[]" ]; then
        id=$(jq -r '.id' <<< "$runner")
        gh_api PUT "/orgs/${ORGNAME}/actions/runners/${id}/labels" \
            "$(jq -nc --argjson l "$SAVED_LABELS" '{labels: $l}')" > /dev/null ||
            warn "  Trả lại labels thất bại — kiểm tra runner $id trên GitHub"
    fi
}

cleanup_ct() {
    pct exec "$1" -- bash -c '
        docker system prune -af > /dev/null 2>&1 || true
        docker volume prune -f > /dev/null 2>&1 || true
        if [ -d /root/actions-runner/_work ]; then
            find /root/actions-runner/_work -mindepth 1 -maxdepth 1 \
                ! -name _tool ! -name _actions -exec rm -rf {} +
        fi
        apt-get clean
        journalctl --vacuum-size=100M > /dev/null 2>&1 || true
        rm -rf /root/.npm/_cacache
        find /tmp -mindepth 1 -mtime +1 -delete 2>/dev/null || true
    '
}

# Clone runner mới qua clone.sh, đặt NEW_ID. Log của clone.sh đi ra stderr (journal).
clone_new() {
    local logf rc
    NEW_ID=""
    logf=$(mktemp)
    "$LXC_RUNNER_LIB/clone.sh" < /dev/null 2>&1 | tee "$logf" >&2
    rc=${PIPESTATUS[0]}
    NEW_ID=$(sed -n 's/^NEW_PCTID=\([0-9]*\)$/\1/p' "$logf" | tail -n1)
    rm -f "$logf"
    [ "$rc" -eq 0 ] && [ -n "$NEW_ID" ]
}

wait_online() {
    local name="$1" waited=0 runner
    while [ "$waited" -lt "$ONLINE_WAIT" ]; do
        runner=$(gh_find_runner "$name") || runner=""
        if [ -n "$runner" ] && [ "$(jq -r '.status' <<< "$runner")" = "online" ]; then
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
    done
    return 1
}

destroy_ct() {
    local vmid="$1" runner="$2" id
    if [ -n "$runner" ]; then
        id=$(jq -r '.id' <<< "$runner")
        gh_api DELETE "/orgs/${ORGNAME}/actions/runners/${id}" > /dev/null ||
            warn "  Gỡ đăng ký runner $id thất bại — runner sẽ offline, xóa tay trên GitHub"
    fi
    pct stop "$vmid" > /dev/null 2>&1 || true
    pct destroy "$vmid" --purge
}

# Đủ chỗ trên storage để clone trước khi xóa container cũ?
# Không đọc được số liệu → coi như đủ (clone trước là hướng an toàn: lỗi thì giữ container cũ)
storage_allows_clone_first() {
    local node avail need
    node=$(pve_node)
    avail=$(pvesh get "/nodes/${node}/storage/${PCT_STORAGE}/status" --output-format json 2>/dev/null | jq '.avail // empty | floor')
    need=$(pvesh get "/nodes/${node}/lxc/${SOURCE_CONTAINER_ID}/status/current" --output-format json 2>/dev/null | jq '.maxdisk // empty | floor')
    if [ -z "$avail" ] || [ -z "$need" ]; then
        warn "  Không đọc được dung lượng storage ${PCT_STORAGE} — clone trước"
        return 0
    fi
    need=$((need + STORAGE_MARGIN_GB * 1024 * 1024 * 1024))
    [ "$avail" -ge "$need" ]
}

rebuild() {
    local vmid="$1" name="$2" runner="$3" new_name

    if storage_allows_clone_first; then
        info "  Rebuild (clone trước, xóa sau)"
        if ! clone_new; then
            notify "❌ LXC rebuild FAILED | ${vmid} (${name}) | clone lỗi — giữ container cũ"
            undrain "$vmid" "$runner"
            return 1
        fi
        new_name=$(pct config "$NEW_ID" | awk '/^hostname:/ {print $2}')
        if ! wait_online "$new_name"; then
            notify "❌ LXC rebuild FAILED | runner mới ${NEW_ID} (${new_name}) không online sau ${ONLINE_WAIT}s — giữ container cũ ${vmid}, kiểm tra ${NEW_ID}"
            undrain "$vmid" "$runner"
            return 1
        fi
        destroy_ct "$vmid" "$runner"
    else
        info "  Rebuild (storage ${PCT_STORAGE} không đủ chỗ — xóa trước, clone sau)"
        destroy_ct "$vmid" "$runner"
        if ! clone_new; then
            notify "❌ LXC rebuild FAILED | đã xóa ${vmid} (${name}) nhưng clone lỗi — thiếu 1 runner"
            return 1
        fi
        new_name=$(pct config "$NEW_ID" | awk '/^hostname:/ {print $2}')
        wait_online "$new_name" ||
            notify "⚠️ LXC rebuild | runner mới ${NEW_ID} (${new_name}) chưa online sau ${ONLINE_WAIT}s"
    fi

    notify "✅ LXC rebuilt | ${vmid} (${name}) → ${NEW_ID} (${new_name})"
    return 0
}

# ── Per-container ──────────────────────────────────────────────────────────

process_ct() {
    local vmid="$1" name="$2" status="$3" disk="$4" maxdisk="$5"
    local pct_used runner after rc

    if [ "$status" != "running" ]; then
        info "[$vmid] $name: $status — bỏ qua"
        return 0
    fi

    if [ "$maxdisk" -gt 0 ]; then
        pct_used=$((disk * 100 / maxdisk))
    else
        pct_used=$(ct_disk_pct "$vmid")
    fi
    if [ -z "$pct_used" ] || [ "$pct_used" -lt "$DISK_THRESHOLD" ]; then
        info "[$vmid] $name: disk ${pct_used:-?}% — OK"
        return 0
    fi

    warn "[$vmid] $name: disk ${pct_used}% >= ${DISK_THRESHOLD}%"

    if ! ct_has_runner "$vmid"; then
        warn "  Không có /root/actions-runner/.runner — không phải runner đã đăng ký, bỏ qua"
        return 0
    fi

    runner=$(jq -c --arg n "$name" 'map(select(.name == $n)) | first // empty' <<< "$RUNNERS")
    [ -z "$runner" ] && warn "  Runner '$name' không có trên GitHub"

    runner_busy "$vmid" "$name"; rc=$?
    if [ "$rc" -ne 1 ]; then
        info "  Runner đang bận — thử lại lần sau"
        SKIPPED_BUSY=$((SKIPPED_BUSY + 1))
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        info "  [DRY-RUN] Sẽ drain → dọn → rebuild nếu vẫn >= ${CLEAN_TARGET}%"
        return 0
    fi

    if ! drain "$vmid" "$name" "$runner"; then
        SKIPPED_BUSY=$((SKIPPED_BUSY + 1))
        return 0
    fi

    if [ "$CLEANUP" = "1" ]; then
        info "  Dọn container..."
        cleanup_ct "$vmid" || warn "  Dọn có lỗi"
        after=$(ct_disk_pct "$vmid")
        info "  Sau khi dọn: ${after:-?}%"
        if [ -n "$after" ] && [ "$after" -lt "$CLEAN_TARGET" ]; then
            undrain "$vmid" "$runner"
            notify "🧹 LXC cleaned | ${vmid} (${name}) | ${pct_used}% → ${after}%"
            CLEANED=$((CLEANED + 1))
            return 0
        fi
    fi

    if [ "$REBUILT" -ge "$MAX_REBUILDS_PER_RUN" ] || ! in_rebuild_window; then
        undrain "$vmid" "$runner"
        # Log only: notifying here would repeat every timer tick until the rebuild happens
        warn "  Disk vẫn ${after:-$pct_used}% — chờ lượt rebuild sau (giới hạn mỗi lượt / khung giờ)"
        return 0
    fi

    if rebuild "$vmid" "$name" "$runner"; then
        REBUILT=$((REBUILT + 1))
    else
        FAILED=$((FAILED + 1))
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────

require_root
require_token

mkdir -p "$LXC_RUNNER_STATE"
exec 9> "$LXC_RUNNER_STATE/recycle.lock"
if ! flock -n 9; then
    info "Lần chạy trước chưa xong — bỏ qua"
    exit 0
fi

info "Recycle: threshold ${DISK_THRESHOLD}%, clean target ${CLEAN_TARGET}%, dry-run ${DRY_RUN}"

if ! RUNNERS=$(gh_list_runners); then
    err "Không đọc được danh sách runner từ GitHub — dừng để tránh xóa nhầm runner đang chạy job"
    exit 1
fi

CTS=$(pve_list_runner_cts) || { err "Không đọc được danh sách container"; exit 1; }
if [ -n "$LXC_IDS" ]; then
    CTS=$(jq -c --arg ids "$LXC_IDS" '($ids | split(",") | map(tonumber)) as $f | map(select(.vmid as $v | $f | index($v)))' <<< "$CTS")
fi

# Read the list on fd 3: pct exec inside the loop would otherwise consume stdin
while IFS=$'\t' read -r vmid name status disk maxdisk <&3; do
    process_ct "$vmid" "$name" "$status" "$disk" "$maxdisk"
done 3< <(jq -r '.[] | [.vmid, .name, .status, (.disk | floor), (.maxdisk | floor)] | @tsv' <<< "$CTS")

info "Xong: rebuilt ${REBUILT}, cleaned ${CLEANED}, bận ${SKIPPED_BUSY}, lỗi ${FAILED}"
[ "$FAILED" -eq 0 ]
