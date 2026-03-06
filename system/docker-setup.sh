#!/bin/bash

# StackPilot - Docker Setup (Based on NOOBS)
# This script uses the official 'noobs' script approved by the hosting provider
# and adds a layer of log rotation optimization.

set -e

_DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    if [ -n "$_DOCKER_DIR" ] && [ -f "$_DOCKER_DIR/../lib/i18n.sh" ]; then
        source "$_DOCKER_DIR/../lib/i18n.sh"
    elif [ -f /opt/stackpilot/lib/i18n.sh ]; then
        source /opt/stackpilot/lib/i18n.sh
    else
        msg() { printf "%s\n" "$1"; }
        msg_n() { printf "%s" "$1"; }
    fi
fi

msg "$MSG_DOCKER_STEP1"
curl -s https://raw.githubusercontent.com/unkn0w/noobs/main/scripts/chce_dockera.sh | bash

msg "$MSG_DOCKER_STEP2"
# Creating/Updating daemon.json to prevent disk exhaustion
# max-size=10m and max-file=3 ensures Docker logs never exceed 30MB per container.

sudo mkdir -p /etc/docker
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF

msg "$MSG_DOCKER_STEP3"
sudo systemctl restart docker

msg "$MSG_DOCKER_STEP4"
msg "$MSG_DOCKER_CONFIG_HDR"
cat /etc/docker/daemon.json
echo ""
msg "$MSG_DOCKER_LOG_DRV" "$(docker info --format '{{.LoggingDriver}}')"
msg "$MSG_DOCKER_LIVE_RESTORE" "$(docker info --format '{{.LiveRestoreEnabled}}')"

echo ""
msg "$MSG_DOCKER_DONE"
