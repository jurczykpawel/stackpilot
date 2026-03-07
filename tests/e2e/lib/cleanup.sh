#!/bin/bash

# StackPilot - E2E Cleanup
# Removes deployed apps after testing.

# Clean up a single app
# Usage: cleanup_app APP_NAME
cleanup_app() {
    local app="$1"

    # Standard path: /opt/stacks/$app
    # Note: --rmi all is intentionally omitted to preserve image cache between runs
    # (avoids Docker Hub rate limits when running tests multiple times)
    ssh "$E2E_SSH" "cd /opt/stacks/$app 2>/dev/null && docker compose down -v 2>/dev/null; rm -rf /opt/stacks/$app" 2>/dev/null

    # Dockge special case: /opt/dockge
    if [ "$app" = "dockge" ]; then
        ssh "$E2E_SSH" "cd /opt/dockge 2>/dev/null && docker compose down -v 2>/dev/null; rm -rf /opt/dockge" 2>/dev/null
    fi

    # Prune only dangling (untagged) images — keep named images for reuse
    ssh "$E2E_SSH" "docker image prune -f" >/dev/null 2>&1

    sleep 2
}

# Clean up all test stacks (nuclear option)
# Usage: cleanup_all
cleanup_all() {
    echo -e "  ${E2E_YELLOW}Cleaning up all test stacks...${E2E_NC}"

    # List all stacks and stop them
    ssh "$E2E_SSH" '
        for dir in /opt/stacks/*/; do
            [ -f "$dir/docker-compose.yaml" ] || [ -f "$dir/docker-compose.yml" ] || continue
            cd "$dir" && docker compose down -v --rmi all 2>/dev/null
        done
        # Dockge
        [ -d /opt/dockge ] && cd /opt/dockge && docker compose down -v --rmi all 2>/dev/null
        # Prune
        docker image prune -af 2>/dev/null
        docker volume prune -f 2>/dev/null
    ' 2>/dev/null

    echo -e "  ${E2E_GREEN}Done${E2E_NC}"
}

# Full domain cleanup: app + DNS record + Caddy config
# Usage: cleanup_domain_app APP_NAME DOMAIN
cleanup_domain_app() {
    local app="$1"
    local domain="$2"

    echo -e "  ${E2E_YELLOW}Cleaning up $app + domain $domain...${E2E_NC}"

    # 1. Stop and remove Docker stack
    cleanup_app "$app"

    # 2. Remove DNS record from Cloudflare
    if cf_dns_delete "$domain"; then
        echo -e "  ${E2E_GREEN}DNS record removed: $domain${E2E_NC}"
    else
        echo -e "  ${E2E_YELLOW}DNS cleanup: no record found or already removed${E2E_NC}"
    fi

    # 3. Remove Caddy reverse proxy config
    caddy_cleanup "$domain"
    echo -e "  ${E2E_GREEN}Caddy config cleaned${E2E_NC}"
}

# Conditionally clean up based on E2E_CLEANUP policy
# Usage: maybe_cleanup APP_NAME PASSED
maybe_cleanup() {
    local app="$1"
    local passed="$2"  # true/false

    case "$E2E_CLEANUP" in
        always)
            cleanup_app "$app"
            ;;
        on-pass)
            if [ "$passed" = true ]; then
                cleanup_app "$app"
            else
                echo -e "  ${E2E_YELLOW}Keeping $app for debugging (cleanup=on-pass)${E2E_NC}"
            fi
            ;;
        never)
            echo -e "  ${E2E_YELLOW}Keeping $app (cleanup=never)${E2E_NC}"
            ;;
    esac
}
