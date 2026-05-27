#!/bin/bash
# StackPilot one-liner installer for: __APP__
# Generated from installers/template.sh — do not edit served files manually.
# Source: https://github.com/jurczykpawel/stackpilot/blob/main/installers/template.sh

set -euo pipefail

APP="__APP__"
BOOTSTRAP_URL="${STACKPILOT_BOOTSTRAP_URL:-https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/system/bootstrap.sh}"
INSTALL_DIR="${STACKPILOT_DIR:-/opt/stackpilot}"

echo ""
echo "=== StackPilot installer: $APP ==="
echo ""

if [ ! -d "$INSTALL_DIR/.git" ]; then
    echo "> StackPilot not found at $INSTALL_DIR — bootstrapping from GitHub"
    curl -fsSL "$BOOTSTRAP_URL" | bash
    echo ""
fi

# If we have a controlling terminal, reattach stdin to it so deploy.sh can
# prompt the user (curl|bash consumes the original stdin). Falls through
# silently in non-interactive contexts (CI, cron) — those should pass --yes.
if { true >/dev/tty; } 2>/dev/null; then
    exec "$INSTALL_DIR/local/deploy.sh" "$APP" "$@" </dev/tty
fi
exec "$INSTALL_DIR/local/deploy.sh" "$APP" "$@"
