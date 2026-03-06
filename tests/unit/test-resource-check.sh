#!/bin/bash

# Tests for lib/resource-check.sh

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

# Load i18n
export TOOLBOX_LANG=en
source "$REPO_ROOT/lib/i18n.sh"

# Put mocks on PATH
export PATH="$REPO_ROOT/tests/mocks:$PATH"

# No-op provider hook (generic provider)
provider_upgrade_suggestion() { return 0; }
export -f provider_upgrade_suggestion

source "$REPO_ROOT/lib/resource-check.sh"

# =============================================================================
# get_available_ram_mb / get_available_disk_mb
# =============================================================================

test_get_available_ram() {
    export MOCK_FREE_AVAILABLE=768
    local ram
    ram=$(get_available_ram_mb)
    assert_eq "768" "$ram" "parses available RAM"
}

test_get_total_ram() {
    export MOCK_FREE_TOTAL=2048
    local total
    total=$(get_total_ram_mb)
    assert_eq "2048" "$total" "parses total RAM"
}

test_get_available_disk() {
    export MOCK_DF_AVAILABLE=10240
    local disk
    disk=$(get_available_disk_mb)
    assert_eq "10240" "$disk" "parses available disk"
}

# =============================================================================
# check_resources
# =============================================================================

test_check_resources_ok() {
    export MOCK_FREE_AVAILABLE=2048
    export MOCK_FREE_TOTAL=4096
    export MOCK_DF_AVAILABLE=10000
    check_resources 256 200 "testapp" > /dev/null 2>&1
    local status=$?
    assert_eq "0" "$status" "returns 0 when resources sufficient"
}

test_check_resources_warn() {
    export MOCK_FREE_AVAILABLE=300
    export MOCK_FREE_TOTAL=2048
    export MOCK_DF_AVAILABLE=10000
    check_resources 256 200 "testapp" > /dev/null 2>&1
    local status=$?
    assert_eq "1" "$status" "returns 1 when RAM is tight"
}

test_check_resources_fail() {
    export MOCK_FREE_AVAILABLE=100
    export MOCK_FREE_TOTAL=512
    export MOCK_DF_AVAILABLE=50
    check_resources 256 200 "testapp" > /dev/null 2>&1
    local status=$?
    assert_eq "2" "$status" "returns 2 when both RAM and disk insufficient"
}

test_check_resources_disk_fail() {
    export MOCK_FREE_AVAILABLE=2048
    export MOCK_FREE_TOTAL=4096
    export MOCK_DF_AVAILABLE=50
    check_resources 256 200 "testapp" > /dev/null 2>&1
    local status=$?
    assert_eq "2" "$status" "returns 2 when disk insufficient"
}

# =============================================================================
# quick_resource_check
# =============================================================================

test_quick_check_pass() {
    export MOCK_FREE_AVAILABLE=1024
    export MOCK_DF_AVAILABLE=5000
    quick_resource_check 256 200
    local status=$?
    assert_eq "0" "$status" "quick check passes"
}

test_quick_check_fail_ram() {
    export MOCK_FREE_AVAILABLE=100
    export MOCK_DF_AVAILABLE=5000
    quick_resource_check 256 200
    local status=$?
    assert_eq "1" "$status" "quick check fails on RAM"
}

test_quick_check_fail_disk() {
    export MOCK_FREE_AVAILABLE=1024
    export MOCK_DF_AVAILABLE=100
    quick_resource_check 256 200
    local status=$?
    assert_eq "1" "$status" "quick check fails on disk"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
