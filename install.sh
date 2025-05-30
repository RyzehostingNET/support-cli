#!/bin/bash

# Installer for Ryzehosting Support Tool
# Assumes DISCORD_WEBHOOK_URL is pre-configured by Ryzehosting provisioning
# Attempts to automatically install dependencies and fetches other scripts from GitHub.

# --- Constants for GitHub paths ---
GITHUB_RAW_BASE_URL="https://raw.githubusercontent.com/RyzehostingNET/support-cli/main"
SUPPORT_SCRIPT_GH_PATH="support.sh"
CLEANUP_SCRIPT_GH_PATH="ryze-support-cleanup.sh"

# --- Script Execution Guard ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

echo "Ryzehosting Support Tool Installer"
echo "----------------------------------"

# --- Configuration (Paths) ---
CONFIG_DIR="/etc/ryze-support-tool"
CONFIG_FILE="$CONFIG_DIR/config"
SUPPORT_SCRIPT_DEST="/usr/local/bin/support"
CLEANUP_SCRIPT_DEST="/usr/local/sbin/ryze-support-cleanup.sh"
PAM_SSHD_CONF="/etc/pam.d/sshd" # Or common-session for wider coverage
PAM_LINE_ADVANCED="session    optional    pam_script.so    script=$CLEANUP_SCRIPT_DEST"

# --- OS Detection & Package Manager ---
OS_ID=""
PKG_MANAGER=""
UPDATE_CMD=""
INSTALL_CMD=""
LDCONFIG_CMD="ldconfig" # Default ldconfig command

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
fi

case "$OS_ID" in
    ubuntu|debian)
        PKG_MANAGER="apt-get"
        UPDATE_CMD="apt-get update -qq"
        INSTALL_CMD="apt-get install -y -qq"
        PAM_SCRIPT_PKG="libpam-script"
        ;;
    centos|rhel|fedora|almalinux|rocky)
        if command -v dnf >/dev/null 2>&1; then
            PKG_MANAGER="dnf"
            UPDATE_CMD=":"
            INSTALL_CMD="dnf install -y -q"
        elif command -v yum >/dev/null 2>&1; then
            PKG_MANAGER="yum"
            UPDATE_CMD=":"
            INSTALL_CMD="yum install -y -q"
        else
            echo "ERROR: Neither dnf nor yum found on this $OS_ID system. Cannot manage packages."
            exit 1
        fi
        PAM_SCRIPT_PKG="pam_script"
        ;;
    *)
        echo "ERROR: Unsupported OS: $OS_ID. Cannot automatically install dependencies."
        echo "Please ensure curl, jq (optional), and pam_script.so are installed manually."
        read -p "Continue installation without automatic dependency management? (y/N): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 1
        PKG_MANAGER="manual"
        UPDATE_CMD=":"
        INSTALL_CMD=":"
        PAM_SCRIPT_PKG="manual"
        ;;
esac

# --- Dependency Installation Function ---
install_if_missing() {
    local cmd_to_check="$1"
    local package_name="$2"
    local human_name="${3:-$package_name}"
    local is_file_check="${4:-false}" # New parameter to indicate if checking for a file

    if [ "$is_file_check" = "true" ]; then
        if [ -f "$cmd_to_check" ]; then # cmd_to_check is actually a file path here
            echo "$human_name (file: $cmd_to_check) found."
            return 0
        fi
    elif command -v "$cmd_to_check" >/dev/null 2>&1; then
        echo "$human_name (command: $cmd_to_check) is already installed."
        return 0
    fi

    if [ "$PKG_MANAGER" == "manual" ]; then
        echo "WARNING: Cannot automatically install $human_name. Please ensure it is installed/present."
        return 1
    fi

    echo "$human_name not found. Attempting to install $package_name..."
    # Run update once logic moved before the first actual install attempt in the main flow
    if $INSTALL_CMD "$package_name"; then
        echo "$package_name installed successfully."
        # If it's a library, try running ldconfig
        if [[ "$package_name" == "$PAM_SCRIPT_PKG" ]] && command -v $LDCONFIG_CMD >/dev/null 2>&1; then
            echo "Running $LDCONFIG_CMD to update library cache..."
            $LDCONFIG_CMD
        fi
        return 0
    else
        echo "ERROR: Failed to install $package_name. Please install it manually and re-run the installer."
        exit 1
    fi
}

# --- Check & Install Dependencies ---
echo "Checking and installing dependencies..."

# Run update command once before any installations if applicable
if [[ "$PKG_MANAGER" == "apt-get" ]]; then
    echo "Updating package lists ($PKG_MANAGER update)..."
    $UPDATE_CMD || { echo "ERROR: Failed to update package lists. Please check your network and repository configuration."; exit 1; }
fi

install_if_missing "curl" "curl" "cURL"
install_if_missing "jq" "jq" "jq (JSON processor)"

# Check for pam_script.so
# Standard paths for pam_script.so, can be expanded
PAM_SCRIPT_SO_PATHS=(
    "/lib/x86_64-linux-gnu/security/pam_script.so"
    "/usr/lib/x86_64-linux-gnu/security/pam_script.so"
    "/lib64/security/pam_script.so"
    "/usr/lib64/security/pam_script.so"
    "/lib/security/pam_script.so" # Generic fallback
    "/usr/lib/security/pam_script.so" # Generic fallback
)
PAM_SCRIPT_SO_FOUND_PATH=""

check_pam_script_so() {
    for p_path in "${PAM_SCRIPT_SO_PATHS[@]}"; do
        if [ -f "$p_path" ]; then
            PAM_SCRIPT_SO_FOUND_PATH="$p_path"
            echo "pam_script.so found at $PAM_SCRIPT_SO_FOUND_PATH."
            return 0
        fi
    done
    # Fallback to find, though it might be slow or not work immediately
    local find_path
    find_path=$(find /lib* /usr/lib* -name 'pam_script.so' -print -quit 2>/dev/null)
    if [ -n "$find_path" ] && [ -f "$find_path" ]; then
        PAM_SCRIPT_SO_FOUND_PATH="$find_path"
        echo "pam_script.so found via find at $PAM_SCRIPT_SO_FOUND_PATH."
        return 0
    fi
    return 1
}

if check_pam_script_so; then
    : # Already found
else
    echo "pam_script.so module not found initially."
    if [ "$PKG_MANAGER" != "manual" ] && [ -n "$PAM_SCRIPT_PKG" ]; then
        echo "Attempting to install $PAM_SCRIPT_PKG package..."
        # install_if_missing will handle the actual install command
        install_if_missing "pam_script.so" "$PAM_SCRIPT_PKG" "PAM Script Module ($PAM_SCRIPT_PKG)" true # true indicates file check
        # Re-check after install attempt
        sleep 1 # Give a moment for filesystem changes
        if command -v $LDCONFIG_CMD >/dev/null 2>&1; then $LDCONFIG_CMD; fi # Run ldconfig again
        
        if check_pam_script_so; then
            echo "pam_script.so successfully located after installation of $PAM_SCRIPT_PKG."
        else
            echo "ERROR: Installed $PAM_SCRIPT_PKG but pam_script.so still not found in common locations."
            echo "Checked paths: ${PAM_SCRIPT_SO_PATHS[*]}"
            echo "Please verify the installation of $PAM_SCRIPT_PKG and the location of pam_script.so."
            exit 1
        fi
    else
        echo "ERROR: Cannot automatically install package for pam_script.so. Please install it manually."
        exit 1
    fi
fi
echo "All required dependencies seem to be met."


# --- Verify Ryzehosting Pre-configuration ---
echo "Verifying Ryzehosting pre-configuration..."
if [ ! -d "$CONFIG_DIR" ]; then
    echo "ERROR: Configuration directory $CONFIG_DIR not found."
    echo "This tool expects Ryzehosting to pre-configure it during server provisioning."
    echo "Please contact Ryzehosting support regarding this issue."
    exit 1
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file $CONFIG_FILE not found."
    echo "This tool expects Ryzehosting to pre-configure it with the Discord webhook URL."
    echo "Please contact Ryzehosting support regarding this issue."
    exit 1
fi
DISCORD_WEBHOOK_URL=""
source "$CONFIG_FILE"
if [ -z "$DISCORD_WEBHOOK_URL" ] || [[ ! "$DISCORD_WEBHOOK_URL" == https://discord.com/api/webhooks/* ]]; then
    echo "ERROR: DISCORD_WEBHOOK_URL is not correctly set or is missing in $CONFIG_FILE."
    echo "Please contact Ryzehosting support."
    exit 1
fi
echo "Discord Webhook URL found and seems valid in pre-configuration."
chmod 0700 "$CONFIG_DIR" &>/dev/null
chmod 0600 "$CONFIG_FILE" &>/dev/null
echo "Ensured $CONFIG_FILE permissions are secure."

# --- Fetch and Install Scripts ---
echo "Fetching support scripts from GitHub..."

# Fetch support.sh
echo "Downloading main support script to $SUPPORT_SCRIPT_DEST..."
if curl -sSL "${GITHUB_RAW_BASE_URL}/${SUPPORT_SCRIPT_GH_PATH}" -o "$SUPPORT_SCRIPT_DEST"; then
    chmod +x "$SUPPORT_SCRIPT_DEST"
    echo "Main support script downloaded and made executable."
else
    echo "ERROR: Failed to download ${GITHUB_RAW_BASE_URL}/${SUPPORT_SCRIPT_GH_PATH}"
    exit 1
fi

# Fetch ryze-support-cleanup.sh
echo "Downloading cleanup script to $CLEANUP_SCRIPT_DEST..."
if curl -sSL "${GITHUB_RAW_BASE_URL}/${CLEANUP_SCRIPT_GH_PATH}" -o "$CLEANUP_SCRIPT_DEST"; then
    chmod +x "$CLEANUP_SCRIPT_DEST"
    echo "Cleanup script downloaded and made executable."
else
    echo "ERROR: Failed to download ${GITHUB_RAW_BASE_URL}/${CLEANUP_SCRIPT_GH_PATH}"
    # Attempt to clean up the main support script if its download was successful but cleanup failed
    rm -f "$SUPPORT_SCRIPT_DEST"
    exit 1
fi

# --- Configure PAM ---
echo "Configuring PAM for automatic cleanup..."
if [ ! -f "$PAM_SSHD_CONF" ]; then
    echo "WARNING: $PAM_SSHD_CONF not found. Cannot configure PAM automatically."
    echo "You may need to manually add the following line to your SSHD PAM configuration:"
    echo "$PAM_LINE_ADVANCED"
else
    if grep -qE "pam_script\.so.*script=$CLEANUP_SCRIPT_DEST" "$PAM_SSHD_CONF"; then
        echo "PAM already configured for $CLEANUP_SCRIPT_DEST."
    else
        if [ -n "$(tail -c1 "$PAM_SSHD_CONF")" ]; then echo >> "$PAM_SSHD_CONF"; fi
        echo "$PAM_LINE_ADVANCED" >> "$PAM_SSHD_CONF"
        echo "Added pam_script configuration to $PAM_SSHD_CONF."
        echo "IMPORTANT: Review $PAM_SSHD_CONF to ensure the line is correctly placed if issues arise."
    fi
fi

# --- Final Instructions ---
echo ""
echo "Installation Complete!"
echo "------------------------"
echo "The Ryzehosting Support Tool is now installed."
echo "To create a temporary support account, run as root/sudo:"
echo "  sudo support"
echo ""
echo "The temporary account will be automatically deleted upon logout by the support user."
echo "Review the cleanup script log at /var/log/ryze-support-cleanup.log periodically for audit."
echo ""
echo "To uninstall, run the ./uninstall.sh script (also available from ${GITHUB_RAW_BASE_URL}/uninstall.sh):"
echo "  bash <(curl -sSL ${GITHUB_RAW_BASE_URL}/uninstall.sh)"

exit 0
