#!/bin/bash

# Monitors and cleans up temporary Ryzehosting support users.
# To be run by cron, e.g., every minute.

# --- Configuration ---
STATE_FILE_DIR="/var/lib/ryze-support-tool"
STATE_FILE="$STATE_FILE_DIR/active_support_users.state"
LOCK_FILE="$STATE_FILE_DIR/active_support_users.lock"
LOG_FILE="/var/log/ryze-support-monitor.log" # Log file for this monitor script

SUDOERS_DIR="/etc/sudoers.d"

# Timeouts (in seconds)
PENDING_LOGIN_TIMEOUT=$((60 * 60))         # 1 hour for user to login first time
MAX_SESSION_DURATION=$((8 * 60 * 60))      # 8 hours max active session
LOGOUT_DETECTED_GRACE_PERIOD=$((2 * 60))   # 2 minutes grace period after logout detection

# --- Helper Functions ---
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

delete_support_user() {
    local user_to_delete="$1" # 'local' is CORRECT here because it's inside a function
    if [ -z "$user_to_delete" ]; then return 1; fi

    log_message "Attempting to delete user $user_to_delete and associated sudoers file."
    local sudo_file_to_del="$SUDOERS_DIR/99-ryze-${user_to_delete}" # 'local' is CORRECT here

    if [ -f "$sudo_file_to_del" ]; then
        if rm -f "$sudo_file_to_del"; then
            log_message "Removed sudoers file: $sudo_file_to_del."
        else
            log_message "ERROR: Failed to remove sudoers file: $sudo_file_to_del. RC: $?"
        fi
    fi

    if id "$user_to_delete" &>/dev/null; then
        if userdel -r -f "$user_to_delete"; then
            log_message "Successfully deleted user: $user_to_delete."
        else
            log_message "ERROR: Failed to delete user: $user_to_delete. RC: $?"
        fi
    else
        log_message "User $user_to_delete not found (already deleted or never fully created)."
    fi
}

# --- Main Logic ---
# Ensure log file exists and is writable by root
touch "$LOG_FILE" && chmod 600 "$LOG_FILE" || { echo "CRITICAL: $(date): Cannot create/chmod log file $LOG_FILE" >&2; exit 1; }

# Try to acquire lock, exit if another instance is running
(
    flock -x -n 200 || { log_message "Monitor script already running or lock file stale. Exiting."; exit 1; }

    if [ ! -f "$STATE_FILE" ]; then
        exit 0 # Normal if no support users created yet
    fi

    CURRENT_TIME=$(date +%s)
    TEMP_STATE_FILE=$(mktemp "${STATE_FILE_DIR}/state.XXXXXX")
    if [ -z "$TEMP_STATE_FILE" ]; then
        log_message "ERROR: Could not create temporary state file. Exiting."
        exit 1
    fi
    STATE_CHANGED_THIS_RUN=false

    LOGGED_IN_USERS=$(who | awk '{print $1}' | sort -u)

    while IFS=: read -r username status creation_ts first_login_ts last_active_ts || [[ -n "$username" ]]; do
        if [ -z "$username" ]; then continue; fi

        # ---- VVVV REMOVED 'local' KEYWORD FROM THESE LINES VVVV ----
        keep_this_entry=true
        new_status="$status"
        new_first_login_ts="$first_login_ts"
        new_last_active_ts="$last_active_ts"
        # ---- ^^^^ REMOVED 'local' KEYWORD FROM THESE LINES ^^^^ ----

        user_is_currently_logged_in=false
        if echo "$LOGGED_IN_USERS" | grep -qxF "$username"; then
            user_is_currently_logged_in=true
        fi

        case "$status" in
            "pending_login")
                if "$user_is_currently_logged_in"; then
                    log_message "User $username logged in for the first time. Status -> logged_in."
                    new_status="logged_in"
                    new_first_login_ts="$CURRENT_TIME"
                    new_last_active_ts="$CURRENT_TIME"
                    STATE_CHANGED_THIS_RUN=true
                elif (( CURRENT_TIME - creation_ts > PENDING_LOGIN_TIMEOUT )); then
                    log_message "User $username (pending_login) timed out (>$PENDING_LOGIN_TIMEOUT s without login). Deleting."
                    delete_support_user "$username"
                    keep_this_entry=false
                    STATE_CHANGED_THIS_RUN=true
                fi
                ;;

            "logged_in")
                if "$user_is_currently_logged_in"; then
                    # Only mark state as changed if last_active_ts actually needs updating
                    if [[ "$last_active_ts" -ne "$CURRENT_TIME" ]]; then
                        new_last_active_ts="$CURRENT_TIME" # Update last seen active
                        STATE_CHANGED_THIS_RUN=true
                    fi
                    if (( CURRENT_TIME - first_login_ts > MAX_SESSION_DURATION )); then
                        log_message "User $username (logged_in) exceeded max session duration (>$MAX_SESSION_DURATION s). Deleting."
                        delete_support_user "$username"
                        keep_this_entry=false
                        STATE_CHANGED_THIS_RUN=true
                    fi
                else # Was logged_in, but is not currently logged in
                    log_message "User $username (logged_in) is no longer detected as active. Status -> pending_delete."
                    new_status="pending_delete"
                    new_last_active_ts="$CURRENT_TIME" # Record time logout was detected
                    STATE_CHANGED_THIS_RUN=true
                fi
                ;;

            "pending_delete")
                if "$user_is_currently_logged_in"; then
                    log_message "User $username (pending_delete) logged back in. Status -> logged_in."
                    new_status="logged_in"
                    new_last_active_ts="$CURRENT_TIME"
                    STATE_CHANGED_THIS_RUN=true
                elif (( CURRENT_TIME - last_active_ts > LOGOUT_DETECTED_GRACE_PERIOD )); then
                    log_message "User $username (pending_delete) grace period (>$LOGOUT_DETECTED_GRACE_PERIOD s) expired. Deleting."
                    delete_support_user "$username"
                    keep_this_entry=false
                    STATE_CHANGED_THIS_RUN=true
                fi
                ;;
            *)
                log_message "WARNING: Unknown status '$status' for user $username. Keeping entry."
                ;;
        esac

        if "$keep_this_entry"; then
            echo "$username:$new_status:$creation_ts:$new_first_login_ts:$new_last_active_ts" >> "$TEMP_STATE_FILE"
        fi
    done < "$STATE_FILE"

    if "$STATE_CHANGED_THIS_RUN"; then
        if mv "$TEMP_STATE_FILE" "$STATE_FILE"; then
             : # Successfully moved, do nothing (or minimal log)
        else
            log_message "ERROR: Failed to move temp state file $TEMP_STATE_FILE to $STATE_FILE."
            rm -f "$TEMP_STATE_FILE"
        fi
    else
        rm -f "$TEMP_STATE_FILE"
    fi

) 200>"$LOCK_FILE"

exit 0
