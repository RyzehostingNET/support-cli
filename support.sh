#!/bin/bash

# Script to create a temporary Ryzehosting support user with SSH key-based access.
# Records user for cron-based monitoring and cleanup.
# Prompts for Discord webhook URL each time.

# --- Configuration ---
SUDOERS_DIR="/etc/sudoers.d"
SUPPORT_USER_PREFIX="support"
STATE_FILE_DIR="/var/lib/ryze-support-tool"
STATE_FILE="$STATE_FILE_DIR/active_support_users.state"
LOCK_FILE="$STATE_FILE_DIR/active_support_users.lock"

# --- Script Execution Guard ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

# --- Prompt for Discord Webhook URL ---
DISCORD_WEBHOOK_URL=""
echo "The support team should provide you with a one-time Discord Webhook URL."
while true; do
    read -r -p "Enter the Discord Webhook URL (or press Enter to skip Discord notification): " DISCORD_WEBHOOK_URL_INPUT
    # Remove leading/trailing whitespace which can be pasted accidentally
    DISCORD_WEBHOOK_URL=$(echo "$DISCORD_WEBHOOK_URL_INPUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

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
    SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null)
fi
[ -z "$SERVER_IP" ] && SERVER_IP="N/A"


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
USER_HOME_DIR=$(eval echo "~$USERNAME")

# --- Generate SSH Key Pair & Setup Access ---
KEY_TEMP_DIR=$(mktemp -d)
if [ -z "$KEY_TEMP_DIR" ] || [ ! -d "$KEY_TEMP_DIR" ]; then
    echo "ERROR: Failed to create temporary directory for SSH keys."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi
trap 'rm -rf "$KEY_TEMP_DIR"' EXIT

SSH_KEY_PATH="$KEY_TEMP_DIR/support_key_for_${USERNAME}"
ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q
if [ $? -ne 0 ] || [ ! -f "${SSH_KEY_PATH}" ] || [ ! -f "${SSH_KEY_PATH}.pub" ]; then
    echo "ERROR: Failed to generate SSH key pair."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi

PRIVATE_KEY_CONTENT=$(cat "${SSH_KEY_PATH}")
PUBLIC_KEY_CONTENT=$(cat "${SSH_KEY_PATH}.pub")

USER_SSH_DIR="$USER_HOME_DIR/.ssh"
AUTHORIZED_KEYS_FILE="$USER_SSH_DIR/authorized_keys"

sudo mkdir -p "$USER_SSH_DIR"
sudo chmod 700 "$USER_SSH_DIR"
echo "$PUBLIC_KEY_CONTENT" | sudo tee "$AUTHORIZED_KEYS_FILE" > /dev/null
sudo chmod 600 "$AUTHORIZED_KEYS_FILE"
sudo chown -R "${USERNAME}:${USERNAME}" "$USER_SSH_DIR"
sudo chown "${USERNAME}:${USERNAME}" "$USER_HOME_DIR"

if [ ! -d "$USER_SSH_DIR" ] || [ ! -f "$AUTHORIZED_KEYS_FILE" ]; then
    echo "ERROR: Failed to setup SSH access files for $USERNAME."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi

# --- Grant Sudo Privileges ---
SUDOERS_FILE="$SUDOERS_DIR/99-ryze-${USERNAME}"
mkdir -p "$SUDOERS_DIR"
echo "$USERNAME ALL=(ALL:ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
if [ $? -ne 0 ] || [ ! -f "$SUDOERS_FILE" ]; then
    echo "ERROR: Failed to create or set permissions for sudoers file $SUDOERS_FILE."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi

# --- Record user for monitoring (using flock for safety) ---
mkdir -p "$STATE_FILE_DIR"
chmod 0700 "$STATE_FILE_DIR"

(
    flock -x 200
    CREATION_TIME=$(date +%s)
    echo "$USERNAME:pending_login:$CREATION_TIME:0:0" >> "$STATE_FILE"
) 200>"$LOCK_FILE"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to update the state file for monitoring. User $USERNAME might not be auto-deleted."
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
    ADMIN_USER="${SUDO_USER:-$(whoami)}"
    DISCORD_BOT_NAME="Ryzehosting Support Bot" # Ensure this is defined as a simple string
    DISCORD_AVATAR_URL="https://i.imgur.com/G6k9Y94.png" # Example, replace if needed
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

    echo "--- DEBUG: Raw JSON_PAYLOAD before processing ---" >&2
    echo "$JSON_PAYLOAD" >&2
    echo "--- END DEBUG RAW JSON ---" >&2

    curl_args=(-s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -X POST)

    if command -v jq &> /dev/null; then
        PROCESSED_JSON_FOR_DISCORD=$(echo "$JSON_PAYLOAD" | jq -c .)
        echo "--- DEBUG: JSON processed by jq for Discord ---" >&2
        echo "$PROCESSED_JSON_FOR_DISCORD" >&2
        echo "--- END DEBUG JQ JSON ---" >&2
        RESPONSE_CODE=$(curl "${curl_args[@]}" -d "$PROCESSED_JSON_FOR_DISCORD" "$DISCORD_WEBHOOK_URL")
    else
        echo "--- DEBUG: Fallback JSON processing (no jq) ---" >&2
        COMPACT_JSON_PAYLOAD=$(echo "$JSON_PAYLOAD" | tr -d '\n' | sed 's/  //g') # Basic compaction
        echo "$COMPACT_JSON_PAYLOAD" >&2
        echo "--- END DEBUG FALLBACK JSON ---" >&2
        RESPONSE_CODE=$(curl "${curl_args[@]}" -d "$COMPACT_JSON_PAYLOAD" "$DISCORD_WEBHOOK_URL")
    fi

    if [ "$RESPONSE_CODE" -ge 200 ] && [ "$RESPONSE_CODE" -lt 300 ]; then
        echo "Notification successfully sent to Discord (HTTP Status: $RESPONSE_CODE)."
    else
        echo "WARNING: Failed to send notification to Discord. HTTP Status: $RESPONSE_CODE"
    fi
else
    echo "Skipping Discord notification as no valid webhook URL was provided."
fi

trap - EXIT # Clear the trap if we successfully exit, so temp dir is not removed if we wanted to inspect it
# Actually, the trap 'rm -rf "$KEY_TEMP_DIR"' EXIT should remain to always clean up.
# If you need to inspect, you'd comment out the trap temporarily.

exit 0
