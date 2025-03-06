#!/usr/bin/env bash

set -e

GITHUB_RUNNER_URL="https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz"
TEMPL_URL="http://download.proxmox.com/images/system/ubuntu-23.04-standard_23.04-1_amd64.tar.zst"
PCTSIZE="20G"

if [ -z "$GITHUB_TOKEN" ]; then
    read -p "Enter github token: " GITHUB_TOKEN
    echo
fi
if [ -z "$OWNERREPO" ]; then
    read -p "Enter github owner/repo: " OWNERREPO
    echo
fi


log() {
  local text="$1"
  echo -e "\033[33m$text\033[0m"
}

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
    -hostname github-runner-proxmox-$(openssl rand -hex 3) \
    -cores 4 \
    -memory 4096 \
    -swap 4096 \
    -storage local-lvm \
    -features nesting=1,keyctl=1 \
    -net0 name=eth0,bridge=vmbr1,ip=dhcp,firewall=1,type=veth
log "-- Resizing container to $PCTSIZE"
pct resize $PCTID rootfs $PCTSIZE
log "-- Starting container"
pct start $PCTID
sleep 10
log "-- Running updates"
pct exec $PCTID -- bash -c "apt update -y &&\
    apt install -y git curl &&\
    passwd -d root"

#install docker
log "-- Installing docker"
pct exec $PCTID -- bash -c "curl -qfsSL https://get.docker.com | sh"

log "-- Getting runner installation token"
RES=$(curl -q -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/$OWNERREPO/actions/runners/registration-token)

RUNNER_TOKEN=$(echo $RES | grep -o '"token": "[^"]*' | grep -o '[^"]*$')
  
log "-- Installing runner"
pct exec $PCTID -- bash -c "mkdir actions-runner && cd actions-runner &&\
    curl -o $GITHUB_RUNNER_FILE -L $GITHUB_RUNNER_URL &&\
    tar xzf $GITHUB_RUNNER_FILE &&\
    RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended --url https://github.com/$OWNERREPO --token $RUNNER_TOKEN &&\
    ./svc.sh install root &&\
    ./svc.sh start"

rm $TEMPL_FILE