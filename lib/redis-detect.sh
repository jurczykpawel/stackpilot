#!/bin/bash

# Mikrus Toolbox - Redis Detection
# Wspólna logika detekcji Redis (external vs bundled).
# Używane przez: apps/wordpress/install.sh, apps/postiz/install.sh
#
# Użycie:
#   source /opt/mikrus-toolbox/lib/redis-detect.sh
#   detect_redis "$MODE" "$BUNDLED_NAME"  # MODE: auto|external|bundled
#
# Po wywołaniu ustawia:
#   REDIS_HOST  - "host-gateway" (external) lub nazwa serwisu (bundled)
#
# Hasło Redis:
#   Jeśli external Redis wymaga hasła, user ustawia REDIS_PASS env var.
#   detect_redis NIE dotyka REDIS_PASS - to odpowiedzialność callera.
#
# Parametry:
#   $1 - tryb: auto|external|bundled
#   $2 - nazwa serwisu bundled Redis (domyślnie: "redis")

detect_redis() {
    local MODE="${1:-auto}"
    local BUNDLED_NAME="${2:-redis}"

    REDIS_HOST=""

    # Sprawdź czy coś nasłuchuje na porcie 6379
    _redis_listening() {
        ss -tlnp 2>/dev/null | grep -q ':6379 ' \
            || nc -z localhost 6379 2>/dev/null
    }

    if [ "$MODE" = "external" ]; then
        if _redis_listening; then
            REDIS_HOST="host-gateway"
            echo "✅ Redis: zewnętrzny (host, wymuszony)"
        else
            echo "⚠️  Redis external: nic nie nasłuchuje na localhost:6379"
            echo "   Używam bundled Redis zamiast tego."
            REDIS_HOST="$BUNDLED_NAME"
        fi
    elif [ "$MODE" = "bundled" ]; then
        REDIS_HOST="$BUNDLED_NAME"
        echo "✅ Redis: bundled (wymuszony)"
    elif _redis_listening; then
        REDIS_HOST="host-gateway"
        echo "✅ Redis: zewnętrzny (wykryty na localhost:6379)"
    else
        REDIS_HOST="$BUNDLED_NAME"
        echo "✅ Redis: bundled (brak istniejącego)"
    fi
}
