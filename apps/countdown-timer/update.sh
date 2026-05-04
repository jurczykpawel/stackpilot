#!/bin/bash
# StackPilot - Countdown Timer Update
# Git pull + PHP-FPM reload (required because OPcache validate_timestamps=0
# means PHP-FPM workers won't see new source files until reload).

set -e
set -o pipefail

WEB_ROOT="/var/www/countdown-timer"

if [ ! -d "$WEB_ROOT/.git" ]; then
    echo "Error: $WEB_ROOT is not a git checkout. Did install.sh run?"
    exit 1
fi

echo "--- countdown-timer Update ---"

cd "$WEB_ROOT"
echo "Pulling latest..."
# Run as www-data: the checkout is owned by www-data and modern git
# refuses cross-ownership pulls. sudo -u keeps creds + branch state right.
if [ "$(id -u)" -eq 0 ]; then
    sudo -u www-data git pull --ff-only
else
    git pull --ff-only
fi

# Detect PHP version + reload FPM. With validate_timestamps=0 the workers
# cache compiled bytecode forever; without a reload, the new code is on
# disk but the running pool keeps serving the old version.
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || echo "")
if [ -n "$PHP_VER" ] && systemctl is-active --quiet "php${PHP_VER}-fpm"; then
    echo "Reloading php${PHP_VER}-fpm (OPcache reset)..."
    systemctl reload "php${PHP_VER}-fpm"
fi

echo "Done. countdown-timer updated."
