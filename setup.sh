#!/bin/bash

set -e

# Global variables
SCRIPT_VERSION="1.0.0"
RUNNER_DIR="/opt/actions-runner"
WORKSPACE_BASE="${RUNNER_DIR}/_work"
LOCK_FILE="/tmp/github-runner-setup.lock"
LOG_FILE="/var/log/github-runner-setup.log"
MAINTENANCE_SCRIPT="${RUNNER_DIR}/maintenance.sh"

# Helper functions
log_message() {
    local level="$1"
    local message="$2"
    local log_time="[$(date '+%Y-%m-%d %H:%M:%S')]"
    local log_entry="$log_time [$level] $message"
    
    # Always print to stdout
    echo "$log_entry"
    
    # Try to log to file if we have permission
    if [ -w "$LOG_FILE" ] || [ -w "$(dirname "$LOG_FILE")" ]; then
        echo "$log_entry" >> "$LOG_FILE"
    fi
}

generate_random_string() {
    local length=${1:-8}
    tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w "$length" | head -n 1
}

get_ip_address() {
    hostname -I | awk '{print $1}'
}

create_runner_name() {
    local runner_id="$1"
    local ip_addr=$(get_ip_address)
    echo "runner-${runner_id}-${ip_addr}"
}

check_prerequisites() {
    local runner_id="$1"
    local force_run="$2"
    
    # Check if script is run with sudo
    if [ "$EUID" -eq 0 ]; then
        echo "ERROR: Please run without sudo, the script will ask for sudo when needed"
        exit 1
    fi
    
    # Create log directory with sudo
    if [ ! -f "$LOG_FILE" ]; then
        sudo mkdir -p "$(dirname "$LOG_FILE")"
        sudo touch "$LOG_FILE"
        sudo chown "$USER:$USER" "$LOG_FILE"
        sudo chmod 644 "$LOG_FILE"
    fi
    
    # Check required parameters
    if [ -z "$runner_id" ]; then
        log_message "ERROR" "RUNNER_ID không được để trống. Hãy cung cấp một ID."
        exit 1
    fi
    
    # Check lock file
    if [ -f "$LOCK_FILE" ] && [ "$force_run" != "force" ]; then
        log_message "ERROR" "Script đã được chạy trước đó. Thêm 'force' để chạy lại."
        exit 1
    fi
}

setup_directories() {
    log_message "INFO" "Setting up directories..."
    
    # Create lock file with sudo if needed
    if [ ! -f "$LOCK_FILE" ]; then
        sudo touch "$LOCK_FILE"
        sudo chown "$USER:$USER" "$LOCK_FILE"
        sudo chmod 644 "$LOCK_FILE"
    fi
    
    # Create runner directories
    sudo mkdir -p "$RUNNER_DIR" "$WORKSPACE_BASE" "${WORKSPACE_BASE}/_temp"
    sudo chown -R "$USER:$USER" "$RUNNER_DIR"
    sudo chmod -R 755 "$RUNNER_DIR"
}

setup_system() {
    log_message "INFO" "Setting up system..."
    
    # Update system
    sudo apt-get -o Acquire::Check-Valid-Until=false \
                 -o Acquire::Check-Date=false \
                 -o APT::Get::AllowUnauthenticated=true \
                 update
    
    # Install dependencies
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends \
        curl \
        jq \
        git \
        build-essential \
        unzip \
        python3 \
        python3-pip \
        nodejs \
        npm \
        docker.io
    
    # Configure user permissions
    sudo usermod -aG docker,adm,users,systemd-journal "$USER"
    
    # Configure sudo
    if ! sudo grep -q "$USER ALL=(ALL) NOPASSWD:ALL" /etc/sudoers; then
        echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
    fi
    
    # Configure Git
    git config --global --add safe.directory "*"
    git config --global core.fileMode false
    git config --global core.longpaths true

    # Setup directory permissions
    log_message "INFO" "Setting up directory permissions..."
    
    # Create and set permissions for common directories
    sudo mkdir -p \
        /usr/local/bin \
        /usr/local/aws-cli \
        /usr/local/lib \
        /usr/local/include \
        /usr/local/share \
        /usr/local/etc \
        /var/lib/docker \
        "${WORKSPACE_BASE}/_temp" \
        /tmp/runner \
        ~/.aws

    # Set ownership for directories
    sudo chown -R "$USER:$USER" \
        /usr/local/bin \
        /usr/local/aws-cli \
        /usr/local/lib \
        /usr/local/include \
        /usr/local/share \
        /usr/local/etc \
        "${WORKSPACE_BASE}" \
        "${WORKSPACE_BASE}/_temp" \
        /tmp/runner \
        ~/.aws

    # Set directory permissions
    sudo chmod -R 755 \
        /usr/local/bin \
        /usr/local/aws-cli \
        /usr/local/lib \
        /usr/local/include \
        /usr/local/share \
        /usr/local/etc

    # Set more permissive permissions for temp and workspace directories
    sudo chmod -R 777 \
        "${WORKSPACE_BASE}/_temp" \
        /tmp/runner

    # Set AWS and NPM directory permissions
    sudo chmod 700 ~/.aws
    
    # Create .npm directory for global installations
    mkdir -p ~/.npm
    sudo chown -R "$USER:$USER" ~/.npm
    sudo chmod 775 ~/.npm

    # Ensure Docker socket permissions
    sudo chmod 666 /var/run/docker.sock

    # Install AWS CLI
    log_message "INFO" "Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -o awscliv2.zip
    sudo ./aws/install --update
    rm -rf aws awscliv2.zip
}

setup_docker() {
    log_message "INFO" "Setting up Docker..."
    
    sudo chmod 666 /var/run/docker.sock
    
    # Test Docker
    docker pull hello-world
    docker run --rm hello-world
    docker rmi hello-world
    docker system prune -f
}

install_runner() {
    local runner_name="$1"
    local reg_token="$2"
    local labels="$3"
    
    log_message "INFO" "Installing GitHub Runner..."
    
    cd "$RUNNER_DIR"
    
    # Download and extract runner
    curl -o actions-runner-linux-x64.tar.gz -L \
        https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz
    tar xzf ./actions-runner-linux-x64.tar.gz
    rm actions-runner-linux-x64.tar.gz
    
    # Configure runner
    ./config.sh --url https://github.com/Gravity-Global \
                --token "$reg_token" \
                --name "$runner_name" \
                --labels "$labels" \
                --unattended
    
    # Install service
    sudo ./svc.sh install
    sudo ./svc.sh start
}

setup_maintenance() {
    log_message "INFO" "Setting up maintenance scripts..."
    
    # Create daily maintenance script
    cat << 'EOF' | sudo tee "${MAINTENANCE_SCRIPT}_daily.sh"
#!/bin/bash

# Log start of daily maintenance
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting daily maintenance..."

# Safe system cleanup
apt-get clean
journalctl --vacuum-time=7d

# Safe Docker cleanup (only unused resources)
docker image prune -f --filter "until=24h"
docker container prune -f --filter "until=24h"

# Log completion
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Daily maintenance completed"
EOF

    # Create weekly maintenance script
    cat << 'EOF' | sudo tee "${MAINTENANCE_SCRIPT}_weekly.sh"
#!/bin/bash

# Log start of weekly maintenance
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting weekly maintenance..."

# System update (without restart)
if ! ps aux | grep -i apt | grep -v grep > /dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-reboot
fi

# Full Docker cleanup
docker system prune -f
docker volume prune -f

# Restart runner
systemctl restart actions.runner.*

# Log completion
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Weekly maintenance completed"
EOF
    
    # Set permissions
    sudo chmod +x "${MAINTENANCE_SCRIPT}_daily.sh"
    sudo chmod +x "${MAINTENANCE_SCRIPT}_weekly.sh"
    
    # Setup maintenance schedules
    # Daily at 2 AM
    (crontab -l 2>/dev/null | grep -v "${MAINTENANCE_SCRIPT}_daily.sh"; echo "0 2 * * * ${MAINTENANCE_SCRIPT}_daily.sh") | crontab -
    # Weekly on Sunday at 1 AM
    (crontab -l 2>/dev/null | grep -v "${MAINTENANCE_SCRIPT}_weekly.sh"; echo "0 1 * * 0 ${MAINTENANCE_SCRIPT}_weekly.sh") | crontab -
}

verify_installation() {
    local service_name="$1"
    
    log_message "INFO" "Verifying installation..."
    
    # Check service status
    if ! sudo systemctl is-active --quiet "$service_name"; then
        log_message "WARNING" "Runner service is not active"
        sudo systemctl status "$service_name" || true
    else
        log_message "INFO" "Runner service is active"
    fi
    
    # Verify versions
    log_message "INFO" "Installed versions:"
    docker --version
    python3 --version
    node --version
    npm --version
    git --version
}

cleanup() {
    log_message "INFO" "Cleaning up..."
    sudo rm -f "$LOCK_FILE"
}

show_help() {
    cat << EOF
Usage: $0 <runner_id> [force]

Options:
  runner_id    Unique identifier for the runner
  force        Force reinstallation if already installed

Example:
  $0 test
  $0 prod force
EOF
}

# Function to sync time
sync_time() {
    log_message "INFO" "Synchronizing system time..."
    
    # Method 1: Using Google's headers
    local time_string=$(curl -sI google.com | grep -i "^date:" | cut -d' ' -f2-)
    if [ -n "$time_string" ]; then
        log_message "INFO" "Setting time from Google's response..."
        sudo date -s "$time_string" && {
            log_message "INFO" "Time synchronized successfully"
            return 0
        }
    fi
    
    # Method 2: Using worldtimeapi.org
    local time_string=$(curl -s http://worldtimeapi.org/api/timezone/Etc/UTC | grep -o '"datetime":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$time_string" ]; then
        log_message "INFO" "Setting time from worldtimeapi.org..."
        sudo date -s "$time_string" && {
            log_message "INFO" "Time synchronized successfully"
            return 0
        }
    fi
    
    log_message "WARNING" "Failed to synchronize time"
    return 1
}

# Update main function to include time sync
main() {
    # Parse arguments
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
    esac
    
    local runner_id="$1"
    local force_run="$2"
    local reg_token="BBG5IMRC6S7HTNCQ7S3ZBOLHV3HI4"
    
    # Setup
    check_prerequisites "$runner_id" "$force_run"
    setup_directories
    
    # Sync time before proceeding
    sync_time
    
    # Create runner name
    local runner_name=$(create_runner_name "$runner_id")
    local service_name="actions.runner.Gravity-Global.$runner_name"
    local labels="test-setup,linux,x64"
    
    # Main installation
    setup_system
    setup_docker
    install_runner "$runner_name" "$reg_token" "$labels"
    setup_maintenance
    
    # Verify and cleanup
    verify_installation "$service_name"
    cleanup
    
    log_message "INFO" "Installation completed successfully!"
}

# Execute main function with all arguments
main "$@"
