#!/usr/bin/env bash
# Cài đặt base packages, locale, xóa password root
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

apt update -y
apt install -y locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US LC_ALL=en_US.UTF-8

apt install -y \
    git curl wget unzip \
    software-properties-common apt-transport-https \
    ca-certificates gnupg lsb-release

passwd -d root
echo "✅ base installed"
