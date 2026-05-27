#!/usr/bin/env bash
# =============================================================================
# lxc-monitor-ui.sh
# Live terminal dashboard - theo dõi disk usage các LXC GitHub runner
#
# Cách dùng:
#   ./lxc-monitor-ui.sh              # refresh mỗi 30 giây
#   ./lxc-monitor-ui.sh -i 60        # refresh mỗi 60 giây
#   ./lxc-monitor-ui.sh -i 0         # chỉ chạy 1 lần, không loop
#   Press 'q' để thoát, 'r' để refresh ngay
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
REFRESH_INTERVAL=30

# Parse args
while getopts "i:" opt; do
    case $opt in
        i) REFRESH_INTERVAL="$OPTARG" ;;
    esac
done

# Load .env
if [ -f "$ENV_FILE" ]; then
    set -o allexport
    source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | sed 's/[[:space:]]*#.*//')
    set +o allexport
fi

DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
LXC_IDS="${LXC_IDS:-auto}"
LXC_NAME_PATTERN="${LXC_NAME_PATTERN:-github-runner-}"
ORGNAME="${ORGNAME:-N/A}"
LOG_DIR="${LOG_DIR:-/var/log/lxc-monitor}"

# =============================================================================
# ANSI Color codes
# =============================================================================
R='\033[0m'          # Reset
BOLD='\033[1m'
DIM='\033[2m'

FG_BLACK='\033[30m'
FG_RED='\033[31m'
FG_GREEN='\033[32m'
FG_YELLOW='\033[33m'
FG_BLUE='\033[34m'
FG_MAGENTA='\033[35m'
FG_CYAN='\033[36m'
FG_WHITE='\033[37m'

BG_BLACK='\033[40m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'
BG_MAGENTA='\033[45m'
BG_CYAN='\033[46m'
BG_WHITE='\033[47m'

# =============================================================================
# Helpers
# =============================================================================

# Lấy terminal width
term_width() { tput cols 2>/dev/null || echo 80; }

# In đường kẻ ngang
hline() {
    local char="${1:--}"
    local w
    w=$(term_width)
    printf '%*s' "$w" '' | tr ' ' "$char"
    echo
}

# Căn giữa text
center() {
    local text="$1"
    local plain
    # Bỏ ANSI codes để đo độ dài thật
    plain=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local len=${#plain}
    local w
    w=$(term_width)
    local pad=$(( (w - len) / 2 ))
    printf "%${pad}s" ""
    echo -e "$text"
}

# Progress bar disk usage
disk_bar() {
    local pct="$1"
    local bar_width=20
    local filled=$(( pct * bar_width / 100 ))
    local empty=$(( bar_width - filled ))
    local bar=""

    if   [ "$pct" -ge "$DISK_THRESHOLD" ]; then local color="$FG_RED"
    elif [ "$pct" -ge $(( DISK_THRESHOLD - 15 )) ]; then local color="$FG_YELLOW"
    else local color="$FG_GREEN"
    fi

    bar+="${color}"
    for ((i=0; i<filled; i++)); do bar+="█"; done
    bar+="${DIM}"
    for ((i=0; i<empty; i++)); do bar+="░"; done
    bar+="${R}"
    echo -e "$bar"
}

# Màu cho % disk
pct_color() {
    local pct="$1"
    if   [ "$pct" -ge "$DISK_THRESHOLD" ]; then echo -e "${BOLD}${FG_RED}${pct}%${R}"
    elif [ "$pct" -ge $(( DISK_THRESHOLD - 15 )) ]; then echo -e "${BOLD}${FG_YELLOW}${pct}%${R}"
    else echo -e "${FG_GREEN}${pct}%${R}"
    fi
}

# Lấy danh sách LXC IDs
get_lxc_ids() {
    if [ "$LXC_IDS" = "auto" ]; then
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
        echo "$LXC_IDS" | tr ',' '\n' | tr -d ' '
    fi
}

# Lấy thông tin 1 container
get_container_info() {
    local vmid="$1"
    local hostname status disk_pct disk_free disk_total action

    hostname=$(pct config "$vmid" 2>/dev/null | grep '^hostname:' | awk '{print $2}' || echo "?")
    status=$(pct status "$vmid" 2>/dev/null | awk '{print $2}' || echo "unknown")

    if [ "$status" = "running" ]; then
        # df output: Use / root filesystem
        local df_out
        df_out=$(pct exec "$vmid" -- bash -c "df -h / | tail -1" 2>/dev/null || echo "")
        if [ -n "$df_out" ]; then
            disk_total=$(echo "$df_out" | awk '{print $2}')
            disk_free=$(echo "$df_out"  | awk '{print $4}')
            disk_pct=$(echo "$df_out"   | awk '{print $5}' | tr -d '%')
        else
            disk_total="?"; disk_free="?"; disk_pct=0
        fi

        if [ "$disk_pct" -ge "$DISK_THRESHOLD" ] 2>/dev/null; then
            action="REBUILD"
        else
            action="OK"
        fi
    else
        disk_total="-"; disk_free="-"; disk_pct="-"; action="OFFLINE"
    fi

    echo "$vmid|$hostname|$status|$disk_pct|$disk_free|$disk_total|$action"
}

# Lấy thời gian chạy tiếp theo của timer
next_timer_run() {
    systemctl list-timers lxc-disk-monitor.timer --no-pager 2>/dev/null \
        | grep lxc-disk-monitor \
        | awk '{print $1, $2}' \
        || echo "N/A"
}

# Lấy thời gian chạy lần cuối
last_run_time() {
    local log_today="${LOG_DIR}/lxc-monitor-$(date +%Y%m%d).log"
    if [ -f "$log_today" ]; then
        tail -5 "$log_today" 2>/dev/null \
            | grep "Bắt đầu\|Kết quả" \
            | tail -1 \
            | awk -F'[][]' '{print $2}' \
            || echo "Hôm nay (xem log)"
    else
        echo "Chưa chạy hôm nay"
    fi
}

# =============================================================================
# RENDER DASHBOARD
# =============================================================================

render() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    local w
    w=$(term_width)

    # Header
    clear
    echo -e "${BOLD}${BG_BLUE}${FG_WHITE}"
    printf "%-${w}s\n" "  🖥️  LXC GitHub Runner - Disk Monitor Dashboard"
    echo -e "${R}"

    # Meta info row
    printf "  ${DIM}Org:${R} ${FG_CYAN}${BOLD}%-20s${R}" "$ORGNAME"
    printf "  ${DIM}Threshold:${R} ${FG_YELLOW}${BOLD}%-6s${R}" "${DISK_THRESHOLD}%"
    printf "  ${DIM}Updated:${R} ${FG_WHITE}%s${R}" "$now"
    echo
    printf "  ${DIM}Last run:${R} %-30s" "$(last_run_time)"
    printf "  ${DIM}Next timer:${R} %s" "$(next_timer_run)"
    echo -e "\n"

    # Table header
    echo -e "${BOLD}${BG_BLACK}${FG_WHITE}"
    printf "  %-6s  %-32s  %-9s  %-8s  %-6s  %-6s  %-22s  %s\n" \
        "ID" "HOSTNAME" "STATUS" "DISK%" "FREE" "TOTAL" "USAGE BAR" "ACTION"
    echo -e "${R}"
    hline "─"

    # Lấy danh sách container
    local ids=()
    while IFS= read -r id; do
        [ -n "$id" ] && ids+=("$id")
    done < <(get_lxc_ids)

    local total=0 ok=0 warn_count=0 crit=0 offline=0

    if [ ${#ids[@]} -eq 0 ]; then
        echo ""
        center "  ${FG_YELLOW}⚠️  Không tìm thấy LXC container nào (pattern: '${LXC_NAME_PATTERN}')${R}"
        echo ""
    fi

    for vmid in "${ids[@]}"; do
        local info
        info=$(get_container_info "$vmid")

        IFS='|' read -r id hostname status disk_pct disk_free disk_total action <<< "$info"
        (( total++ )) || true

        # Status màu
        local status_str
        case "$status" in
            running) status_str="${FG_GREEN}● running${R}" ;;
            stopped) status_str="${FG_RED}○ stopped${R}" ;;
            *)       status_str="${FG_YELLOW}? ${status}${R}" ;;
        esac

        # Action màu + counter
        local action_str
        case "$action" in
            OK)
                action_str="${FG_GREEN}✅ OK${R}"
                (( ok++ )) || true
                ;;
            REBUILD)
                action_str="${BOLD}${FG_RED}🔴 REBUILD NEEDED${R}"
                (( crit++ )) || true
                ;;
            OFFLINE)
                action_str="${DIM}⏸  OFFLINE${R}"
                (( offline++ )) || true
                ;;
        esac

        # Disk % màu + bar
        local pct_str bar_str
        if [[ "$disk_pct" =~ ^[0-9]+$ ]]; then
            pct_str=$(pct_color "$disk_pct")
            bar_str=$(disk_bar "$disk_pct")
            if [ "$disk_pct" -ge "$DISK_THRESHOLD" ]; then
                (( warn_count++ )) || true
            fi
        else
            pct_str="${DIM}-${R}"
            bar_str="${DIM}────────────────────${R}"
        fi

        # Truncate hostname nếu dài
        local hn_display="${hostname:0:30}"

        printf "  %-6s  " "$id"
        printf "%-32s  " "$hn_display"
        printf "%-18b  " "$status_str"
        printf "%-17b  " "$pct_str"
        printf "%-6s  " "$disk_free"
        printf "%-6s  " "$disk_total"
        printf "%-31b  " "$bar_str"
        printf "%b\n" "$action_str"
    done

    hline "─"

    # Summary row
    echo ""
    printf "  ${BOLD}Tổng:${R} ${FG_WHITE}%d container(s)${R}   " "$total"
    printf "  ${FG_GREEN}✅ OK: %d${R}" "$ok"
    printf "  ${FG_RED}🔴 Cần rebuild: %d${R}" "$crit"
    printf "  ${DIM}⏸  Offline: %d${R}" "$offline"
    echo -e "\n"

    # Alert box nếu có container cần rebuild
    if [ "$crit" -gt 0 ]; then
        echo -e "  ${BOLD}${BG_RED}${FG_WHITE}  ⚠️  CÓ $crit CONTAINER DISK ĐẦY - Chạy lệnh sau để rebuild ngay:  ${R}"
        echo -e "  ${FG_YELLOW}  ${SCRIPT_DIR}/lxc-disk-monitor.sh${R}"
        echo ""
    fi

    # Log tail
    local log_today="${LOG_DIR}/lxc-monitor-$(date +%Y%m%d).log"
    if [ -f "$log_today" ]; then
        echo -e "  ${BOLD}${FG_CYAN}📄 Log hôm nay (5 dòng cuối):${R}"
        hline "─"
        tail -5 "$log_today" 2>/dev/null | while IFS= read -r line; do
            if echo "$line" | grep -q "\[ERROR\]"; then
                echo -e "  ${FG_RED}$line${R}"
            elif echo "$line" | grep -q "\[WARN\]"; then
                echo -e "  ${FG_YELLOW}$line${R}"
            else
                echo -e "  ${DIM}$line${R}"
            fi
        done
        hline "─"
    fi

    # Footer
    echo ""
    if [ "$REFRESH_INTERVAL" -gt 0 ] 2>/dev/null; then
        echo -e "  ${DIM}Auto-refresh: ${REFRESH_INTERVAL}s  │  Phím: ${R}${BOLD}[r]${R}${DIM} refresh ngay  │  ${R}${BOLD}[q]${R}${DIM} thoát${R}"
    else
        echo -e "  ${DIM}Chế độ: 1 lần  │  Phím: ${R}${BOLD}[q]${R}${DIM} thoát${R}"
    fi
}

# =============================================================================
# MAIN LOOP
# =============================================================================

# Restore terminal khi thoát
cleanup() {
    tput cnorm 2>/dev/null  # hiện lại cursor
    echo -e "${R}"
    exit 0
}
trap cleanup EXIT INT TERM

tput civis 2>/dev/null  # ẩn cursor

render

if [ "$REFRESH_INTERVAL" -le 0 ] 2>/dev/null; then
    # Chỉ chạy 1 lần, đợi phím q
    while IFS= read -r -t 1 -n 1 key 2>/dev/null; do
        [ "$key" = "q" ] && break
    done
    exit 0
fi

# Loop với countdown
elapsed=0
while true; do
    # Đợi từng giây, check phím
    while [ "$elapsed" -lt "$REFRESH_INTERVAL" ]; do
        # Cập nhật countdown ở dòng cuối
        local remaining=$(( REFRESH_INTERVAL - elapsed ))
        tput sc 2>/dev/null  # save cursor
        # Đi xuống cuối màn hình
        tput cup "$(tput lines)" 0 2>/dev/null
        printf "\r  ${DIM}Refresh sau: ${remaining}s  │  [r] refresh ngay  │  [q] thoát   ${R}"
        tput rc 2>/dev/null  # restore cursor

        # Đọc phím với timeout 1 giây
        if IFS= read -r -t 1 -n 1 key 2>/dev/null; then
            case "$key" in
                q|Q) exit 0 ;;
                r|R) break ;;
            esac
        fi
        (( elapsed++ )) || true
    done

    elapsed=0
    render
done
