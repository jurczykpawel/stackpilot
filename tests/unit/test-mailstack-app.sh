#!/bin/bash
# Unit tests for apps/mailstack/*.mjs (install plan, Cloudflare client, orchestration), run with node:test.
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node --test "$REPO_ROOT"/tests/unit/mailstack/*.test.mjs
