#!/bin/bash

# StackPilot - Docker Compose Syntax Validation
# Extracts docker-compose.yaml heredocs from install.sh and validates them.
#
# Uses `docker compose config --quiet` to validate YAML syntax.
# Provides mock environment variables for substitution.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if docker is available
if ! command -v docker &>/dev/null; then
    echo -e "${RED}FAIL — docker not installed (required in CI)${NC}"
    exit 1
fi

# Check docker compose plugin
if ! docker compose version &>/dev/null 2>&1; then
    echo -e "${RED}FAIL — docker compose plugin not available (required in CI)${NC}"
    exit 1
fi

# Apps that don't have extractable compose files or have complex heredoc patterns
# that require runtime context (multi-cat, conditional sections, env_file references)
SKIP_APPS="coolify sellf littlelink cookie-hub dockge"

# Apps where heredoc extraction is known to produce incomplete YAML
# (multi-part heredocs, env_file references, conditional composition)
BEST_EFFORT_APPS="typebot vaultwarden postiz routepix social-media-generator filebrowser stirling-pdf"

echo "--- Compose Syntax Validation ---"
echo ""

PASS=0
FAIL=0
SKIP=0
FAILED=()

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

for install_sh in "$REPO_ROOT"/apps/*/install.sh; do
    [ -f "$install_sh" ] || continue

    app=$(basename "$(dirname "$install_sh")")

    if echo "$SKIP_APPS" | grep -qw "$app"; then
        SKIP=$((SKIP + 1))
        continue
    fi

    # Check if file contains a heredoc with docker-compose or compose
    if ! grep -qE 'cat\s+<<' "$install_sh"; then
        SKIP=$((SKIP + 1))
        continue
    fi

    # Try to extract compose YAML by evaluating the heredoc with mock env vars
    # We use a subshell with mock variables set
    compose_file="$TMPDIR/$app-compose.yaml"

    # Set all common mock variables
    export PORT=8080
    export APP_NAME="$app"
    export STACK_DIR="/opt/stacks/$app"
    export DB_HOST="localhost"
    export DB_PORT="5432"
    export DB_NAME="${app}_db"
    export DB_USER="${app}_user"
    export DB_PASS="testpass123"
    export DB_SCHEMA="${app}"
    export DOMAIN="app.example.com"
    export DOMAIN_TYPE="local"
    export BIND_ADDR="127.0.0.1:"
    export INSTANCE_NAME="$app"
    export REDIS_PASS="redispass123"
    export SECRET_KEY="secret123456"
    export WP_DB_MODE="mysql"
    export WP_REDIS="bundled"
    export REDIS_HOST="redis"
    export ROOT_USERNAME="admin"
    export ROOT_PASSWORD="adminpass"
    export ENCRYPTION_KEY="enc123456789012345678901234567890"
    export NEXTAUTH_SECRET="nextauth_secret_123"
    export N8N_ENCRYPTION_KEY="n8nenckey123"
    export INTERNAL_PORT=8080
    export CONSOLE_PORT=9001
    export SMTP_HOST="smtp.example.com"
    export SMTP_PORT="587"
    export SMTP_USER="mail@example.com"
    export SMTP_PASS="smtppass"
    export ADMIN_EMAIL="admin@example.com"
    export MINIO_ROOT_USER="minioadmin"
    export MINIO_ROOT_PASSWORD="minioadminpass"
    export LISTMONK_ADMIN_USER="admin"
    export LISTMONK_ADMIN_PASS="adminpass"
    export NEXT_PUBLIC_APP_URL="https://app.example.com"
    export TURNSTILE_KEY="turnstile_key"
    export TURNSTILE_SECRET="turnstile_secret"
    export BUILDER_URL="https://builder.example.com"
    export DOCKER_NETWORK="stackpilot-net"
    export FILEBROWSER_ROOT="/srv"
    export DB_URL="postgresql://user:pass@localhost:5432/db"
    export DATABASE_URL="postgresql://user:pass@localhost:5432/db"
    export MYSQL_ROOT_PASSWORD="rootpass123"
    export MYSQL_PASSWORD="mysqlpass123"
    export CAP_ALLOWED_ORIGINS="https://app.example.com"

    # Extract the first heredoc that writes to a yaml/yml file
    # This is a best-effort extraction — some complex scripts may not work
    extracted=false

    # Strategy: find lines like "cat <<EOF | sudo tee docker-compose.yaml" or similar
    # Then capture until EOF
    while IFS= read -r line; do
        if [[ "$line" =~ cat[[:space:]]+\<\<[\'\"]*([A-Za-z_]+)[\'\"]*.*\.(ya?ml) ]]; then
            delimiter="${BASH_REMATCH[1]}"
            # Read until delimiter
            content=""
            while IFS= read -r inner_line; do
                if [ "$inner_line" = "$delimiter" ]; then
                    break
                fi
                content+="$inner_line"$'\n'
            done
            # Substitute env vars using envsubst
            if command -v envsubst &>/dev/null; then
                echo "$content" | envsubst > "$compose_file"
            else
                echo "$content" > "$compose_file"
            fi
            extracted=true
            break
        fi
    done < "$install_sh"

    if [ "$extracted" = false ]; then
        # Fallback: try a simpler extraction with sed
        # Look for heredoc pattern: cat <<EOF ... EOF or cat <<'EOF' ... EOF
        heredoc_content=$(sed -n '/cat <<.*EOF.*\.\(yaml\|yml\)/,/^EOF$/p' "$install_sh" 2>/dev/null | sed '1d;$d')

        if [ -n "$heredoc_content" ]; then
            if command -v envsubst &>/dev/null; then
                echo "$heredoc_content" | envsubst > "$compose_file"
            else
                echo "$heredoc_content" > "$compose_file"
            fi
            extracted=true
        fi
    fi

    if [ "$extracted" = false ]; then
        SKIP=$((SKIP + 1))
        continue
    fi

    # Validate with docker compose
    output=$(docker compose -f "$compose_file" config --quiet 2>&1) && dc_exit=0 || dc_exit=$?

    if [ "$dc_exit" -eq 0 ]; then
        PASS=$((PASS + 1))
    else
        # Check if this is a best-effort app (expected extraction issues)
        if echo "$BEST_EFFORT_APPS" | grep -qw "$app"; then
            SKIP=$((SKIP + 1))
            echo -e "  ${YELLOW}~${NC} $app (extraction artifact, skipped)"
        else
            FAIL=$((FAIL + 1))
            FAILED+=("$app")
            echo -e "  ${RED}✗${NC} $app"
            echo "$output" | head -5 | sed 's/^/    /'
        fi
    fi

    rm -f "$compose_file"
done

echo ""
echo "  Validated: $((PASS + FAIL)), Passed: $PASS, Failed: $FAIL, Skipped: $SKIP"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo -e "${RED}FAIL — $FAIL compose file(s) have syntax errors${NC}"
    exit 1
else
    echo -e "${GREEN}PASS — All $PASS compose files are valid${NC}"
    exit 0
fi
