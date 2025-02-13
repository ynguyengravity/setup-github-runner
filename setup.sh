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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
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
        if [ -z "$SUDO_USER" ]; then
            log_message "ERROR" "Please run without sudo, the script will ask for sudo when needed"
            exit 1
        fi
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
    
    # Create and set permissions for log files
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    sudo touch "$LOG_FILE" "$LOCK_FILE"
    sudo chown "$USER:$USER" "$LOG_FILE" "$LOCK_FILE"
    
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
    log_message "INFO" "Setting up maintenance..."
    
    # Create maintenance script
    cat << 'EOF' | sudo tee "$MAINTENANCE_SCRIPT"
#!/bin/bash

# System update
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y

# System cleanup
apt-get autoremove -y
apt-get clean
journalctl --vacuum-time=7d

# Docker cleanup
docker system prune -f
docker volume prune -f

# Restart runner
systemctl restart actions.runner.*
EOF
    
    sudo chmod +x "$MAINTENANCE_SCRIPT"
    
    # Setup daily maintenance
    (crontab -l 2>/dev/null | grep -v "$MAINTENANCE_SCRIPT"; echo "0 0 * * * $MAINTENANCE_SCRIPT") | crontab -
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
    local reg_token="BBG5IMRUQDG65XTOSKAKCHLHVV464"
    
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
