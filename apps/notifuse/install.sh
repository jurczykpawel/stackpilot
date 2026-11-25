#!/bin/bash
# StackPilot - Notifuse
# Email marketing and transactional email with a dedicated database.
# IMAGE_SIZE_MB=900
# DB_BUNDLED=true
# https://docs.notifuse.com/self-hosting/installation
set -e

APP_NAME="notifuse"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
PORT=${PORT:-8081}
IMAGE_TAG="${IMAGE_TAG:-v42.1}"

if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi
if [ -n "${DOMAIN:-}" ] && [ "$DOMAIN" != "-" ]; then
    API_ENDPOINT="https://$DOMAIN"
else
    API_ENDPOINT="http://localhost:$PORT"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"
if [ -f .env ]; then
    if ! sudo grep -qE '^SECRET_KEY=.+' .env || ! sudo grep -qE '^DB_PASSWORD=.+' .env; then
        echo 'Existing .env is incomplete; restore SECRET_KEY and DB_PASSWORD before redeploying.' >&2
        exit 1
    fi
else
    # Set restrictive permissions before writing credentials.
    sudo touch .env
    sudo chmod 600 .env
    cat <<ENV | sudo tee .env >/dev/null
SECRET_KEY=$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -hex 24)
ENV
fi
sudo chmod 600 .env

cat <<COMPOSE | sudo tee docker-compose.yaml >/dev/null
services:
  notifuse:
    image: notifuse/notifuse:${IMAGE_TAG}
    restart: unless-stopped
    ports:
      - "${BIND_ADDR}${PORT}:8080"
    env_file: .env
    environment:
      SERVER_HOST: 0.0.0.0
      SERVER_PORT: "8080"
      ENVIRONMENT: production
      DB_HOST: postgres
      DB_PORT: "5432"
      DB_USER: postgres
      DB_PASSWORD: \${DB_PASSWORD:?DB_PASSWORD required}
      DB_PREFIX: notifuse
      DB_NAME: notifuse_system
      DB_SSLMODE: disable
      SECRET_KEY: \${SECRET_KEY:?SECRET_KEY required}
      API_ENDPOINT: "${API_ENDPOINT}"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - notifuse-data:/app/data
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/healthz"]
      interval: 5s
      timeout: 5s
      start_period: 30s
      retries: 12
    deploy:
      resources:
        limits:
          memory: 512M
  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: \${DB_PASSWORD:?DB_PASSWORD required}
      POSTGRES_DB: postgres
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 5s
      timeout: 5s
      retries: 12
    deploy:
      resources:
        limits:
          memory: 256M
volumes:
  postgres-data:
  notifuse-data:
COMPOSE

sudo docker compose up -d --wait --wait-timeout 180
printf '%s\n' "$PORT" | sudo tee "$STACK_DIR/.stackpilot-port" >/dev/null
curl --fail --silent --show-error --max-time 10 "http://localhost:$PORT/healthz" >/dev/null
printf 'Notifuse is ready. Open %s/console to complete the setup wizard (admin email and SMTP).\n' "$API_ENDPOINT"
echo 'Keep .env and both data volumes in backups. Configure sending providers in the console.'
