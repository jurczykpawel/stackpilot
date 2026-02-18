#!/bin/bash

# Mikrus Toolbox - Docker Setup (Based on NOOBS)
# This script uses the official 'noobs' script approved by Mikrus creators
# and adds a layer of log rotation optimization.

set -e

echo "--- 1. Running official NOOBS Docker installation ---"
curl -s https://raw.githubusercontent.com/unkn0w/noobs/main/scripts/chce_dockera.sh | bash

echo "--- 2. Applying Mikrus-specific optimizations (Log Rotation) ---"
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

echo "--- 3. Restarting Docker to apply changes ---"
sudo systemctl restart docker

echo "--- 4. Weryfikacja ustawień ---"
echo "Konfiguracja Docker (/etc/docker/daemon.json):"
cat /etc/docker/daemon.json
echo ""
echo "Logging Driver: $(docker info --format '{{.LoggingDriver}}')"
echo "Live Restore: $(docker info --format '{{.LiveRestoreEnabled}}')"

echo ""
echo "✅ Docker is installed (via NOOBS) and optimized for Mikrus!"
