#!/bin/bash
# StackPilot - Plunk
# Transactional and marketing email platform backed by AWS SES.
# IMAGE_SIZE_MB=4500
# DB_BUNDLED=true
# AWS SES credentials are required; configure .env before deployment.
set -e
APP_NAME="plunk"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
PORT=${PORT:-3560}
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/stackpilot/plunk.env"
if [ -f "$CONFIG_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a
fi
BIND_ADDR="127.0.0.1:"
[ "${DOMAIN_TYPE:-}" != cytrus ] || BIND_ADDR=""
APP_URL="http://localhost:$PORT"
if [ -n "${DOMAIN:-}" ] && [ "$DOMAIN" != - ]; then
    [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo 'Invalid domain'; exit 1; }
    APP_URL="https://$DOMAIN"
fi
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"
if ! sudo test -f .env; then
    umask 077
    sudo touch .env
    sudo chmod 600 .env
    cat <<ENV | sudo tee .env >/dev/null
DB_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 32)
MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)
AWS_SES_REGION=${AWS_SES_REGION:-}
AWS_SES_ACCESS_KEY_ID=${AWS_SES_ACCESS_KEY_ID:-}
AWS_SES_SECRET_ACCESS_KEY=${AWS_SES_SECRET_ACCESS_KEY:-}
SES_CONFIGURATION_SET=${SES_CONFIGURATION_SET:-plunk-tracking}
DISABLE_SIGNUPS=true
ENV
fi
sudo chmod 600 .env
for key in DB_PASSWORD JWT_SECRET MINIO_ROOT_PASSWORD AWS_SES_REGION AWS_SES_ACCESS_KEY_ID AWS_SES_SECRET_ACCESS_KEY; do
    if ! sudo grep -qE "^${key}=.+" .env; then
        echo "Configure $key in $STACK_DIR/.env, then run deploy.sh plunk again."
        exit 1
    fi
done
# Refresh public URLs while keeping all persisted credentials.
ENV_TMP=$(mktemp)
trap 'rm -f "$ENV_TMP"' EXIT
sudo cat .env | awk '!/^(API_URI|DASHBOARD_URI|LANDING_URI|WIKI_URI|S3_PUBLIC_URL)=/' > "$ENV_TMP"
cat >> "$ENV_TMP" <<ENV
API_URI=$APP_URL/api
DASHBOARD_URI=$APP_URL
LANDING_URI=$APP_URL
WIKI_URI=$APP_URL
S3_PUBLIC_URL=$APP_URL/uploads
ENV
cat "$ENV_TMP" | sudo tee .env >/dev/null
sudo chmod 600 .env
cat <<'NGINX' | sudo tee nginx.conf >/dev/null
resolver 127.0.0.11 valid=5s ipv6=off;
upstream plunk_api { zone plunk_api 64k; server plunk:8080 resolve; }
upstream plunk_web { zone plunk_web 64k; server plunk:3000 resolve; }
upstream plunk_uploads { zone plunk_uploads 64k; server minio:9000 resolve; }
server {
    listen 80;
    server_name _;
    client_max_body_size 40M;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
    location /api/ { proxy_pass http://plunk_api/; }
    location /uploads/ { proxy_pass http://plunk_uploads/uploads/; }
    location / { proxy_pass http://plunk_web; }
}
NGINX
cat <<COMPOSE | sudo tee docker-compose.yaml >/dev/null
services:
  gateway:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "${BIND_ADDR}${PORT}:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      plunk:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1/api/health >/dev/null && wget -qO- http://127.0.0.1/auth/login >/dev/null"]
      interval: 10s
      timeout: 5s
      retries: 12
    deploy:
      resources:
        limits:
          memory: 32M
  plunk:
    image: ghcr.io/useplunk/plunk:${IMAGE_TAG}
    restart: unless-stopped
    env_file: .env
    environment:
      SERVICE: all
      NODE_ENV: production
      DATABASE_URL: postgresql://plunk:\${DB_PASSWORD}@postgres:5432/plunk
      DIRECT_DATABASE_URL: postgresql://plunk:\${DB_PASSWORD}@postgres:5432/plunk
      REDIS_URL: redis://redis:6379
      S3_ENDPOINT: http://minio:9000
      S3_ACCESS_KEY_ID: plunk
      S3_ACCESS_KEY_SECRET: \${MINIO_ROOT_PASSWORD}
      S3_BUCKET: uploads
      S3_FORCE_PATH_STYLE: "true"
      NTFY_URL: http://ntfy/plunk-notifications
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      minio:
        condition: service_started
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:8080/health"]
      interval: 10s
      timeout: 5s
      start_period: 120s
      retries: 18
    deploy:
      resources:
        limits:
          memory: 1024M
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: plunk
      POSTGRES_DB: plunk
      POSTGRES_PASSWORD: \${DB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "plunk"]
      interval: 5s
      timeout: 5s
      retries: 12
    deploy:
      resources:
        limits:
          memory: 192M
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 48mb --maxmemory-policy noeviction
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 12
    deploy:
      resources:
        limits:
          memory: 96M
  minio:
    image: pgsty/minio:RELEASE.2026-08-04T00-00-00Z
    restart: unless-stopped
    command: server /data
    environment:
      MINIO_ROOT_USER: plunk
      MINIO_ROOT_PASSWORD: \${MINIO_ROOT_PASSWORD}
    volumes:
      - minio_data:/data
    deploy:
      resources:
        limits:
          memory: 256M
  ntfy:
    image: binwiederhier/ntfy:latest
    restart: unless-stopped
    command: serve
    deploy:
      resources:
        limits:
          memory: 64M
volumes:
  postgres_data:
  redis_data:
  minio_data:
COMPOSE
sudo docker compose pull
if [ -n "$(sudo docker compose ps --status running -q gateway)" ]; then
    sudo docker compose exec -T gateway nginx -t
    sudo docker compose exec -T gateway nginx -s reload
fi
sudo docker compose up -d --wait --wait-timeout 360
printf '%s\n' "$PORT" | sudo tee "$STACK_DIR/.stackpilot-port" >/dev/null
echo "Plunk ready: $APP_URL/auth/login"
echo 'Signups are closed. Bootstrap the first account in local SSH-tunnel mode; see apps/plunk/README.md.'
echo 'Configure a verified AWS SES sending domain and configuration set before sending email.'
