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
#   ./local/sync.sh down /opt/stacks/n8n/.env ./backup/ --ssh=mikrus

set -e

# Ten skrypt działa tylko na komputerze lokalnym (rsync wymaga SSH)
if [ -f /klucz_api ]; then
    echo "Ten skrypt działa tylko na komputerze lokalnym (nie na serwerze Mikrus)."
    exit 1
fi

# Znajdź katalog repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Załaduj cli-parser (dla --ssh, --yes, kolorów)
source "$REPO_ROOT/lib/cli-parser.sh"

# Parsuj argumenty — wyciągnij direction, src, dest + flagi CLI
DIRECTION=""
SRC=""
DEST=""
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        --ssh=*|--yes|-y|--dry-run|--help|-h)
            # Te obsłuży parse_args
            ;;
        *)
            POSITIONAL+=("$arg")
            ;;
    esac
done

# Parsuj flagi CLI (--ssh, --yes, --dry-run)
parse_args "$@"

# SSH alias z --ssh lub domyślny
SSH_ALIAS="${SSH_ALIAS:-vps}"

# Wyciągnij pozycyjne argumenty
DIRECTION="${POSITIONAL[0]:-}"
SRC="${POSITIONAL[1]:-}"
DEST="${POSITIONAL[2]:-}"

print_usage() {
    cat <<EOF
StackPilot - File Sync Helper

Użycie:
  $0 up   <local_path> <remote_path> [--ssh=ALIAS]
  $0 down <remote_path> <local_path> [--ssh=ALIAS]

Opcje:
  --ssh=ALIAS    SSH alias (domyślnie: mikrus)
  --dry-run      Pokaż co się wykona bez wykonania
  --help, -h     Pokaż tę pomoc

Przykłady:
  # Upload katalogu na serwer
  $0 up ./my-website /var/www/html

  # Upload na inny serwer
  $0 up ./backup.sql /tmp/ --ssh=hanna

  # Download pliku z serwera
  $0 down /opt/stacks/n8n/.env ./backup/

  # Podgląd bez wykonania
  $0 up ./dist /var/www/public/app --dry-run
EOF
    exit 1
}

if [ -z "$DIRECTION" ] || [ -z "$SRC" ] || [ -z "$DEST" ]; then
    print_usage
fi

# Sprawdź czy rsync jest zainstalowany
if ! command -v rsync &>/dev/null; then
    echo -e "${RED}❌ rsync nie jest zainstalowany.${NC}"
    echo ""
    if [[ "$OSTYPE" == darwin* ]]; then
        echo "Zainstaluj: brew install rsync"
    else
        echo "Zainstaluj: sudo apt install rsync"
    fi
    exit 1
fi

# Walidacja SSH alias (zapobieganie injection)
if ! [[ "$SSH_ALIAS" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    echo -e "${RED}❌ Nieprawidłowy SSH alias: '$SSH_ALIAS'${NC}"
    exit 1
fi

echo ""
echo -e "🔄 Sync: ${BLUE}$DIRECTION${NC} (serwer: $SSH_ALIAS)"

if [ "$DIRECTION" == "up" ]; then
    # Upload: Local -> Remote
    if [ ! -e "$SRC" ]; then
        echo -e "${RED}❌ Lokalna ścieżka '$SRC' nie istnieje.${NC}"
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
    echo -e "${RED}❌ Nieprawidłowy kierunek: '$DIRECTION'. Użyj 'up' lub 'down'.${NC}"
    print_usage
fi

echo ""
echo -e "${GREEN}✅ Sync zakończony.${NC}"
