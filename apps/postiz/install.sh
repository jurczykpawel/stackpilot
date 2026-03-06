#!/bin/bash

# StackPilot - Postiz
# AI-powered social media scheduling tool. Alternative to Buffer/Hootsuite.
# https://github.com/gitroomhq/postiz-app
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=3500  # Postiz + Temporal + PostgreSQL + Redis (bez ES)
# DB_BUNDLED=true
#
# ⚠️  WARNING: Postiz requires a dedicated server (min. 4GB RAM)!
#     Postiz (Next.js + Nest.js + nginx + workers + cron) = ~3GB (webpack build peak ~2.2GB)
#     Temporal + PostgreSQL = ~0.5-0.7GB
#     Razem: ~3.5-4GB RAM
#     Nie instaluj obok innych ciężkich usług!
#
# Stack: 5 kontenerów (+ opcjonalnie bundled PG/Redis)
#   - postiz (aplikacja)
#   - temporal (workflow engine)
#   - temporal-postgresql (baza danych Temporal)
#   - temporal-ui (panel Temporal, opcjonalny)
#   - postiz-postgres (opcjonalny, jeśli bundled)
#   - postiz-redis (opcjonalny, jeśli bundled)
#
# ─── Dlaczego BEZ Elasticsearch? ───────────────────────────────────────────
#
# Oficjalny docker-compose Postiz zawiera Elasticsearch jako visibility store
# dla Temporal. ES daje nielimitowane search attributes i full-text search.
# Ale Postiz z tego NIE korzysta — rejestruje tylko 2 atrybuty (organizationId,
# postId) i robi exact match po UUID, nie full-text search.
#
# Na Mikrusie (4GB RAM) ES zjadłby 256-512MB + dodatkowy kontener, a jedyna
# korzyść (brak limitu atrybutów) jest niepotrzebna przy 2 atrybutach.
#
# Zamiast ES używamy PostgreSQL jako visibility store (oficjalnie wspierane
# od Temporal v1.20). SQL visibility ma limit 3 atrybutów typu Text — Postiz
# potrzebuje 2, więc mieści się z zapasem.
#
# ─── SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES ────────────────────────────────────
#
# Jedyny haczyk: Temporal auto-setup domyślnie rejestruje 7 demo atrybutów,
# w tym 2× Text (CustomStringField, CustomTextField). To zajmuje 2 z 3 slotów
# → Postiz nie mieści się z kolejnymi 2. Rozwiązanie:
#
#   SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES=true  (oficjalny flag auto-setup)
#
# Pomija rejestrację demo attrs → 3 sloty Text wolne → Postiz bierze 2.
# Flag jest oficjalnie udokumentowany i wspierany.
# Ref: https://github.com/temporalio/temporal/issues/4802
#
# Kompatybilne: Temporal v1.29+ (testowane na 1.29.3).
# Forward-compatible: w v1.30+ dojdzie persistenceCustomSearchAttributes
# config (PR #8397) pozwalający zwiększyć limit bez SKIP, ale SKIP nadal
# będzie działać.
#
# Gdyby Postiz w przyszłości potrzebował >3 Text attrs:
#   1. Temporal v1.30+: persistenceCustomSearchAttributes: { Text: 10 }
#      + ALTER TABLE executions_visibility ADD COLUMN Text04-10
#   2. Lub: dodać OpenSearch (256MB heap, single-node) zamiast SQL visibility
#   3. Lub: PR do Postiz zmieniający TEXT→KEYWORD (10 slotów, poprawniejszy
#      typ dla UUID exact match)
#
#
# Baza danych PostgreSQL:
#   Domyślnie bundlowana (postgres:17-alpine w compose).
#   Jeśli deploy.sh przekaże DB_HOST/DB_USER/DB_PASS — używa external DB.
#
# Wymagane zmienne środowiskowe (przekazywane przez deploy.sh):
#   DOMAIN (opcjonalne)
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS (opcjonalne — jeśli external DB)

set -e

APP_NAME="postiz"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-5000}
TEMPORAL_UI_PORT=${TEMPORAL_UI_PORT:-8080}

# Auto-increment Temporal UI port jeśli zajęty (np. NocoDB na 8080)
if ss -tlnp 2>/dev/null | grep -q ":${TEMPORAL_UI_PORT} "; then
    for p in $(seq $((TEMPORAL_UI_PORT + 1)) $((TEMPORAL_UI_PORT + 20))); do
        if ! ss -tlnp 2>/dev/null | grep -q ":${p} "; then
            echo "⚠️  Port $TEMPORAL_UI_PORT (Temporal UI) zajęty — używam $p"
            TEMPORAL_UI_PORT=$p
            break
        fi
    done
fi

echo "--- 📱 Postiz Setup ---"
echo "AI-powered social media scheduler (latest + Temporal)."
echo ""

# Port binding: Cytrus wymaga 0.0.0.0, Cloudflare/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

# RAM check - Postiz z Temporal potrzebuje ~3GB
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 3500 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  UWAGA: Postiz + Temporal zaleca minimum 4GB RAM!        ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Twój serwer: ${TOTAL_RAM}MB RAM                             ║"
    echo "║  Zalecane:    4096MB RAM                                     ║"
    echo "║                                                              ║"
    echo "║  Postiz (~3GB) + Temporal + PG + Redis = ~3.5-4GB RAM       ║"
    echo "║  Na serwerze <4GB mogą być problemy ze stabilnością.         ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

# =============================================================================
# BAZA DANYCH — BUNDLED vs EXTERNAL
# =============================================================================
JWT_SECRET=$(openssl rand -hex 32)

if [ -n "${DB_HOST:-}" ] && [ -n "${DB_USER:-}" ] && [ -n "${DB_PASS:-}" ]; then
    # External DB — przekazana przez deploy.sh (--db=custom)
    USE_BUNDLED_PG=false
    DB_PORT=${DB_PORT:-5432}
    DB_NAME=${DB_NAME:-postiz}
    DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"
    echo "✅ Baza PostgreSQL: external ($DB_HOST:$DB_PORT/$DB_NAME)"
else
    # Bundled DB — postgres:17-alpine w compose
    USE_BUNDLED_PG=true
    PG_POSTIZ_PASS=$(openssl rand -hex 16)
    DATABASE_URL="postgresql://postiz:${PG_POSTIZ_PASS}@postiz-postgres:5432/postiz"
    echo "✅ Baza PostgreSQL: bundled (postgres:17-alpine)"
fi

# =============================================================================
# REDIS — BUNDLED vs EXTERNAL (auto-detekcja)
# =============================================================================
source /opt/stackpilot/lib/redis-detect.sh 2>/dev/null || true
if type detect_redis &>/dev/null; then
    detect_redis "${POSTIZ_REDIS:-auto}" "postiz-redis"
else
    REDIS_HOST="postiz-redis"
    echo "✅ Redis: bundled (lib/redis-detect.sh niedostępne)"
fi

REDIS_PASS="${REDIS_PASS:-}"
if [ "$REDIS_HOST" = "host-gateway" ]; then
    USE_BUNDLED_REDIS=false
    if [ -n "$REDIS_PASS" ]; then
        REDIS_URL="redis://:${REDIS_PASS}@host-gateway:6379"
    else
        REDIS_URL="redis://host-gateway:6379"
    fi
else
    USE_BUNDLED_REDIS=true
    REDIS_URL="redis://postiz-redis:6379"
fi

# Domain / URLs
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domena: $DOMAIN"
    MAIN_URL="https://$DOMAIN"
    FRONTEND_URL="https://$DOMAIN"
    BACKEND_URL="https://$DOMAIN/api"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domena: automatyczna (Cytrus) — URL-e zostaną zaktualizowane"
    MAIN_URL="http://localhost:$PORT"
    FRONTEND_URL="http://localhost:$PORT"
    BACKEND_URL="http://localhost:$PORT/api"
else
    echo "⚠️  Brak domeny - użyj --domain=... lub dostęp przez SSH tunnel"
    MAIN_URL="http://localhost:$PORT"
    FRONTEND_URL="http://localhost:$PORT"
    BACKEND_URL="http://localhost:$PORT/api"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# =============================================================================
# PLIK .env — OFICJALNY TEMPLATE Z REPOZYTORIUM POSTIZ
# =============================================================================
# Pobieramy .env.example tylko przy pierwszej instalacji (nie nadpisujemy uzupełnionych kluczy)
if [ ! -f .env ]; then
    ENV_URL="https://raw.githubusercontent.com/gitroomhq/postiz-app/main/.env.example"
    if curl -sf "$ENV_URL" -o /tmp/postiz-env-example 2>/dev/null; then
        # Dodaj nagłówek z instrukcją
        {
            echo "# ╔════════════════════════════════════════════════════════════════╗"
            echo "# ║  Postiz — klucze API platform social media                    ║"
            echo "# ║  Uzupełnij tylko te platformy, z których chcesz korzystać.    ║"
            echo "# ║  Docs: https://docs.postiz.com/providers                      ║"
            echo "# ╚════════════════════════════════════════════════════════════════╝"
            echo ""
            cat /tmp/postiz-env-example
        } | sudo tee .env > /dev/null
        rm -f /tmp/postiz-env-example
        sudo chmod 600 .env
        echo "✅ Plik .env pobrany z repozytorium Postiz: $STACK_DIR/.env"
    else
        echo "⚠️  Nie udało się pobrać .env.example — utwórz plik ręcznie"
        echo "   $ENV_URL"
    fi
else
    echo "✅ Plik .env już istnieje — nie nadpisuję"
fi

# =============================================================================
# TEMPORAL DYNAMIC CONFIG
# =============================================================================
sudo mkdir -p "$STACK_DIR/dynamicconfig"
cat <<'DYNEOF' | sudo tee "$STACK_DIR/dynamicconfig/development-sql.yaml" > /dev/null
limit.maxIDLength:
  - value: 255
    constraints: {}
system.forceSearchAttributesCacheRefreshOnRead:
  - value: true
    constraints: {}
DYNEOF

# =============================================================================
# DOCKER COMPOSE — PEŁNY STACK Z TEMPORAL
# =============================================================================

# Warunkowe bloki: bundled vs external PostgreSQL / Redis
POSTIZ_DEPENDS_LIST=""
POSTIZ_EXTRA_HOSTS=""
POSTIZ_PG_SERVICE=""
POSTIZ_REDIS_SERVICE=""

if [ "$USE_BUNDLED_PG" = true ]; then
    POSTIZ_DEPENDS_LIST="${POSTIZ_DEPENDS_LIST}
      postiz-postgres:
        condition: service_healthy"
    POSTIZ_PG_SERVICE="
  # --- PostgreSQL (baza Postiz) ---
  postiz-postgres:
    image: postgres:17-alpine
    restart: always
    environment:
      - POSTGRES_USER=postiz
      - POSTGRES_PASSWORD=${PG_POSTIZ_PASS}
      - POSTGRES_DB=postiz
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    networks:
      - postiz-network
    healthcheck:
      test: [\"CMD\", \"pg_isready\", \"-U\", \"postiz\", \"-d\", \"postiz\"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 256M"
fi

if [ "$USE_BUNDLED_REDIS" = true ]; then
    POSTIZ_DEPENDS_LIST="${POSTIZ_DEPENDS_LIST}
      postiz-redis:
        condition: service_healthy"
    POSTIZ_REDIS_SERVICE="
  # --- Redis ---
  postiz-redis:
    image: redis:7.2-alpine
    restart: always
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ./redis-data:/data
    networks:
      - postiz-network
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"ping\"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 128M"
fi

# Extra hosts dla external DB/Redis
if [ "$USE_BUNDLED_PG" = false ] || [ "$USE_BUNDLED_REDIS" = false ]; then
    POSTIZ_EXTRA_HOSTS="    extra_hosts:
      - \"host-gateway:host-gateway\""
fi

# Buduj depends_on
if [ -n "$POSTIZ_DEPENDS_LIST" ]; then
    POSTIZ_DEPENDS="    depends_on:${POSTIZ_DEPENDS_LIST}"
else
    POSTIZ_DEPENDS=""
fi

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  # --- Postiz (aplikacja główna) ---
  postiz:
    image: ghcr.io/gitroomhq/postiz-app:latest
    restart: always
    env_file: .env
    ports:
      - "${BIND_ADDR}$PORT:5000"
    environment:
      - MAIN_URL=$MAIN_URL
      - FRONTEND_URL=$FRONTEND_URL
      - NEXT_PUBLIC_BACKEND_URL=$BACKEND_URL
      - BACKEND_INTERNAL_URL=http://localhost:3000
      - DATABASE_URL=$DATABASE_URL
      - REDIS_URL=$REDIS_URL
      - TEMPORAL_ADDRESS=temporal:7233
      - JWT_SECRET=$JWT_SECRET
      - IS_GENERAL=true
      - STORAGE_PROVIDER=local
      - UPLOAD_DIRECTORY=/uploads
      - NEXT_PUBLIC_UPLOAD_DIRECTORY=/uploads
      - NX_ADD_PLUGINS=false
    volumes:
      - ./config:/config
      - ./uploads:/uploads
    networks:
      - postiz-network
      - temporal-network
$POSTIZ_DEPENDS
$POSTIZ_EXTRA_HOSTS
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://localhost:5000').then(r=>{process.exit(r.ok?0:1)}).catch(()=>process.exit(1))\""]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s
    deploy:
      resources:
        limits:
          memory: 3072M
$POSTIZ_PG_SERVICE
$POSTIZ_REDIS_SERVICE

  # --- Temporal (workflow engine) ---
  # SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES=true → nie rejestruje domyślnych Text01-03
  # (SQL visibility limit = 3 Text attrs; Postiz potrzebuje 2: organizationId, postId)
  temporal:
    image: temporalio/auto-setup:1.29.3
    restart: always
    depends_on:
      - temporal-postgresql
    environment:
      - DB=postgres12
      - DB_PORT=5432
      - POSTGRES_USER=temporal
      - POSTGRES_PWD=temporal
      - POSTGRES_SEEDS=temporal-postgresql
      - DYNAMIC_CONFIG_FILE_PATH=config/dynamicconfig/development-sql.yaml
      - SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES=true
      - TEMPORAL_NAMESPACE=default
    networks:
      - temporal-network
    volumes:
      - ./dynamicconfig:/etc/temporal/config/dynamicconfig
    deploy:
      resources:
        limits:
          memory: 512M

  # --- PostgreSQL (baza Temporal) ---
  temporal-postgresql:
    image: postgres:16-alpine
    restart: always
    environment:
      - POSTGRES_USER=temporal
      - POSTGRES_PASSWORD=temporal
    volumes:
      - ./temporal-postgres-data:/var/lib/postgresql/data
    networks:
      - temporal-network
    deploy:
      resources:
        limits:
          memory: 256M

  # --- Temporal UI (panel zarządzania workflow) ---
  temporal-ui:
    image: temporalio/ui:2.34.0
    restart: always
    environment:
      - TEMPORAL_ADDRESS=temporal:7233
      - TEMPORAL_CORS_ORIGINS=http://127.0.0.1:3000
    networks:
      - temporal-network
    ports:
      - "127.0.0.1:$TEMPORAL_UI_PORT:8080"
    depends_on:
      - temporal
    deploy:
      resources:
        limits:
          memory: 256M

networks:
  postiz-network:
  temporal-network:
EOF

# Policz kontenery
CONTAINER_COUNT=4  # postiz + temporal + temporal-pg + temporal-ui
[ "$USE_BUNDLED_PG" = true ] && CONTAINER_COUNT=$((CONTAINER_COUNT + 1))
[ "$USE_BUNDLED_REDIS" = true ] && CONTAINER_COUNT=$((CONTAINER_COUNT + 1))

echo ""
echo "✅ Docker Compose wygenerowany ($CONTAINER_COUNT kontenerów)"
echo "   Uruchamiam stack..."
echo ""

sudo docker compose up -d

# Health check - Temporal + Postiz potrzebują więcej czasu na start
echo "⏳ Czekam na uruchomienie Postiz (~90-120s, Temporal + Next.js)..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 120 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    for i in $(seq 1 12); do
        sleep 10
        if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
            echo "✅ Postiz działa (po $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 12 ]; then
            echo "❌ Kontener nie wystartował w 120s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

# =============================================================================
# WERYFIKACJA UPLOADSÓW (wymagane dla TikTok, Instagram media)
# =============================================================================
UPLOADS_OK=false
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    for i in $(seq 1 6); do
        UPLOAD_CHECK=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${DOMAIN}/uploads/" 2>/dev/null || echo "000")
        if [ "$UPLOAD_CHECK" -ge 200 ] && [ "$UPLOAD_CHECK" -lt 500 ]; then
            UPLOADS_OK=true
            break
        fi
        sleep 5
    done
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Postiz zainstalowany!"
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Otwórz https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Dostęp przez SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi

if [ "$UPLOADS_OK" = true ]; then
    echo ""
    echo -e "${GREEN:-\033[0;32m}✅ Uploady publiczne: https://${DOMAIN}/uploads/${NC:-\033[0m}"
    echo "   TikTok, Instagram i inne platformy wymagające pull_from_url będą działać."
else
    echo ""
    echo -e "${YELLOW:-\033[1;33m}⚠️  Uploady mogą nie być dostępne publicznie!${NC:-\033[0m}"
    echo "   TikTok pobiera media przez URL — pliki muszą być dostępne po HTTPS."
    echo "   Sprawdź: https://<twoja-domena>/uploads/"
    echo "   Alternatywa: Cloudflare R2 (STORAGE_PROVIDER=cloudflare-r2)"
fi

echo ""
echo "📝 Następne kroki:"
echo "   1. Utwórz konto administratora w przeglądarce"
echo "   2. Wyłącz rejestrację (komenda poniżej!)"
echo "   3. Uzupełnij klucze API w pliku .env:"
echo ""
echo "      ssh ${SSH_ALIAS:-vps} 'nano $STACK_DIR/.env'"
echo ""
echo "      Uzupełnij pary KEY/SECRET tylko dla platform, z których korzystasz."
echo "      Po zapisaniu: ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && docker compose up -d'"
echo "      Docs: https://docs.postiz.com/providers"
echo ""
echo "   ⚠️  Ważne uwagi przy konfiguracji providerów:"
echo "   • Facebook: przełącz app z Development → Live (inaczej posty widoczne tylko dla Ciebie!)"
echo "   • LinkedIn: dodaj Advertising API (bez tego tokeny nie odświeżają się!)"
echo "   • TikTok: domena z uploadami musi być zweryfikowana w TikTok Developer Account"
echo "   • YouTube: po konfiguracji Brand Account poczekaj ~5h na propagację"
echo "   • Threads: złożona konfiguracja — przeczytaj docs.postiz.com/providers/threads"
echo "   • Discord/Slack: ikona aplikacji jest wymagana (bez niej błąd 404)"
echo ""
echo "🔒 WAŻNE — wyłącz rejestrację po utworzeniu konta:"
echo "   ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && sed -i \"/IS_GENERAL/a\\\\      - DISABLE_REGISTRATION=true\" docker-compose.yaml && docker compose up -d'"
