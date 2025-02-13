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

# Setup workspace directories
echo "[INFO] Setting up workspace directories..."
WORKSPACE_BASE="/home/$USER/actions-runner/_work"
sudo mkdir -p "$WORKSPACE_BASE"
sudo mkdir -p "$WORKSPACE_BASE/_temp"
sudo chown -R $USER:$USER "$WORKSPACE_BASE"
sudo chmod -R 755 "$WORKSPACE_BASE"

# Ensure Git has correct permissions
echo "[INFO] Configuring Git..."
git config --global --add safe.directory "*"
git config --global core.fileMode false
git config --global core.longpaths true

if [ -f "$LOCK_FILE" ] && [ "$FORCE_RUN" != "force" ]; then
    echo "[ERROR] Script đã được chạy trước đó. Nếu muốn chạy lại, hãy thêm tham số 'force'."
    exit 1
fi

echo "[INFO] Nhận tham số đầu vào..."
RUNNER_ID=$1
# REG_TOKEN=$2
REG_TOKEN="BBG5IMRUQDG65XTOSKAKCHLHVV464"
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
SERVICE_NAME="actions.runner.$GITHUB_OWNER.$RUNNER_NAME"

# Cập nhật hệ thống
echo "[INFO] Cập nhật hệ thống..."
sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y

# Cài đặt các gói cần thiết
echo "[INFO] Cài đặt các gói hỗ trợ..."
# Stop and disable systemd-timesyncd if it's running
echo "[INFO] Stopping and disabling systemd-timesyncd..."
sudo systemctl stop systemd-timesyncd
sudo systemctl disable systemd-timesyncd

# Remove conflicting packages
echo "[INFO] Removing conflicting packages..."
sudo apt remove -y ntpsec systemd-timesyncd || true

# Install required packages
echo "[INFO] Installing required packages..."
sudo apt update
sudo apt install -y curl jq git build-essential unzip python3 python3-pip nodejs npm chrony

# Configure time synchronization with chrony
echo "[INFO] Configuring chrony..."
sudo systemctl enable chronyd
sudo systemctl start chronyd

# Cài đặt Docker nếu chưa có
echo "[INFO] Kiểm tra Docker..."
if ! command -v docker &> /dev/null; then
    echo "[INFO] Cài đặt Docker..."
    sudo apt install -y docker.io
fi

# Thêm user hiện tại vào các nhóm cần thiết
echo "[INFO] Thêm user vào các nhóm cần thiết..."
sudo usermod -aG docker,adm,users,systemd-journal $USER

# Cấu hình sudo không cần mật khẩu cho user hiện tại
echo "[INFO] Cấu hình sudo không cần mật khẩu..."
if ! sudo grep -q "$USER ALL=(ALL) NOPASSWD:ALL" /etc/sudoers; then
    echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
fi

# Tạo và cấp quyền cho các thư mục cần thiết
echo "[INFO] Cấp quyền cho các thư mục cần thiết..."
sudo mkdir -p /usr/local/{aws-cli,bin,test-dir}
sudo chown -R $USER:$USER /usr/local/aws-cli
sudo chown -R $USER:$USER /usr/local/bin
sudo chown -R $USER:$USER /usr/local/test-dir
sudo chmod -R 755 /usr/local/aws-cli
sudo chmod -R 755 /usr/local/bin
sudo chmod -R 755 /usr/local/test-dir

# Cấp quyền cho Docker socket
echo "[INFO] Cấp quyền cho Docker socket..."
sudo chmod 666 /var/run/docker.sock

# Test Docker và cleanup
echo "[INFO] Test Docker và pull images..."
echo "Testing Docker pull..."
docker pull ubuntu:20.04
docker pull nginx:latest
docker pull hello-world

echo "Testing Docker run..."
docker run --rm hello-world

echo "Cleaning up Docker test..."
docker rmi ubuntu:20.04 nginx:latest hello-world
docker system prune -f

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

# Cấp quyền cho thư mục actions-runner
echo "[INFO] Cấp quyền cho thư mục actions-runner..."
sudo chown -R $USER:$USER ~/actions-runner
sudo chmod -R 755 ~/actions-runner

# Kiểm tra trạng thái runner
echo "[INFO] Kiểm tra trạng thái runner..."
sudo systemctl status $SERVICE_NAME || echo "[WARNING] Runner có thể chưa hoạt động đúng. Hãy kiểm tra lại."

echo "[INFO] GitHub Runner đã được cài đặt thành công và đang chạy với tên $RUNNER_NAME!"

# Verify installation
echo "[INFO] Verifying installation..."
echo "- Docker version: $(docker --version)"
echo "- Python version: $(python3 --version)"
echo "- Node.js version: $(node --version)"
echo "- NPM version: $(npm --version)"
echo "- Git version: $(git --version)"

# After installing runner service, ensure workspace permissions again
echo "[INFO] Final workspace permissions check..."
sudo chown -R $USER:$USER "$WORKSPACE_BASE"
sudo chmod -R 755 "$WORKSPACE_BASE"
find "$WORKSPACE_BASE" -type d -exec chmod 755 {} \;
find "$WORKSPACE_BASE" -type f -exec chmod 644 {} \;
