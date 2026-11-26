#!/bin/bash

# StackPilot - Unit tests for system/backup-core.sh (restic backup engine)
# Docker, restic, curl and flock are stubs on PATH; fixtures describe containers and mounts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/test-runner.sh"
ENGINE="$REPO_ROOT/system/backup-core.sh"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    T=$TEST_TMPDIR
    STACKS="$T/stacks"
    FIX="$T/fixtures"
    LOG="$T/calls.log"
    mkdir -p "$T/bin" "$FIX/mounts" "$STACKS" "$T/snap"
    : > "$LOG"
    : > "$FIX/containers"
    cat > "$T/backup.env" <<EOF
RESTIC_REPOSITORY=$T/repo
RESTIC_PASSWORD=test-password
BACKUP_PING_URL=https://hc.example/ping/abc
EOF

    cat > "$T/bin/docker" <<'STUB'
#!/bin/bash
printf 'docker %s\n' "$*" >> "$LOG"
case "$1" in
    ps) cut -d'|' -f1 "$FIX/containers"; exit 0 ;;
    inspect)
        if [[ "$*" == *Mounts* ]]; then cat "$FIX/mounts/${*: -1}" 2>/dev/null; else cat "$FIX/containers"; fi
        exit 0 ;;
    exec)
        shift; [ "$1" = -i ] && { shift; cat > "$FIX/stdin.$1"; }
        id=$1; shift
        case "$*" in
            *"/proc/1/comm"*) echo "${MOCK_COMM:-postgres}"; exit 0 ;;
        esac
        printf '%s\n' "$*" >> "$FIX/exec.$id"
        [ "$id" = "${MOCK_EXEC_FAIL:-}" ] && exit 1
        echo "DUMP:$id"; exit 0 ;;
    run) shift; printf 'run-env PGPASSWORD=%s MYSQL_PWD=%s\n' "${PGPASSWORD:-}" "${MYSQL_PWD:-}" >> "$LOG"; echo "EXTERNAL-DUMP"; exit 0 ;;
    volume)
        [ "$2" = inspect ] && { echo "$T/newvol/${*: -1}"; mkdir -p "$T/newvol/${*: -1}"; }
        exit 0 ;;
    compose)
        [ "$2" = ps ] && echo c1
        exit 0 ;;
esac
STUB

    cat > "$T/bin/restic" <<'STUB'
#!/bin/bash
printf 'restic %s\n' "$*" >> "$LOG"
case "$1" in
    version) echo "restic 0.19.1 compiled with go1.24 on linux/amd64" ;;
    cat) exit "${MOCK_RESTIC_CAT_EXIT:-0}" ;;
    init)
        case "${MOCK_REPO:-existing}" in
            missing) echo "created restic repository" ;;
            existing) echo "Fatal: create key failed: repository master key and config already initialized" >&2; exit 1 ;;
            *) echo "Fatal: create repository failed: client.BucketExists: Access Denied" >&2; exit 1 ;;
        esac ;;
    backup) exit "${MOCK_RESTIC_BACKUP_EXIT:-0}" ;;
    restore)
        target="" include=""
        while [ $# -gt 0 ]; do
            case "$1" in --target) target=$2; shift ;; --include) include=$2; shift ;; esac
            shift
        done
        if [ -e "$MOCK_SNAP_ROOT$include" ]; then
            mkdir -p "$target$(dirname "$include")"
            cp -R "$MOCK_SNAP_ROOT$include" "$target$(dirname "$include")/"
        fi ;;
esac
exit 0
STUB

    printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$LOG"\n' > "$T/bin/curl"
    printf '#!/bin/bash\nexit 0\n' > "$T/bin/flock"
    chmod +x "$T/bin/"*

    export LOG FIX T
    export MOCK_SNAP_ROOT="$T/snap"; SNAP=$MOCK_SNAP_ROOT
    export PATH="$T/bin:$PATH"
    export BACKUP_ENV="$T/backup.env"
    export STACKS_DIR="$STACKS"
    export BACKUP_STAGE="$T/stage"
    export BACKUP_PATHS="$STACKS $T/missing"
    export BACKUP_CRON_FILE="$T/cron"
    export BACKUP_LOCK_FILE="$T/lock"
    export DB_CREDENTIALS_FILE="$T/db-credentials.conf"
    export BACKUP_RESTORE_TMP="$T/restore-tmp"
    unset MOCK_EXEC_FAIL MOCK_RESTIC_CAT_EXIT MOCK_RESTIC_BACKUP_EXIT MOCK_COMM
}

add_container() { # id|workdir|service|image|running, then mount lines type|name|source|dest
    local line=$1
    shift
    echo "$line" >> "$FIX/containers"
    : > "$FIX/mounts/${line%%|*}"
    local m
    for m in "$@"; do echo "$m" >> "$FIX/mounts/${line%%|*}"; done
}

backup_args() { grep '^restic backup' "$LOG"; }

test_run_dumps_running_databases_and_skips_their_raw_data() {
    mkdir -p "$STACKS/umami" "$STACKS/immich/postgres" "$STACKS/immich/init" "$STACKS/mailcheap" "$STACKS/cap" "$STACKS/routepix"
    add_container "c1|$STACKS/umami|db|postgres:16-alpine|true" "volume|umami_db-data|$T/vol/umami_db-data/_data|/var/lib/postgresql/data"
    add_container "c2|$STACKS/umami|umami|ghcr.io/umami-software/umami:postgresql-latest|true"
    add_container "c3|$STACKS/immich|database|ghcr.io/immich-app/postgres:14-vectorchord0.4.3|true" \
        "bind||$STACKS/immich/postgres|/var/lib/postgresql/data" "bind||$STACKS/immich/init|/docker-entrypoint-initdb.d"
    add_container "c4|$STACKS/mailcheap|mongo|mongo:7.0.45|true" "volume|mailcheap_mongo-data|$T/vol/mailcheap_mongo-data/_data|/data/db"
    add_container "c5|$STACKS/cap|mysql|mysql:8.0|false" "volume|cap_db-data|$T/vol/cap_db-data/_data|/var/lib/mysql"
    add_container "c6|$STACKS/routepix|app|ghcr.io/x/routepix:latest|true" "volume|routepix_app_data|$T/vol/routepix_app_data/_data|/app/data"
    add_container "c7|/home/someone/proj|db|postgres:16|true" "volume|proj_db|$T/vol/proj_db/_data|/var/lib/postgresql/data"

    bash "$ENGINE" run > "$T/out" 2>&1
    assert_eq "0" "$?" "run succeeds" || cat "$T/out"

    assert_contains "$(cat "$T/stage/db/umami/db.postgres")" "DUMP:c1" "postgres dump written"
    assert_contains "$(cat "$FIX/exec.c1")" "pg_dumpall" "postgres dumped with pg_dumpall"
    assert_contains "$(cat "$T/stage/db/umami/db.mount")" "$(printf 'volume\tumami_db-data')" "DB volume recorded for restore"
    assert_contains "$(cat "$FIX/exec.c4")" "mongodump" "MongoDB dumped"
    assert_true test -s "$T/stage/db/mailcheap/mongo.mongo"
    assert_contains "$(cat "$T/stage/db/immich/database.mount")" "$STACKS/immich/postgres" "bind DB dir recorded"
    assert_false test -e "$FIX/exec.c5"
    assert_false test -e "$FIX/exec.c7"

    local args
    args=$(backup_args)
    assert_contains "$args" "--exclude $STACKS/immich/postgres" "live bind DB dir excluded"
    assert_not_contains "$args" "--exclude $STACKS/immich/init" "init scripts stay in the backup"
    assert_contains "$args" "$T/vol/routepix_app_data/_data" "app volume backed up"
    assert_contains "$args" "$T/vol/cap_db-data/_data" "stopped DB volume backed up raw"
    assert_not_contains "$args" "umami_db-data" "dumped DB volume not copied raw"
    assert_not_contains "$args" "mailcheap_mongo-data" "dumped Mongo volume not copied raw"
    assert_not_contains "$args" "$T/missing" "missing paths skipped"
    assert_contains "$args" "--tag stackpilot" "snapshot tagged"
    assert_contains "$(cat "$T/stage/volumes/routepix.list")" "$(printf 'routepix_app_data\t%s' "$T/vol/routepix_app_data/_data")" "volume manifest"
    assert_contains "$(cat "$T/stage/stacks.list")" "routepix" "stack list"
    assert_contains "$(grep '^restic forget' "$LOG")" "--prune" "retention applied"
    assert_contains "$(grep '^curl' "$LOG")" "https://hc.example/ping/abc" "success ping"
    assert_not_contains "$(grep '^curl' "$LOG")" "/fail" "no failure ping"
}

test_run_takes_consistent_sqlite_snapshots() {
    command -v sqlite3 >/dev/null || { skip_test "sqlite3 not installed"; return 0; }
    mkdir -p "$STACKS/vaultwarden/data"
    sqlite3 "$STACKS/vaultwarden/data/db.sqlite3" "PRAGMA journal_mode=WAL; CREATE TABLE t(v); INSERT INTO t VALUES ('secret-row');" > /dev/null
    echo "not a database" > "$STACKS/vaultwarden/data/notes.db"

    bash "$ENGINE" run > "$T/out" 2>&1
    assert_eq "0" "$?" "run succeeds" || cat "$T/out"
    local index
    index=$(cat "$T/stage/sqlite/vaultwarden/index")
    assert_eq "1" "$(wc -l < "$T/stage/sqlite/vaultwarden/index" | tr -d ' ')" "only real SQLite files"
    assert_contains "$index" "$STACKS/vaultwarden/data/db.sqlite3" "original path recorded"
    assert_not_contains "$(cat "$T/out")" "No such file" "no shell errors in the log"
    assert_eq "secret-row" "$(sqlite3 "$T/stage/sqlite/vaultwarden/1.sqlite" 'SELECT v FROM t')" "snapshot readable"
}

test_run_failure_still_backs_up_and_sends_failure_ping() {
    mkdir -p "$STACKS/umami"
    add_container "c1|$STACKS/umami|db|postgres:16-alpine|true" "volume|umami_db-data|$T/vol/umami_db-data/_data|/var/lib/postgresql/data"
    MOCK_EXEC_FAIL=c1 bash "$ENGINE" run > "$T/out" 2>&1
    assert_not_eq "0" "$?" "run reports failure"
    assert_true grep -q '^restic backup' "$LOG"
    assert_contains "$(grep '^curl' "$LOG")" "https://hc.example/ping/abc/fail" "failure ping"
    assert_false test -e "$T/stage/db/umami/db.postgres"
}

test_run_fails_when_restic_backup_fails() {
    MOCK_RESTIC_BACKUP_EXIT=3 bash "$ENGINE" run > "$T/out" 2>&1
    assert_not_eq "0" "$?" "incomplete snapshot is a failure"
    assert_contains "$(grep '^curl' "$LOG")" "/fail" "failure ping"
}

test_run_dumps_external_databases_without_password_in_arguments() {
    cat > "$DB_CREDENTIALS_FILE" <<'EOF'
CUSTOM_DATABASES=(
    "shared-pg:postgres:db.example.net:5432:appdb:appuser:S3cr3tPass"
)
EOF
    bash "$ENGINE" run > "$T/out" 2>&1
    assert_eq "0" "$?" "run succeeds" || cat "$T/out"
    assert_contains "$(cat "$T/stage/external/shared-pg.postgres")" "EXTERNAL-DUMP" "external dump written"
    assert_contains "$(grep '^docker run' "$LOG")" "pg_dump" "dumped with pg_dump"
    assert_not_contains "$(grep '^docker run' "$LOG")" "S3cr3tPass" "password not in arguments"
    assert_contains "$(grep '^run-env' "$LOG")" "PGPASSWORD=S3cr3tPass" "password passed via environment"
}

test_init_creates_missing_repository_and_cron() {
    MOCK_REPO=missing bash "$ENGINE" init > "$T/out" 2>&1
    assert_eq "0" "$?" "init succeeds" || cat "$T/out"
    assert_true grep -q '^restic init' "$LOG"
    assert_contains "$(cat "$T/cron")" "stackpilot-backup run" "cron job installed"
}

test_init_keeps_existing_repository() {
    bash "$ENGINE" init > "$T/out" 2>&1
    assert_eq "0" "$?" "init succeeds" || cat "$T/out"
    assert_true grep -q '^restic cat config' "$LOG"
    assert_contains "$(cat "$T/out")" "existing repository" "reuse reported"
}

test_init_rejects_wrong_password_for_existing_repository() {
    MOCK_RESTIC_CAT_EXIT=12 bash "$ENGINE" init > "$T/out" 2>&1
    assert_not_eq "0" "$?" "init fails"
    assert_contains "$(cat "$T/out")" "Wrong password" "reason shown"
    assert_false test -e "$T/cron"
    assert_not_contains "$(cat "$T/out")" "test-password" "password never printed"
}

test_init_storage_error_fails_at_once() {
    MOCK_REPO=error bash "$ENGINE" init > "$T/out" 2>&1
    assert_not_eq "0" "$?" "init fails"
    assert_contains "$(cat "$T/out")" "Access Denied" "storage error shown"
    assert_false grep -q '^restic cat' "$LOG"
    assert_false test -e "$T/cron"
}

test_restore_requires_confirmation_flag() {
    bash "$ENGINE" restore latest umami > "$T/out" 2>&1
    assert_not_eq "0" "$?" "restore refuses without --yes"
    assert_false grep -q '^restic restore' "$LOG"
}

test_restore_app_recreates_database_from_dump() {
    local meta="$SNAP$T/stage"
    mkdir -p "$meta/db/umami" "$meta/sqlite/umami" "$SNAP$STACKS/umami/data" "$SNAP$T/vol/umami_uploads/_data" "$STACKS/umami"
    echo umami > "$meta/stacks.list"
    echo "CREATE TABLE restored;" > "$meta/db/umami/db.postgres"
    printf 'volume\tumami_db-data\n' > "$meta/db/umami/db.mount"
    mkdir -p "$meta/volumes"
    printf 'umami_uploads\t%s\n' "$T/vol/umami_uploads/_data" > "$meta/volumes/umami.list"
    echo "uploaded" > "$SNAP$T/vol/umami_uploads/_data/file.txt"
    echo "services: {}" > "$SNAP$STACKS/umami/docker-compose.yaml"
    echo "snapshot-copy" > "$meta/sqlite/umami/1.sqlite"
    printf '1\t%s\n' "$STACKS/umami/data/app.db" > "$meta/sqlite/umami/index"
    echo "live-copy" > "$SNAP$STACKS/umami/data/app.db"
    echo "stale" > "$STACKS/umami/docker-compose.yaml"

    bash "$ENGINE" restore latest umami --yes > "$T/out" 2>&1
    assert_eq "0" "$?" "restore succeeds" || cat "$T/out"

    local calls
    calls=$(grep -n -E '^docker (compose|volume rm)|^restic restore .*--include '"$STACKS"'/umami$' "$LOG")
    assert_contains "$calls" "docker compose down" "stack stopped"
    local down rm files up_db
    down=$(grep -n 'docker compose down' "$LOG" | head -1 | cut -d: -f1)
    rm=$(grep -n 'docker volume rm -f umami_db-data' "$LOG" | head -1 | cut -d: -f1)
    files=$(grep -n "restic restore latest --target / --include $STACKS/umami\$" "$LOG" | head -1 | cut -d: -f1)
    up_db=$(grep -n 'docker compose up -d db' "$LOG" | head -1 | cut -d: -f1)
    assert_true test -n "$down" -a -n "$rm" -a -n "$files" -a -n "$up_db"
    assert_true test "$down" -lt "$rm" -a "$rm" -lt "$up_db" -a "$files" -lt "$up_db"
    assert_eq "CREATE TABLE restored;" "$(cat "$FIX/stdin.c1")" "dump loaded into the database"
    assert_contains "$(cat "$FIX/exec.c1")" "psql" "loaded with psql"
    assert_eq "uploaded" "$(cat "$T/newvol/umami_uploads/file.txt")" "volume data restored into the volume"
    assert_eq "snapshot-copy" "$(cat "$STACKS/umami/data/app.db")" "SQLite file replaced by its consistent snapshot"
    assert_eq "docker compose up -d" "$(grep '^docker compose' "$LOG" | tail -1)" "stack started last"
}

test_restore_unknown_app_fails_before_touching_anything() {
    mkdir -p "$SNAP$T/stage"
    echo umami > "$SNAP$T/stage/stacks.list"
    bash "$ENGINE" restore latest nope --yes > "$T/out" 2>&1
    assert_not_eq "0" "$?" "unknown app rejected"
    assert_false grep -q '^docker compose' "$LOG"
}

run_tests "$0"
