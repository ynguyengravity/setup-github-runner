#!/usr/bin/env bash
# Cài đặt và khởi động GitHub Actions runner
# Biến được truyền vào qua environment:
#   RUNNER_TOKEN, RUNNER_URL, RUNNER_NAME, RUNNER_LABELS,
#   RUNNER_GROUP, GITHUB_RUNNER_FILE, ORGNAME
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

: "${RUNNER_TOKEN:?}"
: "${RUNNER_URL:?}"
: "${RUNNER_NAME:?}"
: "${RUNNER_LABELS:?}"
: "${RUNNER_GROUP:?}"
: "${GITHUB_RUNNER_FILE:?}"
: "${ORGNAME:?}"

cd /root/actions-runner

if [ ! -f "${GITHUB_RUNNER_FILE}" ]; then
    echo "⚠️  Tarball không có trong template — tải xuống..."
    curl -fsSL -o "${GITHUB_RUNNER_FILE}" -L "$(ls /root/actions-runner/*.tar.gz 2>/dev/null | head -1 || echo 'MISSING')"
fi

echo "📦 Giải nén runner..."
tar xzf "${GITHUB_RUNNER_FILE}"
rm -f "${GITHUB_RUNNER_FILE}"

echo "⚙️  Cấu hình runner..."
RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended \
    --url "${RUNNER_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --runnergroup "${RUNNER_GROUP}"

./svc.sh install root
./svc.sh start

systemctl enable "actions.runner.${ORGNAME}.${RUNNER_NAME}.service"

echo 'export LANG=en_US.UTF-8' >> /root/.bashrc
echo 'export LC_ALL=en_US.UTF-8' >> /root/.bashrc

echo "✅ runner installed and started"
