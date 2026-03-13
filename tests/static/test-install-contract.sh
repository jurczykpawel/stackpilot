#!/bin/bash

# StackPilot - Install Script Contract Validation
# Verifies that every apps/*/install.sh follows the required contract.
#
# Required for standard apps:
#   - set -e
#   - APP_NAME=
#   - STACK_DIR=
#   - PORT=${PORT:-  (unless TCP-only or special)
#   - docker compose  (unless special deployment)
#
# Known exceptions (non-standard deploy):
#   - coolify:     uses curl|bash installer, no STACK_DIR
#   - sellf:       PM2/Bun deployment, no docker compose
#   - littlelink:  static site, no docker compose, no STACK_DIR
#   - cookie-hub:  JS snippet, no docker compose

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Apps exempt from standard contract checks
# dockge uses DOCKGE_DIR instead of STACK_DIR and has its own naming conventions
EXEMPT_APPS="coolify sellf littlelink cookie-hub dockge"

echo "--- Install Script Contract ---"
echo ""

PASS=0
FAIL=0
SKIP=0
FAILED=()

for install_sh in "$REPO_ROOT"/apps/*/install.sh; do
    [ -f "$install_sh" ] || continue

    app=$(basename "$(dirname "$install_sh")")

    # Check if exempt
    if echo "$EXEMPT_APPS" | grep -qw "$app"; then
        SKIP=$((SKIP + 1))
        continue
    fi

    errors=()

    # Check: set -e
    if ! grep -q '^set -e' "$install_sh"; then
        errors+=("missing 'set -e'")
    fi

    # Check: APP_NAME=
    if ! grep -q 'APP_NAME=' "$install_sh"; then
        errors+=("missing APP_NAME=")
    fi

    # Check: STACK_DIR=
    if ! grep -q 'STACK_DIR=' "$install_sh"; then
        errors+=("missing STACK_DIR=")
    fi

    # Check: docker compose (at least one call, not in a comment)
    if ! grep -v '^\s*#' "$install_sh" | grep -q 'docker compose'; then
        errors+=("missing 'docker compose'")
    fi

    if [ "${#errors[@]}" -gt 0 ]; then
        FAIL=$((FAIL + 1))
        FAILED+=("$app: ${errors[*]}")
        echo -e "  ${RED}✗${NC} $app — ${errors[*]}"
    else
        PASS=$((PASS + 1))
    fi
done

echo ""
echo "  Checked: $((PASS + FAIL)), Passed: $PASS, Failed: $FAIL, Skipped: $SKIP (exempt)"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo -e "${RED}FAIL — $FAIL install script(s) violate the contract${NC}"
    exit 1
else
    echo -e "${GREEN}PASS — All $PASS install scripts follow the contract${NC}"
    exit 0
fi
