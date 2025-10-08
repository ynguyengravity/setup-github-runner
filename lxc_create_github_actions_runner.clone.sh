#!/usr/bin/env bash

set -e

# Configuration variables
SOURCE_CONTAINER_ID=100
GITHUB_RUNNER_URL="https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz"
RUNNER_LABELS="vn-gaqc-docker,test-setup"
# RUNNER_LABELS="test-playwright"
RUNNER_GROUP="VN-Team"
ORGNAME="Gravity-Global"
CURRENT_DATE=$(date +%Y%m%d)

# Get GitHub token
if [ -z "$GITHUB_TOKEN" ]; then
    read -p "Enter github token: " GITHUB_TOKEN
    echo
fi

# Set organization URLs
RUNNER_URL="https://github.com/${ORGNAME}"
API_URL="https://api.github.com/orgs/${ORGNAME}/actions/runners/registration-token"

log() {
  local text="$1"
  echo -e "\033[33m$text\033[0m"
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

# Get next available container ID
NEW_PCTID=$(pvesh get /cluster/nextid)
GITHUB_RUNNER_FILE=$(basename $GITHUB_RUNNER_URL)

log "-- Cloning container ${SOURCE_CONTAINER_ID} to new container ID: ${NEW_PCTID}"

# Stop source container if running
if pct status $SOURCE_CONTAINER_ID | grep -q "running"; then
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

# Update hostname in container
pct set $NEW_PCTID --hostname github-runner-${NEW_PCTID}-${CURRENT_DATE}

# Start the new container
log "-- Starting new container ${NEW_PCTID}"
pct start $NEW_PCTID
sleep 10

# Wait for container to be fully ready
log "-- Waiting for container to be ready..."
sleep 15

# Reset machine ID to avoid conflicts
log "-- Resetting machine ID"
pct exec $NEW_PCTID -- bash -c "rm -f /etc/machine-id /var/lib/dbus/machine-id && \
    systemd-machine-id-setup && \
    dbus-uuidgen --ensure"

# Get runner installation token
log "-- Getting runner installation token"
log "-- Using API URL: $API_URL"
RES=$(curl -q -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  $API_URL)

# Display response for debugging
echo "API Response: $RES"

RUNNER_TOKEN=$(echo $RES | grep -o '"token": "[^"]*' | grep -o '[^"]*$')

if [ -z "$RUNNER_TOKEN" ]; then
    log "ERROR: Failed to get runner token. Please check your token and organization name."
    log "Make sure your token has admin:org permission for organization runners."
    exit 1
fi

# Install GitHub Actions runner
log "-- Installing GitHub Actions runner"
pct exec $NEW_PCTID -- bash -c "export LANG=en_US.UTF-8 && \
    export LC_ALL=en_US.UTF-8 && \
    mkdir -p actions-runner && cd actions-runner && \
    curl -o $GITHUB_RUNNER_FILE -L $GITHUB_RUNNER_URL && \
    tar xzf $GITHUB_RUNNER_FILE && \
    RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended \
    --url $RUNNER_URL \
    --token $RUNNER_TOKEN \
    --name github-runner-${NEW_PCTID}-${CURRENT_DATE} \
    --labels $RUNNER_LABELS \
    --runnergroup \"$RUNNER_GROUP\" && \
    ./svc.sh install root && \
    ./svc.sh start"

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

# Restart source container if it was running
if pct status $SOURCE_CONTAINER_ID | grep -q "stopped"; then
    log "-- Restarting source container ${SOURCE_CONTAINER_ID}"
    pct start $SOURCE_CONTAINER_ID
fi

log "-- Setup completed successfully!"
log "-- Container ID: $NEW_PCTID is now running GitHub Actions runner for $ORGNAME"
log "-- Runner name: github-runner-${NEW_PCTID}-${CURRENT_DATE}"
log "-- Runner labels: ${RUNNER_LABELS}"
log "-- Runner group: ${RUNNER_GROUP}"
log "-- Auto-start enabled: Container will start automatically when Proxmox boots"
log "-- Source container ${SOURCE_CONTAINER_ID} has been restarted"
