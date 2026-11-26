#!/bin/bash

# StackPilot - Backup engine (restic)
# Installed on the server as /usr/local/sbin/stackpilot-backup by local/setup-backup.sh.
#
#   stackpilot-backup init                         install restic, open or create the repository, add the cron job
#   stackpilot-backup run                          one encrypted snapshot: files, Docker volumes, database dumps
#   stackpilot-backup snapshots                    list snapshots
#   stackpilot-backup restore <snapshot> [app] --yes   restore everything or one app (overwrites data)
#
# Configuration: /opt/stackpilot/config/backup.env (mode 600), written by setup-backup.sh.
# Log lines are plain English: this runs from cron; interactive text lives in local/*.sh.

set -euo pipefail
umask 077

BACKUP_ENV=${BACKUP_ENV:-/opt/stackpilot/config/backup.env}
DB_CREDENTIALS_FILE=${DB_CREDENTIALS_FILE:-/opt/stackpilot/config/db-credentials.conf}
STACKS_DIR=${STACKS_DIR:-/opt/stacks}
BACKUP_STAGE=${BACKUP_STAGE:-/opt/backups/stackpilot}
BACKUP_PATHS=${BACKUP_PATHS:-/opt/stacks /opt/dockge /opt/backups /etc/caddy /var/www}
BACKUP_CRON_FILE=${BACKUP_CRON_FILE:-/etc/cron.d/stackpilot-backup}
BACKUP_LOCK_FILE=${BACKUP_LOCK_FILE:-/run/lock/stackpilot-backup.lock}
BACKUP_RESTORE_TMP=${BACKUP_RESTORE_TMP:-/var/tmp}
ENGINE_PATH=/usr/local/sbin/stackpilot-backup
RESTIC_VERSION=0.19.1
RESTIC_SHA256_amd64=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
RESTIC_SHA256_arm64=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465
FAILED=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "ERROR: $*" >&2; FAILED=1; }
die() { log "ERROR: $*" >&2; exit 1; }

load_config() {
    [ -r "$BACKUP_ENV" ] || die "Missing $BACKUP_ENV. Run ./local/setup-backup.sh first."
    set -a
    # shellcheck source=/dev/null
    source "$BACKUP_ENV"
    set +a
    : "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is not set in $BACKUP_ENV}"
}

take_lock() {
    mkdir -p "$(dirname "$BACKUP_LOCK_FILE")"
    exec 9> "$BACKUP_LOCK_FILE"
    flock -n 9 || die "Another backup or restore is running."
}

# --- Database detection ----------------------------------------------------

db_kind() {
    local NAME=${1##*/}
    case "${NAME%%[:@]*}" in
        *postgres*|*pgvector*|*postgis*|*timescaledb*) echo postgres ;;
        *mysql*|*mariadb*) echo mysql ;;
        mongo) echo mongo ;;
    esac
}

is_db_data() {
    case "$1:$2" in
        postgres:/var/lib/postgresql*|mysql:/var/lib/mysql*|mongo:/data/db*) return 0 ;;
    esac
    return 1
}

# Scripts run inside the database container with its own environment.
# shellcheck disable=SC2016
db_script() {
    case "$1-$2" in
        dump-postgres) echo 'exec pg_dumpall -U "${POSTGRES_USER:-postgres}"' ;;
        load-postgres) echo 'exec psql -q -U "${POSTGRES_USER:-postgres}" -d postgres' ;;
        ready-postgres) echo 'pg_isready -q -h 127.0.0.1 -U "${POSTGRES_USER:-postgres}"' ;;
        dump-mysql) echo 'D=$(command -v mariadb-dump || command -v mysqldump); P=${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}
if [ -n "$P" ]; then MYSQL_PWD=$P exec "$D" -uroot --all-databases --single-transaction --routines --events
else MYSQL_PWD=${MYSQL_PASSWORD:-$MARIADB_PASSWORD} exec "$D" -u"${MYSQL_USER:-$MARIADB_USER}" --single-transaction --routines --databases "${MYSQL_DATABASE:-$MARIADB_DATABASE}"; fi' ;;
        load-mysql) echo 'C=$(command -v mariadb || command -v mysql); P=${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}
if [ -n "$P" ]; then MYSQL_PWD=$P exec "$C" -uroot
else MYSQL_PWD=${MYSQL_PASSWORD:-$MARIADB_PASSWORD} exec "$C" -u"${MYSQL_USER:-$MARIADB_USER}"; fi' ;;
        ready-mysql) echo '$(command -v mariadb-admin || command -v mysqladmin) ping -h 127.0.0.1 --silent' ;;
        dump-mongo|load-mongo)
            local TOOL="mongodump --quiet --archive"
            [ "$1" = dump ] || TOOL="mongorestore --quiet --archive --drop"
            echo 'if [ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ]; then exec '"$TOOL"' -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin
else exec '"$TOOL"'; fi' ;;
        ready-mongo) echo 'mongosh --quiet --eval 1 >/dev/null 2>&1 || mongo --quiet --eval 1 >/dev/null 2>&1' ;;
    esac
}

# Fills DUMPS (id|stack|service|kind), VOLUMES (stack|name|path) and EXCLUDES;
# writes <service>.mount files naming the database data each dump replaces.
collect_containers() {
    DUMPS=() VOLUMES=() EXCLUDES=()
    local IDS ID DIR SVC IMAGE RUNNING STACK KIND TYPE NAME SRC DEST
    IDS=$(docker ps -aq --filter label=com.docker.compose.project.working_dir)
    [ -n "$IDS" ] || return 0
    # shellcheck disable=SC2086
    while IFS='|' read -r ID DIR SVC IMAGE RUNNING; do
        [ -n "$ID" ] && [ "$(dirname "$DIR")" = "$STACKS_DIR" ] || continue
        STACK=${DIR##*/}
        KIND=$(db_kind "$IMAGE")
        [ -n "$KIND" ] && [ "$RUNNING" = true ] || KIND=""
        [ -z "$KIND" ] || DUMPS+=("$ID|$STACK|$SVC|$KIND")
        while IFS='|' read -r TYPE NAME SRC DEST; do
            if [ -n "$KIND" ] && is_db_data "$KIND" "$DEST"; then
                mkdir -p "$BACKUP_STAGE/db/$STACK"
                if [ "$TYPE" = volume ]; then
                    printf 'volume\t%s\n' "$NAME" >> "$BACKUP_STAGE/db/$STACK/$SVC.mount"
                else
                    printf 'bind\t%s\n' "$SRC" >> "$BACKUP_STAGE/db/$STACK/$SVC.mount"
                    EXCLUDES+=(--exclude "$SRC")
                fi
            elif [ "$TYPE" = volume ]; then
                VOLUMES+=("$STACK|$NAME|$SRC")
            fi
        done < <(docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}{{println}}{{end}}' "$ID")
    done < <(docker inspect -f '{{.Id}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.State.Running}}' $IDS)
}

dump_databases() {
    local ENTRY ID STACK SVC KIND OUT
    for ENTRY in ${DUMPS[@]+"${DUMPS[@]}"}; do
        IFS='|' read -r ID STACK SVC KIND <<< "$ENTRY"
        OUT="$BACKUP_STAGE/db/$STACK/$SVC.$KIND"
        if docker exec "$ID" sh -c "$(db_script dump "$KIND")" > "$OUT.part"; then
            mv "$OUT.part" "$OUT"
            log "Dumped $KIND database $STACK/$SVC"
        else
            rm -f "$OUT.part"
            warn "Dump of $KIND database $STACK/$SVC failed"
        fi
    done
}

# Databases on other hosts (format: ID:TYPE:HOST:PORT:DATABASE:USER:PASSWORD).
# Client tools run in a throwaway container; the password travels in the environment.
dump_external_databases() {
    [ -f "$DB_CREDENTIALS_FILE" ] || return 0
    local CUSTOM_DATABASES=() ENTRY DB_ID DB_TYPE DB_HOST DB_PORT DB_NAME DB_USER DB_PASS OUT
    # shellcheck source=/dev/null
    source "$DB_CREDENTIALS_FILE"
    mkdir -p "$BACKUP_STAGE/external"
    for ENTRY in ${CUSTOM_DATABASES[@]+"${CUSTOM_DATABASES[@]}"}; do
        IFS=':' read -r DB_ID DB_TYPE DB_HOST DB_PORT DB_NAME DB_USER DB_PASS <<< "$ENTRY"
        OUT="$BACKUP_STAGE/external/$DB_ID.$DB_TYPE"
        if case "$DB_TYPE" in
            postgres) PGPASSWORD=$DB_PASS docker run --rm --network host -e PGPASSWORD postgres:18-alpine \
                pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" ;;
            mysql) MYSQL_PWD=$DB_PASS docker run --rm --network host -e MYSQL_PWD mysql:8.4 \
                mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" --single-transaction "$DB_NAME" ;;
            *) false ;;
        esac > "$OUT.part"; then
            mv "$OUT.part" "$OUT"
            log "Dumped external $DB_TYPE database $DB_ID"
        else
            rm -f "$OUT.part"
            warn "Dump of external database $DB_ID failed"
        fi
    done
}

is_sqlite() { [ "$(head -c 15 "$1" 2>/dev/null)" = "SQLite format 3" ]; }

# Hot SQLite files are copied with the online backup API so the snapshot is consistent.
snapshot_sqlite() {
    local STACK DIR FILE OUT N ENTRY NAME
    if ! command -v sqlite3 > /dev/null; then
        warn "sqlite3 is missing; run 'stackpilot-backup init'"
        return 0
    fi
    for DIR in "$STACKS_DIR"/*/; do
        printf '%s|%s\n' "$(basename "$DIR")" "${DIR%/}"
    done > "$BACKUP_STAGE/sqlite-dirs"
    for ENTRY in ${VOLUMES[@]+"${VOLUMES[@]}"}; do
        IFS='|' read -r STACK NAME DIR <<< "$ENTRY"
        printf '%s|%s\n' "$STACK" "$DIR"
    done >> "$BACKUP_STAGE/sqlite-dirs"
    sort -u -o "$BACKUP_STAGE/sqlite-dirs" "$BACKUP_STAGE/sqlite-dirs"
    while IFS='|' read -r STACK DIR; do
        [ -d "$DIR" ] || continue
        while IFS= read -r -d '' FILE; do
            is_sqlite "$FILE" || continue
            mkdir -p "$BACKUP_STAGE/sqlite/$STACK"
            N=$(( $(wc -l < "$BACKUP_STAGE/sqlite/$STACK/index" 2>/dev/null || echo 0) + 1 ))
            OUT="$BACKUP_STAGE/sqlite/$STACK/$N.sqlite"
            if sqlite3 "$FILE" ".timeout 20000" ".backup '$OUT'"; then
                printf '%s\t%s\n' "$N" "$FILE" >> "$BACKUP_STAGE/sqlite/$STACK/index"
            else
                rm -f "$OUT"
                warn "SQLite snapshot of $FILE failed"
            fi
        done < <(find "$DIR" -maxdepth 4 -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) \
            -not -path "$BACKUP_STAGE/*" -print0 2>/dev/null)
    done < "$BACKUP_STAGE/sqlite-dirs"
    rm -f "$BACKUP_STAGE/sqlite-dirs"
}

notify() {
    local URL=${BACKUP_PING_URL:-}
    [ -n "$URL" ] || return 0
    [ "$1" -eq 0 ] || URL=${BACKUP_PING_FAIL_URL:-${URL%/}/fail}
    curl -fsS --max-time 10 --retry 3 -o /dev/null "$URL" || log "Notification to the heartbeat URL failed"
}

cmd_run() {
    local ENTRY STACK NAME SRC P SOURCES=()
    load_config
    take_lock
    trap 'STATUS=$?; notify "$STATUS"; exit "$STATUS"' EXIT
    log "Backup started"
    rm -rf "$BACKUP_STAGE"
    mkdir -p "$BACKUP_STAGE/db" "$BACKUP_STAGE/volumes"
    for P in "$STACKS_DIR"/*/; do
        [ -d "$P" ] && basename "$P"
    done > "$BACKUP_STAGE/stacks.list"
    collect_containers
    dump_databases
    dump_external_databases
    snapshot_sqlite
    for ENTRY in ${VOLUMES[@]+"${VOLUMES[@]}"}; do
        IFS='|' read -r STACK NAME SRC <<< "$ENTRY"
        printf '%s\t%s\n' "$NAME" "$SRC" >> "$BACKUP_STAGE/volumes/$STACK.list.part"
        SOURCES+=("$SRC")
    done
    for P in "$BACKUP_STAGE"/volumes/*.list.part; do
        [ -e "$P" ] && sort -u "$P" > "${P%.part}" && rm -f "$P"
    done
    for P in $BACKUP_PATHS; do
        [ -e "$P" ] && SOURCES+=("$P")
    done
    [ -d "$BACKUP_STAGE" ] && SOURCES+=("$BACKUP_STAGE")
    restic backup --tag stackpilot --exclude-caches ${EXCLUDES[@]+"${EXCLUDES[@]}"} "${SOURCES[@]}" ||
        warn "restic backup failed or skipped unreadable files"
    restic forget --tag stackpilot --group-by host,tags --keep-daily "${BACKUP_KEEP_DAILY:-14}" \
        --keep-weekly "${BACKUP_KEEP_WEEKLY:-8}" --keep-monthly "${BACKUP_KEEP_MONTHLY:-12}" --prune ||
        warn "restic forget/prune failed"
    if [ "$(date +%u)" = 7 ]; then
        restic check || warn "restic check found a problem in the repository"
    fi
    [ "$FAILED" -eq 0 ] || die "Backup finished with errors"
    log "Backup finished"
}

# --- Setup -------------------------------------------------------------------

restic_is_current() {
    local V
    V=$(restic version 2>/dev/null | awk '{print $2}') || return 1
    [ -n "$V" ] && [ "$(printf '%s\n0.17.0\n' "$V" | sort -V | head -1)" = 0.17.0 ]
}

install_restic() {
    local ARCH SUM TMP
    case "$(uname -m)" in
        x86_64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die "Unsupported CPU architecture $(uname -m); install restic 0.17 or newer manually." ;;
    esac
    SUM="RESTIC_SHA256_$ARCH"
    TMP=$(mktemp -d)
    curl -fsSL -o "$TMP/restic.bz2" \
        "https://github.com/restic/restic/releases/download/v$RESTIC_VERSION/restic_${RESTIC_VERSION}_linux_$ARCH.bz2"
    echo "${!SUM}  $TMP/restic.bz2" | sha256sum -c --quiet || die "restic download checksum mismatch"
    bunzip2 "$TMP/restic.bz2"
    install -m 755 "$TMP/restic" /usr/local/bin/restic
    rm -rf "$TMP"
    log "Installed restic $RESTIC_VERSION"
}

cmd_init() {
    local MISSING=() TOOL RC=0
    load_config
    for TOOL in sqlite3 bzip2 curl flock; do
        command -v "$TOOL" > /dev/null || MISSING+=("$TOOL")
    done
    if [ ${#MISSING[@]} -gt 0 ]; then
        MISSING=("${MISSING[@]/flock/util-linux}")
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING[@]}" > /dev/null
    fi
    restic_is_current || install_restic
    restic cat config > /dev/null || RC=$?
    case "$RC" in
        0) log "Using the existing repository" ;;
        10) restic init > /dev/null && log "Repository created" ;;
        12) die "Wrong password for the existing repository" ;;
        *) die "Cannot open the repository (restic exit code $RC)" ;;
    esac
    cat > "$BACKUP_CRON_FILE" <<EOF
# StackPilot - daily restic backup (files, Docker volumes, database dumps)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root $ENGINE_PATH run >> /var/log/stackpilot-backup.log 2>&1
EOF
    chmod 644 "$BACKUP_CRON_FILE"
    log "Daily backup scheduled at 03:00"
}

# --- Restore -----------------------------------------------------------------

has_compose() { compgen -G "$1/*compose.y*ml" > /dev/null; }

has_dump() { [ -e "$1.postgres" ] || [ -e "$1.mysql" ] || [ -e "$1.mongo" ]; }

stack_compose() {
    local DIR=$1
    shift
    (cd "$DIR" && docker compose "$@")
}

wait_for_db() {
    local ID=$1 KIND=$2 TRIES=90
    while [ "$TRIES" -gt 0 ]; do
        # Official images run a temporary server during first start; PID 1 becomes the real server afterwards.
        case "$(docker exec "$ID" cat /proc/1/comm 2>/dev/null)" in
            postgres|mysqld|mariadbd|mongod)
                docker exec "$ID" sh -c "$(db_script ready "$KIND")" && return 0 ;;
        esac
        TRIES=$((TRIES - 1))
        sleep 2
    done
    return 1
}

restore_stack() {
    local SNAP=$1 STACK=$2 META=$3 WORK=$4
    local DIR="$STACKS_DIR/$STACK" MOUNT DUMP SVC KIND TYPE REF NAME OLD NEW N ORIG ID
    log "Restoring $STACK"
    ! has_compose "$DIR" || stack_compose "$DIR" down || true
    for MOUNT in "$META/db/$STACK"/*.mount; do
        [ -e "$MOUNT" ] || continue
        has_dump "${MOUNT%.mount}" || continue
        while IFS=$'\t' read -r TYPE REF; do
            if [ "$TYPE" = volume ]; then docker volume rm -f "$REF" > /dev/null; else rm -rf "$REF"; fi
        done < "$MOUNT"
    done
    restic restore "$SNAP" --target / --include "$DIR"
    if has_compose "$DIR"; then
        stack_compose "$DIR" create
        if [ -f "$META/volumes/$STACK.list" ]; then
            while IFS=$'\t' read -r NAME OLD; do
                NEW=$(docker volume inspect -f '{{.Mountpoint}}' "$NAME")
                restic restore "$SNAP" --target "$WORK/volume" --include "$OLD"
                find "$NEW" -mindepth 1 -delete
                cp -a "$WORK/volume$OLD/." "$NEW/"
                rm -rf "$WORK/volume"
            done < "$META/volumes/$STACK.list"
        fi
    fi
    if [ -f "$META/sqlite/$STACK/index" ]; then
        while IFS=$'\t' read -r N ORIG; do
            cp "$META/sqlite/$STACK/$N.sqlite" "$ORIG"
            rm -f "$ORIG-wal" "$ORIG-shm"
        done < "$META/sqlite/$STACK/index"
    fi
    if ! has_compose "$DIR"; then
        log "$STACK has no Compose file: files restored, start it again (for example by re-running deploy.sh)"
        return 0
    fi
    for DUMP in "$META/db/$STACK"/*.postgres "$META/db/$STACK"/*.mysql "$META/db/$STACK"/*.mongo; do
        [ -e "$DUMP" ] || continue
        SVC=$(basename "${DUMP%.*}")
        KIND=${DUMP##*.}
        stack_compose "$DIR" up -d "$SVC"
        ID=$(stack_compose "$DIR" ps -q "$SVC")
        wait_for_db "$ID" "$KIND" || die "Database $STACK/$SVC did not become ready"
        docker exec -i "$ID" sh -c "$(db_script load "$KIND")" < "$DUMP" || die "Loading $STACK/$SVC failed"
        log "Loaded $KIND database $STACK/$SVC"
    done
    stack_compose "$DIR" up -d
}

cmd_restore() {
    local SNAP=${1:-} APP="" CONFIRMED=no ARG P META STACK
    shift || true
    for ARG in "$@"; do
        case "$ARG" in --yes) CONFIRMED=yes ;; *) APP=$ARG ;; esac
    done
    [ -n "$SNAP" ] || die "Usage: stackpilot-backup restore <snapshot|latest> [app] --yes"
    [ "$CONFIRMED" = yes ] || die "Restore overwrites data; pass --yes to confirm."
    load_config
    take_lock
    mkdir -p "$BACKUP_RESTORE_TMP"
    RESTORE_WORK=$(mktemp -d "$BACKUP_RESTORE_TMP/stackpilot-restore.XXXXXX")
    trap 'rm -rf "$RESTORE_WORK"' EXIT
    restic restore "$SNAP" --target "$RESTORE_WORK" --include "$BACKUP_STAGE"
    META="$RESTORE_WORK$BACKUP_STAGE"
    [ -f "$META/stacks.list" ] || die "Snapshot $SNAP has no StackPilot metadata."
    if [ -n "$APP" ]; then
        grep -qx -- "$APP" "$META/stacks.list" || die "App $APP is not in snapshot $SNAP."
    else
        for P in $BACKUP_PATHS; do
            case "$P" in "$STACKS_DIR"|/opt/backups) continue ;; esac
            restic restore "$SNAP" --target / --include "$P"
        done
        ! systemctl is-active --quiet caddy 2> /dev/null || systemctl reload caddy || true
    fi
    while IFS= read -r STACK; do
        [ -z "$APP" ] || [ "$STACK" = "$APP" ] || continue
        restore_stack "$SNAP" "$STACK" "$META" "$RESTORE_WORK"
    done < "$META/stacks.list"
    log "Restore finished"
}

case "${1:-}" in
    init) cmd_init ;;
    run) cmd_run ;;
    snapshots) shift; load_config; restic snapshots --tag stackpilot "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    *) echo "Usage: $0 init | run | snapshots | restore <snapshot|latest> [app] --yes" >&2; exit 2 ;;
esac
