#!/bin/bash

# Installer for Ryzehosting Support Tool
# Assumes DISCORD_WEBHOOK_URL is pre-configured by Ryzehosting provisioning
# Attempts to automatically install dependencies.

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
            # dnf usually doesn't require an explicit update command before install for single packages
            UPDATE_CMD=":" # No-op
            INSTALL_CMD="dnf install -y -q"
        elif command -v yum >/dev/null 2>&1; then
            PKG_MANAGER="yum"
            UPDATE_CMD=":" # No-op, yum check-update can be slow
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
        # Allow proceeding if user wants to try, but dependencies might fail later
        read -p "Continue installation without automatic dependency management? (y/N): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 1
        # Set dummy commands if proceeding
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

    if command -v "$cmd_to_check" >/dev/null 2>&1; then
        echo "$human_name (command: $cmd_to_check) is already installed."
        return 0
    fi

    if [ "$PKG_MANAGER" == "manual" ]; then
        echo "WARNING: Cannot automatically install $human_name. Please ensure it is installed."
        return 1 # Indicate potential issue
    fi

    echo "$human_name (command: $cmd_to_check) not found. Attempting to install $package_name..."
    $UPDATE_CMD # Run update once, typically before the first install
    if $INSTALL_CMD "$package_name"; then
        echo "$human_name ($package_name) installed successfully."
        # Re-run update_cmd only once logic
        UPDATE_CMD=":" # Set to no-op after first successful use
        return 0
    else
        echo "ERROR: Failed to install $human_name ($package_name). Please install it manually and re-run the installer."
        exit 1
    fi
}

# --- Check & Install Dependencies ---
echo "Checking and installing dependencies..."
install_if_missing "curl" "curl" "cURL"
install_if_missing "jq" "jq" "jq (JSON processor)" # jq is used for robust JSON, script has fallback

# Check for pam_script.so (this is a file, not a command)
PAM_SCRIPT_SO_PATH=$(find /lib*/security/ -name 'pam_script.so' -print -quit 2>/dev/null)
if [ -n "$PAM_SCRIPT_SO_PATH" ]; then
    echo "pam_script.so found at $PAM_SCRIPT_SO_PATH."
else
    echo "pam_script.so module not found."
    if [ "$PKG_MANAGER" != "manual" ] && [ -n "$PAM_SCRIPT_PKG" ]; then
        echo "Attempting to install $PAM_SCRIPT_PKG package..."
        $UPDATE_CMD
        if $INSTALL_CMD "$PAM_SCRIPT_PKG"; then
            echo "$PAM_SCRIPT_PKG installed successfully."
            PAM_SCRIPT_SO_PATH=$(find /lib*/security/ -name 'pam_script.so' -print -quit 2>/dev/null)
            if [ -z "$PAM_SCRIPT_SO_PATH" ]; then
                 echo "ERROR: Installed $PAM_SCRIPT_PKG but pam_script.so still not found. Please check installation."
                 exit 1
            fi
            UPDATE_CMD=":"
        else
            echo "ERROR: Failed to install $PAM_SCRIPT_PKG. Please install it manually and re-run installer."
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

# Source the config to check for the variable
DISCORD_WEBHOOK_URL="" # Clear it before sourcing
source "$CONFIG_FILE"

if [ -z "$DISCORD_WEBHOOK_URL" ] || [[ ! "$DISCORD_WEBHOOK_URL" == https://discord.com/api/webhooks/* ]]; then
    echo "ERROR: DISCORD_WEBHOOK_URL is not correctly set or is missing in $CONFIG_FILE."
    echo "The file should be pre-configured by Ryzehosting."
    echo "Please contact Ryzehosting support."
    exit 1
fi
echo "Discord Webhook URL found and seems valid in pre-configuration."
# DO NOT echo the $DISCORD_WEBHOOK_URL here for security.

# --- Ensure config file has strict permissions (Provisioning should do this, but we can enforce)
chmod 0700 "$CONFIG_DIR" &>/dev/null
chmod 0600 "$CONFIG_FILE" &>/dev/null
echo "Ensured $CONFIG_FILE permissions are secure."


# --- Copy Scripts ---
echo "Copying scripts..."
# Assuming the scripts are in the same directory as install.sh
# For GitHub, user would clone repo and run ./install.sh from repo root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Adjust these names if your files in the repo are named support.sh and ryze-support-cleanup.sh
SUPPORT_SCRIPT_SOURCE="${SCRIPT_DIR}/support.sh" # Name it support.sh in your repo
CLEANUP_SCRIPT_SOURCE="${SCRIPT_DIR}/ryze-support-cleanup.sh" # Name it ryze-support-cleanup.sh in repo

if [ ! -f "$SUPPORT_SCRIPT_SOURCE" ]; then
    echo "ERROR: Main support script (expected: ${SUPPORT_SCRIPT_SOURCE}) not found."
    echo "Make sure it's in the same directory as install.sh and named correctly."
    exit 1
fi
if [ ! -f "$CLEANUP_SCRIPT_SOURCE" ]; then
    echo "ERROR: Cleanup script (expected: ${CLEANUP_SCRIPT_SOURCE}) not found."
    echo "Make sure it's in the same directory as install.sh and named correctly."
    exit 1
fi

cp "$SUPPORT_SCRIPT_SOURCE" "$SUPPORT_SCRIPT_DEST"
cp "$CLEANUP_SCRIPT_SOURCE" "$CLEANUP_SCRIPT_DEST"

chmod +x "$SUPPORT_SCRIPT_DEST"
chmod +x "$CLEANUP_SCRIPT_DEST"
echo "Scripts copied and made executable."

# --- Configure PAM ---
echo "Configuring PAM for automatic cleanup..."
if [ ! -f "$PAM_SSHD_CONF" ]; then
    echo "WARNING: $PAM_SSHD_CONF not found. Cannot configure PAM automatically."
    echo "You may need to manually add the following line to your SSHD PAM configuration:"
    echo "$PAM_LINE_ADVANCED"
else
    # Check if pam_script is already configured for our script
    # Using a more specific grep to avoid false positives if user has other pam_script.so lines
    if grep -qE "pam_script\.so.*script=$CLEANUP_SCRIPT_DEST" "$PAM_SSHD_CONF"; then
        echo "PAM already configured for $CLEANUP_SCRIPT_DEST."
    else
        # Add the line.
        # A safer way is to find the last 'session' line and add after it, or use a tool like augtool.
        # For simplicity, appending. REVIEW THIS FOR PRODUCTION ROBUSTNESS.
        # Ensure there's a newline before adding, in case the file doesn't end with one
        if [ -n "$(tail -c1 "$PAM_SSHD_CONF")" ]; then echo >> "$PAM_SSHD_CONF"; fi # Add newline if not present
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
echo "The Discord webhook URL is pre-configured by Ryzehosting and stored securely."
echo ""
echo "To create a temporary support account, run as root/sudo:"
echo "  sudo support"
echo ""
echo "The temporary account will be automatically deleted upon logout by the support user."
echo "Review the cleanup script log at /var/log/ryze-support-cleanup.log periodically for audit."
echo ""
echo "To uninstall, run the ./uninstall.sh script (as root/sudo) from the same directory where you ran install.sh."

exit 0
