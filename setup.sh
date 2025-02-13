#!/bin/bash

set -e

# Global variables
LOCK_FILE="/tmp/github-runner-setup.lock"
LOG_FILE="/var/log/github-runner-setup.log"
MAINTENANCE_SCRIPT="/usr/local/bin/runner-maintenance.sh"
MAINT_LOG="/var/log/runner-maintenance.log"

# Function to setup logging
setup_logging() {
    # Create log directory if it doesn't exist
    sudo mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$MAINT_LOG")"
    
    # Create and set permissions for log files
    sudo touch "$LOG_FILE" "$MAINT_LOG"
    sudo chown "$SUDO_USER:$SUDO_USER" "$LOG_FILE" "$MAINT_LOG" 2>/dev/null || sudo chown "$USER:$USER" "$LOG_FILE" "$MAINT_LOG"
    sudo chmod 644 "$LOG_FILE" "$MAINT_LOG"
    
    # Create and set permissions for lock file
    sudo touch "$LOCK_FILE"
    sudo chown "$SUDO_USER:$SUDO_USER" "$LOCK_FILE" 2>/dev/null || sudo chown "$USER:$USER" "$LOCK_FILE"
    sudo chmod 644 "$LOCK_FILE"
    
    # Setup logging
    exec 1> >(tee -a "$LOG_FILE")
    exec 2>&1
}

# Function to check prerequisites
check_prerequisites() {
    log_message "INFO" "Checking prerequisites..."
    
    # Get effective user
    EFFECTIVE_USER=$(whoami)
    if [ "$EFFECTIVE_USER" = "root" ]; then
        if [ -z "$SUDO_USER" ]; then
            log_message "ERROR" "Please run the script as a normal user with sudo privileges"
            exit 1
        fi
        # If running with sudo, switch back to the original user
        su - "$SUDO_USER" -c "cd $(pwd) && ./$(basename "$0") $*"
        exit $?
    fi
    
    # Check if user has sudo privileges
    if ! sudo -v &>/dev/null; then
        log_message "ERROR" "User must have sudo privileges"
        exit 1
    fi
    
    # Check required parameters
    if [ -z "$1" ]; then
        log_message "ERROR" "RUNNER_ID không được để trống. Hãy cung cấp một ID."
        exit 1
    fi
    
    # Check lock file
    if [ -f "$LOCK_FILE" ] && [ "$2" != "force" ]; then
        log_message "ERROR" "Script đã được chạy trước đó. Thêm 'force' để chạy lại."
        exit 1
    fi
}

# Function to log messages
log_message() {
    local level="$1"
    local message="$2"
    echo "[$level] $message"
}

# Function to cleanup system
cleanup_system() {
    log_message "INFO" "Performing system cleanup..."
    
    # Package cleanup
    sudo apt-get clean
    sudo apt-get autoclean
    sudo apt-get autoremove -y
    sudo rm -rf /var/lib/apt/lists/*
    
    # Kernel cleanup
    sudo apt-get remove -y $(dpkg -l 'linux-*' | sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d') || true
    
    # Log cleanup
    sudo journalctl --vacuum-time=7d
    
    # Temp cleanup
    sudo rm -rf /tmp/* /var/tmp/*
    
    # Docker cleanup
    if command -v docker &> /dev/null; then
        docker system prune -f
        docker volume prune -f
        docker network prune -f
    fi
}

# Function to update system
update_system() {
    log_message "INFO" "Performing system update..."
    
    sudo apt-get update
    DEBIAN_FRONTEND=noninteractive sudo apt-get upgrade -y
    DEBIAN_FRONTEND=noninteractive sudo apt-get dist-upgrade -y
    sudo apt-get --fix-broken install -y
    sudo apt-get autoremove -y
    sudo apt-get clean
}

# Function to setup maintenance cron
setup_maintenance_cron() {
    log_message "INFO" "Setting up automatic maintenance..."
    
    # Create maintenance script
    cat << 'EOF' | sudo tee "$MAINTENANCE_SCRIPT"
#!/bin/bash

MAINT_LOG="/var/log/runner-maintenance.log"
echo "[$(date)] Starting maintenance..." >> "$MAINT_LOG"

# System update and upgrade
echo "[$(date)] Starting system update..." >> "$MAINT_LOG"
apt-get update >> "$MAINT_LOG" 2>&1

echo "[$(date)] Starting system upgrade..." >> "$MAINT_LOG"
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >> "$MAINT_LOG" 2>&1

echo "[$(date)] Starting distribution upgrade..." >> "$MAINT_LOG"
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y >> "$MAINT_LOG" 2>&1

# System cleanup
echo "[$(date)] Starting system cleanup..." >> "$MAINT_LOG"
apt-get autoremove -y >> "$MAINT_LOG" 2>&1
apt-get clean >> "$MAINT_LOG" 2>&1
journalctl --vacuum-time=7d >> "$MAINT_LOG" 2>&1

# Docker maintenance
if command -v docker &> /dev/null; then
    echo "[$(date)] Starting Docker cleanup..." >> "$MAINT_LOG"
    docker system prune -f >> "$MAINT_LOG" 2>&1
    docker volume prune -f >> "$MAINT_LOG" 2>&1
fi

# Service maintenance
echo "[$(date)] Restarting runner service..." >> "$MAINT_LOG"
systemctl restart actions.runner.* >> "$MAINT_LOG" 2>&1

echo "[$(date)] Maintenance completed successfully" >> "$MAINT_LOG"

# Check system status after maintenance
echo "[$(date)] System status after maintenance:" >> "$MAINT_LOG"
df -h >> "$MAINT_LOG" 2>&1
free -h >> "$MAINT_LOG" 2>&1
uptime >> "$MAINT_LOG" 2>&1
EOF

    sudo chmod +x "$MAINTENANCE_SCRIPT"
    
    # Setup cron job for daily maintenance at midnight
    CRON_CMD="0 0 * * * $MAINTENANCE_SCRIPT"
    (crontab -l 2>/dev/null | grep -v "$MAINTENANCE_SCRIPT"; echo "$CRON_CMD") | crontab -
    
    log_message "INFO" "Automatic maintenance configured to run at midnight daily"
    log_message "INFO" "Maintenance logs will be written to $MAINT_LOG"
}

# Function to setup time synchronization
setup_time_sync() {
    log_message "INFO" "Setting up time synchronization..."
    
    # Remove conflicting packages
    sudo apt-mark hold systemd-timesyncd ntpsec ntp time-daemon || true
    sudo dpkg --force-all -P systemd-timesyncd ntpsec ntp time-daemon || true
    sudo systemctl stop systemd-timesyncd || true
    sudo systemctl disable systemd-timesyncd || true
    
    # Install and configure chrony
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends chrony
    
    if [ -f /etc/chrony/chrony.conf ]; then
        sudo cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
        echo "server pool.ntp.org iburst" | sudo tee /etc/chrony/chrony.conf
    fi
    
    sudo systemctl enable chronyd
    sudo systemctl start chronyd
    
    # Verify chrony
    if ! systemctl is-active --quiet chronyd; then
        log_message "WARNING" "Chrony failed to start. Attempting fix..."
        sudo apt-get install --reinstall -y chrony
        sudo systemctl restart chronyd
    fi
}

# Function to setup Docker
setup_docker() {
    log_message "INFO" "Setting up Docker..."
    
    if ! command -v docker &> /dev/null; then
        sudo apt install -y docker.io
    fi
    
    sudo usermod -aG docker $USER
    sudo chmod 666 /var/run/docker.sock
    
    # Test Docker
    docker pull hello-world
    docker run --rm hello-world
    docker rmi hello-world
    docker system prune -f
}

# Function to setup runner
setup_runner() {
    local RUNNER_ID="$1"
    local REG_TOKEN="$2"
    local IP_ADDRESS=$(hostname -I | awk '{print $1}')
    local RUNNER_NAME="runner-$RUNNER_ID-$IP_ADDRESS"
    local LABELS="test-setup,linux,x64"
    local SERVICE_NAME="actions.runner.Gravity-Global.$RUNNER_NAME"
    
    log_message "INFO" "Setting up GitHub Runner..."
    
    # Create runner directory
    mkdir -p ~/actions-runner
    cd ~/actions-runner
    
    # Download and extract runner
    curl -o actions-runner-linux-x64.tar.gz -L https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz
    tar xzf ./actions-runner-linux-x64.tar.gz
    rm actions-runner-linux-x64.tar.gz
    
    # Configure runner
    ./config.sh --url https://github.com/Gravity-Global --token $REG_TOKEN --name $RUNNER_NAME --labels $LABELS --unattended
    
    # Install service
    sudo ./svc.sh install
    sudo ./svc.sh start
    
    # Set permissions
    sudo chown -R $USER:$USER ~/actions-runner
    sudo chmod -R 755 ~/actions-runner
    
    # Verify service
    sudo systemctl status $SERVICE_NAME || log_message "WARNING" "Runner may not be running correctly"
}

# Main function
main() {
    local RUNNER_ID="$1"
    local FORCE_RUN="$2"
    local REG_TOKEN="BBG5IMRUQDG65XTOSKAKCHLHVV464"
    
    setup_logging
    check_prerequisites "$RUNNER_ID" "$FORCE_RUN"
    
    log_message "INFO" "Starting GitHub Runner setup..."
    
    update_system
    cleanup_system
    setup_time_sync
    setup_docker
    setup_runner "$RUNNER_ID" "$REG_TOKEN"
    setup_maintenance_cron
    
    log_message "INFO" "Setup completed successfully!"
}

# Execute main function with all arguments
main "$@"
