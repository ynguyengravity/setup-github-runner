#!/usr/bin/env bash

set -e

GITHUB_RUNNER_URL="https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz"
TEMPL_URL="http://download.proxmox.com/images/system/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
PCTSIZE="50G"
RUNNER_LABELS="vn-gaqc-docker,test-setup"
# RUNNER_LABELS="test-playwright"
RUNNER_GROUP="VN-Team"
ORGNAME="Gravity-Global"
CURRENT_DATE=$(date +%Y%m%d)X

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

log "-- Using Ubuntu 22.04 LTS (Jammy Jellyfish) template - supported until 2027"
log "-- Setting up runner for Organization: ${ORGNAME}"
log "-- Using runner labels: ${RUNNER_LABELS}"
log "-- Using runner group: ${RUNNER_GROUP}"
log "-- Date: ${CURRENT_DATE}"

# Không cần hỏi IP và Gateway khi sử dụng DHCP
# read -e -p "Container Address IP (CIDR format): " -i "192.168.0.123/24" IP_ADDR
# read -e -p "Container Gateway IP: " -i "192.168.0.1" GATEWAY

TEMPL_FILE=$(basename $TEMPL_URL)
GITHUB_RUNNER_FILE=$(basename $GITHUB_RUNNER_URL)
PCTID=$(pvesh get /cluster/nextid)

if [ -f "$TEMPL_FILE" ]; then
    log "-- Template $TEMPL_FILE already exists, skipping download."
else
    log "-- Downloading $TEMPL_FILE template..."
    curl -q -C - -o $TEMPL_FILE $TEMPL_URL
fi

log "-- Creating LXC container with ID:$PCTID"
pct create $PCTID $TEMPL_FILE \
    -arch amd64 \
    -ostype ubuntu \
    -hostname github-runner-${PCTID}-${CURRENT_DATE} \
    -cores 5 \
    -memory 32768 \
    -swap 32768 \
    -storage local-lvm2 \
    -features nesting=1,keyctl=1 \
    -unprivileged 0 \
    -net0 name=eth0,bridge=vmbr1,ip=dhcp,firewall=1,type=veth

log "-- Resizing container to $PCTSIZE"
pct resize $PCTID rootfs $PCTSIZE

# Configure LXC for Docker - direct file edit approach
log "-- Configuring LXC container for Docker compatibility"
# Directly editing the container config file
CONTAINER_CONFIG="/etc/pve/lxc/${PCTID}.conf"
echo "# Docker support configuration" >> $CONTAINER_CONFIG
echo "lxc.apparmor.profile: unconfined" >> $CONTAINER_CONFIG
echo "lxc.cgroup.devices.allow: a" >> $CONTAINER_CONFIG
echo "lxc.cap.drop: " >> $CONTAINER_CONFIG

# Enable TUN/TAP for OpenVPN
log "-- Enabling TUN/TAP devices for OpenVPN"
echo "# TUN/TAP device support" >> $CONTAINER_CONFIG
echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> $CONTAINER_CONFIG
echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> $CONTAINER_CONFIG

log "-- Starting container"
pct start $PCTID
sleep 10

# Create TUN device if it doesn't exist
log "-- Setting up TUN device"
pct exec $PCTID -- bash -c "mkdir -p /dev/net && \
    mknod /dev/net/tun c 10 200 || true && \
    chmod 600 /dev/net/tun"

log "-- Configure locale settings"
pct exec $PCTID -- bash -c "apt update -y && \
    apt install -y locales && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 LANGUAGE=en_US LC_ALL=en_US.UTF-8"

log "-- Running updates and installing base packages"
pct exec $PCTID -- bash -c "export DEBIAN_FRONTEND=noninteractive && \
    export LANG=en_US.UTF-8 && \
    export LC_ALL=en_US.UTF-8 && \
    apt update -y && \
    apt install -y git curl software-properties-common apt-transport-https ca-certificates gnupg lsb-release && \
    passwd -d root"

# Install browsers (Edge, Chrome, Firefox) - LXC compatible approach
log "-- Installing browsers (Edge, Chrome, Firefox) - LXC compatible approach"
pct exec $PCTID -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Chrome
if ! command -v google-chrome > /dev/null; then
  echo "Installing Google Chrome..."
  rm -f /etc/apt/sources.list.d/google-chrome.list
  wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | apt-key add -
  echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
fi

# Edge
if ! command -v microsoft-edge > /dev/null; then
  echo "Installing Microsoft Edge..."
  rm -f /usr/share/keyrings/microsoft-edge.gpg
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-edge.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" > /etc/apt/sources.list.d/microsoft-edge.list
fi

# Firefox (non-snap only)
if ! command -v firefox > /dev/null || snap list | grep -q firefox; then
  echo "Installing Firefox from PPA..."
  add-apt-repository -y ppa:mozillateam/ppa > /dev/null 2>&1
  echo "Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001" > /etc/apt/preferences.d/mozillateam-firefox
fi

apt update -y
apt install -y google-chrome-stable microsoft-edge-stable firefox xvfb libxss1 libasound2 libgtk-3-0 libnss3 libdrm2 libgbm1 libxshmfence1

echo "✅ Browsers installed"
'


# Verify browser installations
log "-- Verifying browser installations"
pct exec $PCTID -- bash -c "echo 'Checking Firefox...' && firefox --version || echo 'Firefox not found'"
pct exec $PCTID -- bash -c "echo 'Checking Chrome...' && google-chrome --version || echo 'Chrome not found'"
pct exec $PCTID -- bash -c "echo 'Checking Edge...' && microsoft-edge --version || echo 'Edge not found'"

# Clean up duplicate repository entries
log "-- Cleaning up duplicate repository entries"
pct exec $PCTID -- bash -c "rm -f /etc/apt/sources.list.d/google.list || true"

# Install Node.js
log "-- Installing Node.js"
pct exec $PCTID -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Install Node.js using NodeSource repository
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Verify Node.js installation
node --version
npm --version

echo "✅ Node.js installed"
'

# Verify Playwright installation
log "-- Verifying Playwright installation"
pct exec $PCTID -- bash -c "yes | npx playwright --version"

# Install OpenVPN
log "-- Installing OpenVPN"
pct exec $PCTID -- bash -c "export DEBIAN_FRONTEND=noninteractive && \
    export LANG=en_US.UTF-8 && \
    export LC_ALL=en_US.UTF-8 && \
    apt update -y && \
    apt install -y openvpn openvpn-systemd-resolved resolvconf net-tools iptables iproute2 && \
    systemctl enable openvpn"

# Verify TUN device is working
log "-- Verifying TUN device"
pct exec $PCTID -- bash -c "ls -la /dev/net/tun && \
    cat /dev/net/tun || echo 'TUN device exists but cannot be read (this is normal)'"

#install docker
log "-- Installing docker"
pct exec $PCTID -- bash -c "export LANG=en_US.UTF-8 && \
    export LC_ALL=en_US.UTF-8 && \
    curl -fsSL https://get.docker.com | sh"

# Configure Docker to work properly in LXC
log "-- Configuring Docker for LXC environment"
pct exec $PCTID -- bash -c "mkdir -p /etc/docker"
pct exec $PCTID -- bash -c "echo '{\"storage-driver\":\"overlay2\",\"iptables\":false}' > /etc/docker/daemon.json"

# Create systemd override for Docker
pct exec $PCTID -- bash -c "mkdir -p /etc/systemd/system/docker.service.d/"
pct exec $PCTID -- bash -c "echo '[Service]' > /etc/systemd/system/docker.service.d/override.conf"
pct exec $PCTID -- bash -c "echo 'ExecStart=' >> /etc/systemd/system/docker.service.d/override.conf"
pct exec $PCTID -- bash -c "echo 'ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock' >> /etc/systemd/system/docker.service.d/override.conf"

# Remove AppArmor to prevent Docker issues
pct exec $PCTID -- bash -c "apt-get update && apt-get install -y apparmor-utils"
pct exec $PCTID -- bash -c "systemctl disable apparmor"
pct exec $PCTID -- bash -c "systemctl stop apparmor"

# Restart Docker with the new configuration
pct exec $PCTID -- bash -c "systemctl daemon-reload"
pct exec $PCTID -- bash -c "systemctl restart docker"
pct exec $PCTID -- bash -c "docker run --rm hello-world || echo 'Docker test failed, but continuing...'"

# Install AWS CLI
log "-- Installing AWS CLI"
pct exec $PCTID -- bash -c "export LANG=en_US.UTF-8 && \
    export LC_ALL=en_US.UTF-8 && \
    apt-get update && \
    apt-get install -y unzip && \
    curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip' && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws && \
    ln -sf /usr/local/bin/aws /usr/bin/aws && \
    ln -sf /usr/local/bin/aws_completer /usr/bin/aws_completer && \
    echo 'export PATH=$PATH:/usr/local/bin:/usr/bin' >> /root/.bashrc && \
    echo 'export PATH=$PATH:/usr/local/bin:/usr/bin' >> /etc/environment && \
    source /etc/environment && \
    aws --version"

log "-- Getting runner installation token"
log "-- Using API URL: $API_URL"
RES=$(curl -q -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  $API_URL)

# Hiển thị response cho người dùng
echo "API Response: $RES"

RUNNER_TOKEN=$(echo $RES | grep -o '"token": "[^"]*' | grep -o '[^"]*$')

if [ -z "$RUNNER_TOKEN" ]; then
    log "ERROR: Failed to get runner token. Please check your token and organization name."
    log "Make sure your token has admin:org permission for organization runners."
    exit 1
fi


# Install Playwright with dependencies
log "-- Installing Playwright with dependencies"
# Đổi CDN tải browser nếu cần (ví dụ dùng AzureEdge)
pct exec $PCTID -- bash -c "export LANG=en_US.UTF-8 && \
    export LC_ALL=en_US.UTF-8 && \
    export PLAYWRIGHT_DOWNLOAD_HOST=\"https://playwright.azureedge.net\" && \
    yes | npx playwright@latest install --with-deps"


# log "-- Installing runner"
# pct exec $PCTID -- bash -c "export LANG=en_US.UTF-8 && \
#     export LC_ALL=en_US.UTF-8 && \
#     mkdir actions-runner && cd actions-runner && \
#     curl -o $GITHUB_RUNNER_FILE -L $GITHUB_RUNNER_URL && \
#     tar xzf $GITHUB_RUNNER_FILE && \
#     RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended \
#     --url $RUNNER_URL \
#     --token $RUNNER_TOKEN \
#     --name github-runner-${PCTID}-${CURRENT_DATE} \
#     --labels $RUNNER_LABELS \
#     --runnergroup \"$RUNNER_GROUP\" && \
#     ./svc.sh install root && \
#     ./svc.sh start"

# # Configure runner service to start automatically on boot
# log "-- Configuring runner service to start automatically on boot"
# pct exec $PCTID -- bash -c "systemctl enable actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service"

# # Add locale settings to container's .bashrc
# pct exec $PCTID -- bash -c "echo 'export LANG=en_US.UTF-8' >> /root/.bashrc"
# pct exec $PCTID -- bash -c "echo 'export LC_ALL=en_US.UTF-8' >> /root/.bashrc"

# # Verify AWS CLI installation and ensure it's in PATH for runner sessions
# log "-- Verifying AWS CLI installation"
# pct exec $PCTID -- bash -c "which aws && aws --version || echo 'AWS CLI installation failed!'"
# pct exec $PCTID -- bash -c "echo 'Ensuring AWS CLI is in PATH...'"
# pct exec $PCTID -- bash -c "ln -sf /usr/local/bin/aws /usr/bin/aws"
# pct exec $PCTID -- bash -c "ln -sf /usr/local/bin/aws_completer /usr/bin/aws_completer"

# # Add AWS CLI to GitHub Actions runner service environment
# log "-- Adding AWS CLI to GitHub Actions runner service environment"
# pct exec $PCTID -- bash -c "mkdir -p /etc/systemd/system/actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service.d/"
# pct exec $PCTID -- bash -c "echo '[Service]' > /etc/systemd/system/actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service.d/path.conf"
# pct exec $PCTID -- bash -c "echo 'Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /etc/systemd/system/actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service.d/path.conf"
# pct exec $PCTID -- bash -c "systemctl daemon-reload"
# pct exec $PCTID -- bash -c "systemctl restart actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service || true"

# # Enable auto-start for the container
# log "-- Enabling auto-start for container $PCTID"
# pct set $PCTID --onboot 1

# log "-- Setup completed successfully!"
# log "-- Container ID: $PCTID is now running GitHub Actions runner for $ORGNAME"
# log "-- Runner name: github-runner-${PCTID}-${CURRENT_DATE}"
# log "-- Runner labels: ${RUNNER_LABELS}"
# log "-- Runner group: ${RUNNER_GROUP}"
# log "-- Auto-start enabled: Container will start automatically when Proxmox boots"

# # rm $TEMPL_FILE