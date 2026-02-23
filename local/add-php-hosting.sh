#!/bin/bash

# StackPilot - Add PHP Hosting
# Adds PHP hosting via Caddy + PHP-FPM.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/add-php-hosting.sh DOMAIN [SSH_ALIAS] [DIRECTORY]
#
# Examples:
#   ./local/add-php-hosting.sh app.example.com
#   ./local/add-php-hosting.sh app.example.com vps /var/www/app

set -e

DOMAIN="$1"
SSH_ALIAS="${2:-vps}"
WEB_ROOT="${3:-/var/www/php}"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 DOMAIN [SSH_ALIAS] [DIRECTORY]"
    echo ""
    echo "Examples:"
    echo "  $0 app.example.com vps                        # Cloudflare + Caddy + PHP-FPM"
    echo "  $0 app.example.com vps /var/www/app            # Custom directory"
    echo ""
    echo "Defaults:"
    echo "  SSH_ALIAS: vps"
    echo "  DIRECTORY: /var/www/php"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

echo ""
echo "Adding PHP Hosting"
echo ""
echo "   Domain:    $DOMAIN"
echo "   Server:    $SSH_ALIAS"
echo "   Directory: $WEB_ROOT"
echo ""

echo "Mode: Caddy + PHP-FPM"

# Create directory
server_exec "sudo mkdir -p '$WEB_ROOT' && sudo chown -R \$(whoami) '$WEB_ROOT' && sudo chmod -R o+rX '$WEB_ROOT'"

# Install PHP-FPM if missing
if ! server_exec "bash -c 'ls /run/php/php*-fpm.sock >/dev/null 2>&1'"; then
    echo "Installing PHP-FPM..."
    server_exec "bash -s" << 'PHPEOF'
set -e
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || echo "")
if [ -z "$PHP_VER" ]; then
    sudo apt-get update -qq && sudo apt-get install -y -qq php-fpm 2>&1
else
    sudo apt-get update -qq && sudo apt-get install -y -qq "php${PHP_VER}-fpm" 2>&1
fi
PHP_SVC=$(systemctl list-unit-files | grep 'php.*fpm' | awk '{print $1}' | head -1)
if [ -n "$PHP_SVC" ]; then
    sudo systemctl enable "$PHP_SVC"
    sudo systemctl start "$PHP_SVC"
fi
PHPEOF
    echo "PHP-FPM installed"
else
    echo "PHP-FPM already installed"
fi

# Install Caddy if missing
if ! server_exec "command -v sp-expose >/dev/null 2>&1"; then
    echo "Installing Caddy + sp-expose..."
    server_exec "bash -s" < "$SCRIPT_DIR/../system/caddy-install.sh" || { echo "Caddy install failed"; exit 1; }
    echo "Caddy installed"
else
    echo "Caddy already installed"
fi

# Configure DNS via Cloudflare if available
if [ -f "$SCRIPT_DIR/dns-add.sh" ]; then
    "$SCRIPT_DIR/dns-add.sh" "$DOMAIN" "$SSH_ALIAS" || echo "DNS may already exist"
fi

# Configure Caddy with PHP-FPM
server_exec "sp-expose '$DOMAIN' '$WEB_ROOT' php"

echo "Caddy + PHP-FPM configured"

echo ""
echo "PHP Hosting ready!"
echo ""
echo "URL: https://$DOMAIN"
echo "Files: $WEB_ROOT"
echo ""
echo "Test:   ssh $SSH_ALIAS \"echo '<?php echo phpinfo();' > $WEB_ROOT/info.php\""
echo "Verify: curl https://$DOMAIN/info.php"
echo ""
