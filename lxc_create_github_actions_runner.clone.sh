#!/usr/bin/env bash

set -e

# Configuration variables
# Tất cả biến đọc từ env trước, fallback về giá trị mặc định
SOURCE_CONTAINER_ID="${SOURCE_CONTAINER_ID:-100}"
GITHUB_RUNNER_URL="${GITHUB_RUNNER_URL:-https://github.com/actions/runner/releases/download/v2.338.0/actions-runner-linux-x64-2.338.0.tar.gz}"
RUNNER_LABELS="${RUNNER_LABELS:-vn-gaqc-docker,test-setup}"
RUNNER_GROUP="${RUNNER_GROUP:-VN-Team}"
ORGNAME="${ORGNAME:-Gravity-Global}"
# Optional resource overrides for the clone (empty = inherit from template)
PCT_CORES="${PCT_CORES:-}"
PCT_MEMORY="${PCT_MEMORY:-}"   # MiB
PCT_SWAP="${PCT_SWAP:-}"       # MiB
CURRENT_DATE=$(date +%Y%m%d)

# Get GitHub token
# Nếu chạy unattended (từ service/cron): bắt buộc GITHUB_TOKEN phải có trong env
# Nếu chạy tay: hỏi nếu chưa có
if [ -z "$GITHUB_TOKEN" ]; then
    if [ -t 0 ]; then
        # Có terminal → hỏi người dùng
        read -rsp "Enter github token: " GITHUB_TOKEN
        echo
    else
        # Không có terminal (service/cron) → exit ngay, không treo
        echo "ERROR: GITHUB_TOKEN chưa được đặt. Thêm vào .env hoặc export trước khi chạy." >&2
        exit 1
    fi
fi

# Set organization URLs
RUNNER_URL="https://github.com/${ORGNAME}"
API_URL="https://api.github.com/orgs/${ORGNAME}/actions/runners/registration-token"

log() {
  local text="$1"
  echo -e "\033[33m$text\033[0m"
}

sanitize_container_config() {
    local container_id="$1"
    local container_config="/etc/pve/lxc/${container_id}.conf"

    if [ ! -f "$container_config" ]; then
        return
    fi

    # Remove deprecated/overriding keys from older templates.
    sed -i '/^lxc\.cgroup\.devices\.allow:/d' "$container_config"
    sed -i '/^lxc\.apparmor\.profile:/d' "$container_config"

    if ! grep -q '^lxc.cgroup2.devices.allow: a$' "$container_config"; then
        echo "lxc.cgroup2.devices.allow: a" >> "$container_config"
    fi
}

log "-- Cloning GitHub Actions runner from template container ID: ${SOURCE_CONTAINER_ID}"
log "-- Setting up runner for Organization: ${ORGNAME}"
log "-- Using runner labels: ${RUNNER_LABELS}"
log "-- Using runner group: ${RUNNER_GROUP}"
log "-- Date: ${CURRENT_DATE}"

# Check if source container exists
if ! pct status $SOURCE_CONTAINER_ID >/dev/null 2>&1; then
    log "ERROR: Source container ID ${SOURCE_CONTAINER_ID} does not exist!"
    log "Please make sure you have run the master script first to create the template."
    exit 1
fi

log "-- Sanitizing source container config ${SOURCE_CONTAINER_ID}"
sanitize_container_config $SOURCE_CONTAINER_ID

# Get next available container ID
NEW_PCTID=$(pvesh get /cluster/nextid)
GITHUB_RUNNER_FILE=$(basename $GITHUB_RUNNER_URL)   # dùng làm tên file bên trong container

log "-- Cloning container ${SOURCE_CONTAINER_ID} to new container ID: ${NEW_PCTID}"

# Stop source container if running (remember its state to restore it later)
SOURCE_WAS_RUNNING=false
if pct status $SOURCE_CONTAINER_ID | grep -q "running"; then
    SOURCE_WAS_RUNNING=true
    log "-- Stopping source container ${SOURCE_CONTAINER_ID}"
    pct stop $SOURCE_CONTAINER_ID
fi

# Clone the container
log "-- Cloning container..."
pct clone $SOURCE_CONTAINER_ID $NEW_PCTID \
    -hostname github-runner-${NEW_PCTID}-${CURRENT_DATE} \
    -full 1

# Configure the cloned container
log "-- Configuring cloned container ${NEW_PCTID}"

# Note: Container config (/etc/pve/lxc/${NEW_PCTID}.conf) is automatically copied from source
# This includes Docker support, TUN/TAP devices, and all LXC configurations
log "-- Container config automatically inherited from template (ID: ${SOURCE_CONTAINER_ID})"

log "-- Sanitizing cloned container config ${NEW_PCTID}"
sanitize_container_config $NEW_PCTID

# Update hostname in container
pct set $NEW_PCTID --hostname github-runner-${NEW_PCTID}-${CURRENT_DATE}

# Apply resource overrides if provided
[ -n "$PCT_CORES" ] && pct set $NEW_PCTID --cores $PCT_CORES
[ -n "$PCT_MEMORY" ] && pct set $NEW_PCTID --memory $PCT_MEMORY
[ -n "$PCT_SWAP" ] && pct set $NEW_PCTID --swap $PCT_SWAP

# Start the new container
log "-- Starting new container ${NEW_PCTID}"
pct start $NEW_PCTID

# Wait for network/DNS (DHCP) instead of a fixed sleep
log "-- Waiting for container network"
for i in $(seq 1 30); do
    if pct exec $NEW_PCTID -- getent hosts api.github.com > /dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "ERROR: Container $NEW_PCTID has no network after 60s"
        exit 1
    fi
    sleep 2
done

# Reset machine ID to avoid conflicts; lock root password (templates built
# by older master.sh had an empty root password)
log "-- Resetting machine ID"
pct exec $NEW_PCTID -- bash -c "rm -f /etc/machine-id /var/lib/dbus/machine-id && \
    systemd-machine-id-setup && \
    dbus-uuidgen --ensure && \
    passwd -l root"

# Get runner installation token
log "-- Getting runner installation token"
log "-- Using API URL: $API_URL"
RES=$(curl -q -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  $API_URL)

RUNNER_TOKEN=$(echo $RES | grep -o '"token": "[^"]*' | grep -o '[^"]*$')

if [ -z "$RUNNER_TOKEN" ]; then
    # No token in the response, so it is safe to print for debugging
    echo "API Response: $RES"
    log "ERROR: Failed to get runner token. Please check your token and organization name."
    log "Make sure your token has admin:org permission for organization runners."
    exit 1
fi

# Install GitHub Actions runner — tarball already pre-downloaded in template (master.sh)
log "-- Installing GitHub Actions runner (using pre-downloaded tarball)"
pct exec $NEW_PCTID -- bash -c "
    set -e
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    cd /root/actions-runner

    if [ ! -f ${GITHUB_RUNNER_FILE} ]; then
        echo '⚠️  Tarball not found in template, downloading fallback...'
        curl -fsSL -o ${GITHUB_RUNNER_FILE} -L ${GITHUB_RUNNER_URL}
    fi

    echo '📦 Extracting...'
    tar xzf ${GITHUB_RUNNER_FILE}

    echo '🗑️  Removing tarball...'
    rm -f ${GITHUB_RUNNER_FILE}

    echo '⚙️  Configuring runner...'
    RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended \
        --url ${RUNNER_URL} \
        --token ${RUNNER_TOKEN} \
        --name github-runner-${NEW_PCTID}-${CURRENT_DATE} \
        --labels ${RUNNER_LABELS} \
        --runnergroup '${RUNNER_GROUP}'

    ./svc.sh install root
    ./svc.sh start
    echo '✅ Runner installed and started'
"

# Configure runner service to start automatically on boot
log "-- Configuring runner service to start automatically on boot"
pct exec $NEW_PCTID -- bash -c "systemctl enable actions.runner.${ORGNAME}.github-runner-${NEW_PCTID}-${CURRENT_DATE}.service"

# Add locale settings to container's .bashrc
pct exec $NEW_PCTID -- bash -c "echo 'export LANG=en_US.UTF-8' >> /root/.bashrc"
pct exec $NEW_PCTID -- bash -c "echo 'export LC_ALL=en_US.UTF-8' >> /root/.bashrc"

# Verify AWS CLI installation and ensure it's in PATH for runner sessions
log "-- Verifying AWS CLI installation"
pct exec $NEW_PCTID -- bash -c "which aws && aws --version || echo 'AWS CLI installation failed!'"
pct exec $NEW_PCTID -- bash -c "echo 'Ensuring AWS CLI is in PATH...'"
pct exec $NEW_PCTID -- bash -c "ln -sf /usr/local/bin/aws /usr/bin/aws"
pct exec $NEW_PCTID -- bash -c "ln -sf /usr/local/bin/aws_completer /usr/bin/aws_completer"

# Add AWS CLI to GitHub Actions runner service environment
log "-- Adding AWS CLI to GitHub Actions runner service environment"
pct exec $NEW_PCTID -- bash -c "mkdir -p /etc/systemd/system/actions.runner.${ORGNAME}.github-runner-${NEW_PCTID}-${CURRENT_DATE}.service.d/"
pct exec $NEW_PCTID -- bash -c "echo '[Service]' > /etc/systemd/system/actions.runner.${ORGNAME}.github-runner-${NEW_PCTID}-${CURRENT_DATE}.service.d/path.conf"
pct exec $NEW_PCTID -- bash -c "echo 'Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /etc/systemd/system/actions.runner.${ORGNAME}.github-runner-${NEW_PCTID}-${CURRENT_DATE}.service.d/path.conf"
pct exec $NEW_PCTID -- bash -c "systemctl daemon-reload"
pct exec $NEW_PCTID -- bash -c "systemctl restart actions.runner.${ORGNAME}.github-runner-${NEW_PCTID}-${CURRENT_DATE}.service || true"

# Enable auto-start for the container
log "-- Enabling auto-start for container $NEW_PCTID"
pct set $NEW_PCTID --onboot 1

# Restart source container only if it was running before the clone
if [ "$SOURCE_WAS_RUNNING" = true ] && pct status $SOURCE_CONTAINER_ID | grep -q "stopped"; then
    log "-- Restarting source container ${SOURCE_CONTAINER_ID}"
    pct start $SOURCE_CONTAINER_ID
fi

log "-- Setup completed successfully!"
log "-- Container ID: $NEW_PCTID is now running GitHub Actions runner for $ORGNAME"
log "-- Runner name: github-runner-${NEW_PCTID}-${CURRENT_DATE}"
log "-- Runner labels: ${RUNNER_LABELS}"
log "-- Runner group: ${RUNNER_GROUP}"
log "-- Auto-start enabled: Container will start automatically when Proxmox boots"
if [ "$SOURCE_WAS_RUNNING" = true ]; then
    log "-- Source container ${SOURCE_CONTAINER_ID} has been restarted"
fi

# Machine-readable result for callers (lxc-runner clone/recycle)
echo "NEW_PCTID=${NEW_PCTID}"
