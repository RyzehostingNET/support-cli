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
    # Ensure LOG_FILE is defined and not empty
    if [ -n "$LOG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
    else
        # Fallback if LOG_FILE somehow not set, though unlikely here
        echo "$(date '+%Y-%m-%d %H:%M:%S') (LOG_FILE not set): $1" >&2
    fi
}

# Ensure log file is writable by root, create if not exists
# Make sure this happens only once per script invocation if possible, but for now, it's fine.
if ! touch "$LOG_FILE"; then
    # If touch fails, we can't log to file. Log to stderr (which might go to journald)
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Could not touch log file $LOG_FILE. Permissions?" >&2
    exit 1 # Exit if we can't even create the log file
fi
if ! chmod 600 "$LOG_FILE"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: Could not chmod log file $LOG_FILE." >&2
    # Continue, but logging might be an issue or file might be world-readable briefly
fi

# --- CRITICAL DEBUGGING LOGS ---
# Log essential PAM variables immediately after log file creation
# to see what environment the script is running in.
log_message "--- ryze-support-cleanup.sh invoked ---"
log_message "Raw PAM_USER: [$PAM_USER]"
log_message "Raw PAM_RUSER: [$PAM_RUSER]"
log_message "Raw PAM_RHOST: [$PAM_RHOST]"
log_message "Raw PAM_SERVICE: [$PAM_SERVICE]"
log_message "Raw PAM_TTY: [$PAM_TTY]"
log_message "Raw PAM_TYPE: [$PAM_TYPE]"
log_message "Script UID: $(id -u), EUID: $(id -euid)"
log_message "---------------------------------------"
# --- END CRITICAL DEBUGGING LOGS ---


# Only act on close_session events
if [ "$PAM_TYPE" != "close_session" ]; then
    log_message "Exiting: PAM_TYPE is [$PAM_TYPE], not 'close_session'."
    exit 0
fi

# Check if the user logging out is one of our support users
# Add quotes around PAM_USER for safety, though prefix matching should be fine
if [[ "$PAM_USER" != ${SUPPORT_USER_PREFIX}_* ]]; then
    log_message "Exiting: PAM_USER [$PAM_USER] does not match prefix [${SUPPORT_USER_PREFIX}_*]."
    exit 0
fi

# If we reach here, conditions are met to proceed
log_message "Proceeding: PAM_USER [$PAM_USER] detected for cleanup. PAM_TYPE: [$PAM_TYPE]."

# Check if the user has any other active sessions
# 'who' lists logged-in users.
# A small delay might be beneficial for session data to fully clear.
log_message "Waiting for 3 seconds before checking active sessions..."
sleep 3

# Check active sessions using 'who'
# The -q option with grep makes it silent and only returns exit status
# Need to ensure PAM_USER is not empty for safety in grep pattern
if [ -n "$PAM_USER" ] && who | grep -qw "^${PAM_USER}\s"; then
    log_message "User $PAM_USER still has other active sessions. Not deleting yet."
    exit 0
fi

log_message "No active sessions found for $PAM_USER. Proceeding with deletion."

# Delete sudoers file
SUDOERS_FILE="$SUDOERS_DIR/99-ryze-${PAM_USER}"
if [ -f "$SUDOERS_FILE" ]; then
    if rm -f "$SUDOERS_FILE"; then
        log_message "Removed sudoers file $SUDOERS_FILE."
    else
        log_message "ERROR: Failed to remove sudoers file $SUDOERS_FILE. Return code: $?."
    fi
else
    log_message "Sudoers file $SUDOERS_FILE not found for $PAM_USER."
fi

# Delete the user and their home directory
# Use -f (force) with userdel
log_message "Attempting to delete user $PAM_USER..."
if userdel -r -f "$PAM_USER"; then
    log_message "Successfully deleted user $PAM_USER and their home directory."
else
    USERDEL_EC=$?
    log_message "ERROR: Failed to delete user $PAM_USER. Exit code: $USERDEL_EC. Manual cleanup might be required."
fi

log_message "--- ryze-support-cleanup.sh finished ---"
exit 0
