#!/usr/bin/env bash
# Shared helpers for lxc-runner (sourced, not executed)

LXC_RUNNER_LIB="${LXC_RUNNER_LIB:-/usr/lib/lxc-runner}"
LXC_RUNNER_STATE="${LXC_RUNNER_STATE:-/var/lib/lxc-runner}"
LXC_RUNNER_CONFIG="${LXC_RUNNER_CONFIG:-/etc/lxc-runner/lxc-runner.env}"

log()  { echo -e "\033[33m$*\033[0m"; }
info() { echo "[$(date '+%F %T')] $*"; }
warn() { echo "[$(date '+%F %T')] WARN: $*" >&2; }
err()  { echo "[$(date '+%F %T')] ERROR: $*" >&2; }

# Load KEY=VALUE config. Variables already set in the environment win,
# so `PCT_CORES=6 lxc-runner clone` overrides the file.
load_config() {
    local line key value
    [ -r "$LXC_RUNNER_CONFIG" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # Strip one pair of surrounding quotes; value is taken literally (no eval)
        if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        if [ -z "${!key+x}" ]; then
            export "$key=$value"
        fi
    done < "$LXC_RUNNER_CONFIG"

    : "${ORGNAME:=Gravity-Global}"
    : "${SOURCE_CONTAINER_ID:=100}"
    : "${LXC_NAME_PATTERN:=^github-runner-}"
    export ORGNAME SOURCE_CONTAINER_ID LXC_NAME_PATTERN
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Cần chạy bằng root"
        exit 1
    fi
}

require_token() {
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        err "GITHUB_TOKEN chưa được đặt trong $LXC_RUNNER_CONFIG"
        exit 1
    fi
}

# ── Notifications (optional) ───────────────────────────────────────────────

notify() {
    local text="$1"
    info "$text"
    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        curl -fsS -m 15 -X POST -H 'Content-Type: application/json' \
            -d "$(jq -n --arg t "$text" '{text: $t}')" \
            "$SLACK_WEBHOOK_URL" > /dev/null || warn "Gửi Slack thất bại"
    fi
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        curl -fsS -m 15 -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${text}" > /dev/null || warn "Gửi Telegram thất bại"
    fi
}

# ── GitHub API ─────────────────────────────────────────────────────────────

# gh_api METHOD PATH [JSON_BODY] → prints response body, non-zero on HTTP error
gh_api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-fsS -m 30 -X "$method"
        -H "Accept: application/vnd.github+json"
        -H "Authorization: Bearer ${GITHUB_TOKEN}"
        -H "X-GitHub-Api-Version: 2022-11-28")
    [ -n "$body" ] && args+=(-H "Content-Type: application/json" -d "$body")
    curl "${args[@]}" "https://api.github.com${path}"
}

# All org runners as a single JSON array (handles pagination)
gh_list_runners() {
    local page=1 batch all='[]' count
    while :; do
        batch=$(gh_api GET "/orgs/${ORGNAME}/actions/runners?per_page=100&page=${page}") || return 1
        all=$(jq -c --argjson a "$all" '$a + .runners' <<< "$batch")
        count=$(jq '.runners | length' <<< "$batch")
        [ "$count" -lt 100 ] && break
        page=$((page + 1))
    done
    echo "$all"
}

# gh_find_runner NAME [RUNNERS_JSON] → runner object or empty
gh_find_runner() {
    local name="$1" runners="${2:-}"
    [ -n "$runners" ] || runners=$(gh_list_runners) || return 1
    jq -c --arg n "$name" 'map(select(.name == $n)) | first // empty' <<< "$runners"
}

# ── Proxmox ────────────────────────────────────────────────────────────────

# Proxmox node name is the short hostname
pve_node() { hostname -s; }

# Runner containers on this node as JSON: [{vmid,name,status,disk,maxdisk}]
pve_list_runner_cts() {
    pvesh get "/nodes/$(pve_node)/lxc" --output-format json |
        jq -c --arg re "$LXC_NAME_PATTERN" --arg tpl "$SOURCE_CONTAINER_ID" '
            map(select((.name // "") | test($re)))
            | map(select((.vmid | tostring) != $tpl))
            | map({vmid: (.vmid | tonumber), name, status,
                   disk: (.disk // 0), maxdisk: (.maxdisk // 0)})
            | sort_by(.vmid)'
}

# Root filesystem usage in percent, measured inside the container
ct_disk_pct() {
    pct exec "$1" -- df -P / 2>/dev/null | awk 'NR==2 { sub("%", "", $5); print $5 }'
}

# True if the container holds a registered runner (skips templates/broken CTs)
ct_has_runner() {
    pct exec "$1" -- test -f /root/actions-runner/.runner > /dev/null 2>&1
}

# True if a job process is running inside the container
ct_job_running() {
    pct exec "$1" -- pgrep -f Runner.Worker > /dev/null 2>&1
}

ct_runner_service() {
    local action="$1" vmid="$2"
    # Resolve the unit file name: globs only match loaded units, a stopped one may be unloaded
    pct exec "$vmid" -- bash -c \
        "systemctl list-unit-files 'actions.runner.*' --no-legend | awk '{print \$1}' | xargs -r systemctl $action" \
        > /dev/null 2>&1
}
