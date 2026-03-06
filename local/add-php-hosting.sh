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

_APH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_APH_DIR/../lib/i18n.sh"
fi

msg ""
msg "$MSG_APH_HEADER"
msg ""
msg "$MSG_APH_DOMAIN" "$DOMAIN"
msg "$MSG_APH_SERVER" "$SSH_ALIAS"
msg "$MSG_APH_DIR" "$WEB_ROOT"
msg ""

msg "$MSG_APH_MODE"

# Create directory
server_exec "sudo mkdir -p '$WEB_ROOT' && sudo chown -R \$(whoami) '$WEB_ROOT' && sudo chmod -R o+rX '$WEB_ROOT'"

# Install PHP-FPM if missing
if ! server_exec "bash -c 'ls /run/php/php*-fpm.sock >/dev/null 2>&1'"; then
    msg "$MSG_APH_PHP_INSTALLING"
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
    msg "$MSG_APH_PHP_INSTALLED"
else
    msg "$MSG_APH_PHP_ALREADY"
fi

# Install Caddy if missing
if ! server_exec "command -v sp-expose >/dev/null 2>&1"; then
    msg "$MSG_APH_CADDY_INSTALLING"
    server_exec "bash -s" < "$SCRIPT_DIR/../system/caddy-install.sh" || { msg "$MSG_APH_CADDY_FAIL"; exit 1; }
    msg "$MSG_APH_CADDY_INSTALLED"
else
    msg "$MSG_APH_CADDY_ALREADY"
fi

# Configure DNS via Cloudflare if available
if [ -f "$SCRIPT_DIR/dns-add.sh" ]; then
    "$SCRIPT_DIR/dns-add.sh" "$DOMAIN" "$SSH_ALIAS" || msg "$MSG_APH_DNS_MAYBE_EXISTS"
fi

# Configure Caddy with PHP-FPM
server_exec "sp-expose '$DOMAIN' '$WEB_ROOT' php"

msg "$MSG_APH_CADDY_CONFIGURED"

msg ""
msg "$MSG_APH_READY"
msg ""
msg "$MSG_APH_URL" "$DOMAIN"
msg "$MSG_APH_FILES" "$WEB_ROOT"
msg ""
msg "$MSG_APH_TEST" "$SSH_ALIAS" "$WEB_ROOT"
msg "$MSG_APH_VERIFY" "$DOMAIN"
msg ""
