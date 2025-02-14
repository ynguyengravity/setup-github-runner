#!/bin/bash

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# Constants
LOG_FILE="/var/log/machine-id-reset.log"
IP_FILE="/root/.initial_ip"
BACKUP_DIR="/root/machine-id-backup"
BACKUP_RETENTION_DAYS=30

# Setup logging
setup_logging() {
    # Create log file with secure permissions
    touch "$LOG_FILE" 2>/dev/null || {
        echo "Cannot create log file"
        exit 1
    }
    chmod 640 "$LOG_FILE"
}

# Function to log messages
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1"
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# Function to check disk space
check_disk_space() {
    local min_space=500000  # 500MB in KB
    local available_space=$(df -k /root | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -lt "$min_space" ]; then
        log_message "ERROR: Not enough disk space. Required: ${min_space}KB, Available: ${available_space}KB"
        return 1
    fi
    return 0
}

# Function to get current IP address
get_current_ip() {
    ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1
}

# Function to clean old backups
clean_old_backups() {
    if [ -d "$BACKUP_DIR" ]; then
        log_message "Cleaning backups older than $BACKUP_RETENTION_DAYS days"
        find "$BACKUP_DIR" -type f -mtime +$BACKUP_RETENTION_DAYS -delete
    fi
}

# Initialize
setup_logging
check_disk_space || exit 1

# Store initial IP if not already stored
if [ ! -f "$IP_FILE" ]; then
    get_current_ip > "$IP_FILE"
    chmod 600 "$IP_FILE"
    log_message "Initial IP stored: $(cat $IP_FILE)"
fi

# Check if IP has changed
initial_ip=$(cat "$IP_FILE")
current_ip=$(get_current_ip)

log_message "Initial IP: $initial_ip"
log_message "Current IP: $current_ip"

if [ "$initial_ip" == "$current_ip" ]; then
    log_message "IP hasn't changed. Starting machine-id reset process..."
    
    # Clean old backups first
    clean_old_backups
    
    # Create backup directory with secure permissions
    log_message "Creating backup directory..."
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    # Backup with timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    
    if [ -f /etc/machine-id ]; then
        cp /etc/machine-id "$BACKUP_DIR/machine-id.$timestamp"
        chmod 600 "$BACKUP_DIR/machine-id.$timestamp"
    fi

    if [ -f /var/lib/dbus/machine-id ]; then
        cp /var/lib/dbus/machine-id "$BACKUP_DIR/dbus-machine-id.$timestamp"
        chmod 600 "$BACKUP_DIR/dbus-machine-id.$timestamp"
    fi

    # Remove existing machine-id files
    log_message "Removing existing machine-id files..."
    rm -f /etc/machine-id
    rm -f /var/lib/dbus/machine-id

    # Generate new machine-id
    log_message "Generating new machine-id..."
    if ! systemd-machine-id-setup; then
        log_message "ERROR: Failed to generate new machine-id"
        exit 1
    fi

    # Set up systemd service if not exists
    if [ ! -f /etc/systemd/system/machine-id-reset.service ]; then
        cat > /etc/systemd/system/machine-id-reset.service << EOF
[Unit]
Description=Reset machine-id and check IP
After=network.target

[Service]
Type=oneshot
ExecStart=$(readlink -f $0)
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

        chmod 644 /etc/systemd/system/machine-id-reset.service
        if ! systemctl enable machine-id-reset.service; then
            log_message "ERROR: Failed to enable machine-id-reset service"
            exit 1
        fi
    fi

    log_message "Rebooting system in 5 seconds..."
    sync
    sleep 5
    reboot
else
    log_message "IP has changed successfully. Cleaning up..."
    # Clean up
    rm -f "$IP_FILE"
    if systemctl is-enabled machine-id-reset.service &>/dev/null; then
        systemctl disable machine-id-reset.service
    fi
    rm -f /etc/systemd/system/machine-id-reset.service
    log_message "Cleanup completed. System is ready to use."
fi
