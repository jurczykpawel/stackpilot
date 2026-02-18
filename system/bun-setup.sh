#!/bin/bash

# StackPilot - Bun + PM2 Setup
# Installs Bun (runtime) and PM2 (process manager) for Node.js/Next.js apps
# Author: Paweł (Lazy Engineer)

set -e

echo "--- 🥟 Bun + PM2 Setup ---"

# Check if Bun is already installed
if command -v bun &> /dev/null; then
    BUN_VERSION=$(bun --version)
    echo "✅ Bun already installed: v$BUN_VERSION"
else
    echo "📦 Installing Bun..."
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

    echo "✅ Bun installed: v$(bun --version)"
fi

# Check if PM2 is already installed
if command -v pm2 &> /dev/null; then
    PM2_VERSION=$(pm2 --version)
    echo "✅ PM2 already installed: v$PM2_VERSION"
else
    echo "📦 Installing PM2..."
    bun install -g pm2

    echo "✅ PM2 installed: v$(pm2 --version)"

    # Configure autostart
    echo "⚙️  Configuring PM2 autostart..."
    # pm2 startup generates a command that needs to be executed
    STARTUP_CMD=$(pm2 startup 2>/dev/null | grep -E "^\s*sudo" | head -1)
    if [ -n "$STARTUP_CMD" ]; then
        eval "$STARTUP_CMD" 2>/dev/null || true
    fi
fi

echo ""
echo "✅ Bun + PM2 ready!"
echo ""
