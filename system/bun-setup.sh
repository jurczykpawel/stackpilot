#!/bin/bash

# Mikrus Toolbox - Bun + PM2 Setup
# Instaluje Bun (runtime) i PM2 (process manager) dla aplikacji Node.js/Next.js
# Author: Paweł (Lazy Engineer)

set -e

echo "--- 🥟 Bun + PM2 Setup ---"

# Sprawdź czy Bun już zainstalowany
if command -v bun &> /dev/null; then
    BUN_VERSION=$(bun --version)
    echo "✅ Bun już zainstalowany: v$BUN_VERSION"
else
    echo "📦 Instaluję Bun..."
    curl -fsSL https://bun.sh/install | bash

    # Dodaj do PATH dla bieżącej sesji
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"

    # Dodaj do .bashrc jeśli nie ma
    if ! grep -q 'BUN_INSTALL' ~/.bashrc 2>/dev/null; then
        echo '' >> ~/.bashrc
        echo '# Bun' >> ~/.bashrc
        echo 'export BUN_INSTALL="$HOME/.bun"' >> ~/.bashrc
        echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> ~/.bashrc
    fi

    echo "✅ Bun zainstalowany: v$(bun --version)"
fi

# Sprawdź czy PM2 już zainstalowany
if command -v pm2 &> /dev/null; then
    PM2_VERSION=$(pm2 --version)
    echo "✅ PM2 już zainstalowany: v$PM2_VERSION"
else
    echo "📦 Instaluję PM2..."
    bun install -g pm2

    echo "✅ PM2 zainstalowany: v$(pm2 --version)"

    # Konfiguruj autostart
    echo "⚙️  Konfiguruję PM2 autostart..."
    # pm2 startup generuje komendę którą trzeba wykonać
    STARTUP_CMD=$(pm2 startup 2>/dev/null | grep -E "^\s*sudo" | head -1)
    if [ -n "$STARTUP_CMD" ]; then
        eval "$STARTUP_CMD" 2>/dev/null || true
    fi
fi

echo ""
echo "✅ Bun + PM2 gotowe!"
echo ""
