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

# Load cli-parser (for --ssh, --yes, colors)
source "$REPO_ROOT/lib/cli-parser.sh"

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
    echo -e "${RED}❌ rsync is not installed.${NC}"
    echo ""
    if [[ "$OSTYPE" == darwin* ]]; then
        echo "Install: brew install rsync"
    else
        echo "Install: sudo apt install rsync"
    fi
    exit 1
fi

# Validate SSH alias (prevent injection)
if ! [[ "$SSH_ALIAS" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    echo -e "${RED}❌ Invalid SSH alias: '$SSH_ALIAS'${NC}"
    exit 1
fi

echo ""
echo -e "🔄 Sync: ${BLUE}$DIRECTION${NC} (server: $SSH_ALIAS)"

if [ "$DIRECTION" == "up" ]; then
    # Upload: Local -> Remote
    if [ ! -e "$SRC" ]; then
        echo -e "${RED}❌ Local path '$SRC' does not exist.${NC}"
        exit 1
    fi

    echo "   $SRC → $SSH_ALIAS:$DEST"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run] rsync -avzP \"$SRC\" \"$SSH_ALIAS:$DEST\"${NC}"
    else
        rsync -avzP -e "ssh -o ConnectTimeout=10" "$SRC" "$SSH_ALIAS:$DEST"
    fi

elif [ "$DIRECTION" == "down" ]; then
    # Download: Remote -> Local
    echo "   $SSH_ALIAS:$SRC → $DEST"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run] rsync -avzP \"$SSH_ALIAS:$SRC\" \"$DEST\"${NC}"
    else
        rsync -avzP -e "ssh -o ConnectTimeout=10" "$SSH_ALIAS:$SRC" "$DEST"
    fi

else
    echo -e "${RED}❌ Invalid direction: '$DIRECTION'. Use 'up' or 'down'.${NC}"
    print_usage
fi

echo ""
echo -e "${GREEN}✅ Sync complete.${NC}"
