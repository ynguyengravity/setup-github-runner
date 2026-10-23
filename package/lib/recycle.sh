#!/usr/bin/env bash
# lxc-runner recycle: dọn hoặc rebuild runner container khi disk >= DISK_THRESHOLD,
# chỉ khi runner đang rảnh (không có job).
#
# Luồng cho mỗi container:
#   1. disk < DISK_THRESHOLD                → bỏ qua
#   2. runner đang bận (GitHub API / Runner.Worker) → bỏ qua, lần sau thử lại
#   3. drain: gỡ custom labels trên GitHub, chờ, kiểm tra lại, stop runner service
#   4. số runner > MAX_RUNNERS → gỡ đăng ký + xóa container, không clone thêm
#   5. dọn (docker prune, _work, apt, journal) → disk < CLEAN_TARGET thì trả runner về
#   6. còn đầy → clone runner mới từ template, gỡ đăng ký + xóa container cũ
#
# Container đang tắt (2 lượt liên tiếp, không bị lock, có runner trên GitHub):
#   gỡ đăng ký + xóa; tổng <= MAX_RUNNERS thì clone thay.
# Cuối lượt: FILL_TO_MAX=1 và tổng < MAX_RUNNERS → clone thêm (tối đa MAX_CLONES_PER_RUN).

set -uo pipefail

LXC_RUNNER_LIB="${LXC_RUNNER_LIB:-/usr/lib/lxc-runner}"
# shellcheck source=common.sh
source "$LXC_RUNNER_LIB/common.sh"
load_config
# Secrets stay shell-local so pct exec (which keeps the host env) never passes them into
# containers; clone_new hands GITHUB_TOKEN to clone.sh explicitly
export -n GITHUB_TOKEN SLACK_WEBHOOK_URL TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

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
MAX_RUNNERS="${MAX_RUNNERS:-}"              # rỗng = không giới hạn (luôn clone thay thế)
REBUILD_HOURS="${REBUILD_HOURS:-}"          # vd "1-6"; rỗng = bất kỳ lúc nào
LXC_IDS="${LXC_IDS:-}"                      # vd "101,102"; rỗng = tất cả runner
DRAIN_WAIT="${DRAIN_WAIT:-20}"              # giây chờ sau khi gỡ labels
ONLINE_WAIT="${ONLINE_WAIT:-180}"           # giây chờ runner mới online
STORAGE_MARGIN_GB="${STORAGE_MARGIN_GB:-10}"
PCT_STORAGE="${PCT_STORAGE:-local-lvm2}"
FILL_TO_MAX="${FILL_TO_MAX:-0}"             # 1 = clone thêm cho đủ MAX_RUNNERS
MAX_CLONES_PER_RUN="${MAX_CLONES_PER_RUN:-2}"

REBUILT=0 REMOVED=0 CLEANED=0 ADDED=0 SKIPPED_BUSY=0 FAILED=0
RUNNER_TOTAL=0   # số runner container hiện có (cập nhật khi xóa/clone trong lượt này)
RUNNERS='[]'
SAVED_LABELS='[]'
# Container thấy đang tắt ở lượt trước / lượt này (chỉ xử lý khi tắt 2 lượt liên tiếp)
STOPPED_FILE="$LXC_RUNNER_STATE/stopped.list"
STOPPED_PREV=" $(cat "$STOPPED_FILE" 2>/dev/null | tr '\n' ' ') "
STOPPED_NOW=""

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
    GITHUB_TOKEN="$GITHUB_TOKEN" "$LXC_RUNNER_LIB/clone.sh" < /dev/null 2>&1 | tee "$logf" >&2
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

# Container đang tắt: gỡ đăng ký + xóa; tổng <= MAX_RUNNERS thì clone thay.
# Chỉ xử lý khi đã tắt từ lượt trước, không bị lock, và có runner cùng tên trên GitHub
# (không exec vào container tắt được để kiểm tra .runner — tránh xóa nhầm template cũ).
process_stopped() {
    local vmid="$1" name="$2" lock="$3" runner new_name

    if [ "$lock" != "-" ]; then
        info "[$vmid] $name: stopped, đang bị lock '$lock' — bỏ qua"
        return 0
    fi
    if [[ "$STOPPED_PREV" != *" $vmid:$name "* ]]; then
        STOPPED_NOW+="$vmid:$name "
        warn "[$vmid] $name: stopped — xử lý nếu lượt sau vẫn tắt"
        return 0
    fi

    runner=$(jq -c --arg n "$name" 'map(select(.name == $n)) | first // empty' <<< "$RUNNERS")
    if [ -z "$runner" ]; then
        STOPPED_NOW+="$vmid:$name "
        warn "[$vmid] $name: stopped nhưng không có runner cùng tên trên GitHub — không xóa (kiểm tra tay)"
        return 0
    fi
    if [ "$(jq -r '.busy' <<< "$runner")" = "true" ]; then
        STOPPED_NOW+="$vmid:$name "
        warn "[$vmid] $name: stopped nhưng GitHub báo busy — bỏ qua"
        return 0
    fi

    local over_max=0
    if [ -n "$MAX_RUNNERS" ] && [ "$RUNNER_TOTAL" -gt "$MAX_RUNNERS" ]; then
        over_max=1
    fi
    if [ "$over_max" = "0" ] && [ "$REBUILT" -ge "$MAX_REBUILDS_PER_RUN" ]; then
        STOPPED_NOW+="$vmid:$name "
        warn "[$vmid] $name: stopped — chờ lượt rebuild sau (giới hạn mỗi lượt)"
        return 0
    fi

    if [ "$DRY_RUN" = "1" ] || ! in_rebuild_window; then
        local why="[DRY-RUN]"
        [ "$DRY_RUN" = "1" ] || why="ngoài khung giờ ${REBUILD_HOURS}, lượt sau"
        STOPPED_NOW+="$vmid:$name "
        if [ "$over_max" = "1" ]; then
            info "[$vmid] $name: stopped — ${why} sẽ xóa, không clone (${RUNNER_TOTAL} > max ${MAX_RUNNERS})"
        else
            info "[$vmid] $name: stopped — ${why} sẽ xóa + clone thay"
        fi
        return 0
    fi

    warn "[$vmid] $name: stopped 2 lượt liên tiếp — xóa"
    if ! destroy_ct "$vmid" "$runner"; then
        notify "❌ LXC remove FAILED | ${vmid} (${name}) đang tắt"
        FAILED=$((FAILED + 1))
        return 0
    fi
    RUNNER_TOTAL=$((RUNNER_TOTAL - 1))

    if [ "$over_max" = "1" ]; then
        REMOVED=$((REMOVED + 1))
        notify "🗑️ LXC removed | ${vmid} (${name}) đang tắt | còn ${RUNNER_TOTAL}/${MAX_RUNNERS} runner"
        return 0
    fi

    if ! clone_new; then
        notify "❌ LXC replace FAILED | đã xóa ${vmid} (${name}) đang tắt nhưng clone lỗi — thiếu 1 runner"
        FAILED=$((FAILED + 1))
        return 0
    fi
    RUNNER_TOTAL=$((RUNNER_TOTAL + 1))
    REBUILT=$((REBUILT + 1))
    new_name=$(pct config "$NEW_ID" | awk '/^hostname:/ {print $2}')
    wait_online "$new_name" ||
        notify "⚠️ LXC replace | runner mới ${NEW_ID} (${new_name}) chưa online sau ${ONLINE_WAIT}s"
    notify "♻️ LXC replaced | ${vmid} (${name}) đang tắt → ${NEW_ID} (${new_name})"
}

# FILL_TO_MAX: clone thêm cho đủ MAX_RUNNERS (tối đa MAX_CLONES_PER_RUN mỗi lượt)
fill_to_max() {
    local missing n i new_name
    [ "$FILL_TO_MAX" = "1" ] && [ -n "$MAX_RUNNERS" ] || return 0
    if [ -n "$LXC_IDS" ]; then
        info "Fill: bỏ qua vì đang giới hạn LXC_IDS"
        return 0
    fi

    missing=$((MAX_RUNNERS - RUNNER_TOTAL))
    [ "$missing" -gt 0 ] || return 0
    n=$(( missing < MAX_CLONES_PER_RUN ? missing : MAX_CLONES_PER_RUN ))

    if [ "$DRY_RUN" = "1" ]; then
        info "Fill: [DRY-RUN] thiếu ${missing} runner (${RUNNER_TOTAL}/${MAX_RUNNERS}) — sẽ clone thêm ${n}"
        return 0
    fi
    if ! in_rebuild_window; then
        info "Fill: thiếu ${missing} runner — ngoài khung giờ ${REBUILD_HOURS}, chờ lượt sau"
        return 0
    fi

    info "Fill: thiếu ${missing} runner (${RUNNER_TOTAL}/${MAX_RUNNERS}) — clone thêm ${n}"
    for ((i = 1; i <= n; i++)); do
        if ! storage_allows_clone_first; then
            warn "Fill: storage ${PCT_STORAGE} không đủ chỗ — dừng"
            break
        fi
        if ! clone_new; then
            notify "❌ LXC fill FAILED | clone lỗi (${RUNNER_TOTAL}/${MAX_RUNNERS})"
            FAILED=$((FAILED + 1))
            break
        fi
        RUNNER_TOTAL=$((RUNNER_TOTAL + 1))
        ADDED=$((ADDED + 1))
        new_name=$(pct config "$NEW_ID" | awk '/^hostname:/ {print $2}')
        wait_online "$new_name" ||
            warn "Fill: runner mới ${NEW_ID} (${new_name}) chưa online sau ${ONLINE_WAIT}s"
    done
    [ "$ADDED" -gt 0 ] && notify "➕ LXC fill | clone thêm ${ADDED} → ${RUNNER_TOTAL}/${MAX_RUNNERS} runner"
    return 0
}

process_ct() {
    local vmid="$1" name="$2" status="$3" lock="$4" disk="$5" maxdisk="$6"
    local pct_used runner after rc

    if [ "$status" = "stopped" ]; then
        process_stopped "$vmid" "$name" "$lock"
        return 0
    fi
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

    local over_max=0
    if [ -n "$MAX_RUNNERS" ] && [ "$RUNNER_TOTAL" -gt "$MAX_RUNNERS" ]; then
        over_max=1
    fi

    if [ "$DRY_RUN" = "1" ]; then
        if [ "$over_max" = "1" ]; then
            info "  [DRY-RUN] ${RUNNER_TOTAL} runner > max ${MAX_RUNNERS} — sẽ drain → xóa, không clone thêm"
        else
            info "  [DRY-RUN] Sẽ drain → dọn → rebuild nếu vẫn >= ${CLEAN_TARGET}%"
        fi
        return 0
    fi

    if ! drain "$vmid" "$name" "$runner"; then
        SKIPPED_BUSY=$((SKIPPED_BUSY + 1))
        return 0
    fi

    # Vượt số lượng tối đa: xóa luôn, không dọn, không clone thay thế
    if [ "$over_max" = "1" ]; then
        if ! in_rebuild_window; then
            undrain "$vmid" "$runner"
            warn "  Ngoài khung giờ ${REBUILD_HOURS} — chờ lượt sau để xóa"
            return 0
        fi
        if destroy_ct "$vmid" "$runner"; then
            RUNNER_TOTAL=$((RUNNER_TOTAL - 1))
            REMOVED=$((REMOVED + 1))
            notify "🗑️ LXC removed | ${vmid} (${name}) | disk ${pct_used}% | còn ${RUNNER_TOTAL}/${MAX_RUNNERS} runner"
        else
            notify "❌ LXC remove FAILED | ${vmid} (${name})"
            FAILED=$((FAILED + 1))
        fi
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

# Shared with `lxc-runner clone/template`: never act while a clone is half-done
if ! lock_or_skip; then
    info "Đang có recycle/clone/template khác chạy — bỏ qua lượt này"
    exit 0
fi

info "Recycle: threshold ${DISK_THRESHOLD}%, clean target ${CLEAN_TARGET}%, dry-run ${DRY_RUN}"

if ! RUNNERS=$(gh_list_runners); then
    err "Không đọc được danh sách runner từ GitHub — dừng để tránh xóa nhầm runner đang chạy job"
    exit 1
fi

CTS=$(pve_list_runner_cts) || { err "Không đọc được danh sách container"; exit 1; }
# Đếm trên toàn bộ runner (kể cả container đang tắt), trước khi lọc LXC_IDS
RUNNER_TOTAL=$(jq 'length' <<< "$CTS")
if [ -n "$MAX_RUNNERS" ] && ! [[ "$MAX_RUNNERS" =~ ^[0-9]+$ ]]; then
    err "MAX_RUNNERS phải là số nguyên: '$MAX_RUNNERS'"
    exit 2
fi
info "Runners: ${RUNNER_TOTAL}${MAX_RUNNERS:+ (max ${MAX_RUNNERS})}"
if [ -n "$LXC_IDS" ]; then
    CTS=$(jq -c --arg ids "$LXC_IDS" '($ids | split(",") | map(tonumber)) as $f | map(select(.vmid as $v | $f | index($v)))' <<< "$CTS")
fi

# Read the list on fd 3: pct exec inside the loop would otherwise consume stdin
# Empty lock → "-": consecutive tabs would collapse into one field in `read`
while IFS=$'\t' read -r vmid name status lock disk maxdisk <&3; do
    process_ct "$vmid" "$name" "$status" "$lock" "$disk" "$maxdisk"
done 3< <(jq -r '.[] | [.vmid, .name, .status, (if .lock == "" then "-" else .lock end),
                        (.disk | floor), (.maxdisk | floor)] | @tsv' <<< "$CTS")

fill_to_max

# Remember containers still stopped for the next run (only when scanning all)
[ -z "$LXC_IDS" ] && echo "$STOPPED_NOW" | tr ' ' '\n' | sed '/^$/d' > "$STOPPED_FILE"

info "Xong: rebuilt ${REBUILT}, removed ${REMOVED}, added ${ADDED}, cleaned ${CLEANED}, bận ${SKIPPED_BUSY}, lỗi ${FAILED} — còn ${RUNNER_TOTAL} runner"
[ "$FAILED" -eq 0 ]
