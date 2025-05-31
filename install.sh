#!/bin/bash

# Installer for Ryzehosting Support Tool (Cron-Based Monitoring)

# --- GitHub Raw URL Base ---
GITHUB_RAW_BASE_URL="https://raw.githubusercontent.com/RyzehostingNET/support-cli/main"

# --- Configuration (Paths) ---
SUPPORT_SCRIPT_DEST="/usr/local/bin/support"
MONITOR_SCRIPT_DEST="/usr/local/sbin/ryze-support-monitor.sh"
STATE_FILE_DIR="/var/lib/ryze-support-tool"
CRON_FILE_NAME="ryze-support-monitor"
CRON_FILE_DEST="/etc/cron.d/$CRON_FILE_NAME"

# --- Script Execution Guard ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

echo "Ryzehosting Support Tool Installer (Cron-Based)"
echo "----------------------------------------------"

# --- OS Detection & Package Manager ---
OS_ID=""
PKG_MANAGER_CMD=""
UPDATE_CMD=""
INSTALL_CMD_PREFIX="" # For apt-get, yum, dnf

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
fi

case "$OS_ID" in
    ubuntu|debian)
        PKG_MANAGER_CMD="apt-get"
        UPDATE_CMD="apt-get update -qq"
        INSTALL_CMD_PREFIX="apt-get install -y -qq"
        ;;
    centos|rhel|fedora|almalinux|rocky)
        if command -v dnf >/dev/null 2>&1; then
            PKG_MANAGER_CMD="dnf"
            UPDATE_CMD=":" # dnf usually doesn't require explicit separate update
            INSTALL_CMD_PREFIX="dnf install -y -q"
        elif command -v yum >/dev/null 2>&1; then
            PKG_MANAGER_CMD="yum"
            UPDATE_CMD=":"
            INSTALL_CMD_PREFIX="yum install -y -q"
        else
            echo "ERROR: Neither dnf nor yum found. Cannot manage packages."
            exit 1
        fi
        ;;
    *)
        echo "ERROR: Unsupported OS: $OS_ID. Cannot automatically install dependencies."
        read -p "Continue installation without automatic dependency management? (y/N): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 1
        PKG_MANAGER_CMD="manual" # Will skip installs
        ;;
esac

# --- Dependency Installation Function ---
install_if_missing() {
    local cmd_to_check="$1"
    local package_name="$2"
    local human_name="${3:-$package_name}"

    if command -v "$cmd_to_check" >/dev/null 2>&1; then
        echo "$human_name (command: $cmd_to_check) is already installed."
        return 0
    fi

    if [ "$PKG_MANAGER_CMD" == "manual" ]; then
        echo "WARNING: Cannot automatically install $human_name. Please ensure it is installed."
        return 1 # Indicate potential issue
    fi

    echo "$human_name not found. Attempting to install $package_name..."
    # Run update_cmd only if it's not a no-op (i.e., for apt-get first time)
    if [ "$UPDATE_CMD" != ":" ]; then
        echo "Updating package lists ($PKG_MANAGER_CMD update)..."
        $UPDATE_CMD || { echo "ERROR: Failed to update package lists."; exit 1; }
        UPDATE_CMD=":" # Ensure update runs only once
    fi

    if $INSTALL_CMD_PREFIX "$package_name"; then
        echo "$package_name installed successfully."
        return 0
    else
        echo "ERROR: Failed to install $package_name. Please install it manually and re-run."
        exit 1
    fi
}

# --- Check & Install Dependencies ---
echo "Checking and installing dependencies..."
install_if_missing "curl" "curl" "cURL" # Used by support.sh to send to Discord
install_if_missing "flock" "util-linux" "flock (from util-linux)" # For script locking
# jq is optional in support.sh, but good to have for robust Discord JSON
install_if_missing "jq" "jq" "jq (JSON processor)"
echo "Dependencies met or installation attempted."

# --- Create State Directory ---
echo "Creating state directory $STATE_FILE_DIR..."
mkdir -p "$STATE_FILE_DIR"
chmod 0700 "$STATE_FILE_DIR" # Accessible only by root
# The lock file and state file will be created by the scripts when first needed.
echo "State directory created."

# --- Fetch and Install Scripts ---
echo "Fetching and installing scripts..."
# support.sh
echo "Downloading main support script to $SUPPORT_SCRIPT_DEST..."
if curl -sSL "${GITHUB_RAW_BASE_URL}/support.sh" -o "$SUPPORT_SCRIPT_DEST"; then
    chmod +x "$SUPPORT_SCRIPT_DEST"
    echo "Main support script installed."
else
    echo "ERROR: Failed to download main support script from GitHub."
    exit 1
fi

# ryze-support-monitor.sh
echo "Downloading monitor script to $MONITOR_SCRIPT_DEST..."
if curl -sSL "${GITHUB_RAW_BASE_URL}/ryze-support-monitor.sh" -o "$MONITOR_SCRIPT_DEST"; then
    chmod +x "$MONITOR_SCRIPT_DEST"
    echo "Monitor script installed."
else
    echo "ERROR: Failed to download monitor script from GitHub."
    rm -f "$SUPPORT_SCRIPT_DEST" # Clean up if main script was downloaded
    exit 1
fi

# --- Setup Cron Job ---
echo "Setting up cron job for the monitor script..."
CRON_JOB_CONTENT="SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Ryzehosting Support User Monitor - runs every minute
*/1 * * * * root $MONITOR_SCRIPT_DEST >> /var/log/ryze-support-monitor-cron.log 2>&1
"
# Piping to tee as root to write the file
echo "$CRON_JOB_CONTENT" | sudo tee "$CRON_FILE_DEST" > /dev/null
if [ $? -eq 0 ]; then
    chmod 0644 "$CRON_FILE_DEST" # Standard cron file permissions
    echo "Cron job created at $CRON_FILE_DEST."
    echo "The monitor will start running within the next minute."
else
    echo "ERROR: Failed to create cron job file $CRON_FILE_DEST."
    echo "Please create it manually with the following content:"
    echo "---------------------------------------------------"
    echo "$CRON_JOB_CONTENT"
    echo "---------------------------------------------------"
    # Clean up downloaded scripts if cron setup fails, as tool won't be fully functional
    rm -f "$SUPPORT_SCRIPT_DEST" "$MONITOR_SCRIPT_DEST"
    exit 1
fi

# --- Final Instructions ---
echo ""
echo "Installation Complete!"
echo "------------------------"
echo "The Ryzehosting Support Tool (Cron-Based) is now installed."
echo "The main command is 'sudo support'."
echo "Temporary users will be monitored and cleaned up by a cron job running every minute."
echo "Logs for the monitor script: /var/log/ryze-support-monitor.log"
echo "Logs for the cron job itself: /var/log/ryze-support-monitor-cron.log"
echo ""
echo "To uninstall, run the uninstall.sh script from GitHub:"
echo "  sudo bash <(curl -sSL ${GITHUB_RAW_BASE_URL}/uninstall.sh)"
exit 0
