#!/bin/bash

# StackPilot - Add Static Hosting
# Dodaje publiczny hosting plików statycznych.
# Używa nginx w Dockerze dla Cytrus lub Caddy file_server dla Cloudflare.
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   ./local/add-static-hosting.sh DOMENA [SSH_ALIAS] [KATALOG] [PORT]
#
# Przykłady:
#   ./local/add-static-hosting.sh static.byst.re
#   ./local/add-static-hosting.sh static.byst.re mikrus /var/www/public 8096
#   ./local/add-static-hosting.sh cdn.example.com mikrus /var/www/assets 8097

set -e

DOMAIN="$1"
SSH_ALIAS="${2:-mikrus}"
WEB_ROOT="${3:-/var/www/public}"
PORT="${4:-8096}"

if [ -z "$DOMAIN" ]; then
    echo "Użycie: $0 DOMENA [SSH_ALIAS] [KATALOG] [PORT]"
    echo ""
    echo "Przykłady:"
    echo "  $0 static.byst.re                              # Cytrus, domyślne ustawienia"
    echo "  $0 cdn.example.com mikrus                       # Cloudflare"
    echo "  $0 assets.byst.re mikrus /var/www/assets 8097  # Własny katalog i port"
    echo ""
    echo "Domyślne:"
    echo "  SSH_ALIAS: mikrus"
    echo "  KATALOG:   /var/www/public"
    echo "  PORT:      8096"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

echo ""
echo "🌍 Dodawanie Static Hosting"
echo ""
echo "   Domena:  $DOMAIN"
echo "   Serwer:  $SSH_ALIAS"
echo "   Katalog: $WEB_ROOT"
echo "   Port:    $PORT"
echo ""

# Wykryj typ domeny
is_cytrus_domain() {
    case "$1" in
        *.byst.re|*.bieda.it|*.toadres.pl|*.tojest.dev|*.mikr.us|*.srv24.pl|*.vxm.pl) return 0 ;;
        *) return 1 ;;
    esac
}

if is_cytrus_domain "$DOMAIN"; then
    echo "🍊 Tryb: Cytrus (nginx w Dockerze)"

    # Utwórz katalog
    server_exec "sudo mkdir -p '$WEB_ROOT' && sudo chown -R 1000:1000 '$WEB_ROOT' && sudo chmod -R o+rX '$WEB_ROOT'"

    # Sprawdź czy port wolny
    if server_exec "netstat -tlnp 2>/dev/null | grep -q ':$PORT ' || ss -tlnp | grep -q ':$PORT '"; then
        echo "❌ Port $PORT jest już zajęty!"
        echo "   Użyj innego portu: $0 $DOMAIN $SSH_ALIAS $WEB_ROOT INNY_PORT"
        exit 1
    fi

    # Uruchom nginx
    STACK_NAME="static-$(echo "$DOMAIN" | sed 's/\./-/g')"
    server_exec "mkdir -p /opt/stacks/$STACK_NAME && cat > /opt/stacks/$STACK_NAME/docker-compose.yaml << 'EOF'
services:
  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - \"$PORT:80\"
    volumes:
      - $WEB_ROOT:/usr/share/nginx/html:ro
    deploy:
      resources:
        limits:
          memory: 32M
EOF
cd /opt/stacks/$STACK_NAME && docker compose up -d"

    echo "✅ nginx uruchomiony na porcie $PORT"

    # Zarejestruj domenę
    echo ""
    "$SCRIPT_DIR/cytrus-domain.sh" "$DOMAIN" "$PORT" "$SSH_ALIAS"

else
    echo "☁️  Tryb: Cloudflare (Caddy file_server)"

    # Utwórz katalog
    server_exec "sudo mkdir -p '$WEB_ROOT' && sudo chown -R 1000:1000 '$WEB_ROOT' && sudo chmod -R o+rX '$WEB_ROOT'"

    # Skonfiguruj DNS
    "$SCRIPT_DIR/dns-add.sh" "$DOMAIN" "$SSH_ALIAS" || echo "DNS może już istnieć"

    # Skonfiguruj Caddy
    server_exec "sp-expose '$DOMAIN' '$WEB_ROOT' static"

    echo "✅ Caddy skonfigurowany"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Static Hosting gotowy!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "🌍 URL: https://$DOMAIN"
echo "📂 Pliki: $WEB_ROOT"
echo ""
echo "Wrzuć plik: ssh $SSH_ALIAS 'echo test > $WEB_ROOT/test.txt'"
echo "Sprawdź:    curl https://$DOMAIN/test.txt"
echo ""
