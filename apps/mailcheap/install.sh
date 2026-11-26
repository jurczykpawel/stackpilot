#!/bin/bash
# StackPilot - MailCheap
# Newsletter platform with contacts, archives and API/MCP.
# IMAGE_SIZE_MB=1600
# DB_BUNDLED=true
# ONELINER=false
set -e
APP_NAME="mailcheap"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
PORT=${PORT:-3000}
IMAGE="${MAILCHEAP_IMAGE:-stackpilot/mailcheap:f8b0b7fbc93ce09c1221c8bdc073b729c0efe237}"

if [ -n "${BUILD_FILE:-}" ]; then
    [ -f "$BUILD_FILE" ] || { echo 'Error: BUILD_FILE does not exist.' >&2; exit 1; }
    sudo docker load -i "$BUILD_FILE"
fi
if ! sudo docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Error: build MailCheap locally with apps/mailcheap/build.sh, then sync and load its image on this server (see apps/mailcheap/README.md)."
    exit 1
fi
BIND_ADDR="127.0.0.1:"
[ "${DOMAIN_TYPE:-}" != cytrus ] || BIND_ADDR=""
APP_URL="http://localhost:$PORT"
if [ -n "${DOMAIN:-}" ] && [ "$DOMAIN" != '-' ]; then
    APP_URL="https://$DOMAIN"
fi
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"
if [ ! -f .env ]; then
    sudo install -m 600 /dev/null .env
    cat <<ENV | sudo tee .env >/dev/null
MONGO_ROOT_PASSWORD=$(openssl rand -hex 24)
BETTER_AUTH_SECRET=$(openssl rand -hex 32)
SUPPRESSION_HASH_KEY=$(openssl rand -hex 32)
CREDENTIALS_ENCRYPTION_KEY=$(openssl rand -base64 32)
CRON_SECRET=$(openssl rand -hex 32)
NODE_ENV=production
MAILCHEAP_CLOUD=false
SENDING_ENABLED=false
ADMIN_EMAILS=
ALLOWED_EMAILS=
EMAIL_FROM=
# Sign-in requires RESEND_API_KEY, or the SES/PostShiba variables from upstream .env.example.
# Campaign delivery additionally requires QSTASH_TOKEN and both QSTASH signing keys.
ENV
fi
sudo chmod 600 .env
for KEY in MONGO_ROOT_PASSWORD BETTER_AUTH_SECRET SUPPRESSION_HASH_KEY CREDENTIALS_ENCRYPTION_KEY CRON_SECRET; do
    VALUE=$(sudo awk -v key="$KEY" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' .env)
    if [ "${#VALUE}" -lt 32 ]; then
        echo "Error: $KEY is missing or too short in $STACK_DIR/.env. Restore the existing configuration; deployed secrets must remain stable."
        exit 1
    fi
done
cat <<COMPOSE | sudo tee docker-compose.yaml >/dev/null
services:
  mailcheap:
    image: "$IMAGE"
    pull_policy: never
    restart: unless-stopped
    env_file: .env
    environment:
      APP_URL: "$APP_URL"
      PORT: "3000"
      HOSTNAME: "0.0.0.0"
      MONGODB_URI: "mongodb://root:\${MONGO_ROOT_PASSWORD}@mongo:27017/mailcheap?authSource=admin"
    ports:
      - "${BIND_ADDR}${PORT}:3000"
    depends_on:
      mongo:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/signin').then(async r=>process.exit(r.ok&&(await r.text()).includes('Sign in to MailCheap')?0:1)).catch(()=>process.exit(1))"]
      interval: 5s
      timeout: 5s
      start_period: 30s
      retries: 12
    deploy:
      resources:
        limits:
          memory: 512M
  mongo:
    image: mongo:7.0.45
    restart: unless-stopped
    environment:
      MONGO_INITDB_ROOT_USERNAME: root
      MONGO_INITDB_ROOT_PASSWORD: \${MONGO_ROOT_PASSWORD}
    command: ["mongod", "--wiredTigerCacheSizeGB", "0.25"]
    volumes:
      - mongo-data:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "quit(db.adminCommand('ping').ok ? 0 : 1)"]
      interval: 5s
      timeout: 10s
      retries: 20
    deploy:
      resources:
        limits:
          memory: 512M
volumes:
  mongo-data:
COMPOSE
sudo docker compose up -d --wait --wait-timeout 180
if ! curl -fsS --max-time 10 "http://127.0.0.1:$PORT/api/health" >/dev/null; then
    echo "Error: MailCheap health check failed."
    exit 1
fi
if ! SIGNIN_HTML=$(curl -fsS --max-time 10 "http://127.0.0.1:$PORT/signin") || [[ "$SIGNIN_HTML" != *'Sign in to MailCheap'* ]]; then
    echo "Error: MailCheap sign-in page is not ready."
    exit 1
fi
printf '%s\n' "$PORT" | sudo tee "$STACK_DIR/.stackpilot-port" >/dev/null
echo "MailCheap installed: $APP_URL/signin"
echo "Configure ADMIN_EMAILS, EMAIL_FROM and your sign-in email provider in $STACK_DIR/.env, then run docker compose up -d."
echo "Before campaigns, configure SES/PostShiba and QStash using the upstream self-hosting guide; SENDING_ENABLED stays false until you enable it."
