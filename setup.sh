#!/bin/bash

set -e

LOCK_FILE="/tmp/github-runner-setup.lock"
FORCE_RUN=$2
LOG_FILE="/var/log/github-runner-setup.log"

# Tạo và set quyền cho log file và lock file
sudo touch "$LOG_FILE"
sudo chown $USER:$USER "$LOG_FILE"
sudo touch "$LOCK_FILE"
sudo chown $USER:$USER "$LOCK_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Bắt đầu script cài đặt GitHub Runner..."

if [ -f "$LOCK_FILE" ] && [ "$FORCE_RUN" != "force" ]; then
    echo "[ERROR] Script đã được chạy trước đó. Nếu muốn chạy lại, hãy thêm tham số 'force'."
    exit 1
fi

echo "[INFO] Nhận tham số đầu vào..."
RUNNER_ID=$1
# REG_TOKEN=$2
REG_TOKEN="BBG5IMVLOR7VHP4BKW2ZQ7DHVVQYE"
if [ -z "$RUNNER_ID" ]; then
    echo "[ERROR] RUNNER_ID không được để trống. Hãy cung cấp một ID."
    exit 1
fi
if [ -z "$REG_TOKEN" ]; then
    echo "[ERROR] REG_TOKEN không được để trống. Hãy cung cấp một token hợp lệ."
    exit 1
fi

IP_ADDRESS=$(hostname -I | awk '{print $1}')
GITHUB_OWNER="Gravity-Global"
RUNNER_NAME="runner-$RUNNER_ID-$IP_ADDRESS"
LABELS="test-setup,linux,x64"

# Cập nhật hệ thống
echo "[INFO] Cập nhật hệ thống..."
sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y

# Cài đặt các gói cần thiết
echo "[INFO] Cài đặt các gói hỗ trợ..."
sudo apt install -y curl jq git ntp build-essential

# Cài đặt Docker nếu chưa có
echo "[INFO] Kiểm tra Docker..."
if ! command -v docker &> /dev/null; then
    echo "[INFO] Cài đặt Docker..."
    sudo apt install -y docker.io
fi

# Thêm user hiện tại vào nhóm Docker
echo "[INFO] Thêm user vào nhóm Docker..."
sudo usermod -aG docker $USER

# Cấu hình sudo không cần mật khẩu
echo "[INFO] Cấu hình sudo không cần mật khẩu..."
if ! sudo grep -q "$USER ALL=(ALL) NOPASSWD:ALL" /etc/sudoers; then
    echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
fi

# Tạo thư mục actions-runner với quyền user hiện tại
echo "[INFO] Tạo thư mục actions-runner..."
mkdir -p ~/actions-runner
cd ~/actions-runner

# Cài đặt runner
echo "[INFO] Tải và cài đặt GitHub Runner..."
curl -o actions-runner-linux-x64.tar.gz -L https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz
tar xzf ./actions-runner-linux-x64.tar.gz
rm actions-runner-linux-x64.tar.gz

# Đăng ký runner
echo "[INFO] Đăng ký runner..."
./config.sh --url https://github.com/$GITHUB_OWNER --token $REG_TOKEN --name $RUNNER_NAME --labels $LABELS --unattended

# Cài đặt runner như một service
echo "[INFO] Cài đặt runner như một service..."
sudo ./svc.sh install
sudo ./svc.sh start

# Kiểm tra trạng thái runner
echo "[INFO] Kiểm tra trạng thái runner..."
sudo systemctl status actions.runner || echo "[WARNING] Runner có thể chưa hoạt động đúng. Hãy kiểm tra lại."

echo "[INFO] GitHub Runner đã được cài đặt thành công và đang chạy với tên $RUNNER_NAME!"
