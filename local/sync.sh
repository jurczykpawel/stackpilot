#!/bin/bash

# StackPilot - File Sync Helper
# Easy wrapper around rsync for uploading/downloading files.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/sync.sh up   <local_path> <remote_path> [--ssh=ALIAS]
#   ./local/sync.sh down <remote_path> <local_path> [--ssh=ALIAS]
#
# Examples:
#   ./local/sync.sh up ./my-website /var/www/html
#   ./local/sync.sh up ./backup.sql /tmp/ --ssh=hanna
#   ./local/sync.sh down /opt/stacks/n8n/.env ./backup/ --ssh=vps

set -e

# This script only runs on the local machine (rsync requires SSH)
if [ -f /opt/stackpilot/.server-marker ]; then
    echo "This script only runs on the local machine (not on the server)."
    exit 1
fi

# Find repo directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load cli-parser (for --ssh, --yes, colors) — cli-parser loads i18n
source "$REPO_ROOT/lib/cli-parser.sh"

# i18n guard (cli-parser already loads it, but guard for safety)
_SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_SYNC_DIR/../lib/i18n.sh"
fi

# Parse arguments — extract direction, src, dest + CLI flags
DIRECTION=""
SRC=""
DEST=""
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        --ssh=*|--yes|-y|--dry-run|--help|-h)
            # These will be handled by parse_args
            ;;
        *)
            POSITIONAL+=("$arg")
            ;;
    esac
done

# Parse CLI flags (--ssh, --yes, --dry-run)
parse_args "$@"

# SSH alias from --ssh or default
SSH_ALIAS="${SSH_ALIAS:-vps}"

# Extract positional arguments
DIRECTION="${POSITIONAL[0]:-}"
SRC="${POSITIONAL[1]:-}"
DEST="${POSITIONAL[2]:-}"

print_usage() {
    cat <<EOF
StackPilot - File Sync Helper

Usage:
  $0 up   <local_path> <remote_path> [--ssh=ALIAS]
  $0 down <remote_path> <local_path> [--ssh=ALIAS]

Options:
  --ssh=ALIAS    SSH alias (default: vps)
  --dry-run      Preview what would be executed without running it
  --help, -h     Show this help

Examples:
  # Upload a directory to the server
  $0 up ./my-website /var/www/html

  # Upload to a different server
  $0 up ./backup.sql /tmp/ --ssh=hanna

  # Download a file from the server
  $0 down /opt/stacks/n8n/.env ./backup/

  # Preview without executing
  $0 up ./dist /var/www/public/app --dry-run
EOF
    exit 1
}

if [ -z "$DIRECTION" ] || [ -z "$SRC" ] || [ -z "$DEST" ]; then
    print_usage
fi

# Check if rsync is installed
if ! command -v rsync &>/dev/null; then
    msg "$MSG_SYNC_NO_RSYNC"
    echo ""
    if [[ "$OSTYPE" == darwin* ]]; then
        msg "$MSG_SYNC_NO_RSYNC_MAC"
    else
        msg "$MSG_SYNC_NO_RSYNC_LINUX"
    fi
    exit 1
fi

# Validate SSH alias (prevent injection)
if ! [[ "$SSH_ALIAS" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    msg "$MSG_SYNC_INVALID_ALIAS" "$SSH_ALIAS"
    exit 1
fi

echo ""
msg "$MSG_SYNC_HEADER" "$DIRECTION" "$SSH_ALIAS"

if [ "$DIRECTION" == "up" ]; then
    # Upload: Local -> Remote
    if [ ! -e "$SRC" ]; then
        msg "$MSG_SYNC_NO_SRC" "$SRC"
        exit 1
    fi

    msg "$MSG_SYNC_UP_ARROW" "$SRC" "$SSH_ALIAS" "$DEST"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        msg "$MSG_SYNC_DRYRUN_UP" "$SRC" "$SSH_ALIAS" "$DEST"
    else
        rsync -avzP -e "ssh -o ConnectTimeout=10" "$SRC" "$SSH_ALIAS:$DEST"
    fi

elif [ "$DIRECTION" == "down" ]; then
    # Download: Remote -> Local
    msg "$MSG_SYNC_DOWN_ARROW" "$SSH_ALIAS" "$SRC" "$DEST"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        msg "$MSG_SYNC_DRYRUN_DOWN" "$SSH_ALIAS" "$SRC" "$DEST"
    else
        rsync -avzP -e "ssh -o ConnectTimeout=10" "$SSH_ALIAS:$SRC" "$DEST"
    fi

else
    msg "$MSG_SYNC_INVALID_DIR" "$DIRECTION"
    print_usage
fi

echo ""
msg "$MSG_SYNC_DONE"
