#!/bin/bash

# StackPilot - Backup Setup Wizard
# Configures encrypted restic backups of the whole server: app files, Docker volumes and databases.
# Author: Paweł (Lazy Engineer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/server-exec.sh"
source "$REPO_ROOT/lib/backup-remote.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: $0 [ssh_alias]"
    echo ""
    echo "Configures encrypted daily backups with restic: app files, Docker volumes and databases."
    echo "Destinations: Cloudflare R2 (default), Backblaze B2, any S3 endpoint, SFTP, a directory on the server."
    echo "Default SSH alias: vps"
    exit 0
fi

SSH_ALIAS="${1:-vps}"

ask() { # VAR DEFAULT MESSAGE [ARGS...]
    local VAR=$1 DEFAULT=$2 REPLY_VALUE
    shift 2
    read -r -p "$(msg_n "$@")" REPLY_VALUE || true
    printf -v "$VAR" '%s' "${REPLY_VALUE:-$DEFAULT}"
}

ask_secret() {
    local REPLY_VALUE
    read -r -s -p "$(msg_n "$2")" REPLY_VALUE || true
    echo ""
    printf -v "$1" '%s' "$REPLY_VALUE"
}

require() { [ -n "$1" ] || { msg "$MSG_BKP_REQUIRED"; exit 1; }; }

echo ""
msg "$MSG_BKP_HEADER"
msg "$MSG_BKP_SERVER" "$(server_user)" "$(server_hostname)"
echo ""
msg "$MSG_BKP_INTRO"
ask CONFIRM "" "$MSG_BKP_CONFIRM"
[[ "$CONFIRM" =~ ^[TtYy] ]] || { msg "$MSG_BKP_CANCELLED"; exit 1; }

echo ""
msg "$MSG_BKP_CHOOSE"
msg "$MSG_BKP_OPT_R2"
msg "$MSG_BKP_OPT_B2"
msg "$MSG_BKP_OPT_S3"
msg "$MSG_BKP_OPT_SFTP"
msg "$MSG_BKP_OPT_LOCAL"
ask CHOICE 1 "$MSG_BKP_CHOICE"

ENV_LINES=()
add_env() { ENV_LINES+=("$(printf '%s=%q' "$1" "$2")"); }

bucket_repo() { # ENDPOINT_URL
    local BUCKET PREFIX
    ask BUCKET "" "$MSG_BKP_BUCKET"
    require "$BUCKET"
    DEFAULT_PREFIX=$(server_exec hostname < /dev/null)
    ask PREFIX "$DEFAULT_PREFIX" "$MSG_BKP_PREFIX" "$DEFAULT_PREFIX"
    REPOSITORY="s3:$1/$BUCKET/${PREFIX#/}"
    ask KEY_ID "" "$MSG_BKP_KEY_ID"
    ask_secret KEY_SECRET "$MSG_BKP_KEY_SECRET"
    require "$KEY_ID"
    require "$KEY_SECRET"
    add_env AWS_ACCESS_KEY_ID "$KEY_ID"
    add_env AWS_SECRET_ACCESS_KEY "$KEY_SECRET"
}

case "$CHOICE" in
    1)
        msg "$MSG_BKP_R2_HINT"
        ask ACCOUNT_ID "" "$MSG_BKP_R2_ACCOUNT"
        require "$ACCOUNT_ID"
        bucket_repo "https://$ACCOUNT_ID.r2.cloudflarestorage.com"
        add_env AWS_DEFAULT_REGION auto
        ;;
    2)
        msg "$MSG_BKP_B2_HINT"
        ask ENDPOINT "" "$MSG_BKP_B2_ENDPOINT"
        require "$ENDPOINT"
        bucket_repo "https://${ENDPOINT#https://}"
        ;;
    3)
        ask ENDPOINT "" "$MSG_BKP_S3_ENDPOINT"
        [[ "$ENDPOINT" =~ ^https?:// ]] || { msg "$MSG_BKP_S3_ENDPOINT_INVALID"; exit 1; }
        bucket_repo "${ENDPOINT%/}"
        ask REGION us-east-1 "$MSG_BKP_S3_REGION"
        add_env AWS_DEFAULT_REGION "$REGION"
        ;;
    4)
        msg "$MSG_BKP_SFTP_HINT"
        ask TARGET "" "$MSG_BKP_SFTP_TARGET"
        [[ "$TARGET" =~ ^[^@[:space:]]+@[^:[:space:]]+:/. ]] || { msg "$MSG_BKP_SFTP_INVALID"; exit 1; }
        REPOSITORY="sftp:$TARGET"
        ;;
    5)
        msg "$MSG_BKP_LOCAL_HINT"
        ask TARGET "" "$MSG_BKP_LOCAL_PATH"
        [[ "$TARGET" = /?* ]] || { msg "$MSG_BKP_LOCAL_INVALID"; exit 1; }
        REPOSITORY="$TARGET"
        ;;
    *) msg "$MSG_BKP_INVALID_CHOICE"; exit 1 ;;
esac

echo ""
msg "$MSG_BKP_PASSWORD_INFO"
ask_secret PASSWORD "$MSG_BKP_PASSWORD_PROMPT"
NEW_PASSWORD=false
if [ -z "$PASSWORD" ]; then
    PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
    NEW_PASSWORD=true
fi

echo ""
msg "$MSG_BKP_PING_INFO"
ask PING_URL "" "$MSG_BKP_PING_PROMPT"
[ -z "$PING_URL" ] || [[ "$PING_URL" =~ ^https?://[^[:space:]]+$ ]] || { msg "$MSG_BKP_PING_INVALID"; exit 1; }

RUN_NOW=n
if [ "$NEW_PASSWORD" = true ]; then
    ask RUN_NOW y "$MSG_BKP_RUN_NOW"
fi

ENV_LINES=("$(printf 'RESTIC_REPOSITORY=%q' "$REPOSITORY")" "$(printf 'RESTIC_PASSWORD=%q' "$PASSWORD")" "${ENV_LINES[@]}")
[ -z "$PING_URL" ] || add_env BACKUP_PING_URL "$PING_URL"

echo ""
msg "$MSG_BKP_DEPLOYING"
backup_install_engine
# The current configuration is replaced only after the new one opens or creates the repository.
CONFIG=/opt/stackpilot/config/backup.env
printf '%s\n' "# StackPilot backup configuration (restic). Keep this file private." "${ENV_LINES[@]}" |
    backup_write_private "$CONFIG.new"

if ! server_exec "$(backup_sudo) sh -c 'BACKUP_ENV=$CONFIG.new $BACKUP_ENGINE init && mv -f $CONFIG.new $CONFIG || { rm -f $CONFIG.new; exit 1; }'" < /dev/null; then
    msg "$MSG_BKP_INIT_FAILED"
    exit 1
fi

if [ "$NEW_PASSWORD" = true ]; then
    echo ""
    msg "$MSG_BKP_PASSWORD_SHOW"
    echo "    $PASSWORD"
    msg "$MSG_BKP_PASSWORD_WARN"
fi

if [[ "$RUN_NOW" =~ ^[TtYy] ]]; then
    echo ""
    msg "$MSG_BKP_RUNNING"
    server_exec "$(backup_sudo) $BACKUP_ENGINE run" < /dev/null || msg "$MSG_BKP_RUN_FAILED"
fi

echo ""
msg "$MSG_BKP_DONE"
msg "$MSG_BKP_SUMMARY_WHAT"
msg "$MSG_BKP_SUMMARY_WHEN"
[ -n "$PING_URL" ] || msg "$MSG_BKP_SUMMARY_NO_PING"
echo ""
msg "$MSG_BKP_CMDS"
msg "$MSG_BKP_CMD_RUN" "$SSH_ALIAS" "$BACKUP_ENGINE"
msg "$MSG_BKP_CMD_LIST" "$SSH_ALIAS" "$BACKUP_ENGINE"
msg "$MSG_BKP_CMD_RESTORE" "$SSH_ALIAS"
