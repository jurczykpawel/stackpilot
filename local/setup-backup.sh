#!/bin/bash

# StackPilot - Backup Setup Wizard
# Configures cloud backup on the VPS using local Rclone for auth.
# Author: Paweł (Lazy Engineer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

_BKP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_BKP_DIR/../lib/i18n.sh"
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: $0 [ssh_alias]"
    echo ""
    echo "Configures automatic cloud backups (Google Drive, Dropbox, S3, etc.)."
    echo "Requires rclone installed locally."
    echo "Default SSH alias: vps"
    exit 0
fi

# Configuration
VPS_HOST="${1:-vps}" # First argument or default to 'vps'
SSH_ALIAS="$VPS_HOST"
REMOTE_NAME="backup_remote"
TEMP_CONF="/tmp/rclone_stackpilot_setup.conf"

# Get remote server info for confirmation
REMOTE_HOST=$(server_hostname)
REMOTE_USER=$(server_user)

echo ""
msg "$MSG_BKP_HEADER_TOP"
msg "$MSG_BKP_HEADER_TITLE"
msg "$MSG_BKP_HEADER_MID"
msg "$MSG_BKP_HEADER_SERVER" "$REMOTE_USER" "$REMOTE_HOST"
msg "$MSG_BKP_HEADER_BOT"
echo ""
msg "$MSG_BKP_INTRO"
read -p "$(msg_n "$MSG_BKP_CONFIRM")" -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[TtYy]$ ]]; then
    msg "$MSG_BKP_CANCELLED"
    exit 1
fi

# 1. Check Local Prerequisites
if ! command -v rclone &> /dev/null; then
    msg "$MSG_BKP_NO_RCLONE"
    echo ""
    msg "$MSG_BKP_NO_RCLONE_WHY"
    msg "$MSG_BKP_NO_RCLONE_WHY2"
    echo ""
    msg "$MSG_BKP_NO_RCLONE_INSTALL"
    msg "$MSG_BKP_NO_RCLONE_MAC"
    msg "$MSG_BKP_NO_RCLONE_LINUX"
    msg "$MSG_BKP_NO_RCLONE_WIN"
    echo ""
    msg "$MSG_BKP_NO_RCLONE_RETRY"
    exit 1
fi

# 2. Select Provider
echo ""
msg "$MSG_BKP_CHOOSE_PROVIDER"
msg "$MSG_BKP_PROVIDER_GDRIVE"
msg "$MSG_BKP_PROVIDER_DROPBOX"
msg "$MSG_BKP_PROVIDER_ONEDRIVE"
msg "$MSG_BKP_PROVIDER_MEGA"
msg "$MSG_BKP_PROVIDER_S3"
read -p "$(msg_n "$MSG_BKP_PROVIDER_PROMPT")" CHOICE

case $CHOICE in
    1) TYPE="drive"; CONF_ARGS="scope=drive.file" ;;
    2) TYPE="dropbox"; CONF_ARGS="" ;;
    3) TYPE="onedrive"; CONF_ARGS="" ;;
    4) TYPE="mega"; CONF_ARGS="" ;;
    5) TYPE="s3"; CONF_ARGS="provider=AWS env_auth=false" ;;
    *) msg "$MSG_BKP_INVALID_CHOICE"; exit 1 ;;
esac

echo ""
msg "$MSG_BKP_AUTH_HEADER" "$TYPE"
msg "$MSG_BKP_AUTH_GENERATE"
if [[ "$TYPE" == "mega" || "$TYPE" == "s3" ]]; then
    msg "$MSG_BKP_AUTH_CREDS"
else
    if is_on_server; then
        msg "$MSG_BKP_AUTH_BROWSER_WARN"
        msg "$MSG_BKP_AUTH_BROWSER_HINT"
        msg "$MSG_BKP_AUTH_BROWSER_ALT"
    fi
    msg "$MSG_BKP_AUTH_BROWSER"
fi
echo ""

# 3. Generate Config Locally
# We create a temporary config file just for this session
rm -f "$TEMP_CONF"
touch "$TEMP_CONF"

# Logic for Encryption abstraction
# If Encrypt = NO:  backup_remote -> Provider
# If Encrypt = YES: raw_cloud -> Provider, backup_remote (crypt) -> raw_cloud

echo ""
read -p "$(msg_n "$MSG_BKP_ENCRYPT_PROMPT")" ENCRYPT_CHOICE

if [[ "$ENCRYPT_CHOICE" =~ ^[Yy]$ ]]; then
    msg "$MSG_BKP_ENCRYPT_HEADER"
    msg "$MSG_BKP_ENCRYPT_INFO"
    read -s -p "$(msg_n "$MSG_BKP_ENCRYPT_PASS")" PASS1
    echo ""
    read -s -p "$(msg_n "$MSG_BKP_ENCRYPT_CONFIRM")" PASS2
    echo ""

    if [ "$PASS1" != "$PASS2" ]; then
        msg "$MSG_BKP_ENCRYPT_MISMATCH"
        exit 1
    fi

    # Create the raw backend first
    msg "$MSG_BKP_ENCRYPT_AUTH"
    rclone config create "raw_cloud" "$TYPE" $CONF_ARGS --config "$TEMP_CONF" >/dev/null

    # Create the crypt wrapper named 'backup_remote'
    # remote needs to point to the raw remote + bucket/folder path if needed
    # usually: raw_cloud:/
    msg "$MSG_BKP_ENCRYPT_LAYER"
    rclone config create "$REMOTE_NAME" crypt remote="raw_cloud:/" password="$PASS1" --config "$TEMP_CONF" >/dev/null

    msg "$MSG_BKP_ENCRYPT_OK"
else
    # Direct setup
    msg "$MSG_BKP_DIRECT_AUTH"
    rclone config create "$REMOTE_NAME" "$TYPE" $CONF_ARGS --config "$TEMP_CONF"
fi

echo ""
msg "$MSG_BKP_AUTH_OK"

# 4. Deploy to Server
echo ""
msg "$MSG_BKP_DEPLOY_HEADER"

# 4a. Install Rclone on server if missing
msg "$MSG_BKP_CHECK_RCLONE"
server_exec "command -v rclone >/dev/null || (curl https://rclone.org/install.sh | sudo bash)"

# 4b. Upload Config
msg "$MSG_BKP_UPLOAD_CONFIG"
# We read the config content and write it to the server securely
CONF_CONTENT=$(cat "$TEMP_CONF")
server_exec "mkdir -p ~/.config/rclone && echo '$CONF_CONTENT' > ~/.config/rclone/rclone.conf && chmod 600 ~/.config/rclone/rclone.conf"

# 4c. Upload Backup Script
msg "$MSG_BKP_INSTALL_SCRIPT"
REPO_ROOT="$SCRIPT_DIR/.."
server_pipe_to "$REPO_ROOT/system/backup-core.sh" ~/backup-core.sh

# 4d. Setup Cron
msg "$MSG_BKP_SETUP_CRON"
CRON_CMD="0 3 * * * /root/backup-core.sh >> /var/log/stackpilot-backup.log 2>&1"
# Check if job exists, if not append
server_exec "crontab -l | grep -v 'backup-core.sh' | { cat; echo '$CRON_CMD'; } | crontab -"

# Cleanup
rm -f "$TEMP_CONF"

echo ""
msg "$MSG_BKP_DONE"
echo ""
msg "$MSG_BKP_WHAT_HAPPENS"
msg "$MSG_BKP_SCHEDULE" "$TYPE"
msg "$MSG_BKP_DIRS"
echo ""
msg "$MSG_BKP_RUN_NOW"
msg "$MSG_BKP_RUN_CMD" "$VPS_HOST"
echo ""
msg "$MSG_BKP_VERIFY"
msg "$MSG_BKP_VERIFY_CMD" "$VPS_HOST"
echo ""
msg "$MSG_BKP_RESTORE"
msg "$MSG_BKP_RESTORE_CMD" "$VPS_HOST"
echo ""
if [[ "$ENCRYPT_CHOICE" =~ ^[Yy]$ ]]; then
    msg "$MSG_BKP_ENCRYPT_NOTE"
    msg "$MSG_BKP_ENCRYPT_NOTE2"
fi
