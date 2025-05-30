#!/bin/bash

# Script to create a temporary support user
# This script is intended to be placed at /usr/local/bin/support
# Must be run as root or with sudo

CONFIG_FILE="/etc/ryze-support-tool/config"
SUDOERS_DIR="/etc/sudoers.d"
SUPPORT_USER_PREFIX="support" # PAM cleanup script will look for this prefix

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file $CONFIG_FILE not found."
    echo "This tool may not have been installed correctly, or Ryzehosting pre-configuration is missing."
    echo "Please contact Ryzehosting support."
    exit 1
fi
# Source the config file to get DISCORD_WEBHOOK_URL
DISCORD_WEBHOOK_URL="" # Initialize to prevent environment leak if not set
source "$CONFIG_FILE"

if [ -z "$DISCORD_WEBHOOK_URL" ] || [[ ! "$DISCORD_WEBHOOK_URL" == https://discord.com/api/webhooks/* ]]; then
    echo "ERROR: DISCORD_WEBHOOK_URL is not correctly set or is missing in $CONFIG_FILE."
    echo "Please contact Ryzehosting support."
    exit 1
fi

# --- Generate User Details ---
# Generate a more unique username part to avoid collisions if script is run rapidly
RAND_SUFFIX=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)
USERNAME="${SUPPORT_USER_PREFIX}_$(date +%s)_${RAND_SUFFIX}"
PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=[]{}|;' | head -c 20) # Stronger password
VM_HOSTNAME=$(hostname -f 2>/dev/null || hostname) # Use FQDN if available
# Get primary IP address
SERVER_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null)
fi
[ -z "$SERVER_IP" ] && SERVER_IP="N/A"


echo "Creating temporary support user: $USERNAME..."

# --- Create User ---
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists. This should not happen. Aborting."
    exit 1
fi

# Create user with a home directory and bash shell
useradd -m -s /bin/bash "$USERNAME"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create user $USERNAME."
    exit 1
fi

# Set password
echo "$USERNAME:$PASSWORD" | sudo chpasswd
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to set password for $USERNAME."
    sudo userdel -r "$USERNAME" &>/dev/null # Attempt cleanup
    exit 1
fi

# --- Grant Sudo Privileges ---
SUDOERS_FILE="$SUDOERS_DIR/99-ryze-${USERNAME}"
# Ensure the directory exists, though it should on most systems
mkdir -p "$SUDOERS_DIR"
echo "$USERNAME ALL=(ALL:ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
if [ $? -ne 0 ] || [ ! -f "$SUDOERS_FILE" ]; then # Check if file was actually created
    echo "ERROR: Failed to create or set permissions for sudoers file $SUDOERS_FILE."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi

echo "User $USERNAME created successfully."

# --- Display Information ---
echo "--------------------------------------------------"
echo "Temporary Support Account Details:"
echo "Hostname (VM-ID): $VM_HOSTNAME"
echo "Server IP:        $SERVER_IP"
echo "Username:         $USERNAME"
echo "Password:         $PASSWORD"
echo "--------------------------------------------------"
echo "This account will be automatically deleted after the support user logs out."
echo "Please provide these details to the support agent."

# --- Send to Discord ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
ADMIN_USER="${SUDO_USER:-$(whoami)}" # User who ran the script
DISCORD_BOT_NAME="Support Account" # Customize if needed
DISCORD_AVATAR_URL="https://i.imgur.com/G6k9Y94.png" # Example Ryze logo, replace with your actual one

JSON_PAYLOAD=$(cat <<EOF
{
  "username": "$DISCORD_BOT_NAME",
  "avatar_url": "$DISCORD_AVATAR_URL",
  "embeds": [{
    "title": "New Temporary Support Account Created",
    "color": 3447003,
    "fields": [
      {"name": "Hostname (VM-ID)", "value": "$VM_HOSTNAME", "inline": true},
      {"name": "Server IP", "value": "$SERVER_IP", "inline": true},
      {"name": "Username", "value": "\`$USERNAME\`", "inline": false},
      {"name": "Password", "value": "|| \`$PASSWORD\` ||", "inline": false},
      {"name": "Requested By", "value": "\`$ADMIN_USER\`", "inline": true},
      {"name": "Status", "value": "Active - Awaiting logout for deletion", "inline": true}
    ],
    "footer": {
      "text": "Ryzehosting Support System - $(date)"
    },
    "timestamp": "$TIMESTAMP"
  }]
}
EOF
)

# Attempt to use jq if available for robust JSON, otherwise direct echo
if command -v jq &> /dev/null; then
    # Using process substitution for jq to handle multiline JSON correctly if it has issues with @-
    RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                         -H "Content-Type: application/json" \
                         -X POST -d "$(echo "$JSON_PAYLOAD" | jq -c .)" "$DISCORD_WEBHOOK_URL")
else
    # Fallback if jq is not installed - ensure JSON_PAYLOAD is perfectly formed and compact
    # This might require the JSON to be a single line or very carefully escaped.
    # For simplicity, we assume the heredoc above is well-formed.
    COMPACT_JSON_PAYLOAD=$(echo "$JSON_PAYLOAD" | tr -d '\n' | sed 's/  //g') # Basic compaction
    RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                         -H "Content-Type: application/json" \
                         -X POST -d "$COMPACT_JSON_PAYLOAD" "$DISCORD_WEBHOOK_URL")
fi


if [ "$RESPONSE_CODE" -ge 200 ] && [ "$RESPONSE_CODE" -lt 300 ]; then
    echo "Credentials successfully sent to Discord (HTTP Status: $RESPONSE_CODE)."
else
    echo "WARNING: Failed to send credentials to Discord. HTTP Status: $RESPONSE_CODE"
    echo "Please manually relay the credentials."
    # Optionally, log the failed payload for debugging, but be careful with credentials
    # echo "Failed payload: $JSON_PAYLOAD" >> /var/log/ryze-support-discord-error.log
fi

exit 0
