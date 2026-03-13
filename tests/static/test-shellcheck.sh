#!/bin/bash

# StackPilot - ShellCheck Static Analysis
# Runs shellcheck on all .sh files with known exclusions.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if shellcheck is available
if ! command -v shellcheck &>/dev/null; then
    echo -e "${RED}FAIL — shellcheck not installed (required in CI)${NC}"
    exit 1
fi

# Exclusions:
#   SC1090 - Can't follow non-constant source (we source dynamic paths)
#   SC1091 - Not following sourced file (same)
#   SC2034 - Variable appears unused (MSG_ keys used by msg())
#   SC2155 - Declare and assign separately (common Bash pattern, low risk)
#   SC2086 - Double quote to prevent globbing (intentional in many places)
#   SC2129 - Consider using { cmd1; cmd2; } >> file (style preference)
#   SC2064 - Use single quotes for trap (intentional: need var expansion at define-time)
#   SC2089 - Quotes treated literally (intentional: SSH env var passing pattern)
#   SC2090 - Quotes treated literally (related to SC2089)
#   SC2163 - Export dynamic variable name (valid: export "$VAR_NAME" works in Bash)
#   SC2010 - ls|grep (acceptable in non-critical cleanup contexts)
EXCLUDES="SC1090,SC1091,SC2034,SC2155,SC2086,SC2129,SC2064,SC2089,SC2090,SC2163,SC2010"

# Files to skip entirely (generated, third-party, or locale data)
SKIP_PATTERNS=(
    "locale/en.sh"
    "locale/pl.sh"
    "tests/mocks/"
    "mcp-server/"
    "node_modules/"
    ".git/"
)

echo "--- ShellCheck Analysis ---"
echo ""

PASS=0
FAIL=0
SKIP=0
FAILED_FILES=()

# Find all .sh files
while IFS= read -r -d '' file; do
    rel="${file#$REPO_ROOT/}"

    # Check skip patterns
    skip=false
    for pattern in "${SKIP_PATTERNS[@]}"; do
        if [[ "$rel" == *"$pattern"* ]]; then
            skip=true
            break
        fi
    done
    if [ "$skip" = true ]; then
        SKIP=$((SKIP + 1))
        continue
    fi

    # Run shellcheck
    output=$(shellcheck -e "$EXCLUDES" -S warning "$file" 2>&1) && sc_exit=0 || sc_exit=$?

    if [ "$sc_exit" -eq 0 ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_FILES+=("$rel")
        echo -e "  ${RED}✗${NC} $rel"
        echo "$output" | head -20 | sed 's/^/    /'
        if [ "$(echo "$output" | wc -l)" -gt 20 ]; then
            echo "    ... (truncated)"
        fi
    fi
done < <(find "$REPO_ROOT" -name "*.sh" -type f -print0 | sort -z)

echo ""
echo "  Checked: $((PASS + FAIL)), Passed: $PASS, Failed: $FAIL, Skipped: $SKIP"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo -e "${RED}FAIL — $FAIL file(s) have shellcheck warnings${NC}"
    for f in "${FAILED_FILES[@]}"; do
        echo "  - $f"
    done
    exit 1
else
    echo -e "${GREEN}PASS — All $PASS files pass shellcheck${NC}"
    exit 0
fi
