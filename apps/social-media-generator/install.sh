#!/bin/bash

# StackPilot - Social Media Generator
# Generate brand-consistent social media graphics from HTML templates.
# One text, multiple formats (Instagram, Stories, YouTube).
# https://github.com/jurczykpawel/social-media-generator
# Author: Pawel
#
# IMAGE_SIZE_MB=1000  # Python 3.12 + Playwright/Chromium + FastAPI + deps
#
# WARNING: This app requires at least 2GB RAM!
#     Social Media Generator runs headless Chromium for rendering graphics.
#     On servers with <2GB RAM it may crash or freeze.
#
# Stack: FastAPI + Playwright (Chromium) + PostgreSQL 16
# UI: Web panel with magic link authentication
# API: REST API for programmatic image generation

set -e

APP_NAME="social-media-generator"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8000}
REPO_URL="https://github.com/jurczykpawel/social-media-generator.git"

echo "--- 🎨 Social Media Generator Setup ---"
echo "Generate brand-consistent social media graphics from HTML templates."
echo ""

# Port binding: 127.0.0.1 for security (Caddy proxies)
BIND_ADDR="127.0.0.1:"

# Check available RAM - REQUIRED minimum 2GB!
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 1800 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ERROR: Not enough RAM for Social Media Generator!           ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Your server: ${TOTAL_RAM}MB RAM                             ║"
    echo "║  Required:    2048MB RAM                                     ║"
    echo "║                                                              ║"
    echo "║  This app runs headless Chromium (~1GB RAM).                 ║"
    echo "║  On servers with <2GB RAM it will crash or freeze.           ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "Domain: $DOMAIN"
else
    echo "No domain configured - access via SSH tunnel"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Clone or update repository
if [ -d "$STACK_DIR/repo/.git" ]; then
    echo "Updating repository..."
    cd "$STACK_DIR/repo"
    sudo git pull --quiet
    cd "$STACK_DIR"
else
    echo "Cloning repository..."
    sudo git clone --depth 1 "$REPO_URL" "$STACK_DIR/repo"
fi

# Generate secrets
SECRET_KEY=$(openssl rand -hex 32)
PG_PASS=$(openssl rand -hex 16)

# Generate .env
BASE_URL=""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    BASE_URL="https://$DOMAIN"
fi

cat <<EOF | sudo tee .env > /dev/null
SECRET_KEY=$SECRET_KEY
DATABASE_URL=postgresql://smg:${PG_PASS}@db:5432/smg
BASE_URL=${BASE_URL:-http://localhost:$PORT}
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
EMAIL_FROM=
CREDIT_PRODUCTS={"100-credits": 100, "500-credits": 500, "unlimited": 10000}
POSTGRES_DB=smg
POSTGRES_USER=smg
POSTGRES_PASSWORD=$PG_PASS
EOF

sudo chmod 600 .env
echo "Configuration generated"

# Generate docker-compose.yaml
cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  app:
    build:
      context: ./repo
      dockerfile: Dockerfile
    restart: always
    ports:
      - "${BIND_ADDR}$PORT:8000"
    env_file: .env
    volumes:
      - app_data:/app/data
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 1024M

  db:
    image: postgres:16-alpine
    restart: always
    env_file: .env
    volumes:
      - pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "smg"]
      interval: 2s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 256M

volumes:
  app_data:
  pg_data:
EOF

# Build and start
echo "Building Docker image (this may take a few minutes)..."
sudo docker compose build --quiet 2>/dev/null || sudo docker compose build
sudo docker compose up -d

# Health check - Chromium needs time to start
echo "Waiting for startup (~60-90s, Chromium is loading)..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "Installation failed!"; exit 1; }
else
    for i in $(seq 1 9); do
        sleep 10
        if curl -sf "http://localhost:$PORT/health" > /dev/null 2>&1; then
            echo "Social Media Generator is running (after $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 9 ]; then
            echo "Container did not start within 90s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

echo ""
echo "================================================================"
echo "Social Media Generator installed!"
echo "================================================================"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "Panel: https://$DOMAIN"
    echo "API:   https://$DOMAIN/docs"
else
    echo "Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
    echo "   Panel: http://localhost:$PORT"
    echo "   API:   http://localhost:$PORT/docs"
fi
echo ""
echo "SECRET_KEY saved in: $STACK_DIR/.env"
echo ""
echo "Next steps:"
echo "   1. Configure SMTP in .env (magic link auth requires email)"
echo "   2. Open the panel and register an account (first user = admin)"
echo "   3. Add custom brands in /opt/stacks/$APP_NAME/repo/brands/"
echo ""
echo "API usage example:"
echo "   curl -X POST http://localhost:$PORT/api/generate \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"brand\": \"example\", \"template\": \"quote-card\", \"text\": \"Hello!\"}'"
