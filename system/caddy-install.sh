#!/bin/bash

# Mikrus Toolbox - Caddy Server & Helper Tool
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

echo "--- 2. Installing 'mikrus-expose' Helper Tool ---"

# Creating a lazy wrapper script to add domains easily
cat <<'EOF' | sudo tee /usr/local/bin/mikrus-expose > /dev/null
#!/bin/bash
# Usage: mikrus-expose <domain> <port_or_path> [mode]
# Modes:
#   proxy (default) - reverse_proxy localhost:PORT
#   static          - file_server from PATH
#
# Examples:
#   mikrus-expose n8n.example.pl 5678              # proxy mode
#   mikrus-expose static.example.pl /var/www/app static  # static mode

DOMAIN=$1
PORT_OR_PATH=$2
MODE="${3:-proxy}"
CADDYFILE="/etc/caddy/Caddyfile"

if [ -z "$DOMAIN" ] || [ -z "$PORT_OR_PATH" ]; then
    echo "Usage: mikrus-expose <domain> <port_or_path> [mode]"
    echo ""
    echo "Modes:"
    echo "  proxy  - reverse_proxy localhost:PORT (default)"
    echo "  static - file_server from PATH"
    echo ""
    echo "Examples:"
    echo "  mikrus-expose n8n.example.pl 5678"
    echo "  mikrus-expose static.example.pl /var/www/app static"
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

# Check if domain already exists to avoid duplicates
if grep -q "$DOMAIN" "$CADDYFILE"; then
    echo "⚠️  Domain $DOMAIN already exists in Caddyfile. Please edit manually."
    exit 1
fi

if [ "$MODE" = "static" ]; then
    echo "🚀 Exposing $DOMAIN -> $PORT_OR_PATH (static files)"
    cat <<CONFIG | sudo tee -a "$CADDYFILE"

$DOMAIN {
    root * $PORT_OR_PATH
    file_server
    header Access-Control-Allow-Origin "*"
}
CONFIG
else
    echo "🚀 Exposing $DOMAIN -> localhost:$PORT_OR_PATH (reverse proxy)"
    cat <<CONFIG | sudo tee -a "$CADDYFILE"

$DOMAIN {
    reverse_proxy localhost:$PORT_OR_PATH
}
CONFIG
fi

# Reload Caddy to apply changes (zero downtime)
sudo systemctl reload caddy

echo "✅ Done! Your site should be live at https://$DOMAIN"
EOF

# Make it executable
sudo chmod +x /usr/local/bin/mikrus-expose

echo "--- Setup Complete ---"
echo "✅ Caddy is running."
echo "✅ 'mikrus-expose' tool installed."
echo "   Usage: mikrus-expose app.domain.com 5000"
