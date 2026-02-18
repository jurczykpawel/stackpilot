#!/bin/bash

# Mikrus Toolbox - Install Toolbox on Server
# Kopiuje toolbox na serwer Mikrus, żeby skrypty działały bezpośrednio.
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   ./local/install-toolbox.sh [ssh_alias]
#
# Po instalacji na serwerze:
#   ssh mikrus
#   deploy.sh uptime-kuma
#   cytrus-domain.sh - 3001

set -e

SSH_ALIAS="${1:-mikrus}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ten skrypt działa tylko z komputera lokalnego
if [ -f /klucz_api ]; then
    echo "Ten skrypt działa tylko na komputerze lokalnym."
    echo "Toolbox jest już zainstalowany na tym serwerze."
    exit 1
fi

echo ""
echo "📦 Instalacja Mikrus Toolbox na serwerze"
echo ""
echo "   Serwer: $SSH_ALIAS"
echo "   Źródło: $REPO_ROOT"
echo "   Cel:    /opt/mikrus-toolbox/"
echo ""

# Sprawdź rsync
if ! command -v rsync &>/dev/null; then
    echo "❌ rsync nie jest zainstalowany"
    echo "   Mac:   brew install rsync"
    echo "   Linux: sudo apt install rsync"
    exit 1
fi

# Kopiuj toolbox na serwer
echo "🚀 Kopiuję pliki..."
rsync -az --delete \
    --exclude '.git' \
    --exclude 'node_modules' \
    --exclude 'mcp-server' \
    --exclude '.claude' \
    --exclude '*.md' \
    "$REPO_ROOT/" "$SSH_ALIAS:/opt/mikrus-toolbox/"

# Dodaj do PATH — wykryj shell na serwerze i użyj właściwego pliku
# zsh: ~/.zshenv (czytany ZAWSZE — interactive, non-interactive, login, non-login)
# bash: ~/.bashrc (czytany przy ssh host "cmd" + interactive)
echo "🔧 Konfiguruję PATH..."
TOOLBOX_LINE='export PATH=/opt/mikrus-toolbox/local:$PATH'
ssh "$SSH_ALIAS" "
    REMOTE_SHELL=\$(basename \"\$SHELL\" 2>/dev/null)

    # zsh → ~/.zshenv
    if [ \"\$REMOTE_SHELL\" = 'zsh' ]; then
        if ! grep -q 'mikrus-toolbox/local' ~/.zshenv 2>/dev/null; then
            echo '' >> ~/.zshenv
            echo '# Mikrus Toolbox' >> ~/.zshenv
            echo '$TOOLBOX_LINE' >> ~/.zshenv
        fi
    fi

    # bash → ~/.bashrc (na początku, przed guardem interaktywnym)
    if [ -f ~/.bashrc ]; then
        if ! grep -q 'mikrus-toolbox/local' ~/.bashrc 2>/dev/null; then
            sed -i '1i\\# Mikrus Toolbox\nexport PATH=/opt/mikrus-toolbox/local:\$PATH\n' ~/.bashrc
        fi
    fi

    # Wyczyść stare wpisy z .profile
    if grep -q 'mikrus-toolbox/local' ~/.profile 2>/dev/null; then
        sed -i '/# Mikrus Toolbox/d; /mikrus-toolbox\/local/d' ~/.profile
    fi
"

echo ""
echo "✅ Toolbox zainstalowany!"
echo ""
echo "Teraz możesz:"
echo "   ssh $SSH_ALIAS"
echo "   deploy.sh uptime-kuma"
echo "   cytrus-domain.sh - 3001"
echo ""
echo "Aktualizacja: uruchom ten skrypt ponownie"
echo ""
