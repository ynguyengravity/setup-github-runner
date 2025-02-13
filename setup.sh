#!/bin/bash

set -e

# Global variables
LOCK_FILE="/tmp/github-runner-setup.lock"
LOG_FILE="/var/log/github-runner-setup.log"
MAINTENANCE_SCRIPT="/usr/local/bin/runner-maintenance.sh"
MAINT_LOG="/var/log/runner-maintenance.log"

# Function to check prerequisites and setup permissions
check_and_setup_permissions() {
    local RUNNER_ID="$1"
    local FORCE_RUN="$2"
    
    # Check if script is run with sudo
    if [ "$EUID" -eq 0 ]; then
        if [ -z "$SUDO_USER" ]; then
            echo "[ERROR] Please run without sudo, the script will ask for sudo when needed"
            exit 1
        fi
        # Get the actual user's home directory
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        USER_HOME="$HOME"
    fi
    
    # Create log directories and set permissions first
    sudo mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$MAINT_LOG")"
    sudo touch "$LOG_FILE" "$MAINT_LOG" "$LOCK_FILE"
    sudo chown -R "$USER:$USER" "$(dirname "$LOG_FILE")" "$(dirname "$MAINT_LOG")"
    sudo chmod 755 "$(dirname "$LOG_FILE")" "$(dirname "$MAINT_LOG")"
    sudo chmod 644 "$LOG_FILE" "$MAINT_LOG" "$LOCK_FILE"
    
    # Check required parameters
    if [ -z "$RUNNER_ID" ]; then
        echo "[ERROR] RUNNER_ID không được để trống. Hãy cung cấp một ID."
        exit 1
    fi
    
    # Check lock file
    if [ -f "$LOCK_FILE" ] && [ "$FORCE_RUN" != "force" ]; then
        echo "[ERROR] Script đã được chạy trước đó. Thêm 'force' để chạy lại."
        exit 1
    fi
    
    # Verify sudo access
    if ! sudo -v; then
        echo "[ERROR] User must have sudo privileges"
        exit 1
    fi
}

# Function to setup logging
setup_logging() {
    # Setup logging after permissions are correct
    exec 1> >(tee -a "$LOG_FILE")
    exec 2>&1
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
    
    # Fix time sync issue first
    log_message "INFO" "Synchronizing system time..."
    if ! command -v ntpdate &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive sudo apt-get update
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y ntpdate
    fi
    sudo ntpdate pool.ntp.org || log_message "WARNING" "ntpdate failed, continuing with chrony"
    
    # Update with minimal packages
    sudo apt-get update
    
    # Install only essential packages
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        git \
        jq \
        docker.io
    
    # Clean up
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
    
    # Debug: Check initial state
    log_message "DEBUG" "Checking initial system state..."
    dpkg -l | grep chrony || log_message "DEBUG" "Chrony not found in package list"
    ls -l /lib/systemd/system/chrony* || log_message "DEBUG" "No chrony service files found in /lib/systemd/system/"
    ls -l /etc/systemd/system/chrony* || log_message "DEBUG" "No chrony service files found in /etc/systemd/system/"
    
    # Remove conflicting packages
    log_message "INFO" "Removing conflicting packages..."
    sudo systemctl stop systemd-timesyncd || true
    sudo systemctl disable systemd-timesyncd || true
    sudo apt-mark hold systemd-timesyncd || true
    
    # Clean up any existing chrony installation
    log_message "INFO" "Cleaning up existing chrony installation..."
    sudo apt-get remove --purge -y chrony || true
    sudo apt-get autoremove -y
    
    # Install chrony
    log_message "INFO" "Installing chrony..."
    DEBIAN_FRONTEND=noninteractive sudo apt-get update
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y chrony
    
    # Debug: Check installation results
    log_message "DEBUG" "Checking chrony installation..."
    dpkg -l | grep chrony || log_message "ERROR" "Chrony installation failed"
    ls -l /lib/systemd/system/chrony* || log_message "ERROR" "No chrony service files found after installation"
    
    # Reload systemd to recognize new service
    log_message "INFO" "Reloading systemd..."
    sudo systemctl daemon-reload
    
    # Detect chrony service name
    local CHRONY_SERVICE=""
    log_message "DEBUG" "Looking for chrony service..."
    systemctl list-unit-files | grep -i chrony
    
    if systemctl list-unit-files | grep -q "chronyd.service"; then
        CHRONY_SERVICE="chronyd"
    elif systemctl list-unit-files | grep -q "chrony.service"; then
        CHRONY_SERVICE="chrony"
    else
        log_message "ERROR" "Could not find chrony service after installation. Debug info:"
        systemctl list-unit-files | grep -i chrony
        journalctl -xe --no-pager | tail -n 50
        exit 1
    fi
    
    log_message "INFO" "Detected chrony service as: $CHRONY_SERVICE"
    
    # Configure chrony
    if [ -f /etc/chrony/chrony.conf ]; then
        log_message "INFO" "Configuring chrony..."
        sudo cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
        cat << 'EOF' | sudo tee /etc/chrony/chrony.conf
# Use multiple NTP servers for better reliability
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
server 3.pool.ntp.org iburst

# Record the rate at which the system clock gains/losses time
driftfile /var/lib/chrony/drift

# Allow the system clock to be stepped in the first three updates
makestep 1.0 3

# Enable kernel synchronization of the real-time clock (RTC)
rtcsync

# Specify directory for log files
logdir /var/log/chrony
EOF
    else
        log_message "ERROR" "chrony.conf not found at /etc/chrony/chrony.conf"
        ls -l /etc/chrony/ || log_message "ERROR" "/etc/chrony/ directory not found"
    fi
    
    # Start and verify chrony
    log_message "INFO" "Starting chrony service..."
    sudo systemctl enable $CHRONY_SERVICE || log_message "ERROR" "Failed to enable $CHRONY_SERVICE"
    sudo systemctl restart $CHRONY_SERVICE || {
        log_message "ERROR" "Failed to restart $CHRONY_SERVICE. Service status:"
        sudo systemctl status $CHRONY_SERVICE
        journalctl -xe --no-pager | tail -n 50
    }
    sleep 2  # Give chrony time to start
    
    # Check chrony status
    if sudo systemctl is-active --quiet $CHRONY_SERVICE; then
        log_message "INFO" "Chrony service started successfully"
        sudo chronyc sources
    else
        log_message "WARNING" "Chrony failed to start. Attempting fix..."
        sudo apt-get install --reinstall -y chrony
        sudo systemctl daemon-reload
        sudo systemctl restart $CHRONY_SERVICE
        if ! sudo systemctl is-active --quiet $CHRONY_SERVICE; then
            log_message "ERROR" "Failed to start chrony service. Debug info:"
            sudo systemctl status $CHRONY_SERVICE
            journalctl -xe --no-pager | tail -n 50
            ls -l /var/log/chrony/ || true
            cat /var/log/chrony/measurements.log || true
            exit 1
        fi
    fi
    
    # Verify time synchronization
    log_message "INFO" "Verifying time synchronization..."
    if ! sudo chronyc tracking; then
        log_message "WARNING" "Could not verify time synchronization. Debug info:"
        sudo chronyc sources
        sudo chronyc tracking
        sudo chronyc sourcestats
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
    
    # Check permissions and prerequisites first
    check_and_setup_permissions "$RUNNER_ID" "$FORCE_RUN"
    setup_logging
    
    log_message "INFO" "Starting GitHub Runner setup..."
    
    # Setup time sync first to avoid update issues
    setup_time_sync
    update_system
    cleanup_system
    setup_docker
    setup_runner "$RUNNER_ID" "$REG_TOKEN"
    setup_maintenance_cron
    
    log_message "INFO" "Setup completed successfully!"
}

# Execute main function with all arguments
main "$@"
