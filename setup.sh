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
    
    # Update package lists with time check disabled
    sudo apt-get -o Acquire::Check-Valid-Until=false \
                 -o Acquire::Check-Date=false \
                 -o APT::Get::AllowUnauthenticated=true \
                 update
    
    # Install essential packages
    DEBIAN_FRONTEND=noninteractive sudo apt-get -o Acquire::Check-Valid-Until=false \
                                               -o Acquire::Check-Date=false \
                                               -o APT::Get::AllowUnauthenticated=true \
                                               install -y --no-install-recommends \
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
    log_message "DEBUG" "Current system time: $(date)"
    
    # Try to sync hardware clock first
    log_message "INFO" "Attempting to sync hardware clock..."
    sudo hwclock --hctosys || log_message "WARNING" "Failed to sync from hardware clock"
    
    # Manual time sync using multiple methods
    log_message "INFO" "Attempting manual time sync..."
    
    # Method 1: Using date command with HTTP
    TIME_STRING=$(curl -sI http://google.com | grep -i "^date:" | cut -d' ' -f2-)
    if [ -n "$TIME_STRING" ]; then
        log_message "INFO" "Got time from HTTP header"
        sudo date -s "$TIME_STRING" || log_message "WARNING" "Failed to set time from HTTP"
    fi
    
    # Method 2: Using specific time server
    if ! date -s "$(curl -s --head http://time.nist.gov | grep '^Date:' | cut -d' ' -f2-)"
    then
        log_message "WARNING" "Failed to sync with time.nist.gov"
        
        # Method 3: Direct NTP query
        if command -v timeout &> /dev/null; then
            log_message "INFO" "Attempting direct NTP query..."
            echo -n "time.google.com 123" | timeout 3 nc -u time.google.com 123
            if [ $? -eq 0 ]; then
                log_message "INFO" "NTP query successful"
            else
                log_message "WARNING" "NTP query failed"
            fi
        fi
    fi
    
    log_message "DEBUG" "Time after sync attempts: $(date)"
    
    # Install required packages without time check
    log_message "INFO" "Installing required packages..."
    sudo apt-get -o Acquire::Check-Valid-Until=false \
                 -o Acquire::Check-Date=false \
                 -o APT::Get::AllowUnauthenticated=true \
                 update
    
    sudo apt-get -o Acquire::Check-Valid-Until=false \
                 -o Acquire::Check-Date=false \
                 -o APT::Get::AllowUnauthenticated=true \
                 install -y --no-install-recommends chrony
    
    # Configure chrony immediately
    if [ -f /etc/chrony/chrony.conf ]; then
        log_message "INFO" "Configuring chrony..."
        cat << 'EOF' | sudo tee /etc/chrony/chrony.conf
# Allow large clock corrections
makestep 1.0 -1

# Use multiple NTP servers
server time.google.com iburst
server time.cloudflare.com iburst
server time.facebook.com iburst
server time.apple.com iburst

# Record clock drift
driftfile /var/lib/chrony/drift

# Enable kernel RTC sync
rtcsync

# Log directory
logdir /var/log/chrony
EOF
        
        # Start chrony service
        log_message "INFO" "Starting chrony service..."
        sudo systemctl enable chrony
        sudo systemctl restart chrony
        
        # Wait for chrony to start and sync
        sleep 5
        
        # Check chrony status
        if sudo systemctl is-active --quiet chrony; then
            log_message "INFO" "Chrony service started successfully"
            sudo chronyc tracking || true
            sudo chronyc sources || true
        else
            log_message "WARNING" "Chrony service failed to start, continuing anyway..."
        fi
    else
        log_message "ERROR" "Chrony configuration file not found"
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
