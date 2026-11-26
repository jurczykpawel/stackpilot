#!/bin/bash

# StackPilot - Docker Setup
# Uses the vendor installer on Debian and the provider installer on Ubuntu.

set -e
set -o pipefail

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

install_docker_for_distribution() {
    local distribution="$1"
    if [ "$distribution" = debian ]; then
        local installer status=0
        installer=$(mktemp)
        if ! curl -fsSL https://get.docker.com -o "$installer"; then
            rm "$installer"
            return 1
        fi
        # get.docker.com treats any non-empty DRY_RUN, "false" included, as a dry run
        (unset DRY_RUN; bash "$installer") || status=$?
        rm "$installer"
        return "$status"
    fi
    curl -fsSL https://raw.githubusercontent.com/unkn0w/noobs/main/scripts/chce_dockera.sh | bash
}

docker_setup_main() {
    msg "$MSG_DOCKER_STEP1"
    local distribution
    distribution="$(. /etc/os-release; printf '%s' "$ID")"
    install_docker_for_distribution "$distribution"

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
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    docker_setup_main "$@"
fi
