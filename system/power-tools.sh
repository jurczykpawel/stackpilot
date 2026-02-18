#!/bin/bash

# Mikrus Toolbox - Power Tools
# Installs CLI utilities useful for automation (n8n via SSH) and management.
# Includes: yt-dlp, ffmpeg, jq, pup, mc, ncdu.
# Author: Paweł (Lazy Engineer)

set -e

echo "--- 🛠️  Installing Power Tools ---"

# 1. Standard Repos
echo "Installing APT packages (ffmpeg, jq, mc, ncdu)..."
sudo apt-get update -q
sudo apt-get install -y ffmpeg jq mc ncdu unzip

# 2. yt-dlp (Latest Binary)
echo "Installing yt-dlp (Latest)..."
sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
sudo chmod a+rx /usr/local/bin/yt-dlp

# 3. pup (HTML Processor - jq for HTML)
echo "Installing pup..."
# We download the linux zip
PUP_VERSION="v0.4.0"
curl -L "https://github.com/ericchiang/pup/releases/download/$PUP_VERSION/pup_${PUP_VERSION}_linux_amd64.zip" -o /tmp/pup.zip
unzip -o /tmp/pup.zip -d /tmp
sudo mv /tmp/pup /usr/local/bin/pup
sudo chmod +x /usr/local/bin/pup
rm /tmp/pup.zip

# 4. Rclone (Ensure it's there)
if ! command -v rclone &> /dev/null; then
    echo "Installing rclone..."
    curl https://rclone.org/install.sh | sudo bash
fi

echo "--- ✅ Installation Complete ---"
echo "Binary Locations:"
echo " - yt-dlp:  $(which yt-dlp)"
echo " - ffmpeg:  $(which ffmpeg)"
echo " - jq:      $(which jq)"
echo " - pup:     $(which pup)"
echo ""
echo "💡 Usage in n8n:"
echo "   Use 'Execute Command' node with SSH to localhost."
echo "   Command: 'yt-dlp https://youtube.com/watch?v=...' "
