#!/bin/bash

# StackPilot - Restore from backup
# Lists restic snapshots and restores everything or one app (files, Docker volumes, databases).

set -e

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: $0 [ssh_alias] [app]"
    echo ""
    echo "Restores a snapshot made by setup-backup.sh. Without [app] it restores every app"
    echo "in /opt/stacks plus /opt/dockge, /etc/caddy and /var/www. Overwrites current data."
    echo "Default SSH alias: vps"
    exit 0
fi

SSH_ALIAS="${1:-vps}"
APP="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"
source "$SCRIPT_DIR/../lib/backup-remote.sh"

echo ""
msg "$MSG_REST_HEADER"
msg "$MSG_REST_SERVER" "$(server_user)" "$(server_hostname)"
echo ""

SUDO=$(backup_sudo)
backup_install_engine
if ! server_exec "$SUDO $BACKUP_ENGINE snapshots" < /dev/null; then
    msg "$MSG_REST_NO_CONFIG"
    exit 1
fi
echo ""

read -r -p "$(msg_n "$MSG_REST_SNAPSHOT")" SNAPSHOT || true
SNAPSHOT=${SNAPSHOT:-latest}
if [ -z "$APP" ]; then
    read -r -p "$(msg_n "$MSG_REST_APP")" APP || true
fi
if [[ ! "$SNAPSHOT" =~ ^[A-Za-z0-9]+$ ]] || [[ ! "$APP" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; then
    msg "$MSG_REST_INVALID"
    exit 1
fi

echo ""
if [ -n "$APP" ]; then msg "$MSG_REST_WARN_APP" "$APP"; else msg "$MSG_REST_WARN_ALL"; fi
msg "$MSG_REST_WARN_DETAIL"
read -r -p "$(msg_n "$MSG_REST_CONFIRM")" CONFIRM || true
if [ "$CONFIRM" != "YES" ] && [ "$CONFIRM" != "TAK" ]; then
    msg "$MSG_REST_CANCELLED"
    exit 1
fi

if server_exec "$SUDO $BACKUP_ENGINE restore $SNAPSHOT ${APP:+$APP }--yes" < /dev/null; then
    msg "$MSG_REST_DONE"
else
    msg "$MSG_REST_FAILED"
    exit 1
fi
