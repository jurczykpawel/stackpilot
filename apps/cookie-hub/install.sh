#!/bin/bash

# StackPilot - Cookie Hub (Klaro!)
# Centralized Cookie Consent Manager for all your domains.
# Supports both Docker (Cytrus) and Caddy (Cloudflare) modes.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=50  # nginx:alpine (only for Docker mode)

set -e

APP_NAME="cookie-hub"
echo "--- Cookie Hub Setup (Klaro!) ---"
echo "Centralized server for Cookie Consent scripts."

# Required: DOMAIN
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "-" ]; then
    echo "Brak wymaganej zmiennej: DOMAIN"
    echo "   Uzycie: DOMAIN=assets.example.com ./install.sh"
    exit 1
fi
echo "Domena: $DOMAIN"

# Detect domain type: Cytrus (*.byst.re, *.mikr.us) vs Cloudflare
is_cytrus_domain() {
    case "$1" in
        *.byst.re|*.mikr.us|*.srv24.pl|*.vxm.pl) return 0 ;;
        *) return 1 ;;
    esac
}

# Prerequisites: npm
if ! command -v npm &> /dev/null; then
    echo "NPM not found. Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# Determine paths based on mode
if is_cytrus_domain "$DOMAIN"; then
    echo "Tryb: Cytrus (Docker + nginx)"
    STACK_DIR="/opt/stacks/$APP_NAME"
    PUBLIC_DIR="$STACK_DIR/public"
    PORT="${PORT:-8091}"
else
    echo "Tryb: Cloudflare (Caddy file_server)"
    STACK_DIR="/var/www/$APP_NAME"
    PUBLIC_DIR="$STACK_DIR"
fi

# Setup directory
sudo mkdir -p "$PUBLIC_DIR"
cd "$STACK_DIR"

# Install Klaro via NPM (if not already installed)
if [ ! -f "$PUBLIC_DIR/klaro.js" ]; then
    echo "Installing Klaro via NPM..."

    # Create temp directory for npm
    TEMP_NPM=$(mktemp -d)
    cd "$TEMP_NPM"
    npm init -y > /dev/null
    npm install klaro

    # Copy dist files to public
    sudo cp node_modules/klaro/dist/klaro.js "$PUBLIC_DIR/"
    sudo cp node_modules/klaro/dist/klaro.css "$PUBLIC_DIR/"

    # Cleanup
    cd /
    rm -rf "$TEMP_NPM"
fi

# Create config template if not exists
if [ ! -f "$PUBLIC_DIR/config.js" ]; then
    echo "Generating default config.js..."
    cat <<'CONFIGJS' | sudo tee "$PUBLIC_DIR/config.js" > /dev/null
// Klaro Configuration - Centralized
// Edit this file to add/remove services across ALL your sites.

var klaroConfig = {
    elementID: 'klaro',
    storageMethod: 'cookie',
    cookieName: 'mikrus_consent',
    cookieExpiresAfterDays: 365,
    default: false,
    mustConsent: false,
    acceptAll: true,
    hideDeclineAll: false,
    hideLearnMore: false,
    lang: 'pl',

    translations: {
        pl: {
            consentModal: {
                title: 'Szanujemy Twoja prywatnosc',
                description: 'Uzywamy plikow cookie i innych technologii, aby zapewnic najlepsza jakosc korzystania z naszej strony.'
            },
            consentNotice: {
                description: 'Uzywamy plikow cookie do analizy ruchu i personalizacji tresci.',
                learnMore: 'Dostosuj zgody'
            },
            purposes: {
                analytics: 'Analityka',
                security: 'Bezpieczenstwo',
                marketing: 'Marketing'
            },
            ok: 'Zaakceptuj wszystko',
            save: 'Zapisz wybrane',
            decline: 'Odrzuc'
        }
    },

    services: [
        {
            name: 'googleAnalytics',
            default: true,
            title: 'Google Analytics / Umami',
            purposes: ['analytics'],
            cookies: [[/^_ga/], [/^_gid/], [/^umami/]]
        }
    ]
};
CONFIGJS
fi

# Mode-specific setup
if is_cytrus_domain "$DOMAIN"; then
    # === CYTRUS MODE: Docker + nginx ===
    cd "$STACK_DIR"

    # Add CORS headers via nginx config
    cat <<'NGINXCONF' | sudo tee "$STACK_DIR/nginx.conf" > /dev/null
server {
    listen 80;
    root /usr/share/nginx/html;

    location / {
        add_header Access-Control-Allow-Origin "*";
        try_files $uri $uri/ =404;
    }
}
NGINXCONF

    cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  cookie-hub:
    image: nginx:alpine
    restart: always
    ports:
      - "$PORT:80"
    volumes:
      - ./public:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    deploy:
      resources:
        limits:
          memory: 32M

EOF

    sudo docker compose up -d

    sleep 3
    if curl -sf "http://localhost:$PORT/klaro.js" > /dev/null 2>&1; then
        echo "Cookie Hub dziala na porcie $PORT"
    else
        echo "Blad uruchomienia!"; sudo docker compose logs --tail 10; exit 1
    fi

    # Zapisz port dla deploy.sh (do konfiguracji domeny)
    echo "$PORT" > /tmp/app_port

    echo ""
    echo "Cookie Hub started!"
    echo "   Port: $PORT"
    echo "   Config: $PUBLIC_DIR/config.js"

else
    # === CLOUDFLARE MODE: Caddy ===
    # Caddy will be configured by deploy.sh via sp-expose
    echo "$PUBLIC_DIR" > /tmp/cookiehub_webroot

    echo ""
    echo "Cookie Hub installed!"
    echo "   Config: $PUBLIC_DIR/config.js"
fi

echo ""
echo "HOW TO USE:"
echo "Paste this in <head> of every website:"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "<link rel=\"stylesheet\" href=\"https://$DOMAIN/klaro.css\" />"
    echo "<script defer src=\"https://$DOMAIN/config.js\"></script>"
    echo "<script defer src=\"https://$DOMAIN/klaro.js\"></script>"
else
    echo "(domena zostanie wyświetlona po konfiguracji)"
fi
