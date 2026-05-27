#!/bin/bash
# StackPilot one-liner setup: __NAME__
# Generated from installers/setup-template.sh — do not edit served files manually.
# Bootstraps stackpilot if missing, then runs local/__SCRIPT__.

set -euo pipefail

NAME="__NAME__"
SCRIPT="__SCRIPT__"
BOOTSTRAP_URL="${STACKPILOT_BOOTSTRAP_URL:-https://stackpilot.techskills.academy/install}"
INSTALL_DIR="${STACKPILOT_DIR:-/opt/stackpilot}"

echo ""
echo "=== StackPilot setup: $NAME ==="
echo ""

if [ ! -d "$INSTALL_DIR/.git" ]; then
    echo "> StackPilot not found at $INSTALL_DIR — bootstrapping"
    curl -fsSL "$BOOTSTRAP_URL" | bash
    echo ""
fi

if { true >/dev/tty; } 2>/dev/null; then
    exec "$INSTALL_DIR/local/$SCRIPT" "$@" </dev/tty
fi
exec "$INSTALL_DIR/local/$SCRIPT" "$@"
