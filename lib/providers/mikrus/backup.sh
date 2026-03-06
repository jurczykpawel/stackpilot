#!/bin/bash

# StackPilot - Mikrus Provider: Backup Setup
# Configures Mikrus's built-in 200MB free backup.
# Runs on the server (not locally).

set -e

_MBKP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_MBKP_DIR/../../i18n.sh"
fi

msg "$MSG_MBKP_HEADER"
echo ""
msg "$MSG_MBKP_IMPORTANT"
msg "$MSG_MBKP_PANEL"
echo ""

msg "$MSG_MBKP_DEPS"
apt install -y -qq acl > /dev/null 2>&1 && msg "$MSG_MBKP_ACL_OK" || msg "$MSG_MBKP_ACL_SKIP"

echo ""
msg "$MSG_MBKP_SSH_KEY"
ssh-keyscan -H strych.mikr.us >> ~/.ssh/known_hosts 2>/dev/null
msg "$MSG_MBKP_SSH_KEY_OK"

echo ""
msg "$MSG_MBKP_NOOBS"
curl -s https://raw.githubusercontent.com/unkn0w/noobs/main/scripts/chce_backup.sh | bash

echo ""
msg "$MSG_MBKP_VERIFY"

# Test SSH connection to backup server
if ssh -i /backup_key -o BatchMode=yes -o ConnectTimeout=10 strych.mikr.us "echo ok" 2>/dev/null | grep -q "ok"; then
    msg "$MSG_MBKP_CONN_OK"
    echo ""
    msg "$MSG_MBKP_INFO"
    msg "$MSG_MBKP_INFO1"
    msg "$MSG_MBKP_INFO2"
    msg "$MSG_MBKP_INFO3"
    echo ""
    msg "$MSG_MBKP_RESTORE"
    msg "$MSG_MBKP_RESTORE1" "$(hostname)"
    msg "$MSG_MBKP_RESTORE2"
    msg "$MSG_MBKP_RESTORE3"
    echo ""
    msg "$MSG_MBKP_RESTORE_CMD" "$(hostname)"
    msg "$MSG_MBKP_RESTORE_EX1"
    msg "$MSG_MBKP_RESTORE_EX2"
    echo ""
    msg "$MSG_MBKP_LIMIT"
else
    echo ""
    msg "$MSG_MBKP_CONN_FAIL"
    echo ""
    msg "$MSG_MBKP_FAIL_REASON"
    msg "$MSG_MBKP_FAIL1"
    msg "$MSG_MBKP_FAIL2"
    msg "$MSG_MBKP_FAIL3"
    msg "$MSG_MBKP_FAIL4"
    echo ""
    exit 1
fi
