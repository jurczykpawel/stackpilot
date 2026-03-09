#!/bin/bash

# StackPilot - E2E Tests: Sellf
#
# Tests all runtime × domain-type combinations for the sellf app.
# Each test:
#   1. PRE-CHECK  — verifies port is free and no stale process exists
#   2. DEPLOY     — runs deploy.sh with the given flags
#   3. POST-CHECK — verifies the correct process type holds the port (not a stale one)
#   4. CLEANUP    — removes all traces (PM2, Docker, Caddy, DNS, files)
#
# Usage:
#   ./tests/run.sh e2e --ssh=hetzner --suite=sellf
#   bash tests/e2e/sellf.sh --ssh=hetzner
#   bash tests/e2e/sellf.sh --ssh=hetzner --filter=docker+cloudflare

set -o pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$E2E_DIR/../.." && pwd)"

source "$E2E_DIR/config.sh"
source "$E2E_DIR/lib/assertions.sh"
source "$E2E_DIR/lib/cleanup.sh"

# --- Parse args ---
FILTER=""
for arg in "$@"; do
    case "$arg" in
        --ssh=*)     E2E_SSH="${arg#--ssh=}" ;;
        --filter=*)  FILTER="${arg#--filter=}" ;;
        --cleanup=*) E2E_CLEANUP="${arg#--cleanup=}"; export E2E_CLEANUP ;;
    esac
done

# --- Sellf-specific cleanup ---

# Remove a named sellf instance completely
# Usage: sellf_cleanup INSTANCE_NAME [DOMAIN]
#   INSTANCE_NAME: e.g. "sellf-test", "sellf-caddy", "" (no-domain instance = "sellf")
sellf_cleanup() {
    local instance="$1"    # e.g. "sellf-test"
    local domain="${2:-}"

    local pm2_name stack_dir docker_name
    if [ -n "$instance" ]; then
        pm2_name="sellf-${instance}"
        stack_dir="/opt/stacks/sellf-${instance}"
        docker_name="sellf-${instance}"
    else
        pm2_name="sellf"
        stack_dir="/opt/stacks/sellf"
        docker_name="sellf-default"
    fi

    ssh "$E2E_SSH" "
        # PM2
        pm2 delete '$pm2_name' 2>/dev/null || true
        pm2 save --force 2>/dev/null || true
        # Docker
        docker stop '$docker_name' 2>/dev/null || true
        docker rm   '$docker_name' 2>/dev/null || true
        # Files
        rm -rf '$stack_dir'
    " 2>/dev/null

    # Caddy + DNS (only for named domains)
    if [ -n "$domain" ]; then
        caddy_cleanup "$domain"
        cf_dns_delete "$domain" 2>/dev/null || true
    fi

    # Prune dangling images
    ssh "$E2E_SSH" "docker image prune -f" >/dev/null 2>&1
}

# --- Pre-check helpers ---

# Verify port is NOT in use on the server.
# Returns 0 (OK) or 1 (port already in use — stale process).
sellf_precheck_port() {
    local port="$1"
    local test_label="$2"

    if assert_port "$port"; then
        local holder
        holder=$(ssh "$E2E_SSH" "ss -tlnp | grep ':${port} ' | grep -oP 'users:\(\(\"[^\"]+\"' | head -1" 2>/dev/null)
        echo -e "  ${E2E_RED}PRE-CHECK FAIL: port $port already in use ($holder)${E2E_NC}"
        echo -e "  ${E2E_RED}Cannot reliably test — stale process would cause false positive${E2E_NC}"
        E2E_RESULTS+=("FAIL|$test_label|pre-check: port $port occupied")
        E2E_FAIL=$((E2E_FAIL + 1))
        return 1
    fi
    return 0
}

# Verify no PM2 process and no Docker container with given name exists.
sellf_precheck_process() {
    local pm2_name="$1"
    local docker_name="$2"
    local test_label="$3"

    local stale=""
    ssh "$E2E_SSH" "pm2 list 2>/dev/null | grep -q '$pm2_name'" 2>/dev/null && stale="PM2:$pm2_name"
    ssh "$E2E_SSH" "docker ps -a --format '{{.Names}}' | grep -q '^${docker_name}$'" 2>/dev/null && stale="${stale:+$stale, }Docker:$docker_name"

    if [ -n "$stale" ]; then
        echo -e "  ${E2E_RED}PRE-CHECK FAIL: stale process found: $stale${E2E_NC}"
        echo -e "  ${E2E_RED}Cannot reliably test — stale process would cause false positive${E2E_NC}"
        E2E_RESULTS+=("FAIL|$test_label|pre-check: stale process ($stale)")
        E2E_FAIL=$((E2E_FAIL + 1))
        return 1
    fi
    return 0
}

# Post-check: verify the port is held by the expected runtime (pm2 or docker),
# NOT by a stale process from a previous test.
#   runtime: "pm2" → process name contains "node" or "bun" and matches pm2_name in pm2 list
#   runtime: "docker" → docker container is running with given name
sellf_postcheck_runtime() {
    local port="$1"
    local runtime="$2"
    local pm2_name="$3"
    local docker_name="$4"
    local test_label="$5"

    if [ "$runtime" = "docker" ]; then
        if ! ssh "$E2E_SSH" "docker ps --format '{{.Names}}' | grep -q '^${docker_name}$'" 2>/dev/null; then
            echo -e "  ${E2E_RED}POST-CHECK FAIL: Docker container '$docker_name' not running${E2E_NC}"
            local logs
            logs=$(ssh "$E2E_SSH" "docker logs '$docker_name' 2>&1 | tail -5" 2>/dev/null)
            while IFS= read -r line; do echo "    $line"; done <<< "$logs"
            E2E_RESULTS+=("FAIL|$test_label|post-check: Docker container not running")
            E2E_FAIL=$((E2E_FAIL + 1))
            return 1
        fi
        # Extra: confirm port is held by Docker (not PM2 leftover)
        local port_holder
        port_holder=$(ssh "$E2E_SSH" "ss -tlnp | grep ':${port} '" 2>/dev/null)
        if echo "$port_holder" | grep -q "next-server\|node.*standalone"; then
            echo -e "  ${E2E_RED}POST-CHECK FAIL: port $port is held by Node/PM2, not Docker${E2E_NC}"
            E2E_RESULTS+=("FAIL|$test_label|post-check: PM2 holds port instead of Docker")
            E2E_FAIL=$((E2E_FAIL + 1))
            return 1
        fi
    else
        # PM2 mode
        if ! ssh "$E2E_SSH" "pm2 list 2>/dev/null | grep -q '$pm2_name.*online'" 2>/dev/null; then
            echo -e "  ${E2E_RED}POST-CHECK FAIL: PM2 process '$pm2_name' not online${E2E_NC}"
            E2E_RESULTS+=("FAIL|$test_label|post-check: PM2 process not online")
            E2E_FAIL=$((E2E_FAIL + 1))
            return 1
        fi
        # Extra: confirm no Docker container is interfering
        if ssh "$E2E_SSH" "docker ps --format '{{.Names}}' | grep -q '^${docker_name}$'" 2>/dev/null; then
            echo -e "  ${E2E_RED}POST-CHECK FAIL: Docker container '$docker_name' still running (should be stopped)${E2E_NC}"
            E2E_RESULTS+=("FAIL|$test_label|post-check: Docker container still running")
            E2E_FAIL=$((E2E_FAIL + 1))
            return 1
        fi
    fi

    return 0
}

# --- Main test function ---

# sellf_test LABEL RUNTIME DOMAIN_TYPE [DOMAIN]
#   LABEL:       human-readable name e.g. "pm2+cloudflare"
#   RUNTIME:     pm2 | docker
#   DOMAIN_TYPE: cloudflare | caddy | local
#   DOMAIN:      full domain (optional; omit for domain-type=local)
#
# NOTE: Port is NOT fixed — deploy.sh assigns the first free port dynamically.
# The actual port is parsed from deploy output ("responding on port XXXX").
sellf_test() {
    local label="$1"
    local runtime="$2"
    local domain_type="$3"
    local domain="${4:-}"

    # Apply filter
    if [ -n "$FILTER" ] && [[ "$label" != *"$FILTER"* ]]; then
        return 0
    fi

    # Derive instance name (first subdomain component) and process names
    local instance pm2_name docker_name
    if [ -n "$domain" ]; then
        instance="${domain%%.*}"
        pm2_name="sellf-${instance}"
        docker_name="sellf-${instance}"
    else
        instance=""
        pm2_name="sellf"
        docker_name="sellf-default"
    fi

    local test_num=$((E2E_PASS + E2E_FAIL + E2E_SKIP + 1))
    echo ""
    echo -e "${E2E_BOLD}[$test_num] sellf | $label${E2E_NC}"
    echo -e "    runtime=$runtime  domain-type=$domain_type"
    [ -n "$domain" ] && echo -e "    domain=$domain"

    # --- PRE-CHECK ---
    echo "  [pre]  no stale PM2/Docker process?"
    sellf_precheck_process "$pm2_name" "$docker_name" "$label" || { sellf_cleanup "$instance" "$domain"; return 1; }

    echo -e "  ${E2E_GREEN}pre-checks passed${E2E_NC}"

    # --- BUILD FLAGS ---
    local -a flags=(--supabase=local "--runtime=$runtime" "--domain-type=$domain_type" --yes)
    [ -n "$domain" ] && flags+=("--domain=$domain")

    # --- DEPLOY ---
    echo "  [deploy] running deploy.sh sellf ${flags[*]} ..."
    local deploy_output deploy_exit
    deploy_output=$("$REPO_ROOT/local/deploy.sh" sellf --ssh="$E2E_SSH" "${flags[@]}" 2>&1) \
        && deploy_exit=0 || deploy_exit=$?

    if [ "$deploy_exit" -ne 0 ]; then
        echo -e "  ${E2E_RED}FAIL: deploy failed (exit $deploy_exit)${E2E_NC}"
        echo "$deploy_output" | tail -15 | sed 's/^/    /'
        E2E_RESULTS+=("FAIL|sellf $label|deploy failed (exit $deploy_exit)")
        E2E_FAIL=$((E2E_FAIL + 1))
        sellf_cleanup "$instance" "$domain"
        return 1
    fi

    # --- Parse actual port from deploy output ---
    local port
    port=$(echo "$deploy_output" | grep -oE 'responding on port [0-9]+' | grep -oE '[0-9]+$' | tail -1)
    if [ -z "$port" ]; then
        echo -e "  ${E2E_RED}FAIL: could not parse port from deploy output${E2E_NC}"
        echo "$deploy_output" | tail -5 | sed 's/^/    /'
        E2E_RESULTS+=("FAIL|sellf $label|port not found in deploy output")
        E2E_FAIL=$((E2E_FAIL + 1))
        sellf_cleanup "$instance" "$domain"
        return 1
    fi
    echo "  [info] assigned port: $port"

    # --- POST-CHECK: correct process holds the port ---
    echo "  [post] checking runtime ($runtime owns port $port)..."
    sellf_postcheck_runtime "$port" "$runtime" "$pm2_name" "$docker_name" "$label" \
        || { sellf_cleanup "$instance" "$domain"; return 1; }

    # --- HTTP CHECK ---
    echo "  [http] localhost:$port..."
    local http_code
    http_code=$(assert_http "$port" "200 301 302" 30)
    local http_exit=$?

    if [ "$http_exit" -eq 0 ]; then
        echo -e "  ${E2E_GREEN}PASS: HTTP $http_code (port $port)${E2E_NC}"
        E2E_RESULTS+=("PASS|sellf $label|HTTP $http_code port $port")
        E2E_PASS=$((E2E_PASS + 1))
    else
        echo -e "  ${E2E_RED}FAIL: HTTP $http_code (expected 200/301/302)${E2E_NC}"
        E2E_RESULTS+=("FAIL|sellf $label|HTTP $http_code")
        E2E_FAIL=$((E2E_FAIL + 1))
        sellf_cleanup "$instance" "$domain"
        return 1
    fi

    # --- CLEANUP ---
    echo "  [cleanup]..."
    sellf_cleanup "$instance" "$domain"

    # Verify port is free again after cleanup
    sleep 3
    if assert_port "$port"; then
        echo -e "  ${E2E_YELLOW}WARNING: port $port still in use after cleanup${E2E_NC}"
    fi
}

# =============================================================================
# TEST CASES
# =============================================================================
# Each case runs sequentially to avoid port conflicts.
# Ports are staggered so if cleanup is slow the next test doesn't collide.

echo ""
echo -e "${E2E_BOLD}════════════════════════════════════════${E2E_NC}"
echo -e "${E2E_BOLD} Sellf E2E Tests (ssh: $E2E_SSH)${E2E_NC}"
echo -e "${E2E_BOLD}════════════════════════════════════════${E2E_NC}"

# NOTE: Ports are assigned dynamically by deploy.sh (first free port).
# The actual port is parsed from deploy output — no hardcoded ports here.

# domain-type=cloudflare tests
sellf_test "docker+cloudflare" docker cloudflare "sellf-test.automagicznie.pl"
sellf_test "pm2+cloudflare"    pm2    cloudflare "sellf-test.automagicznie.pl"

# domain-type=caddy tests
sellf_test "docker+caddy"      docker caddy      "sellf-caddy.automagicznie.pl"
sellf_test "pm2+caddy"         pm2    caddy      "sellf-caddy.automagicznie.pl"

# domain-type=local tests (no domain, single instance)
sellf_test "docker+local"      docker local      ""
sellf_test "pm2+local"         pm2    local      ""

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${E2E_BOLD}════════════════════════════════════════${E2E_NC}"
echo -e "${E2E_BOLD} Results${E2E_NC}"
echo -e "${E2E_BOLD}════════════════════════════════════════${E2E_NC}"
echo ""

for result in "${E2E_RESULTS[@]}"; do
    IFS='|' read -r status name detail <<< "$result"
    case "$status" in
        PASS) echo -e "  ${E2E_GREEN}✓ PASS${E2E_NC}  $name — $detail" ;;
        FAIL) echo -e "  ${E2E_RED}✗ FAIL${E2E_NC}  $name — $detail" ;;
        SKIP) echo -e "  ${E2E_YELLOW}⊘ SKIP${E2E_NC}  $name — $detail" ;;
    esac
done

echo ""
echo -e "  Pass: ${E2E_GREEN}$E2E_PASS${E2E_NC}  Fail: ${E2E_RED}$E2E_FAIL${E2E_NC}  Skip: ${E2E_YELLOW}$E2E_SKIP${E2E_NC}"
echo ""

[ "$E2E_FAIL" -eq 0 ]
