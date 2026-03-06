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

# i18n guard (server-exec.sh already loads it)
_REST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_REST_DIR/../lib/i18n.sh"
fi

# Get remote server info for confirmation
REMOTE_HOST=$(server_hostname)
REMOTE_USER=$(server_user)

echo ""
msg "$MSG_REST_HEADER_TOP"
msg "$MSG_REST_HEADER_TITLE"
msg "$MSG_REST_HEADER_MID"
msg "$MSG_REST_HEADER_SERVER" "$REMOTE_USER" "$REMOTE_HOST"
msg "$MSG_REST_HEADER_BOT"
echo ""
msg "$MSG_REST_WARNING"
msg "$MSG_REST_WARNING2"
echo ""
read -p "$(msg_n "$MSG_REST_CONFIRM")" -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[TtYy]$ ]]; then
    msg "$MSG_REST_CANCELLED"
    exit 1
fi

read -p "$(msg_n "$MSG_REST_PRESS_ENTER")"

# 1. Deploy the restore core script (ensure it's up to date)
REPO_ROOT="$SCRIPT_DIR/.."
server_pipe_to "$REPO_ROOT/system/restore-core.sh" ~/restore-core.sh

# 2. Execute it interactively
# -t is crucial here to allow user input (typing 'YES') inside the SSH session
server_exec_tty "./restore-core.sh"
