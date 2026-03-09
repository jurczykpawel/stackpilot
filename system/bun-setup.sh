#!/bin/bash

# StackPilot - Bun + PM2 Setup
# Installs Bun (runtime) and PM2 (process manager) for Node.js/Next.js apps
# Author: Paweł (Lazy Engineer)

set -e

_BUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    if [ -n "$_BUN_DIR" ] && [ -f "$_BUN_DIR/../lib/i18n.sh" ]; then
        source "$_BUN_DIR/../lib/i18n.sh"
    elif [ -f /opt/stackpilot/lib/i18n.sh ]; then
        source /opt/stackpilot/lib/i18n.sh
    else
        msg() { printf "%s\n" "$1"; }
        msg_n() { printf "%s" "$1"; }
    fi
fi

msg "$MSG_BUN_HEADER"

# Check if Bun is already installed
if command -v bun &> /dev/null; then
    BUN_VERSION=$(bun --version)
    msg "$MSG_BUN_ALREADY" "$BUN_VERSION"
else
    msg "$MSG_BUN_INSTALLING"
    # Ensure unzip is available (required by the Bun installer)
    if ! command -v unzip &> /dev/null; then
        apt-get install -y unzip -qq 2>/dev/null || yum install -y unzip -q 2>/dev/null || true
    fi
    curl -fsSL https://bun.sh/install | bash

    # Add to PATH for the current session
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"

    # Add to .bashrc if not present
    if ! grep -q 'BUN_INSTALL' ~/.bashrc 2>/dev/null; then
        echo '' >> ~/.bashrc
        echo '# Bun' >> ~/.bashrc
        echo 'export BUN_INSTALL="$HOME/.bun"' >> ~/.bashrc
        echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> ~/.bashrc
    fi

    msg "$MSG_BUN_INSTALLED" "$(bun --version)"
fi

# PM2 requires 'node' in PATH (it uses #!/usr/bin/env node shebang).
# If node is not available but bun is, create a symlink: node -> bun
# Bun is Node-compatible and can run PM2 scripts transparently.
if ! command -v node &> /dev/null && command -v bun &> /dev/null; then
    BUN_BIN="$(command -v bun)"
    BUN_BIN_DIR="$(dirname "$BUN_BIN")"
    ln -sf "$BUN_BIN" "$BUN_BIN_DIR/node"
    export PATH="$BUN_BIN_DIR:$PATH"
fi

# Check if PM2 is already installed
if command -v pm2 &> /dev/null && pm2 --version &> /dev/null 2>&1; then
    PM2_VERSION=$(pm2 --version 2>/dev/null)
    msg "$MSG_PM2_ALREADY" "$PM2_VERSION"
else
    msg "$MSG_PM2_INSTALLING"
    bun install -g pm2

    msg "$MSG_PM2_INSTALLED" "$(pm2 --version 2>/dev/null)"

    # Configure autostart
    msg "$MSG_PM2_AUTOSTART"
    # pm2 startup generates a command that needs to be executed
    STARTUP_CMD=$(pm2 startup 2>/dev/null | grep -E "^\s*sudo" | head -1)
    if [ -n "$STARTUP_CMD" ]; then
        eval "$STARTUP_CMD" 2>/dev/null || true
    fi
fi

echo ""
msg "$MSG_BUN_READY"
echo ""
