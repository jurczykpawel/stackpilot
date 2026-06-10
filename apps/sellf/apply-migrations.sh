#!/bin/bash

# StackPilot - Sellf DB migrations (runs ON the server)
# Author: Paweł (Lazy Engineer)
#
# Applies pending Sellf migrations to the instance's OWN Supabase project using
# the instance's SUPABASE_SERVICE_ROLE_KEY together with Sellf's apply_migration
# RPC (created by migration 20260303_migration_rpc.sql). The service-role key is
# read from the instance's .env.local and NEVER leaves the server — no global
# Personal Access Token, no global PROJECT_REF, always the correct project.
#
# This is invoked by local/setup-supabase-migrations.sh, which ships it here and
# runs it via server_exec. It can also be run directly on a server.
#
# Exit codes:
#   0  - migrations applied (or already up to date)
#   1  - hard error (bad config, a migration failed, auth error)
#   3  - apply_migration RPC not present yet (fresh DB) -> caller should bootstrap
#
# Env:
#   INSTANCE - instance name -> /opt/stacks/sellf-<INSTANCE> (fallback: first sellf-*)
#
# Requires on the server: python3, curl.

set -euo pipefail

INSTANCE="${INSTANCE:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---------------------------------------------------------------------------
# 1. Locate the instance directory
# ---------------------------------------------------------------------------
find_dir() {
  local name="$1"
  if [ -n "$name" ] && [ -d "/opt/stacks/sellf-$name" ]; then
    echo "/opt/stacks/sellf-$name"
  elif [ -n "$name" ] && [ -d "/root/sellf-$name" ]; then
    echo "/root/sellf-$name"
  elif ls -d /opt/stacks/sellf-* >/dev/null 2>&1; then
    ls -d /opt/stacks/sellf-* | head -1
  elif [ -d /opt/stacks/sellf ]; then
    echo "/opt/stacks/sellf"
  elif ls -d /root/sellf-* >/dev/null 2>&1; then
    ls -d /root/sellf-* | head -1
  fi
}

D="$(find_dir "$INSTANCE")"
if [ -z "$D" ] || [ ! -d "$D" ]; then
  echo -e "${RED}❌ No Sellf instance directory found (looked for sellf-${INSTANCE:-*})${NC}" >&2
  exit 1
fi

ENV_FILE="$D/admin-panel/.env.local"
MIG_DIR="$D/admin-panel/supabase/migrations"

if [ ! -f "$ENV_FILE" ]; then
  echo -e "${RED}❌ Missing $ENV_FILE${NC}" >&2
  exit 1
fi
if [ ! -d "$MIG_DIR" ]; then
  echo -e "${YELLOW}⚠️  No migrations directory at $MIG_DIR — nothing to apply${NC}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Read connection details from the instance's own .env.local
# ---------------------------------------------------------------------------
SUPABASE_URL="$(grep -E '^SUPABASE_URL=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
SERVICE_KEY="$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
SUPABASE_URL="${SUPABASE_URL%\"}"; SUPABASE_URL="${SUPABASE_URL#\"}"
SERVICE_KEY="${SERVICE_KEY%\"}"; SERVICE_KEY="${SERVICE_KEY#\"}"

if [ -z "$SUPABASE_URL" ] || [ -z "$SERVICE_KEY" ]; then
  echo -e "${RED}❌ SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set in $ENV_FILE${NC}" >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo -e "${RED}❌ python3 is required on the server${NC}" >&2; exit 1; }
command -v curl    >/dev/null 2>&1 || { echo -e "${RED}❌ curl is required on the server${NC}" >&2; exit 1; }

PROJECT="$(printf '%s' "$SUPABASE_URL" | sed -E 's#^https?://([^./]+).*#\1#')"
echo -e "${BLUE}🗄️  Sellf migrations${NC} → instance '$(basename "$D")' (project: ${PROJECT})"

rpc() {
  # rpc <name> <json-body-file-or-inline> -> prints "<http_code>\n<body>"
  local name="$1" data="$2"
  curl -sS -o /tmp/.sp-rpc-body."$$" -w '%{http_code}' \
    -X POST "${SUPABASE_URL%/}/rest/v1/rpc/${name}" \
    -H "apikey: ${SERVICE_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" \
    -H "Content-Type: application/json" --data "$data"
}

# ---------------------------------------------------------------------------
# 3. Which migrations are already applied? (get_migration_status RPC)
# ---------------------------------------------------------------------------
STATUS_CODE="$(rpc get_migration_status '{}' || true)"
STATUS_BODY="$(cat /tmp/.sp-rpc-body."$$" 2>/dev/null || true)"
rm -f /tmp/.sp-rpc-body."$$"

case "$STATUS_CODE" in
  200) : ;;  # ok
  404)
    echo -e "${YELLOW}ℹ️  apply_migration RPC not present yet (fresh database).${NC}"
    exit 3 ;;
  *)
    echo -e "${RED}❌ get_migration_status RPC failed (HTTP ${STATUS_CODE:-???})${NC}" >&2
    echo "   $STATUS_BODY" | head -1 >&2
    # PostgREST reports a missing function as 404, but some setups answer 400/PGRST202.
    if printf '%s' "$STATUS_BODY" | grep -q 'PGRST202\|Could not find the function'; then
      echo -e "${YELLOW}ℹ️  Treating as fresh database (RPC missing).${NC}"
      exit 3
    fi
    exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 4. Apply each pending migration via apply_migration RPC (checksum-verified)
# ---------------------------------------------------------------------------
applied_new=0
already=0
for f in "$MIG_DIR"/*.sql; do
  [ -e "$f" ] || continue
  version="$(basename "$f" .sql)"
  # get_migration_status returns "<14digits>_<name>" entries
  if printf '%s' "$STATUS_BODY" | grep -q "\"${version}\""; then
    already=$((already + 1))
    continue
  fi

  if out="$(python3 - "$f" "$version" "$SUPABASE_URL" "$SERVICE_KEY" 2>&1 <<'PY'
import json, hashlib, sys, urllib.request, urllib.error
path, version, url, key = sys.argv[1:5]
sql = open(path, encoding='utf-8').read()
body = json.dumps({
    "migration_version": version,
    "migration_sql": sql,
    "content_checksum": hashlib.sha256(sql.encode('utf-8')).hexdigest(),
}).encode('utf-8')
req = urllib.request.Request(
    url.rstrip('/') + "/rest/v1/rpc/apply_migration", data=body, method="POST",
    headers={"apikey": key, "Authorization": "Bearer " + key,
             "Content-Type": "application/json"})
try:
    sys.stdout.write(urllib.request.urlopen(req, timeout=180).read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write("HTTP %s: %s" % (e.code, e.read().decode()))
    sys.exit(1)
except Exception as e:  # noqa: BLE001
    sys.stderr.write(str(e))
    sys.exit(1)
PY
  )"; then
    echo -e "  ${GREEN}✅${NC} $version"
    applied_new=$((applied_new + 1))
  else
    echo -e "  ${RED}❌ $version${NC}" >&2
    printf '%s\n' "$out" | sed 's/^/     /' >&2
    echo -e "${RED}❌ Migration failed — aborting${NC}" >&2
    exit 1
  fi
done

echo -e "${GREEN}✅ Database ready${NC} — ${applied_new} applied, ${already} already present"
