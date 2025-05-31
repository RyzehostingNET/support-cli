# Ryzehosting Support CLI Tool (Cron-Based Monitoring)

This tool provides a command-line interface (`support`) for Ryzehosting customers to quickly create a temporary, privileged user account for Ryzehosting support agents. The account is authenticated using SSH keys and is automatically monitored and deleted by a background cron job after logout or timeout.

**WARNING: This tool creates a temporary user with full root privileges (`sudo NOPASSWD:ALL`). Use with caution and only when requested by a trusted Ryzehosting support agent.**

## Features

*   Simple command: `sudo support`
*   **Prompts for a one-time Discord Webhook URL** each time for notifications.
*   Generates a unique, temporary username.
*   Creates an SSH key pair for authentication; no password is set for the user.
*   Installs the public SSH key for the temporary user.
*   Displays the private SSH key on the admin's console for secure transfer to the support agent.
*   Grants full sudo access to the temporary user without a password.
*   Sends a notification (username, IP, hostname, access method) to the provided Discord webhook (if any). **The private key is NOT sent to Discord.**
*   **A cron job runs every minute to monitor the temporary user.**
*   **The cron job automatically deletes the user account and its sudo privileges:**
    *   Shortly after the user logs out.
    *   If the user never logs in within a defined timeout (default: 1 hour).
    *   If the user's session exceeds a maximum duration (default: 8 hours).

## Prerequisites

*   A Linux server (Debian, Ubuntu, CentOS/RHEL derivatives supported).
*   Root or `sudo` access to run the installer and the `support` command.
*   The server must have `curl` and `flock` (from `util-linux` package) installed (the installer will attempt to install them).
*   `jq` is recommended for robust Discord JSON (installer will attempt to install it).

## Installation

To install or update the tool, run the following command as root or with `sudo` on a fresh server:

```bash
sudo bash <(curl -sSL https://raw.githubusercontent.com/RyzehostingNET/support-cli/main/install.sh)
