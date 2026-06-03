#!/usr/bin/env bash
# Cài đặt Node.js 22.x via NodeSource
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

node --version
npm --version
echo "✅ nodejs installed"
