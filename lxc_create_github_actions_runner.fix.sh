#!/usr/bin/env bash

set -e

GITHUB_RUNNER_URL="https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz"
TEMPL_URL="http://download.proxmox.com/images/system/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
PCTSIZE="20G"
# RUNNER_LABELS="vn-gaqc-docker,test-setup"
RUNNER_LABELS="test-playwright"
RUNNER_GROUP="VN-Team"
ORGNAME="Gravity-Global"
CURRENT_DATE=$(date +%Y%m%d)

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

log "-- Downloading $TEMPL_FILE template..."
curl -q -C - -o $TEMPL_FILE $TEMPL_URL

log "-- Creating LXC container with ID:$PCTID"
pct create $PCTID $TEMPL_FILE \
    -arch amd64 \
    -ostype ubuntu \
    -hostname github-runner-${PCTID}-${CURRENT_DATE} \
    -cores 4 \
    -memory 4096 \
    -swap 4096 \
    -storage local-lvm \
    -features nesting=1,keyctl=1 \
    -unprivileged 0 \
    -net0 name=eth0,bridge=vmbr1,ip=dhcp,firewall=1,type=veth

# Add important LXC configuration for Docker
log "-- Applying special container configurations for Docker"
pct set $PCTID -lxc-config="lxc.apparmor.profile=unconfined" 
pct set $PCTID -lxc-config="lxc.cap.drop=" 
pct set $PCTID -lxc-config="lxc.cgroup.devices.allow=a" 
pct set $PCTID -lxc-config="lxc.mount.auto=proc:rw sys:rw"

log "-- Resizing container to $PCTSIZE"
pct resize $PCTID rootfs $PCTSIZE

log "-- Starting container"
pct start $PCTID
sleep 10

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
    apt install -y git curl software-properties-common apt-transport-https ca-certificates gnupg lsb-release apparmor apparmor-utils && \
    passwd -d root"

# Disable apparmor if it's causing issues
log "-- Configuring AppArmor"
pct exec $PCTID -- bash -c "systemctl disable apparmor && systemctl stop apparmor || true"

# Install Docker using convenience script instead of repository method
log "-- Installing Docker using official convenience script"
pct exec $PCTID -- bash -c "export LANG=en_US.UTF-8 && \
    export LC_ALL=en_US.UTF-8 && \
    export DEBIAN_FRONTEND=noninteractive && \
    curl -fsSL https://get.docker.com -o get-docker.sh && \
    sh get-docker.sh && \
    systemctl enable docker && \
    systemctl start docker && \
    docker --version"

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

log "-- Installing runner"
pct exec $PCTID -- bash -c "export LANG=en_US.UTF-8 && \
    export LC_ALL=en_US.UTF-8 && \
    mkdir actions-runner && cd actions-runner && \
    curl -o $GITHUB_RUNNER_FILE -L $GITHUB_RUNNER_URL && \
    tar xzf $GITHUB_RUNNER_FILE && \
    RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended \
    --url $RUNNER_URL \
    --token $RUNNER_TOKEN \
    --name github-runner-${PCTID}-${CURRENT_DATE} \
    --labels $RUNNER_LABELS \
    --runnergroup \"$RUNNER_GROUP\" && \
    ./svc.sh install root && \
    ./svc.sh start"

# Configure runner service to start automatically on boot
log "-- Configuring runner service to start automatically on boot"
pct exec $PCTID -- bash -c "systemctl enable actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service"

# Add GitHub runner user to docker group
log "-- Adding GitHub runner user to docker group"
pct exec $PCTID -- bash -c "usermod -aG docker root"

# Creating Docker configuration for better performance and to avoid AppArmor issues
log "-- Configuring Docker with best practices"
pct exec $PCTID -- bash -c "mkdir -p /etc/docker"
pct exec $PCTID -- bash -c "cat > /etc/docker/daemon.json <<EOF
{
  \"storage-driver\": \"overlay2\",
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"10m\",
    \"max-file\": \"3\"
  },
  \"default-ulimits\": {
    \"nofile\": {
      \"Name\": \"nofile\",
      \"Hard\": 64000,
      \"Soft\": 64000
    }
  },
  \"exec-opts\": [\"native.cgroupdriver=systemd\"],
  \"features\": {
    \"buildkit\": true
  },
  \"live-restore\": true,
  \"iptables\": false,
  \"bip\": \"172.18.0.1/16\"
}
EOF"

# Configure Docker to not use AppArmor
log "-- Disabling AppArmor for Docker"
pct exec $PCTID -- bash -c "mkdir -p /etc/systemd/system/docker.service.d"
pct exec $PCTID -- bash -c "cat > /etc/systemd/system/docker.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --containerd=/run/containerd/containerd.sock --host=fd:// --add-runtime=runc=/usr/bin/runc --security-opt apparmor=unconfined
EOF"

# Restart Docker with the new configuration
pct exec $PCTID -- bash -c "systemctl daemon-reload && systemctl restart docker"

# Setup docker cleanup cron job to prevent disk space issues
log "-- Setting up Docker cleanup cron job"
pct exec $PCTID -- bash -c "cat > /etc/cron.daily/docker-cleanup <<EOF
#!/bin/bash
/usr/bin/docker system prune -af --volumes >/dev/null 2>&1
EOF"
pct exec $PCTID -- bash -c "chmod +x /etc/cron.daily/docker-cleanup"

# Add locale settings to container's .bashrc
pct exec $PCTID -- bash -c "echo 'export LANG=en_US.UTF-8' >> /root/.bashrc"
pct exec $PCTID -- bash -c "echo 'export LC_ALL=en_US.UTF-8' >> /root/.bashrc"

# Verify AWS CLI installation and ensure it's in PATH for runner sessions
log "-- Verifying AWS CLI installation"
pct exec $PCTID -- bash -c "which aws && aws --version || echo 'AWS CLI installation failed!'"
pct exec $PCTID -- bash -c "echo 'Ensuring AWS CLI is in PATH...'"
pct exec $PCTID -- bash -c "ln -sf /usr/local/bin/aws /usr/bin/aws"
pct exec $PCTID -- bash -c "ln -sf /usr/local/bin/aws_completer /usr/bin/aws_completer"

# Test Docker functionality
log "-- Testing Docker functionality"
pct exec $PCTID -- bash -c "docker run --rm hello-world || echo 'Docker test failed!'"

# Add Docker to GitHub Actions runner service environment
log "-- Adding Docker to GitHub Actions runner service environment"
pct exec $PCTID -- bash -c "mkdir -p /etc/systemd/system/actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service.d/"
pct exec $PCTID -- bash -c "echo '[Service]' > /etc/systemd/system/actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service.d/path.conf"
pct exec $PCTID -- bash -c "echo 'Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /etc/systemd/system/actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service.d/path.conf"
pct exec $PCTID -- bash -c "systemctl daemon-reload"
pct exec $PCTID -- bash -c "systemctl restart actions.runner.${ORGNAME}.github-runner-${PCTID}-${CURRENT_DATE}.service || true"

# Pull some common Docker images to speed up workflows
log "-- Pre-pulling common Docker images"
pct exec $PCTID -- bash -c "docker pull node:16-alpine || true"
pct exec $PCTID -- bash -c "docker pull node:18-alpine || true"
pct exec $PCTID -- bash -c "docker pull nginx:alpine || true"
pct exec $PCTID -- bash -c "docker pull alpine:latest || true"
pct exec $PCTID -- bash -c "docker pull ubuntu:22.04 || true"

log "-- Setup completed successfully!"
log "-- Container ID: $PCTID is now running GitHub Actions runner for $ORGNAME"
log "-- Runner name: github-runner-${PCTID}-${CURRENT_DATE}"
log "-- Runner labels: ${RUNNER_LABELS}"
log "-- Runner group: ${RUNNER_GROUP}"
log "-- Docker has been installed and configured for GitHub Actions"

rm $TEMPL_FILE