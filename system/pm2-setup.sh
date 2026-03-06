#!/bin/bash

# StackPilot - PM2 Setup
# Installs Node.js, PM2 and configures log rotation & startup.
# Perfect for running lightweight scripts without Docker.
# Author: Paweł (Lazy Engineer)

set -e

_PM2S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    if [ -n "$_PM2S_DIR" ] && [ -f "$_PM2S_DIR/../lib/i18n.sh" ]; then
        source "$_PM2S_DIR/../lib/i18n.sh"
    elif [ -f /opt/stackpilot/lib/i18n.sh ]; then
        source /opt/stackpilot/lib/i18n.sh
    else
        msg() { printf "%s\n" "$1"; }
        msg_n() { printf "%s" "$1"; }
    fi
fi

msg "$MSG_PM2S_STEP1"
if ! command -v node &> /dev/null; then
    msg "$MSG_PM2S_NODE_MISSING"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
else
    msg "$MSG_PM2S_NODE_OK" "$(node -v)"
fi

msg "$MSG_PM2S_STEP2"
sudo npm install -p pm2@latest -g

msg "$MSG_PM2S_STEP3"
# This is critical for small VPS to avoid disk exhaustion
pm2 install pm2-logrotate
pm2 set pm2-logrotate:max_size 10M
pm2 set pm2-logrotate:retain 5

msg "$MSG_PM2S_STEP4"
# Generate startup script
STARTUP_CMD=$(pm2 startup | grep "sudo env" || echo "")

if [ -n "$STARTUP_CMD" ]; then
    msg "$MSG_PM2S_STARTUP_RUN"
    eval "$STARTUP_CMD"
    pm2 save
else
    msg "$MSG_PM2S_STARTUP_WARN"
    msg "$MSG_PM2S_STARTUP_HINT"
fi

msg "$MSG_PM2S_DONE_HDR"
msg "$MSG_PM2S_DONE_NODE"
msg "$MSG_PM2S_DONE_LOG"
msg "$MSG_PM2S_TIP"
