#!/bin/bash
# Shared by backup.sh and update.sh.
set -euo pipefail
umask 077

fail() {
    echo "Error: $*" >&2
    exit 1
}

check_dependencies() {
    local COMMAND MISSING=""
    for COMMAND in curl jq restic; do
        command -v "$COMMAND" >/dev/null || MISSING+=" $COMMAND"
    done
    docker compose version >/dev/null 2>&1 || MISSING+=" docker compose"
    if [ -n "$MISSING" ]; then
        fail "Missing dependencies:$MISSING. On Debian or Ubuntu, run 'sudo apt-get install -y jq restic curl'. For Docker Compose, install Docker and its Compose plugin."
    fi
}
check_dependencies

compose() {
    docker compose "$@"
}

lock_stack() {
    cd "$STACK_DIR" || exit
    STATE="$PWD/.stackpilot-immich"
    mkdir "$STATE.lock" 2>/dev/null || fail "Stack is locked. Check $STATE.lock."
    trap 'rmdir "$STATE.lock"' EXIT
    mkdir -p "$STATE"
}

stack_config() {
    local CONFIG
    CONFIG=$(compose config --format json)
    # Read the resolved Compose configuration without sourcing .env as shell code.
    # shellcheck disable=SC2034
    MEDIA=$(jq -er '.services["immich-server"].volumes[] | select(.target == "/data" and .type == "bind") | .source' <<< "$CONFIG")
    # shellcheck disable=SC2034
    DB_PATH=$(jq -er '.services.database.volumes[] | select(.target == "/var/lib/postgresql/data" and .type == "bind") | .source' <<< "$CONFIG")
    DB_USER=$(jq -er '.services.database.environment.POSTGRES_USER' <<< "$CONFIG")
    DB_NAME=$(jq -er '.services.database.environment.POSTGRES_DB' <<< "$CONFIG")
}

server_api() {
    local BINDING
    BINDING=$(compose port immich-server 2283 2>/dev/null) || return 1
    BINDING=${BINDING%%$'\n'*}
    curl -fs --max-time 3 "http://127.0.0.1:${BINDING##*:}/api/server/$1"
}

server_version() {
    server_api version | jq -er '"v\(.major).\(.minor).\(.patch)" | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))'
}

wait_for_immich() {
    local EXPECTED=$1 DEADLINE=$((SECONDS + HEALTH_TIMEOUT))
    while (( SECONDS < DEADLINE )); do
        if server_api ping | jq -e '.res == "pong"' >/dev/null &&
            [ "$(server_version)" = "$EXPECTED" ]; then
            return 0
        fi
        sleep 2
    done
    echo "Immich did not report pong and version $EXPECTED before the deadline." >&2
    return 1
}

# Immich documents a fresh pg_dump for CLI backups and stopping the server to
# keep the database and media in sync. Scheduled Immich dumps may be older.
# https://docs.immich.app/administration/backup-and-restore/#restore-via-command-line
dump_database() {
    compose exec -T database pg_dump --clean --if-exists -U "$DB_USER" -d "$DB_NAME" |
        gzip > "$1"
}

restore_database() {
    local DEADLINE=$((SECONDS + 120))
    until compose exec -T database pg_isready -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; do
        (( SECONDS < DEADLINE )) || return 1
        sleep 2
    done
    gzip -dc "$1" |
        sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" |
        compose exec -T database psql -X -q --single-transaction -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME"
}

STACK_DIR=${IMMICH_STACK_DIR:-/opt/stacks/immich}
HEALTH_TIMEOUT=${IMMICH_HEALTH_TIMEOUT:-600}
[[ "$HEALTH_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || fail "Set IMMICH_HEALTH_TIMEOUT to a positive number of seconds."
unset IMMICH_VERSION
trap 'exit 130' INT
trap 'exit 143' TERM
