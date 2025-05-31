#!/bin/bash

# Script to create a temporary Ryzehosting support user with SSH key-based access.
# Records user for cron-based monitoring and cleanup.
# Prompts for Discord webhook URL each time.

# --- Configuration ---
SUDOERS_DIR="/etc/sudoers.d"
SUPPORT_USER_PREFIX="support"
# STATE_FILE_DIR should be writable by this script (run as root)
# and readable/writable by the monitor cron script (run as root)
STATE_FILE_DIR="/var/lib/ryze-support-tool" # Using /var/lib for persistent state
STATE_FILE="$STATE_FILE_DIR/active_support_users.state"
# LOCK_FILE is used with flock to ensure safe concurrent access to STATE_FILE
LOCK_FILE="$STATE_FILE_DIR/active_support_users.lock" # Must be on the same filesystem as STATE_FILE

# --- Script Execution Guard ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

# --- Prompt for Discord Webhook URL ---
DISCORD_WEBHOOK_URL=""
echo "The support team should provide you with a one-time Discord Webhook URL."
while true; do
    read -p "Enter the Discord Webhook URL (or press Enter to skip Discord notification): " DISCORD_WEBHOOK_URL
    if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
        echo "Skipping Discord notification."
        DISCORD_WEBHOOK_URL="NONE" # Special value to signify no webhook
        break
    elif [[ "$DISCORD_WEBHOOK_URL" == https://discord.com/api/webhooks/* ]]; then
        break
    else
        echo "Invalid Discord Webhook URL format. It should start with 'https://discord.com/api/webhooks/'."
        echo "Please try again or press Enter to skip."
    fi
done

# --- Generate User Details ---
RAND_SUFFIX=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)
USERNAME="${SUPPORT_USER_PREFIX}_$(date +%s)_${RAND_SUFFIX}"
VM_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
SERVER_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null) # Get first IP from hostname -I
fi
[ -z "$SERVER_IP" ] && SERVER_IP="N/A" # Fallback if IP still not found


echo "Creating temporary support user: $USERNAME (SSH Key-Based Access, Cron Monitored)"

# --- Create User ---
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists. This should not happen. Aborting."
    exit 1
fi

useradd -m -s /bin/bash "$USERNAME"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create user $USERNAME."
    exit 1
fi
USER_HOME_DIR=$(eval echo "~$USERNAME") # Get home directory path reliably

# --- Generate SSH Key Pair & Setup Access ---
KEY_TEMP_DIR=$(mktemp -d)
if [ -z "$KEY_TEMP_DIR" ] || [ ! -d "$KEY_TEMP_DIR" ]; then
    echo "ERROR: Failed to create temporary directory for SSH keys."
    sudo userdel -r "$USERNAME" &>/dev/null # Attempt cleanup
    exit 1
fi
# Ensure temp dir is cleaned up when script exits, successfully or on error
trap 'rm -rf "$KEY_TEMP_DIR"' EXIT

SSH_KEY_PATH="$KEY_TEMP_DIR/support_key_for_${USERNAME}"
# echo "Generating SSH key pair..." # Can be less verbose
ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q # Quietly generate key
if [ $? -ne 0 ] || [ ! -f "${SSH_KEY_PATH}" ] || [ ! -f "${SSH_KEY_PATH}.pub" ]; then
    echo "ERROR: Failed to generate SSH key pair."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi

PRIVATE_KEY_CONTENT=$(cat "${SSH_KEY_PATH}")
PUBLIC_KEY_CONTENT=$(cat "${SSH_KEY_PATH}.pub")

# echo "Setting up SSH access for $USERNAME..." # Can be less verbose
USER_SSH_DIR="$USER_HOME_DIR/.ssh"
AUTHORIZED_KEYS_FILE="$USER_SSH_DIR/authorized_keys"

# Perform operations as the new user where possible, or chown later
sudo mkdir -p "$USER_SSH_DIR" # mkdir as root is fine, chown later
sudo chmod 700 "$USER_SSH_DIR"
echo "$PUBLIC_KEY_CONTENT" | sudo tee "$AUTHORIZED_KEYS_FILE" > /dev/null
sudo chmod 600 "$AUTHORIZED_KEYS_FILE"
# Crucially, ensure correct ownership of .ssh dir and authorized_keys file
sudo chown -R "${USERNAME}:${USERNAME}" "$USER_SSH_DIR"
# Also ensure home directory itself has correct ownership if useradd didn't set it (though it usually does)
sudo chown "${USERNAME}:${USERNAME}" "$USER_HOME_DIR"


if [ ! -d "$USER_SSH_DIR" ] || [ ! -f "$AUTHORIZED_KEYS_FILE" ]; then # Basic check
    echo "ERROR: Failed to setup SSH access files for $USERNAME."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi

# --- Grant Sudo Privileges ---
SUDOERS_FILE="$SUDOERS_DIR/99-ryze-${USERNAME}"
mkdir -p "$SUDOERS_DIR" # Ensure /etc/sudoers.d exists
echo "$USERNAME ALL=(ALL:ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
if [ $? -ne 0 ] || [ ! -f "$SUDOERS_FILE" ]; then
    echo "ERROR: Failed to create or set permissions for sudoers file $SUDOERS_FILE."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi

# --- Record user for monitoring (using flock for safety) ---
mkdir -p "$STATE_FILE_DIR" # Installer should create this, but good to have here too
chmod 0700 "$STATE_FILE_DIR" # Restrict access to state dir

(
    # flock on a dedicated lock file. The number (200) is an arbitrary file descriptor.
    flock -x 200
    CREATION_TIME=$(date +%s)
    # Format: username:status:creation_timestamp:first_login_timestamp:last_active_timestamp:discord_webhook_url_if_any
    # Storing webhook here is optional; could be just for Discord notification in this script
    echo "$USERNAME:pending_login:$CREATION_TIME:0:0" >> "$STATE_FILE"
    # If you wanted monitor to send alerts for deletion, webhook could be stored here.
    # For now, keeping it simple: monitor just deletes.
) 200>"$LOCK_FILE" # flock creates/uses this file descriptor associated with $LOCK_FILE

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to update the state file for monitoring. User $USERNAME might not be auto-deleted."
    # Decide if you want to proceed or exit. For now, proceed but warn.
fi

echo "User $USERNAME created and registered for monitoring by the cron job."

# --- Display Information ---
echo "--------------------------------------------------"
echo "Temporary Support Account Details (SSH Key Access):"
echo "Hostname (VM-ID): $VM_HOSTNAME"
echo "Server IP:        $SERVER_IP"
echo "Username:         $USERNAME"
echo ""
echo "SSH Private Key (provide this ENTIRE block to the support agent):"
echo "vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv"
echo "$PRIVATE_KEY_CONTENT"
echo "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^"
echo ""
echo "Example SSH command for agent:"
echo "  ssh -i /path/to/saved_private_key ${USERNAME}@${SERVER_IP}"
echo "--------------------------------------------------"
echo "This account will be automatically deleted by a background monitoring script"
echo "after logout, or if unused/overused for too long."
echo "IMPORTANT: The private key above grants access. Handle it securely."

# --- Send to Discord (if webhook provided) ---
if [ "$DISCORD_WEBHOOK_URL" != "NONE" ] && [ -n "$DISCORD_WEBHOOK_URL" ]; then
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    ADMIN_USER="${SUDO_USER:-$(whoami)}" # User who ran the script
    DISCORD_BOT_NAME="Ryzehosting Support Bot" # Make sure this is consistently set
    DISCORD_AVATAR_URL="https://i.imgur.com/G6k9Y94.png" # Replace with your Ryzehosting logo
    CURRENT_DATE_FOR_FOOTER=$(date) # Expand date here

    JSON_PAYLOAD=$(cat <<EOF
    {
      "username": "$DISCORD_BOT_NAME",
      "avatar_url": "$DISCORD_AVATAR_URL",
      "embeds": [{
        "title": "New Temp Support Account Created (SSH Key - Cron Monitored)",
        "color": 16705372,
        "fields": [
          {"name": "Hostname (VM-ID)", "value": "$VM_HOSTNAME", "inline": true},
          {"name": "Server IP", "value": "$SERVER_IP", "inline": true},
          {"name": "Username", "value": "\`$USERNAME\`", "inline": false},
          {"name": "Access Method", "value": "SSH Key (Private key displayed to admin)", "inline": false},
          {"name": "Requested By", "value": "\`$ADMIN_USER\`", "inline": true},
          {"name": "Status", "value": "Active - Awaiting logout/timeout for deletion", "inline": true}
        ],
        "footer": {
          "text": "Ryzehosting Support System - $CURRENT_DATE_FOR_FOOTER"
        },
        "timestamp": "$TIMESTAMP"
      }]
    }
EOF
    )

    curl_args=(-s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -X POST)
    # Use process substitution for jq if available, ensures robust JSON handling
    if command -v jq &> /dev/null; then
        RESPONSE_CODE=$(curl "${curl_args[@]}" -d <(echo "$JSON_PAYLOAD" | jq -c .) "$DISCORD_WEBHOOK_URL")
    else
        # Fallback: compact JSON manually. More fragile.
        COMPACT_JSON_PAYLOAD=$(echo "$JSON_PAYLOAD" | tr -d '\n' | sed 's/  //g')
        RESPONSE_CODE=$(curl "${curl_args[@]}" -d "$COMPACT_JSON_PAYLOAD" "$DISCORD_WEBHOOK_URL")
    fi

    if [ "$RESPONSE_CODE" -ge 200 ] && [ "$RESPONSE_CODE" -lt 300 ]; then
        echo "Notification successfully sent to Discord (HTTP Status: $RESPONSE_CODE)."
    else
        echo "WARNING: Failed to send notification to Discord. HTTP Status: $RESPONSE_CODE"
        # Optionally, log the failed payload for debugging (be careful with any sensitive info if it were present)
        # echo "Failed payload: $JSON_PAYLOAD" >> /var/log/ryze-support-discord-error.log
    fi
else
    echo "Skipping Discord notification as no valid webhook URL was provided."
fi

# Trap will clean $KEY_TEMP_DIR
exit 0
