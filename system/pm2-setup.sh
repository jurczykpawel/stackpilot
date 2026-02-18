#!/bin/bash

# StackPilot - PM2 Setup
# Installs Node.js, PM2 and configures log rotation & startup.
# Perfect for running lightweight scripts without Docker.
# Author: Paweł (Lazy Engineer)

set -e

echo "--- 1. Checking Node.js ---"
if ! command -v node &> /dev/null; then
    echo "Node.js not found. Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
else
    echo "✅ Node.js already installed ($(node -v))"
fi

echo "--- 2. Installing PM2 ---"
sudo npm install -p pm2@latest -g

echo "--- 3. Configuring PM2 Log Rotation ---"
# This is critical for small VPS to avoid disk exhaustion
pm2 install pm2-logrotate
pm2 set pm2-logrotate:max_size 10M
pm2 set pm2-logrotate:retain 5

echo "--- 4. Configuring Startup ---"
# Generate startup script
STARTUP_CMD=$(pm2 startup | grep "sudo env" || echo "")

if [ -n "$STARTUP_CMD" ]; then
    echo "Running startup command..."
    eval "$STARTUP_CMD"
    pm2 save
else
    echo "⚠️  Startup command could not be generated automatically."
    echo "   Please run 'pm2 startup' manually and follow instructions."
fi

echo "--- Setup Complete ---"
echo "✅ Node.js & PM2 installed."
echo "✅ Log rotation configured (10MB limit)."
echo "💡 Tip: Use 'pm2 start app.js' to run your scripts."
