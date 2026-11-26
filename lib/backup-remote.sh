#!/bin/bash

# StackPilot - helpers shared by local/setup-backup.sh and local/restore.sh.
# Requires lib/server-exec.sh. Secrets travel on stdin, never as command arguments.

BACKUP_ENGINE=/usr/local/sbin/stackpilot-backup
_BR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

backup_sudo() {
    [ "$(server_exec 'id -u' < /dev/null)" = 0 ] || echo sudo
}

# Usage: printf 'data' | backup_write_private /path/on/server
backup_write_private() {
    server_exec "$(backup_sudo) sh -c 'umask 077; mkdir -p \"\$(dirname $1)\" && cat > $1 && chmod 600 $1'"
}

# Install the backup engine that matches this checkout.
backup_install_engine() {
    server_exec "$(backup_sudo) sh -c 'umask 077; cat > $BACKUP_ENGINE && chmod 700 $BACKUP_ENGINE'" \
        < "$_BR_ROOT/system/backup-core.sh"
}
