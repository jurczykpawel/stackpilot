#!/bin/bash

# StackPilot - Coolify
# Open-source PaaS. Twój prywatny Heroku/Vercel z 280+ apkami.
# https://coolify.io
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=2500  # coolify + postgres:15 + redis:7 + soketi + traefik
#
# ⚠️  WYMAGA: Mikrus 4.1+ (8GB RAM, 80GB dysk, 2x CPU)
#     Coolify to pełny PaaS - zarządza WSZYSTKIMI apkami na serwerze.
#     Traefik przejmuje porty 80/443 (SSL, routing).
#     Nie instaluj obok innych apek z stackpilot!
#
# Coolify instaluje się w /data/coolify/ (NIE /opt/stacks/).
# Kontenery: coolify (Laravel), postgres:15, redis:7, soketi (WebSocket), traefik
# Porty: 8000 (UI), 80 (HTTP), 443 (HTTPS), 6001 (WebSocket)
#
# Opcjonalne zmienne środowiskowe:
#   ROOT_USERNAME     - login admina (pomija ekran rejestracji)
#   ROOT_USER_EMAIL   - email admina
#   ROOT_USER_PASSWORD - hasło admina
#   AUTOUPDATE        - "false" aby wyłączyć auto-aktualizacje (domyślnie: włączone)

set -e

APP_NAME="coolify"

echo "--- 🚀 Coolify Setup ---"
echo "Open-source PaaS: Twój prywatny Heroku/Vercel z 280+ apkami."
echo ""

# =============================================================================
# 1. PRE-FLIGHT CHECKS
# =============================================================================

# --- RAM check ---
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
TOTAL_RAM=${TOTAL_RAM:-0}

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 3500 ]; then
    echo "❌ Coolify wymaga minimum 4GB RAM!"
    echo ""
    echo "   Twój serwer: ${TOTAL_RAM}MB RAM"
    echo "   Wymagane:    4096MB (minimum)"
    echo "   Zalecane:    8192MB (Mikrus 4.1+)"
    echo ""
    echo "   Coolify to pełny PaaS (4 kontenery platformy + Traefik)."
    echo "   Na mniejszych serwerach użyj deploy.sh z pojedynczymi apkami."
    exit 1
fi

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 7500 ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  Coolify zaleca 8GB RAM (Mikrus 4.1+)                    ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Twój serwer: ${TOTAL_RAM}MB RAM                             ║"
    echo "║  Zalecane:    8192MB RAM (Mikrus 4.1+)                       ║"
    echo "║                                                              ║"
    echo "║  Coolify zadziała, ale zostanie mało RAM na apki.            ║"
    echo "║  Platforma sama zjada ~500-800MB.                            ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

echo "✅ RAM: ${TOTAL_RAM}MB"

# --- Disk check ---
FREE_DISK=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
FREE_DISK=${FREE_DISK:-0}

if [ "$FREE_DISK" -gt 0 ] && [ "$FREE_DISK" -lt 20000 ]; then
    echo "❌ Coolify wymaga minimum 20GB wolnego miejsca!"
    echo ""
    echo "   Wolne:     ${FREE_DISK}MB (~$((FREE_DISK / 1024))GB)"
    echo "   Wymagane:  20GB (minimum)"
    echo "   Zalecane:  40GB+ (obrazy Docker apek zajmują 500MB-3GB każdy)"
    exit 1
fi

if [ "$FREE_DISK" -gt 0 ] && [ "$FREE_DISK" -lt 35000 ]; then
    echo "⚠️  Dysk: ${FREE_DISK}MB wolne (~$((FREE_DISK / 1024))GB) - może być ciasno"
else
    echo "✅ Dysk: ${FREE_DISK}MB wolne (~$((FREE_DISK / 1024))GB)"
fi

# --- Port check ---
PORTS_BUSY=0
for CHECK_PORT in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":${CHECK_PORT} "; then
        echo "⚠️  Port $CHECK_PORT jest zajęty!"
        PORTS_BUSY=1
    fi
done

if [ "$PORTS_BUSY" -eq 1 ]; then
    echo ""
    echo "   Coolify potrzebuje portów 80 (HTTP) i 443 (HTTPS)."
    echo "   Traefik (reverse proxy Coolify) przejmie te porty."
    echo "   Istniejące usługi na tych portach mogą przestać działać!"
    echo ""
fi

# --- Port 8000 (Coolify UI) ---
source /opt/stackpilot/lib/port-utils.sh 2>/dev/null || true
COOLIFY_PORT=8000
if ss -tlnp 2>/dev/null | grep -q ":8000 "; then
    echo "⚠️  Port 8000 jest zajęty! Szukam wolnego portu dla Coolify UI..."
    if type find_free_port &>/dev/null; then
        COOLIFY_PORT=$(find_free_port 8001)
    else
        # Fallback bez lib
        COOLIFY_PORT=$(ss -tlnp 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | awk 'BEGIN{p=8001} p==$1{p++} END{print p}')
    fi
    echo "✅ Używam portu $COOLIFY_PORT dla Coolify UI"
fi

# --- Existing stacks warning ---
EXISTING_STACKS=0
if [ -d /opt/stacks ]; then
    EXISTING_STACKS=$(ls -d /opt/stacks/*/docker-compose.yaml 2>/dev/null | wc -l || true)
fi
if [ "$EXISTING_STACKS" -gt 0 ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  Wykryto $EXISTING_STACKS istniejących stacków w /opt/stacks/     ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Coolify przejmuje porty 80/443 przez Traefik.               ║"
    echo "║  Apki zainstalowane przez deploy.sh mogą przestać działać.   ║"
    echo "║                                                              ║"
    echo "║  Coolify najlepiej działa na świeżym serwerze.               ║"
    echo "║  Po instalacji zarządzaj WSZYSTKIMI apkami przez panel.      ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

# =============================================================================
# 2. INSTALACJA COOLIFY (oficjalny skrypt)
# =============================================================================

echo "📥 Pobieram i uruchamiam oficjalny instalator Coolify..."
echo "   Źródło: https://cdn.coollabs.io/coolify/install.sh"
echo ""
echo "   Instalator:"
echo "   • Skonfiguruje Docker (jeśli trzeba)"
echo "   • Utworzy /data/coolify/ (konfiguracja, bazy, klucze SSH)"
echo "   • Pobierze i uruchomi kontenery platformy"
echo "   • Skonfiguruje Traefik (reverse proxy)"
echo ""

# Przekaż zmienne środowiskowe do oficjalnego instalatora
# ROOT_USERNAME/ROOT_USER_EMAIL/ROOT_USER_PASSWORD - pre-konfiguracja admina
# AUTOUPDATE - wyłączenie auto-aktualizacji
export ROOT_USERNAME="${ROOT_USERNAME:-}"
export ROOT_USER_EMAIL="${ROOT_USER_EMAIL:-}"
export ROOT_USER_PASSWORD="${ROOT_USER_PASSWORD:-}"
export AUTOUPDATE="${AUTOUPDATE:-}"

# Wyłącz set -e na czas oficjalnego instalatora
# (ma własne set -e, ale niektóre exit kody są buggy - exit 0 przy błędzie)
set +e
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
INSTALL_EXIT=$?
set -e

# Jeśli port 8000 był zajęty, podmień na wolny port
if [ "$COOLIFY_PORT" != "8000" ] && [ -f /data/coolify/source/.env ]; then
    echo ""
    echo "🔧 Zmieniam port Coolify UI: 8000 → $COOLIFY_PORT"
    sed -i "s/^APP_PORT=.*/APP_PORT=$COOLIFY_PORT/" /data/coolify/source/.env
    cd /data/coolify/source && docker compose up -d 2>/dev/null
    sleep 5
fi

if [ "$INSTALL_EXIT" -ne 0 ]; then
    echo ""
    echo "❌ Oficjalny instalator Coolify zakończył się błędem (kod: $INSTALL_EXIT)"
    echo ""
    echo "   Sprawdź logi wyżej. Najczęstsze przyczyny:"
    echo "   • Brak połączenia z CDN (cdn.coollabs.io)"
    echo "   • Docker nie mógł się uruchomić"
    echo "   • Brak uprawnień root"
    echo ""
    echo "   Spróbuj ponownie - instalator jest idempotentny."
    echo "   Logi: cd /data/coolify/source && docker compose logs -f"
    exit 1
fi

# =============================================================================
# 3. HEALTH CHECK
# =============================================================================

# Oficjalny instalator ma własny health check (180s),
# więc jeśli dotarliśmy tutaj, Coolify powinien już działać.
# Robimy krótką weryfikację na wszelki wypadek.

echo ""
echo "⏳ Weryfikuję dostępność panelu Coolify..."

COOLIFY_UP=0
for i in $(seq 1 6); do
    if curl -sf "http://localhost:$COOLIFY_PORT" > /dev/null 2>&1; then
        COOLIFY_UP=1
        break
    fi
    sleep 5
done

if [ "$COOLIFY_UP" -eq 0 ]; then
    echo "⚠️  Panel jeszcze się uruchamia. Sprawdź za chwilę:"
    echo "   curl http://localhost:$COOLIFY_PORT"
    echo "   cd /data/coolify/source && docker compose logs -f"
    echo ""
fi

# =============================================================================
# 4. PODSUMOWANIE
# =============================================================================

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<IP-serwera>")

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Coolify zainstalowany!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "🔗 Panel: http://${SERVER_IP}:${COOLIFY_PORT}"
echo ""

if [ -n "$ROOT_USERNAME" ] && [ -n "$ROOT_USER_PASSWORD" ]; then
    echo "🔑 Konto admina: pre-skonfigurowane ($ROOT_USERNAME)"
else
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  🔒 WAŻNE: Otwórz panel TERAZ i utwórz konto admina!        ║"
    echo "║     Pierwszy zarejestrowany użytkownik = administrator.       ║"
    echo "║     Dopóki się nie zarejestrujesz, panel jest otwarty!        ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
fi

echo ""
echo "📝 Następne kroki:"
echo "   1. Otwórz http://${SERVER_IP}:${COOLIFY_PORT} → utwórz konto admina"
echo "   2. Dodaj serwer (Coolify auto-wykrywa localhost)"
echo "   3. Skonfiguruj domenę w Settings → General"
echo "   4. Deploy pierwszej apki: Resources → + New → Service"
echo ""
echo "🏗️  Architektura Coolify:"
echo "   • Panel UI:      port $COOLIFY_PORT"
echo "   • Traefik HTTP:  port 80  (reverse proxy dla apek)"
echo "   • Traefik HTTPS: port 443 (automatyczny SSL Let's Encrypt)"
echo "   • Dane:          /data/coolify/"
echo ""
echo "📋 Przydatne komendy:"
echo "   cd /data/coolify/source && docker compose logs -f   # logi"
echo "   cd /data/coolify/source && docker compose restart    # restart"
echo ""
