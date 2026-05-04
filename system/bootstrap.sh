#!/bin/bash

# StackPilot - Server-side Bootstrap
# Installs StackPilot on the server via git clone (no local rsync needed).
# Designed to be run via:
#   curl -fsSL https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/system/bootstrap.sh | bash
#
# Use case: Windows / PowerShell users who can't run ./local/install-toolbox.sh
# locally (no bash, no rsync). They SSH in first, then curl-pipe this.
#
# What it does:
#   1. Clones jurczykpawel/stackpilot to /opt/stackpilot
#   2. Marks the install as server-side (.server-marker for server-exec.sh)
#   3. Adds /opt/stackpilot/local to PATH in user's shell rc

set -e

REPO_URL="${STACKPILOT_REPO:-https://github.com/jurczykpawel/stackpilot.git}"
INSTALL_DIR="${STACKPILOT_DIR:-/opt/stackpilot}"
BRANCH="${STACKPILOT_BRANCH:-main}"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Privilege detection ---
if [ "$EUID" -eq 0 ]; then
    SUDO=""
elif command -v sudo &>/dev/null; then
    SUDO="sudo"
else
    echo -e "${RED}Error: must run as root or have sudo available${NC}" >&2
    exit 1
fi

echo ""
echo -e "${BLUE}=== StackPilot Bootstrap ===${NC}"
echo "  Target: $INSTALL_DIR (branch: $BRANCH)"
echo ""

# --- Prerequisites ---
if ! command -v git &>/dev/null; then
    echo -e "${YELLOW}> Installing git...${NC}"
    if command -v apt-get &>/dev/null; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git
    elif command -v dnf &>/dev/null; then
        $SUDO dnf install -y -q git
    elif command -v yum &>/dev/null; then
        $SUDO yum install -y -q git
    elif command -v apk &>/dev/null; then
        $SUDO apk add --quiet git
    else
        echo -e "${RED}Error: no supported package manager found. Install git manually first.${NC}" >&2
        exit 1
    fi
fi

# --- Already installed? ---
if [ -d "$INSTALL_DIR/.git" ]; then
    echo -e "${YELLOW}> StackPilot already installed at $INSTALL_DIR — updating to latest $BRANCH${NC}"
    $SUDO git -C "$INSTALL_DIR" fetch --quiet origin "$BRANCH"
    $SUDO git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH" --quiet
elif [ -e "$INSTALL_DIR" ]; then
    echo -e "${RED}Error: $INSTALL_DIR exists but is not a git repo. Remove it first.${NC}" >&2
    exit 1
else
    echo -e "${GREEN}> Cloning $REPO_URL${NC}"
    $SUDO git clone --quiet --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

# --- Make scripts executable ---
$SUDO find "$INSTALL_DIR/local" "$INSTALL_DIR/system" -name '*.sh' -exec chmod +x {} \;

# --- Server marker (used by lib/server-exec.sh to detect server environment) ---
$SUDO touch "$INSTALL_DIR/.server-marker"

# --- PATH setup ---
echo -e "${GREEN}> Configuring PATH${NC}"
TOOLBOX_LINE="export PATH=$INSTALL_DIR/local:\$PATH"
REMOTE_SHELL=$(basename "${SHELL:-/bin/bash}")

case "$REMOTE_SHELL" in
    zsh)
        # zsh: ~/.zshenv (always read)
        if ! grep -q 'stackpilot/local' "$HOME/.zshenv" 2>/dev/null; then
            {
                echo ''
                echo '# StackPilot'
                echo "$TOOLBOX_LINE"
            } >> "$HOME/.zshenv"
            echo "    Added to ~/.zshenv"
        else
            echo "    Already in ~/.zshenv"
        fi
        ;;
    bash|*)
        # bash (and fallback): ~/.bashrc (prepended, before interactive guard)
        if [ ! -f "$HOME/.bashrc" ]; then
            touch "$HOME/.bashrc"
        fi
        if ! grep -q 'stackpilot/local' "$HOME/.bashrc" 2>/dev/null; then
            # Prepend so PATH is set even if interactive guard blocks rest of file
            tmp=$(mktemp)
            {
                echo '# StackPilot'
                echo "$TOOLBOX_LINE"
                echo ''
                cat "$HOME/.bashrc"
            } > "$tmp"
            mv "$tmp" "$HOME/.bashrc"
            echo "    Added to ~/.bashrc"
        else
            echo "    Already in ~/.bashrc"
        fi
        ;;
esac

# --- Clean up old .profile entries (for users migrating from older versions) ---
if grep -q 'stackpilot/local' "$HOME/.profile" 2>/dev/null; then
    sed -i '/# StackPilot/d; /stackpilot\/local/d' "$HOME/.profile"
fi

# --- Done ---
echo ""
echo -e "${GREEN}=== Bootstrap complete ===${NC}"
echo ""
echo "To use StackPilot in this session, run:"
echo -e "  ${BLUE}export PATH=$INSTALL_DIR/local:\$PATH${NC}"
echo ""
echo "Or open a new shell, then:"
echo -e "  ${BLUE}deploy.sh n8n --domain-type=cloudflare --domain=n8n.example.com --db-source=bundled${NC}"
echo -e "  ${BLUE}add-static-hosting.sh lm.example.com /tmp/files /var/www/lm.example.com${NC}"
echo ""
echo "To update later:"
echo -e "  ${BLUE}curl -fsSL https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/system/bootstrap.sh | bash${NC}"
echo ""
