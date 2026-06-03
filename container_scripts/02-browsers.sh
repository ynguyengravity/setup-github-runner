#!/usr/bin/env bash
# Cài đặt Chrome, Edge, Firefox (LXC-compatible, no snap)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Chrome
if ! command -v google-chrome &>/dev/null; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] \
        http://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list
fi

# Edge
if ! command -v microsoft-edge &>/dev/null; then
    rm -f /usr/share/keyrings/microsoft-edge.gpg
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft-edge.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] \
        https://packages.microsoft.com/repos/edge stable main" \
        > /etc/apt/sources.list.d/microsoft-edge.list
fi

# Firefox (non-snap via PPA)
if ! command -v firefox &>/dev/null || snap list 2>/dev/null | grep -q firefox; then
    add-apt-repository -y ppa:mozillateam/ppa >/dev/null 2>&1
    cat > /etc/apt/preferences.d/mozillateam-firefox <<'EOF'
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOF
fi

apt update -y
# Ubuntu 24.04: libasound2 → libasound2t64, libgtk-3-0 → libgtk-3-0t64
apt install -y \
    google-chrome-stable microsoft-edge-stable firefox \
    xvfb libxss1 libasound2t64 libgtk-3-0t64 libnss3 \
    libdrm2 libgbm1 libxshmfence1

# Cleanup duplicate google.list if any
rm -f /etc/apt/sources.list.d/google.list || true

firefox --version      || echo "firefox not found"
google-chrome --version || echo "chrome not found"
microsoft-edge --version || echo "edge not found"
echo "✅ browsers installed"
