#!/bin/bash

# StackPilot - Backup Setup Wizard
# Configures cloud backup on Mikrus using local Rclone for auth.
# Author: Paweł (Lazy Engineer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Użycie: $0 [ssh_alias]"
    echo ""
    echo "Konfiguruje automatyczne backupy do chmury (Google Drive, Dropbox, S3, itp.)."
    echo "Wymaga zainstalowanego rclone lokalnie."
    echo "Default SSH alias: vps"
    exit 0
fi

# Configuration
VPS_HOST="${1:-vps}" # First argument or default to 'mikrus'
SSH_ALIAS="$VPS_HOST"
REMOTE_NAME="backup_remote"
TEMP_CONF="/tmp/rclone_stackpilot_setup.conf"

# Get remote server info for confirmation
REMOTE_HOST=$(server_hostname)
REMOTE_USER=$(server_user)

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  🛡️  Mikrus Backup Setup Wizard                                ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  Serwer:  $REMOTE_USER@$REMOTE_HOST"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "This tool will configure automatic backups to a cloud provider."
read -p "Kontynuować na tym serwerze? (t/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[TtYy]$ ]]; then
    echo "Anulowano."
    exit 1
fi

# 1. Check Local Prerequisites
if ! command -v rclone &> /dev/null; then
    echo "❌ Rclone nie jest zainstalowany na tym komputerze."
    echo ""
    echo "   Rclone jest potrzebny LOKALNIE do autoryzacji OAuth - Google/Dropbox"
    echo "   wymagają logowania przez przeglądarkę, a serwer nie ma GUI."
    echo ""
    echo "   Instalacja:"
    echo "   - Mac:     brew install rclone"
    echo "   - Linux:   curl https://rclone.org/install.sh | sudo bash"
    echo "   - Windows: https://rclone.org/downloads/ (lub winget install rclone)"
    echo ""
    echo "   Po instalacji uruchom ten skrypt ponownie."
    exit 1
fi

# 2. Select Provider
echo ""
echo "Choose your backup provider:"
echo "1) Google Drive (Recommended)"
echo "2) Dropbox"
echo "3) Microsoft OneDrive"
echo "4) Mega"
echo "5) S3 Compatible (AWS, Wasabi, MinIO, etc.)"
read -p "Select [1-5]: " CHOICE

case $CHOICE in
    1) TYPE="drive"; CONF_ARGS="scope=drive.file" ;;
    2) TYPE="dropbox"; CONF_ARGS="" ;;
    3) TYPE="onedrive"; CONF_ARGS="" ;;
    4) TYPE="mega"; CONF_ARGS="" ;;
    5) TYPE="s3"; CONF_ARGS="provider=AWS env_auth=false" ;;
    *) echo "Invalid choice."; exit 1 ;;
esac

echo ""
echo "--- 🔐 Authenticating with $TYPE ---"
echo "We will now generate a configuration token."
if [[ "$TYPE" == "mega" || "$TYPE" == "s3" ]]; then
    echo "You will be asked for credentials in the terminal."
else
    if is_on_server; then
        echo "⚠️  UWAGA: Ten provider wymaga logowania przez przeglądarkę."
        echo "   Na serwerze nie ma GUI - użyj rclone authorize na komputerze lokalnym"
        echo "   lub wybierz providera bez OAuth (S3, Mega)."
    fi
    echo "A browser window will open for you to log in."
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
read -p "🔒 Do you want to ENCRYPT your backups? (Recommended) [y/N]: " ENCRYPT_CHOICE

if [[ "$ENCRYPT_CHOICE" =~ ^[Yy]$ ]]; then
    echo "--- Setting up Encryption ---"
    echo "Please enter a strong password. You will need this to restore files!"
    read -s -p "Password: " PASS1
    echo ""
    read -s -p "Confirm Password: " PASS2
    echo ""
    
    if [ "$PASS1" != "$PASS2" ]; then
        echo "❌ Passwords do not match. Aborting."
        exit 1
    fi
    
    # Create the raw backend first
    echo "Authenticating with provider..."
    rclone config create "raw_cloud" "$TYPE" $CONF_ARGS --config "$TEMP_CONF" >/dev/null
    
    # Create the crypt wrapper named 'backup_remote'
    # remote needs to point to the raw remote + bucket/folder path if needed
    # usually: raw_cloud:/
    echo "Configuring encryption layer..."
    rclone config create "$REMOTE_NAME" crypt remote="raw_cloud:/" password="$PASS1" --config "$TEMP_CONF" >/dev/null
    
    echo "✅ Encryption configured."
else
    # Direct setup
    echo "Authenticating with provider..."
    rclone config create "$REMOTE_NAME" "$TYPE" $CONF_ARGS --config "$TEMP_CONF"
fi

echo ""
echo "✅ Authentication successful! Config generated."

# 4. Deploy to Mikrus
echo ""
echo "--- 🚀 Deploying to Mikrus ---"

# 4a. Install Rclone on Mikrus if missing
echo "Checking Rclone on server..."
server_exec "command -v rclone >/dev/null || (curl https://rclone.org/install.sh | sudo bash)"

# 4b. Upload Config
echo "Uploading configuration..."
# We read the config content and write it to the server securely
CONF_CONTENT=$(cat "$TEMP_CONF")
server_exec "mkdir -p ~/.config/rclone && echo '$CONF_CONTENT' > ~/.config/rclone/rclone.conf && chmod 600 ~/.config/rclone/rclone.conf"

# 4c. Upload Backup Script
echo "Installing backup script..."
REPO_ROOT="$SCRIPT_DIR/.."
server_pipe_to "$REPO_ROOT/system/backup-core.sh" ~/backup-core.sh

# 4d. Setup Cron
echo "Setting up Cron job (Daily at 3:00 AM)..."
CRON_CMD="0 3 * * * /root/backup-core.sh >> /var/log/stackpilot-backup.log 2>&1"
# Check if job exists, if not append
server_exec "crontab -l | grep -v 'backup-core.sh' | { cat; echo '$CRON_CMD'; } | crontab -"

# Cleanup
rm -f "$TEMP_CONF"

echo ""
echo "✅ Backup do chmury skonfigurowany!"
echo ""
echo "📋 Co się dzieje automatycznie:"
echo "   - Codziennie o 3:00 backup jest wysyłany do $TYPE"
echo "   - Backupowane katalogi: /opt/stacks, /opt/dockge"
echo ""
echo "🚀 Uruchom pierwszy backup TERAZ:"
echo "   ssh $VPS_HOST '~/backup-core.sh'"
echo ""
echo "🔍 Jak sprawdzić czy działa?"
echo "   ssh $VPS_HOST 'tail -20 /var/log/stackpilot-backup.log'"
echo ""
echo "🔄 Jak przywrócić dane?"
echo "   ./local/restore.sh $VPS_HOST"
echo ""
if [[ "$ENCRYPT_CHOICE" =~ ^[Yy]$ ]]; then
    echo "🔐 Szyfrowanie włączone - nazwy folderów w chmurze będą zaszyfrowane."
    echo "   To normalne! Dane są bezpieczne i odszyfrowują się przy restore."
fi
