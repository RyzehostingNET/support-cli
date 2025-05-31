#!/bin/bash

# Uninstaller for Ryzehosting Support Tool (Cron-Based Monitoring)

# --- Configuration (Paths) ---
SUPPORT_SCRIPT_DEST="/usr/local/bin/support"
MONITOR_SCRIPT_DEST="/usr/local/sbin/ryze-support-monitor.sh"
STATE_FILE_DIR="/var/lib/ryze-support-tool"
CRON_FILE_NAME="ryze-support-monitor"
CRON_FILE_DEST="/etc/cron.d/$CRON_FILE_NAME"
MONITOR_LOG_FILE="/var/log/ryze-support-monitor.log"
MONITOR_CRON_LOG_FILE="/var/log/ryze-support-monitor-cron.log"

# --- Script Execution Guard ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

echo "Ryzehosting Support Tool Uninstaller (Cron-Based)"
echo "------------------------------------------------"

read -p "Are you sure you want to uninstall the Ryzehosting Support Tool? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# --- Remove Cron Job ---
echo "Removing cron job..."
if [ -f "$CRON_FILE_DEST" ]; then
    rm -f "$CRON_FILE_DEST"
    echo "Cron file $CRON_FILE_DEST removed."
else
    echo "Cron file $CRON_FILE_DEST not found."
fi
# Attempt to restart cron service to ensure it picks up changes, though often not needed for /etc/cron.d removal
if command -v systemctl &>/dev/null; then
    sudo systemctl try-restart cron.service || sudo systemctl try-restart crond.service
fi


# --- Remove Scripts ---
echo "Removing scripts..."
rm -f "$SUPPORT_SCRIPT_DEST"
rm -f "$MONITOR_SCRIPT_DEST"
echo "Scripts $SUPPORT_SCRIPT_DEST and $MONITOR_SCRIPT_DEST removed."

# --- Handle State Directory and Log Files ---
if [ -d "$STATE_FILE_DIR" ]; then
    read -p "Do you want to remove the state directory $STATE_FILE_DIR (contains active user list)? (y/N): " remove_state
    if [[ "$remove_state" =~ ^[Yy]$ ]]; then
        # Before removing, check if any support users are still listed, warn user to manually clean if so
        if [ -f "${STATE_FILE_DIR}/active_support_users.state" ] && [ -s "${STATE_FILE_DIR}/active_support_users.state" ]; then
            echo "WARNING: There might be active support users listed in the state file."
            echo "It's recommended to ensure they are logged out and manually delete them if necessary"
            echo "before removing the state directory, or let the monitor script clean them up if it's still running."
            read -p "Proceed with removing $STATE_FILE_DIR anyway? (y/N): " confirm_state_removal
            if [[ "$confirm_state_removal" =~ ^[Yy]$ ]]; then
                 rm -rf "$STATE_FILE_DIR"
                 echo "State directory $STATE_FILE_DIR removed."
            else
                echo "State directory $STATE_FILE_DIR kept."
            fi
        else
            rm -rf "$STATE_FILE_DIR"
            echo "State directory $STATE_FILE_DIR removed."
        fi
    else
        echo "State directory $STATE_FILE_DIR kept."
    fi
fi

# Handle log files
for log_to_remove in "$MONITOR_LOG_FILE" "$MONITOR_CRON_LOG_FILE"; do
    if [ -f "$log_to_remove" ]; then
        read -p "Do you want to remove the log file $log_to_remove? (y/N): " remove_log_choice
        if [[ "$remove_log_choice" =~ ^[Yy]$ ]]; then
            rm -f "$log_to_remove"
            echo "Log file $log_to_remove removed."
        else
            echo "Log file $log_to_remove kept."
        fi
    fi
done

echo ""
echo "Uninstallation Complete."
echo "If any support_ users were active, they might need manual cleanup if the state directory was removed before they were processed."
echo "You can check for remaining users with: getent passwd | grep '^support_'"
echo "And remaining sudoers files in /etc/sudoers.d/ named 99-ryze-support_*"

exit 0
