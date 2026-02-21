#!/bin/bash

# StackPilot - Caddy Server & Helper Tool
# Installs Caddy (Modern Reverse Proxy) and a CLI helper for instant HTTPS.
# Author: Paweł (Lazy Engineer)

set -e

echo "--- 1. Installing Caddy (Official Repo) ---"

# Prerequisites
sudo apt install -y -q debian-keyring debian-archive-keyring apt-transport-https curl

# Add Key & Repo
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null

# Install
sudo apt update
sudo apt install caddy -y

echo "--- 2. Installing 'sp-expose' Helper Tool ---"

# Creating a lazy wrapper script to add domains easily
cat <<'EOF' | sudo tee /usr/local/bin/sp-expose > /dev/null
#!/bin/bash
# Usage: sp-expose <domain> <port_or_path> [mode] [--cloudflare]
# Modes:
#   proxy (default) - reverse_proxy localhost:PORT
#   static          - file_server from PATH
#   php             - php_fastcgi + file_server from PATH
#
# Flags:
#   --cloudflare    - HTTP-only (SSL terminates at Cloudflare, prevents redirect loop)
#
# Examples:
#   sp-expose n8n.example.pl 5678                         # proxy mode
#   sp-expose static.example.pl /var/www/app static       # static mode
#   sp-expose app.example.pl /var/www/app php             # PHP + static files
#   sp-expose app.example.pl 5678 proxy --cloudflare      # behind Cloudflare

DOMAIN=$1
PORT_OR_PATH=$2
MODE="${3:-proxy}"
CLOUDFLARE=false
CADDYFILE="/etc/caddy/Caddyfile"

# Parse --cloudflare from any position
for arg in "$@"; do
    if [ "$arg" = "--cloudflare" ]; then
        CLOUDFLARE=true
    fi
done
# If mode got --cloudflare, reset to default
if [ "$MODE" = "--cloudflare" ]; then
    MODE="proxy"
fi

if [ -z "$DOMAIN" ] || [ -z "$PORT_OR_PATH" ]; then
    echo "Usage: sp-expose <domain> <port_or_path> [mode] [--cloudflare]"
    echo ""
    echo "Modes:"
    echo "  proxy  - reverse_proxy localhost:PORT (default)"
    echo "  static - file_server from PATH"
    echo ""
    echo "Flags:"
    echo "  --cloudflare - HTTP-only mode (Cloudflare Flexible SSL)"
    echo ""
    echo "Examples:"
    echo "  sp-expose n8n.example.pl 5678"
    echo "  sp-expose static.example.pl /var/www/app static"
    echo "  sp-expose app.example.pl 5678 proxy --cloudflare"
    exit 1
fi

# Validate domain (prevent Caddyfile injection)
if ! echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'; then
    echo "❌ Invalid domain: $DOMAIN (only letters, numbers, dots, dashes allowed)"
    exit 1
fi

# Validate port (proxy mode) or path (static mode)
if [ "$MODE" = "proxy" ]; then
    if ! echo "$PORT_OR_PATH" | grep -qE '^[0-9]+$'; then
        echo "❌ Invalid port: $PORT_OR_PATH (must be a number)"
        exit 1
    fi
else
    if ! echo "$PORT_OR_PATH" | grep -qE '^/[a-zA-Z0-9/_.-]+$'; then
        echo "❌ Invalid path: $PORT_OR_PATH (must be an absolute path with safe characters)"
        exit 1
    fi
fi

# Determine site address: http:// prefix for Cloudflare Flexible SSL (prevents redirect loop)
SITE_ADDR="$DOMAIN"
if [ "$CLOUDFLARE" = true ]; then
    SITE_ADDR="http://$DOMAIN"
fi

# Check if domain already exists to avoid duplicates
if grep -q "$DOMAIN" "$CADDYFILE"; then
    echo "⚠️  Domain $DOMAIN already exists in Caddyfile. Please edit manually."
    exit 1
fi

if [ "$MODE" = "php" ]; then
    PHP_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)
    if [ -z "$PHP_SOCK" ]; then
        echo "❌ PHP-FPM socket not found. Install php-fpm first."
        exit 1
    fi
    echo "🚀 Exposing $DOMAIN -> $PORT_OR_PATH (PHP + static files)"
    cat <<CONFIG | sudo tee -a "$CADDYFILE"

$SITE_ADDR {
    root * $PORT_OR_PATH
    php_fastcgi unix/$PHP_SOCK
    file_server
}
CONFIG
elif [ "$MODE" = "static" ]; then
    echo "🚀 Exposing $DOMAIN -> $PORT_OR_PATH (static files)"
    cat <<CONFIG | sudo tee -a "$CADDYFILE"

$SITE_ADDR {
    root * $PORT_OR_PATH
    file_server
    header Access-Control-Allow-Origin "*"
}
CONFIG
else
    echo "🚀 Exposing $DOMAIN -> localhost:$PORT_OR_PATH (reverse proxy)"
    cat <<CONFIG | sudo tee -a "$CADDYFILE"

$SITE_ADDR {
    reverse_proxy localhost:$PORT_OR_PATH
}
CONFIG
fi

# Ensure Caddy is running and reload
if ! systemctl is-active --quiet caddy; then
    sudo systemctl start caddy
    sudo systemctl enable caddy 2>/dev/null
else
    sudo systemctl reload caddy
fi

echo "✅ Done! Your site should be live at https://$DOMAIN"
EOF

# Make it executable
sudo chmod +x /usr/local/bin/sp-expose

echo "--- Setup Complete ---"
echo "✅ Caddy is running."
echo "✅ 'sp-expose' tool installed."
echo "   Usage: sp-expose app.domain.com 5000"
