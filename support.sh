#!/bin/bash

# Script to create a temporary support user with SSH key-based access
# This script is intended to be placed at /usr/local/bin/support
# Must be run as root or with sudo

CONFIG_FILE="/etc/ryze-support-tool/config"
SUDOERS_DIR="/etc/sudoers.d"
SUPPORT_USER_PREFIX="support"

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
DISCORD_WEBHOOK_URL=""
source "$CONFIG_FILE"

if [ -z "$DISCORD_WEBHOOK_URL" ] || [[ ! "$DISCORD_WEBHOOK_URL" == https://discord.com/api/webhooks/* ]]; then
    echo "ERROR: DISCORD_WEBHOOK_URL is not correctly set or is missing in $CONFIG_FILE."
    echo "Please contact Ryzehosting support."
    exit 1
fi

# --- Generate User Details ---
RAND_SUFFIX=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)
USERNAME="${SUPPORT_USER_PREFIX}_$(date +%s)_${RAND_SUFFIX}"
VM_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
SERVER_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null)
fi
[ -z "$SERVER_IP" ] && SERVER_IP="N/A"

echo "Creating temporary support user: $USERNAME (SSH Key-Based Access)"

# --- Create User ---
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists. This should not happen. Aborting."
    exit 1
fi

# Create user with a home directory and bash shell
# -m creates home dir, -s sets shell
# We will also create .ssh directory and authorized_keys with correct permissions
useradd -m -s /bin/bash "$USERNAME"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create user $USERNAME."
    exit 1
fi

USER_HOME_DIR=$(eval echo "~$USERNAME") # Get home directory path

# --- Generate SSH Key Pair ---
# Create a temporary directory for ssh-keygen to avoid polluting current dir
KEY_TEMP_DIR=$(mktemp -d)
if [ -z "$KEY_TEMP_DIR" ] || [ ! -d "$KEY_TEMP_DIR" ]; then
    echo "ERROR: Failed to create temporary directory for SSH keys."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi
trap 'rm -rf "$KEY_TEMP_DIR"' EXIT # Ensure temp dir is cleaned up

SSH_KEY_PATH="$KEY_TEMP_DIR/support_key_for_${USERNAME}"
echo "Generating SSH key pair..."
# Generate ed25519 key, no passphrase, quiet
ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q
if [ $? -ne 0 ] || [ ! -f "${SSH_KEY_PATH}" ] || [ ! -f "${SSH_KEY_PATH}.pub" ]; then
    echo "ERROR: Failed to generate SSH key pair."
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi

PRIVATE_KEY_CONTENT=$(cat "${SSH_KEY_PATH}")
PUBLIC_KEY_CONTENT=$(cat "${SSH_KEY_PATH}.pub")

# Save private key to a known location for SCP
SAVED_PRIVATE_KEY_ON_SERVER="/tmp/temp_support_key_for_${USERNAME}.pem"
cp "${SSH_KEY_PATH}" "$SAVED_PRIVATE_KEY_ON_SERVER"
chmod 600 "$SAVED_PRIVATE_KEY_ON_SERVER" # Should already be from ssh-keygen but ensure
echo ""
echo "For easier transfer, the private key has also been saved on the server at:"
echo "  $SAVED_PRIVATE_KEY_ON_SERVER"
echo "You can SCP it to your local machine. It will be deleted when this script exits if not moved."
echo ""

# --- Setup SSH Access for the User ---
echo "Setting up SSH access for $USERNAME..."
USER_SSH_DIR="$USER_HOME_DIR/.ssh"
AUTHORIZED_KEYS_FILE="$USER_SSH_DIR/authorized_keys"

sudo -u "$USERNAME" mkdir -p "$USER_SSH_DIR"
if [ $? -ne 0 ]; then echo "Failed to mkdir $USER_SSH_DIR"; sudo userdel -r "$USERNAME" &>/dev/null; exit 1; fi
sudo -u "$USERNAME" chmod 700 "$USER_SSH_DIR"
if [ $? -ne 0 ]; then echo "Failed to chmod $USER_SSH_DIR"; sudo userdel -r "$USERNAME" &>/dev/null; exit 1; fi

echo "$PUBLIC_KEY_CONTENT" | sudo -u "$USERNAME" tee "$AUTHORIZED_KEYS_FILE" > /dev/null
if [ $? -ne 0 ]; then echo "Failed to write to $AUTHORIZED_KEYS_FILE"; sudo userdel -r "$USERNAME" &>/dev/null; exit 1; fi
sudo -u "$USERNAME" chmod 600 "$AUTHORIZED_KEYS_FILE"
if [ $? -ne 0 ]; then echo "Failed to chmod $AUTHORIZED_KEYS_FILE"; sudo userdel -r "$USERNAME" &>/dev/null; exit 1; fi

# Ensure ownership is correct (useradd -m should handle home dir, but .ssh dir might be created as root initially)
sudo chown -R "${USERNAME}:${USERNAME}" "$USER_HOME_DIR"

# --- Grant Sudo Privileges ---
SUDOERS_FILE="$SUDOERS_DIR/99-ryze-${USERNAME}"
mkdir -p "$SUDOERS_DIR"
echo "$USERNAME ALL=(ALL:ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
if [ $? -ne 0 ] || [ ! -f "$SUDOERS_FILE" ]; then
    echo "ERROR: Failed to create or set permissions for sudoers file $SUDOERS_FILE."
    rm -f "$AUTHORIZED_KEYS_FILE" "$USER_SSH_DIR" # Attempt to clean up SSH keys setup
    sudo userdel -r "$USERNAME" &>/dev/null
    exit 1
fi

echo "User $USERNAME created successfully with SSH key access."

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
echo "This account will be automatically deleted after the support user logs out."
echo "IMPORTANT: The private key above grants access. Handle it securely."

# --- Send to Discord (NO PRIVATE KEY) ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
ADMIN_USER="${SUDO_USER:-$(whoami)}"
DISCORD_BOT_NAME="Ryzehosting Support Bot"
DISCORD_AVATAR_URL="https://i.imgur.com/G6k9Y94.png" # Replace with your Ryzehosting logo

JSON_PAYLOAD=$(cat <<EOF
{
  "username": "$DISCORD_BOT_NAME",
  "avatar_url": "$DISCORD_AVATAR_URL",
  "embeds": [{
    "title": "New Temp Support Account Created (SSH Key Access)",
    "color": 16705372,
    "fields": [
      {"name": "Hostname (VM-ID)", "value": "$VM_HOSTNAME", "inline": true},
      {"name": "Server IP", "value": "$SERVER_IP", "inline": true},
      {"name": "Username", "value": "\`$USERNAME\`", "inline": false},
      {"name": "Access Method", "value": "SSH Key (Private key displayed to admin)", "inline": false},
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

if command -v jq &> /dev/null; then
    RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                         -H "Content-Type: application/json" \
                         -X POST -d "$(echo "$JSON_PAYLOAD" | jq -c .)" "$DISCORD_WEBHOOK_URL")
else
    COMPACT_JSON_PAYLOAD=$(echo "$JSON_PAYLOAD" | tr -d '\n' | sed 's/  //g')
    RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                         -H "Content-Type: application/json" \
                         -X POST -d "$COMPACT_JSON_PAYLOAD" "$DISCORD_WEBHOOK_URL")
fi

if [ "$RESPONSE_CODE" -ge 200 ] && [ "$RESPONSE_CODE" -lt 300 ]; then
    echo "Notification successfully sent to Discord (HTTP Status: $RESPONSE_CODE)."
else
    echo "WARNING: Failed to send notification to Discord. HTTP Status: $RESPONSE_CODE"
fi

# The private key was already displayed. Exit trap will clean $KEY_TEMP_DIR.
exit 0
