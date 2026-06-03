#!/usr/bin/env bash
# Cài đặt Playwright + OS deps + browsers (fallback mirrors)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

npm install -g playwright
npx playwright install-deps

MIRRORS=(
    ""                                                    # default CDN
    "https://npmmirror.com/mirrors/playwright"            # Asia-friendly
    "https://registry.npmmirror.com/-/binary/playwright"  # alternate
)

INSTALLED=false
for mirror in "${MIRRORS[@]}"; do
    if [ -z "$mirror" ]; then
        label="default CDN"
        cmd="npx playwright install"
    else
        label="$mirror"
        cmd="PLAYWRIGHT_DOWNLOAD_HOST=$mirror npx playwright install"
    fi

    echo "⏳ Trying: $label (timeout 180s)..."
    if timeout 180 bash -c "$cmd"; then
        echo "✅ Playwright browsers downloaded from: $label"
        INSTALLED=true
        break
    else
        echo "⚠️  Failed: $label — trying next..."
    fi
done

if [ "$INSTALLED" = false ]; then
    echo "❌ All Playwright mirrors failed!"
    exit 1
fi

npx playwright --version
echo "✅ playwright installed"
