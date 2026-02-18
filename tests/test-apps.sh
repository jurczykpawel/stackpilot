#!/bin/bash
# StackPilot - Automated App Testing
# Tests all apps on a remote server: deploy → check HTTP → cleanup
#
# Usage:
#   ./tests/test-apps.sh                  # uses SSH_HOST=mikrus
#   SSH_HOST=myserver ./tests/test-apps.sh
#   ./tests/test-apps.sh ntfy dockge      # test only specific apps
#
# Requirements:
#   - SSH access to the target server (ssh $SSH_HOST)
#   - deploy.sh in local/deploy.sh
#   - Server with Docker installed

set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SSH="${SSH_HOST:-vps}"
RESULTS=()
PASS=0
FAIL=0
SKIP=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "\n${GREEN}========== [$((PASS+FAIL+SKIP+1))/$TOTAL] $1 ==========${NC}"; }

cleanup_app() {
    local app="$1"
    ssh "$SSH" "cd /opt/stacks/$app 2>/dev/null && sudo docker compose down -v --rmi all 2>/dev/null; sudo rm -rf /opt/stacks/$app" 2>/dev/null
    # Dockge installs to /opt/dockge, not /opt/stacks/dockge
    if [ "$app" = "dockge" ]; then
        ssh "$SSH" "cd /opt/dockge 2>/dev/null && sudo docker compose down -v --rmi all 2>/dev/null; sudo rm -rf /opt/dockge" 2>/dev/null
    fi
    # WordPress uses custom stack dir
    if [ "$app" = "wordpress" ]; then
        ssh "$SSH" "cd /opt/stacks/wordpress 2>/dev/null && sudo docker compose down -v --rmi all 2>/dev/null; sudo rm -rf /opt/stacks/wordpress" 2>/dev/null
    fi
    sleep 2
}

check_localhost() {
    local port="$1"
    local max_wait="${2:-60}"
    local health_path="${3:-/}"
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        HTTP_CODE=$(ssh "$SSH" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:${port}${health_path}" 2>/dev/null)
        if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
            echo "$HTTP_CODE"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "000"
    return 1
}

test_app() {
    local app="$1"
    local port="$2"
    local expected_codes="${3:-200 302 301}"
    local max_wait="${4:-60}"
    local deploy_flags="${5:---domain-type=local --yes}"
    local health_path="${6:-/}"

    log "Testing: $app (port $port)"

    # Deploy
    echo "  Deploying..."
    DEPLOY_OUTPUT=$("$REPO/local/deploy.sh" "$app" --ssh="$SSH" $deploy_flags 2>&1)
    DEPLOY_EXIT=$?

    if [ $DEPLOY_EXIT -ne 0 ]; then
        # Check if it's a resource constraint (expected on small server)
        if echo "$DEPLOY_OUTPUT" | grep -qiE "not enough|insufficient|requires.*MB|requires.*RAM|not enough space"; then
            echo -e "  ${YELLOW}SKIP: resource constraint${NC}"
            echo "$DEPLOY_OUTPUT" | grep -iE "RAM:|Disk:|requires|required" | tail -3 | sed 's/^/    /'
            RESULTS+=("$app | SKIP_RESOURCES | port=$port | server too small")
            SKIP=$((SKIP + 1))
            cleanup_app "$app"
            return
        fi
        echo -e "  ${RED}FAIL: deploy failed (exit $DEPLOY_EXIT)${NC}"
        echo "$DEPLOY_OUTPUT" | tail -5 | sed 's/^/    /'
        RESULTS+=("$app | DEPLOY_FAIL | port=$port | exit=$DEPLOY_EXIT")
        FAIL=$((FAIL + 1))
        cleanup_app "$app"
        return
    fi

    # Check localhost
    echo "  Waiting for app on localhost:$port (max ${max_wait}s)..."
    LOCAL_CODE=$(check_localhost "$port" "$max_wait" "$health_path")

    # Evaluate
    LOCAL_OK=false
    for code in $expected_codes; do
        [ "$LOCAL_CODE" = "$code" ] && LOCAL_OK=true
    done

    if $LOCAL_OK; then
        echo -e "  ${GREEN}PASS: localhost:$port → HTTP $LOCAL_CODE${NC}"
        RESULTS+=("$app | PASS | port=$port | HTTP $LOCAL_CODE")
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL: localhost:$port → HTTP $LOCAL_CODE${NC}"
        echo "  Container status:"
        ssh "$SSH" "cd /opt/stacks/$app 2>/dev/null && sudo docker compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || echo 'no stack dir'" | sed 's/^/    /'
        echo "  Logs (last 5):"
        ssh "$SSH" "cd /opt/stacks/$app 2>/dev/null && sudo docker compose logs --tail 5 2>/dev/null" | sed 's/^/    /'
        RESULTS+=("$app | FAIL | port=$port | HTTP $LOCAL_CODE")
        FAIL=$((FAIL + 1))
    fi

    # Cleanup
    echo "  Cleaning up..."
    cleanup_app "$app"
}

# ============================================================
# APP DEFINITIONS
# ============================================================
# Format: app_name|port|expected_codes|max_wait|deploy_flags|health_path

APPS=(
    # --- No-DB apps ---
    "ntfy|8085|200 302|60|--domain-type=local --yes|/"
    "uptime-kuma|3001|200 302 301|60|--domain-type=local --yes|/"
    "dockge|5001|200 302 301|60|--domain-type=local --yes|/"
    "filebrowser|8095|200 302 301|60|--domain-type=local --yes|/"
    "vaultwarden|8088|200 302|60|--domain-type=local --yes|/"
    "stirling-pdf|8087|200 302 301|120|--domain-type=local --yes|/"
    "convertx|3000|200 302 301|60|--domain-type=local --yes|/"
    "crawl4ai|8000|200 302 404 405|90|--domain-type=local --yes|/"
    "gotenberg|3000|200|60|--domain-type=local --yes|/health"
    "linkstack|8090|200 302 500|60|--domain-type=local --yes|/"
    "littlelink|8090|200 302|60|DOMAIN=test.example.com --domain-type=local --yes|/"
    "cookie-hub|8091|200 302 301|60|DOMAIN=test.example.com --domain-type=local --yes|/"
    "minio|9001|200 302 400 403|60|--domain-type=local --yes|/"

    # --- DB apps (PostgreSQL) ---
    "n8n|5678|200 302|60|--domain-type=local --db-source=shared --yes|/"
    "listmonk|9000|200 302|60|--domain-type=local --db-source=shared --yes|/"
    "umami|3000|200 302|60|--domain-type=local --db-source=shared --yes|/"
    "nocodb|8080|200 302 301|60|--domain-type=local --db-source=shared --yes|/"
    "postiz|5000|200 302|90|--domain-type=local --db-source=shared --yes|/"
    "typebot|3000|200 302|90|--domain-type=local --db-source=shared --yes|/"

    # --- MySQL apps ---
    "wordpress|8080|200 302 301 403|120|--domain-type=local --db-source=shared --yes|/"
    "cap|3000|200 302|90|--domain-type=local --db-source=shared --yes|/"
)

SKIP_APPS=(
    "redis|SKIP|TCP only (no HTTP)|/"
    "mcp-docker|SKIP|MCP protocol (no HTTP)|/"
    "coolify|SKIP|tested separately (Lima VM)|/"
    "gateflow|SKIP|requires Supabase|/"
)

# Filter apps if specific ones requested via CLI args
if [ $# -gt 0 ]; then
    FILTERED=()
    for arg in "$@"; do
        for entry in "${APPS[@]}"; do
            app_name="${entry%%|*}"
            if [ "$app_name" = "$arg" ]; then
                FILTERED+=("$entry")
            fi
        done
    done
    APPS=("${FILTERED[@]}")
    SKIP_APPS=()  # Don't show skips when filtering
fi

TOTAL=$(( ${#APPS[@]} + ${#SKIP_APPS[@]} ))

# ============================================================
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  StackPilot - Automated App Testing                      ║"
echo "║  Server: $SSH                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Run tests
for entry in "${APPS[@]}"; do
    IFS='|' read -r app port codes wait flags health <<< "$entry"
    test_app "$app" "$port" "$codes" "$wait" "$flags" "$health"
done

# Record skips
for entry in "${SKIP_APPS[@]}"; do
    IFS='|' read -r app status reason _ <<< "$entry"
    log "SKIP: $app ($reason)"
    RESULTS+=("$app | SKIP | $reason | -")
    SKIP=$((SKIP + 1))
done

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  TEST RESULTS SUMMARY                                        ║"
echo "╠════════════════════════════════════════════════════════════════╣"
printf "║  %-58s ║\n" "PASS: $PASS | FAIL: $FAIL | SKIP: $SKIP | TOTAL: $((PASS+FAIL+SKIP))"
echo "╠════════════════════════════════════════════════════════════════╣"
for r in "${RESULTS[@]}"; do
    if echo "$r" | grep -q "| PASS"; then
        printf "║  ${GREEN}%-58s${NC} ║\n" "$r"
    elif echo "$r" | grep -q "| .*FAIL"; then
        printf "║  ${RED}%-58s${NC} ║\n" "$r"
    else
        printf "║  ${YELLOW}%-58s${NC} ║\n" "$r"
    fi
done
echo "╚════════════════════════════════════════════════════════════════╝"

# Exit with failure if any tests failed
[ $FAIL -eq 0 ]
