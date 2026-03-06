#!/bin/bash

# StackPilot - Locale Coverage Test
# Verifies that every MSG_ key in locale/en.sh exists in locale/pl.sh and vice versa.
# Run locally — no server required.
#
# Usage:
#   ./tests/static/test-locale-coverage.sh
#   Exit code 0 = all keys match; exit code 1 = mismatches found.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EN_FILE="$REPO_ROOT/locale/en.sh"
PL_FILE="$REPO_ROOT/locale/pl.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

# Extract MSG_ key names (variable name before the = sign)
# Uses sed for BSD/macOS compatibility (no grep -P)
extract_keys() {
    grep -E '^MSG_[A-Z0-9_]+=' "$1" | sed 's/=.*//' | sort
}

EN_KEYS=$(extract_keys "$EN_FILE")
PL_KEYS=$(extract_keys "$PL_FILE")

echo "--- Locale Coverage Check ---"
echo ""

# Keys in EN but missing in PL
MISSING_IN_PL=$(comm -23 <(echo "$EN_KEYS") <(echo "$PL_KEYS"))
if [ -n "$MISSING_IN_PL" ]; then
    echo -e "${RED}Keys in en.sh missing from pl.sh:${NC}"
    while IFS= read -r key; do
        echo "  - $key"
        FAIL=$((FAIL + 1))
    done <<< "$MISSING_IN_PL"
    echo ""
fi

# Keys in PL but missing in EN
MISSING_IN_EN=$(comm -13 <(echo "$EN_KEYS") <(echo "$PL_KEYS"))
if [ -n "$MISSING_IN_EN" ]; then
    echo -e "${RED}Keys in pl.sh missing from en.sh:${NC}"
    while IFS= read -r key; do
        echo "  - $key"
        FAIL=$((FAIL + 1))
    done <<< "$MISSING_IN_EN"
    echo ""
fi

# Count matched keys
EN_COUNT=$(echo "$EN_KEYS" | wc -l | tr -d ' ')
PL_COUNT=$(echo "$PL_KEYS" | wc -l | tr -d ' ')

echo "  en.sh keys: $EN_COUNT"
echo "  pl.sh keys: $PL_COUNT"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}✅ PASS — All $EN_COUNT keys are symmetric between en.sh and pl.sh${NC}"
    exit 0
else
    echo -e "${RED}❌ FAIL — $FAIL missing key(s) found${NC}"
    exit 1
fi
