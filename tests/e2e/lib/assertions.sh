#!/bin/bash

# StackPilot - E2E Assertions
# Remote assertions for E2E tests — checks containers, HTTP, ports on the server.

# Check if an HTTP endpoint responds with an expected code
# Usage: assert_http PORT [EXPECTED_CODES] [TIMEOUT] [PATH]
assert_http() {
    local port="$1"
    local expected="${2:-200 302 301}"
    local timeout="${3:-$E2E_HEALTH_TIMEOUT}"
    local path="${4:-/}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local code
        code=$(ssh "$E2E_SSH" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:${port}${path}" 2>/dev/null)

        if [ -n "$code" ] && [ "$code" != "000" ]; then
            for expected_code in $expected; do
                if [ "$code" = "$expected_code" ]; then
                    echo "$code"
                    return 0
                fi
            done
            # Got a response but not the expected code — keep trying (app may be starting)
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "${code:-000}"
    return 1
}

# Check if a Docker container is running
# Usage: assert_container CONTAINER_NAME_PATTERN
assert_container() {
    local pattern="$1"
    # Use grep -x for exact full-line match on the primary container name,
    # then fall back to anchored prefix match for compose-suffixed names (e.g. app-1).
    ssh "$E2E_SSH" "docker ps --format '{{.Names}}' | grep -qE '^${pattern}(-[0-9]+)?$'" 2>/dev/null
}

# Check if a port is listening on the server
# Usage: assert_port PORT
assert_port() {
    local port="$1"
    ssh "$E2E_SSH" "ss -tlnp | grep -q ':${port} '" 2>/dev/null
}

# Check if a Docker container is healthy
# Usage: assert_healthy CONTAINER_NAME_PATTERN
assert_healthy() {
    local pattern="$1"
    local status
    status=$(ssh "$E2E_SSH" "docker ps --filter 'name=$pattern' --format '{{.Status}}'" 2>/dev/null)
    echo "$status" | grep -qi "healthy"
}

# Check if a TCP service responds (e.g., Redis PING → PONG)
# Usage: assert_tcp_redis PORT [PASSWORD]
assert_tcp_redis() {
    local port="$1"
    local pass="${2:-}"
    local cmd="redis-cli -p $port"
    [ -n "$pass" ] && cmd="$cmd -a '$pass'"
    cmd="$cmd PING"
    local result
    result=$(ssh "$E2E_SSH" "$cmd" 2>/dev/null)
    [ "$result" = "PONG" ]
}

# Get server available RAM in MB
# Usage: get_server_ram
get_server_ram() {
    ssh "$E2E_SSH" "free -m | awk '/^Mem:/ {print \$7}'" 2>/dev/null
}

# Get server available disk in MB
# Usage: get_server_disk
get_server_disk() {
    ssh "$E2E_SSH" "df -m / | awk 'NR==2 {print \$4}'" 2>/dev/null
}

# Check if server is a Mikrus VPS
# Usage: is_mikrus
is_mikrus() {
    ssh "$E2E_SSH" "test -f /klucz_api" 2>/dev/null
}

# Check if an HTTPS endpoint responds with expected code (via public domain)
# Usage: assert_https DOMAIN [EXPECTED_CODES] [TIMEOUT] [PATH]
assert_https() {
    local domain="$1"
    local expected="${2:-200 302 301}"
    local timeout="${3:-90}"
    local path="${4:-/}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${domain}${path}" 2>/dev/null)

        if [ -n "$code" ] && [ "$code" != "000" ]; then
            for expected_code in $expected; do
                if [ "$code" = "$expected_code" ]; then
                    echo "$code"
                    return 0
                fi
            done
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "${code:-000}"
    return 1
}

# Check HTTPS from the server itself (for direct-to-server domains without CF proxy)
# Usage: assert_https_remote DOMAIN [EXPECTED_CODES] [TIMEOUT] [PATH]
assert_https_remote() {
    local domain="$1"
    local expected="${2:-200 302 301}"
    local timeout="${3:-120}"
    local path="${4:-/}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local code
        code=$(ssh "$E2E_SSH" "curl -s -o /dev/null -w '%{http_code}' --max-time 10 'https://${domain}${path}'" 2>/dev/null)

        if [ -n "$code" ] && [ "$code" != "000" ]; then
            for expected_code in $expected; do
                if [ "$code" = "$expected_code" ]; then
                    echo "$code"
                    return 0
                fi
            done
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "${code:-000}"
    return 1
}

# Delete a Cloudflare DNS record by domain name
# Usage: cf_dns_delete FULL_DOMAIN
cf_dns_delete() {
    local full_domain="$1"
    local config_file="$HOME/.config/cloudflare/config"

    [ ! -f "$config_file" ] && return 1

    local api_token root_domain zone_id
    api_token=$(grep "^API_TOKEN=" "$config_file" | cut -d= -f2)
    root_domain=$(echo "$full_domain" | rev | cut -d. -f1-2 | rev)
    zone_id=$(grep "^${root_domain}=" "$config_file" | cut -d= -f2)

    [ -z "$api_token" ] || [ -z "$zone_id" ] && return 1

    # Find the record ID (check both AAAA and A)
    local record_id=""
    for rtype in AAAA A; do
        local response
        response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$rtype&name=$full_domain" \
            -H "Authorization: Bearer $api_token" \
            -H "Content-Type: application/json" 2>/dev/null)

        record_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
        [ -n "$record_id" ] && break
    done

    [ -z "$record_id" ] && return 0  # No record found — already clean

    # Delete the record
    local del_response
    del_response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" 2>/dev/null)

    echo "$del_response" | grep -q '"success":true'
}

# Remove a domain block from Caddy on the server
# Usage: caddy_cleanup DOMAIN
caddy_cleanup() {
    local domain="$1"
    ssh "$E2E_SSH" "
        if grep -q '$domain' /etc/caddy/Caddyfile 2>/dev/null; then
            # Use Python to reliably remove the domain block (handles multi-line blocks)
            python3 -c \"
import re, sys
with open('/etc/caddy/Caddyfile', 'r') as f:
    content = f.read()
# Remove block starting with domain name
pattern = r'(?m)^${domain}\s*\{[^}]*\}\n?'
content = re.sub(pattern, '', content)
# Also strip consecutive blank lines left behind
content = re.sub(r'\n{3,}', '\n\n', content)
with open('/tmp/caddy-cleaned', 'w') as f:
    f.write(content)
\" 2>/dev/null && sudo mv /tmp/caddy-cleaned /etc/caddy/Caddyfile && sudo systemctl reload caddy 2>/dev/null
        fi
    " 2>/dev/null
}
