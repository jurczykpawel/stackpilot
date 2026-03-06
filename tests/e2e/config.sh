#!/bin/bash

# StackPilot - E2E Test Configuration
# Sourced by all E2E test suites.

# SSH host (override via --ssh= or SSH_HOST env)
E2E_SSH="${E2E_SSH:-vps}"

# Timeouts
E2E_DEPLOY_TIMEOUT=120       # max seconds for deploy
E2E_HEALTH_TIMEOUT=60        # max seconds for health check
E2E_HEALTH_TIMEOUT_HEAVY=120 # for heavy apps (stirling-pdf, wordpress, etc.)

# Cleanup policy: "always" | "on-pass" | "never"
E2E_CLEANUP="always"

# Resource thresholds (MB) — skip app if below
E2E_MIN_RAM=250     # available RAM to attempt any deploy
E2E_MIN_DISK=500    # available disk (MB)

# Repo root
E2E_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Results directory
E2E_RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results"
mkdir -p "$E2E_RESULTS_DIR"

# Colors
E2E_RED='\033[0;31m'
E2E_GREEN='\033[0;32m'
E2E_YELLOW='\033[1;33m'
E2E_BLUE='\033[0;34m'
E2E_BOLD='\033[1m'
E2E_NC='\033[0m'

# Counters
E2E_PASS=0
E2E_FAIL=0
E2E_SKIP=0
E2E_RESULTS=()
