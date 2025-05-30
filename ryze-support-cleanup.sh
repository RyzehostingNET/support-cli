#!/bin/bash

# This script is called by pam_script.so on session close.
# It checks if the user logging out is a temporary support user
# and deletes them if they have no other active sessions.
# Intended to be placed at /usr/local/sbin/ryze-support-cleanup.sh

SUPPORT_USER_PREFIX="support" # Must match the prefix in the main script
SUDOERS_DIR="/etc/sudoers.d"
LOG_FILE="/var/log/ryze-support-cleanup.log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

# Ensure log file is writable by root, create if not exists
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"

# PAM environment variables available:
# PAM_USER, PAM_RUSER, PAM_RHOST, PAM_SERVICE, PAM_TTY, PAM_TYPE (open_session, close_session)

# Only act on close_session events
if [ "$PAM_TYPE" != "close_session" ]; then
    exit 0
fi

# Check if the user logging out is one of our support users
if [[ "$PAM_USER" != ${SUPPORT_USER_PREFIX}_* ]]; then
    log_message "Ignoring logout for non-support user: $PAM_USER."
    exit 0 # Not a support user we manage
fi

log_message "PAM_USER $PAM_USER detected for cleanup. PAM_TYPE: $PAM_TYPE. Service: $PAM_SERVICE. TTY: $PAM_TTY."

# Check if the user has any other active sessions
# 'who' lists logged-in users.
# A small delay might be beneficial for session data to fully clear.
sleep 3 # Increased delay slightly

# Check active sessions using 'who'
# The -q option with grep makes it silent and only returns exit status
if who | grep -q "^\s*$PAM_USER\s"; then
    log_message "User $PAM_USER still has other active sessions. Not deleting yet."
    exit 0
fi

# Double-check with 'pgrep -u' if 'who' misses something (e.g., screen/tmux sessions not tied to tty)
# This might be overly cautious or lead to issues if the user legitimately has background processes
# For SSH, 'who' should be sufficient. If more robustness is needed, consider the implications.
# if pgrep -u "$PAM_USER" > /dev/null; then
#    log_message "User $PAM_USER still has active processes (checked with pgrep). Not deleting yet."
#    exit 0
# fi


log_message "No active sessions found for $PAM_USER. Proceeding with deletion."

# Delete sudoers file
SUDOERS_FILE="$SUDOERS_DIR/99-ryze-${PAM_USER}"
if [ -f "$SUDOERS_FILE" ]; then
    rm -f "$SUDOERS_FILE"
    if [ $? -eq 0 ]; then
        log_message "Removed sudoers file $SUDOERS_FILE."
    else
        log_message "ERROR: Failed to remove sudoers file $SUDOERS_FILE."
    fi
else
    log_message "Sudoers file $SUDOERS_FILE not found for $PAM_USER (might have been cleaned up already or never created properly)."
fi

# Delete the user and their home directory
# Use -f (force) with userdel to avoid issues if some files are in use, though this should be rare if sessions are closed.
userdel -r -f "$PAM_USER"
if [ $? -eq 0 ]; then
    log_message "Successfully deleted user $PAM_USER and their home directory."
else
    log_message "ERROR: Failed to delete user $PAM_USER. Exit code: $?. Manual cleanup might be required."
    # Consider sending a Discord alert about failed cleanup if critical
fi

exit 0
