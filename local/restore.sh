#!/bin/bash

# StackPilot - Emergency Restore
# Trigger a full system restore from the latest cloud backup.

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: $0 [ssh_alias]"
    echo ""
    echo "Restores data from the cloud (requires prior backup configuration)."
    echo "Default SSH alias: vps"
    exit 0
fi

VPS_HOST="${1:-vps}" # First argument or default to 'vps'
SSH_ALIAS="$VPS_HOST"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

# Get remote server info for confirmation
REMOTE_HOST=$(server_hostname)
REMOTE_USER=$(server_user)

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  🚨  EMERGENCY RESTORE PROTOCOL                                ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  Server:  $REMOTE_USER@$REMOTE_HOST"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "WARNING: This will restore data from the cloud and OVERWRITE current files!"
echo "All changes since the last backup will be LOST."
echo ""
read -p "Are you sure you want to continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[TtYy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

read -p "Press [Enter] to connect to the server..."

# 1. Deploy the restore core script (ensure it's up to date)
REPO_ROOT="$SCRIPT_DIR/.."
server_pipe_to "$REPO_ROOT/system/restore-core.sh" ~/restore-core.sh

# 2. Execute it interactively
# -t is crucial here to allow user input (typing 'YES') inside the SSH session
server_exec_tty "./restore-core.sh"
