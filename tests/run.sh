#!/bin/bash

# StackPilot - Unified Test Runner
# Usage:
#   ./tests/run.sh              — run unit + static (default)
#   ./tests/run.sh unit         — unit tests only
#   ./tests/run.sh static       — static validation only
#   ./tests/run.sh e2e --ssh=HOST  — E2E integration tests
#   ./tests/run.sh all --ssh=HOST  — everything
#
# Options:
#   --filter=PATTERN    — only run tests matching PATTERN
#   --verbose           — show full output from each test

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Parse arguments
SUITE=""
FILTER=""
VERBOSE=false
SSH_ALIAS=""
E2E_SUITE=""
E2E_APP=""
QUICK=false
E2E_EXTRA_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --filter=*) FILTER="${arg#--filter=}" ;;
        --verbose)  VERBOSE=true ;;
        --ssh=*)    SSH_ALIAS="${arg#--ssh=}" ;;
        --suite=*)  E2E_SUITE="${arg#--suite=}" ;;
        --app=*)    E2E_APP="${arg#--app=}" ;;
        --quick)    QUICK=true ;;
        --domain-type=*|--domain-suffix=*|--cleanup=*) E2E_EXTRA_ARGS+=("$arg") ;;
        -*)         ;; # ignore unknown flags
        *)
            # First non-flag argument is the suite
            if [ -z "$SUITE" ]; then
                SUITE="$arg"
            fi
            ;;
    esac
done

# Default suite
if [ -z "$SUITE" ]; then
    SUITE="default"
fi

# Counters
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_FILES=()

# =============================================================================
# HELPERS
# =============================================================================

run_test_file() {
    local file="$1"
    local name
    name=$(basename "$file" .sh)

    if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
        return 0
    fi

    echo -e "${BLUE}▸${NC} $name"

    local output
    local exit_code
    output=$(bash "$file" 2>&1) && exit_code=0 || exit_code=$?

    # Count passed/failed from output
    local passed failed
    passed=$(echo "$output" | grep -c '✓' || true)
    failed=$(echo "$output" | grep -c '✗' || true)

    if [ "$VERBOSE" = true ] || [ "$exit_code" -ne 0 ]; then
        echo "$output" | sed 's/^/    /'
    else
        # Show only pass/fail summary
        if [ "$failed" -gt 0 ]; then
            echo "$output" | grep -E '(FAIL|✗)' | sed 's/^/    /'
        fi
    fi

    TOTAL_PASS=$((TOTAL_PASS + passed))
    TOTAL_FAIL=$((TOTAL_FAIL + failed))

    if [ "$exit_code" -ne 0 ]; then
        FAILED_FILES+=("$name")
        [ "$failed" -gt 0 ] || TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
}

run_static_file() {
    local file="$1"
    local name
    name=$(basename "$file" .sh)

    if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
        return 0
    fi

    echo -e "${BLUE}▸${NC} $name"

    local output
    local exit_code
    output=$(bash "$file" 2>&1) && exit_code=0 || exit_code=$?

    if [ "$VERBOSE" = true ] || [ "$exit_code" -ne 0 ]; then
        echo "$output" | sed 's/^/    /'
    fi

    if [ "$exit_code" -eq 0 ]; then
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        FAILED_FILES+=("$name")
    fi
}

# =============================================================================
# UNIT TESTS
# =============================================================================

run_unit() {
    echo ""
    echo -e "${BOLD}━━━ Unit Tests ━━━${NC}"
    echo ""

    for test_file in "$TESTS_DIR"/unit/test-*.sh; do
        [ -f "$test_file" ] || continue
        # Skip test-runner.sh (it's a library, not a test)
        [ "$(basename "$test_file")" = "test-runner.sh" ] && continue
        run_test_file "$test_file"
    done
}

# =============================================================================
# STATIC VALIDATION
# =============================================================================

run_static() {
    echo ""
    echo -e "${BOLD}━━━ Static Validation ━━━${NC}"
    echo ""

    for test_file in "$TESTS_DIR"/static/test-*.sh; do
        [ -f "$test_file" ] || continue
        run_static_file "$test_file"
    done
}

# =============================================================================
# E2E TESTS (placeholder)
# =============================================================================

run_e2e() {
    if [ -z "$SSH_ALIAS" ]; then
        echo ""
        echo -e "  ${YELLOW}SKIP${NC}: E2E tests require --ssh=HOST"
        TOTAL_SKIP=$((TOTAL_SKIP + 1))
        return 0
    fi

    local e2e_args=("--ssh=$SSH_ALIAS")
    [ -z "$E2E_SUITE" ] || e2e_args+=("--suite=$E2E_SUITE")
    [ -z "$E2E_APP" ] || e2e_args+=("--app=$E2E_APP")
    [ "$QUICK" != true ] || e2e_args+=("--quick")
    e2e_args+=("${E2E_EXTRA_ARGS[@]}")

    export E2E_RESULTS_DIR="${E2E_RESULTS_DIR:-$TESTS_DIR/e2e/results}"
    local tap_file="$E2E_RESULTS_DIR/results.tap" e2e_exit=0
    mkdir -p "$E2E_RESULTS_DIR"
    : > "$tap_file"
    bash "$TESTS_DIR/e2e/test-runner-e2e.sh" "${e2e_args[@]}" || e2e_exit=$?

    local tap_pass tap_fail tap_skip tap_total tap_plan
    tap_pass=$(grep '^ok ' "$tap_file" | grep -cv SKIP || true)
    tap_fail=$(grep -c '^not ok ' "$tap_file" || true)
    tap_skip=$(grep '^ok ' "$tap_file" | grep -c SKIP || true)
    tap_total=$((tap_pass + tap_fail + tap_skip))
    tap_plan=$(sed -n 's/^1\.\.\([0-9][0-9]*\).*/\1/p' "$tap_file" | tail -1)
    TOTAL_PASS=$((TOTAL_PASS + tap_pass))
    TOTAL_FAIL=$((TOTAL_FAIL + tap_fail))
    TOTAL_SKIP=$((TOTAL_SKIP + tap_skip))
    if [ "$e2e_exit" -ne 0 ] || [ "$tap_total" -eq 0 ] || [ "$tap_plan" != "$tap_total" ]; then
        FAILED_FILES+=("e2e (exit $e2e_exit; TAP $tap_total/${tap_plan:-missing})")
        [ "$tap_fail" -gt 0 ] || TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    return 0
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}$TOTAL_PASS passed${NC}, ${RED}$TOTAL_FAIL failed${NC}, ${YELLOW}$TOTAL_SKIP skipped${NC}"

    if [ "${#FAILED_FILES[@]}" -gt 0 ]; then
        echo ""
        echo -e "  ${RED}Failed:${NC}"
        for f in "${FAILED_FILES[@]}"; do
            echo "    - $f"
        done
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo -e "${BOLD}StackPilot Test Runner${NC}"

START_TIME=$(date +%s)

case "$SUITE" in
    unit)
        run_unit
        ;;
    static)
        run_static
        ;;
    e2e)
        run_e2e
        ;;
    all)
        run_unit
        run_static
        run_e2e
        ;;
    default)
        run_unit
        run_static
        ;;
    *)
        echo "Usage: $0 [unit|static|e2e|all] [options]"
        echo ""
        echo "Suites:"
        echo "  unit     — unit tests (tests/unit/)"
        echo "  static   — static validation (tests/static/)"
        echo "  e2e      — E2E integration tests (tests/e2e/) — requires --ssh=HOST"
        echo "  all      — everything"
        echo "  (none)   — unit + static (default)"
        echo ""
        echo "Options:"
        echo "  --filter=PATTERN    only run tests matching PATTERN"
        echo "  --verbose           show full output"
        echo "  --ssh=HOST          SSH alias for E2E tests"
        echo "  --suite=NAME        E2E suite name"
        echo "  --app=NAME          E2E single app"
        echo "  --quick             E2E quick mode (1 variant per app)"
        echo "  --domain-type=TYPE  E2E email apps: local or cloudflare"
        echo "  --domain-suffix=DNS E2E email apps: test domain suffix"
        echo "  --cleanup=POLICY    E2E cleanup policy"
        exit 1
        ;;
esac

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

print_summary
echo "  Completed in ${ELAPSED}s"
echo ""

if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
