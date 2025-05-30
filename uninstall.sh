#!/bin/bash

# Uninstaller for Ryzehosting Support Tool

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

echo "Ryzehosting Support Tool Uninstaller"
echo "------------------------------------"

# --- Configuration (Paths) ---
CONFIG_DIR="/etc/ryze-support-tool"
# CONFIG_FILE="$CONFIG_DIR/config" # Config file is kept by default, as it's Ryze-provisioned
SUPPORT_SCRIPT_DEST="/usr/local/bin/support"
CLEANUP_SCRIPT_DEST="/usr/local/sbin/ryze-support-cleanup.sh"
PAM_SSHD_CONF="/etc/pam.d/sshd" # Or common-session
# More specific pattern to remove only our line
PAM_LINE_TO_REMOVE_PATTERN="^session\s\+optional\s\+pam_script\.so\s\+script=$CLEANUP_SCRIPT_DEST"
LOG_FILE="/var/log/ryze-support-cleanup.log"

read -p "Are you sure you want to uninstall the Ryzehosting Support Tool? (This will remove the 'support' command and auto-cleanup.) (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# --- Remove Scripts ---
echo "Removing scripts..."
rm -f "$SUPPORT_SCRIPT_DEST"
rm -f "$CLEANUP_SCRIPT_DEST"
echo "Scripts $SUPPORT_SCRIPT_DEST and $CLEANUP_SCRIPT_DEST removed."

# --- Remove PAM Configuration ---
echo "Removing PAM configuration..."
if [ -f "$PAM_SSHD_CONF" ]; then
    # Create a backup before modifying.
    BACKUP_PAM_FILE="${PAM_SSHD_CONF}.bak_ryze_uninstall_$(date +%Y%m%d%H%M%S)"
    cp "$PAM_SSHD_CONF" "$BACKUP_PAM_FILE"
    echo "Backup of $PAM_SSHD_CONF created at $BACKUP_PAM_FILE"

    # Use sed to remove the line.
    # The pattern needs to be specific to avoid removing other pam_script uses.
    # Using a different delimiter for sed in case paths contain /
    sed -i.prev "\|${PAM_LINE_TO_REMOVE_PATTERN}|d" "$PAM_SSHD_CONF"

    if ! grep -qE "script=$CLEANUP_SCRIPT_DEST" "$PAM_SSHD_CONF"; then
        echo "PAM configuration related to $CLEANUP_SCRIPT_DEST successfully removed from $PAM_SSHD_CONF."
        rm -f "${PAM_SSHD_CONF}.prev" # remove sed's automatic backup if change was successful
    else
        echo "WARNING: Could not automatically remove PAM line from $PAM_SSHD_CONF completely."
        echo "The line matching '$PAM_LINE_TO_REMOVE_PATTERN' might still exist or was not found precisely."
        echo "Please manually check and remove any lines related to $CLEANUP_SCRIPT_DEST in $PAM_SSHD_CONF."
        echo "The original file was backed up to $BACKUP_PAM_FILE, and sed created ${PAM_SSHD_CONF}.prev."
    fi
else
    echo "$PAM_SSHD_CONF not found. Skipping PAM cleanup."
fi

# --- Remove Sudoers Files ---
# This is important: remove any leftover sudoers files for support_ users
# The cleanup script *should* handle this, but as a safety measure:
echo "Removing any leftover sudoers files for support users (e.g., /etc/sudoers.d/99-ryze-support_*)..."
# Use find to locate and remove. Using -print before -delete for verbosity.
find /etc/sudoers.d/ -name "99-ryze-support_*" -print -delete
echo "Done checking for leftover sudoers files."


# --- Configuration and Log File Handling ---
echo "The configuration directory $CONFIG_DIR (containing the Discord webhook)"
echo "is NOT removed by this uninstaller as it's assumed to be part of Ryzehosting provisioning."
echo "If you need to remove it, do so manually: sudo rm -rf $CONFIG_DIR"
echo ""
if [ -f "$LOG_FILE" ]; then
    read -p "Do you want to remove the log file $LOG_FILE? (y/N): " remove_log
    if [[ "$remove_log" =~ ^[Yy]$ ]]; then
        rm -f "$LOG_FILE"
        echo "Log file $LOG_FILE removed."
    else
        echo "Log file $LOG_FILE kept."
    fi
fi

echo ""
echo "Uninstallation Complete."
echo "You may need to restart the sshd service if you want PAM changes to take immediate effect for existing sessions,"
echo "though new sessions will use the updated PAM configuration."
# Example: sudo systemctl try-restart sshd (safer than restart)

exit 0
