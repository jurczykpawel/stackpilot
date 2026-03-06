#!/bin/bash

# StackPilot - Power Tools
# Installs CLI utilities useful for automation (n8n via SSH) and management.
# Includes: yt-dlp, ffmpeg, jq, pup, mc, ncdu.
# Author: Paweł (Lazy Engineer)

set -e

_PT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    if [ -n "$_PT_DIR" ] && [ -f "$_PT_DIR/../lib/i18n.sh" ]; then
        source "$_PT_DIR/../lib/i18n.sh"
    elif [ -f /opt/stackpilot/lib/i18n.sh ]; then
        source /opt/stackpilot/lib/i18n.sh
    else
        msg() { printf "%s\n" "$1"; }
        msg_n() { printf "%s" "$1"; }
    fi
fi

msg "$MSG_PT_HEADER"

# 1. Standard Repos
msg "$MSG_PT_APT"
sudo apt-get update -q
sudo apt-get install -y ffmpeg jq mc ncdu unzip

# 2. yt-dlp (Latest Binary)
msg "$MSG_PT_YTDLP"
sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
sudo chmod a+rx /usr/local/bin/yt-dlp

# 3. pup (HTML Processor - jq for HTML)
msg "$MSG_PT_PUP"
# We download the linux zip
PUP_VERSION="v0.4.0"
curl -L "https://github.com/ericchiang/pup/releases/download/$PUP_VERSION/pup_${PUP_VERSION}_linux_amd64.zip" -o /tmp/pup.zip
unzip -o /tmp/pup.zip -d /tmp
sudo mv /tmp/pup /usr/local/bin/pup
sudo chmod +x /usr/local/bin/pup
rm /tmp/pup.zip

# 4. Rclone (Ensure it's there)
if ! command -v rclone &> /dev/null; then
    msg "$MSG_PT_RCLONE"
    curl https://rclone.org/install.sh | sudo bash
fi

msg "$MSG_PT_DONE_HDR"
msg "$MSG_PT_LOCATIONS"
msg "$MSG_PT_YTDLP_LOC" "$(which yt-dlp)"
msg "$MSG_PT_FFMPEG_LOC" "$(which ffmpeg)"
msg "$MSG_PT_JQ_LOC" "$(which jq)"
msg "$MSG_PT_PUP_LOC" "$(which pup)"
echo ""
msg "$MSG_PT_N8N_TIP"
msg "$MSG_PT_N8N_TIP2"
msg "$MSG_PT_N8N_TIP3"
