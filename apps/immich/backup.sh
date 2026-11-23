#!/bin/bash
# shellcheck source=apps/immich/maintenance.sh
source "$(dirname "${BASH_SOURCE[0]}")/maintenance.sh"

usage() {
    echo "Usage: $0 run | check | restore <snapshot|latest> <new-target-directory>" >&2
    exit 2
}

finish_backup() {
    local STATUS=$? URL=${NOTIFY_URL:-}
    trap - EXIT
    if [ "$RESTART_SERVER" = yes ]; then
        compose start immich-server || STATUS=1
    fi
    if [ -n "$URL" ]; then
        if [ "$STATUS" -eq 0 ]; then
            curl -fsS --max-time 10 -d 'Immich backup succeeded' "$URL" >/dev/null 2>&1 ||
                echo "Backup notification failed." >&2
        else
            curl -fsS --max-time 10 -d 'Immich backup failed' "${NOTIFY_FAILURE_URL:-${URL%/}/fail}" >/dev/null 2>&1 ||
                echo "Backup failure notification failed." >&2
        fi
    fi
    rm -f -- "$STATE/database.sql.gz"
    rmdir "$STATE.lock"
    exit "$STATUS"
}

run_backup() {
    local VERSION
    local -a CONFIG_FILES=(docker-compose.yaml)
    lock_stack
    RESTART_SERVER=no
    trap finish_backup EXIT
    stack_config
    VERSION=$(server_version)
    MEDIA=$(cd "$MEDIA" && pwd -P)
    DB_PATH=$(cd "$DB_PATH" && pwd -P)
    for PATH_TO_CHECK in "$PWD" "$DB_PATH" "${RESTIC_REPOSITORY#local:}"; do
        [[ "$PATH_TO_CHECK/" != "$MEDIA/"* ]] ||
            fail "Keep the stack, Postgres data and restic repository outside the media directory."
    done
    [ ! -f docker-compose.override.yaml ] || CONFIG_FILES+=(docker-compose.override.yaml)
    printf '%s\n' "$VERSION" > "$STATE/version"
    printf '%s\n' "$MEDIA" > "$STATE/media-path"
    restic cat config >/dev/null
    RESTART_SERVER=yes
    compose stop immich-server
    dump_database "$STATE/database.sql.gz"
    cp "$MEDIA/thumbs/.immich" "$STATE/thumbs-marker"
    cp "$MEDIA/encoded-video/.immich" "$STATE/video-marker"
    restic backup --tag stackpilot-immich --exclude "$MEDIA/thumbs" --exclude "$MEDIA/encoded-video" \
        .env "${CONFIG_FILES[@]}" .stackpilot-immich/{version,media-path,database.sql.gz,thumbs-marker,video-marker} "$MEDIA"
    compose start immich-server
    RESTART_SERVER=no
    restic forget --tag stackpilot-immich --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
}

recover_snapshot() {
    local SNAPSHOT=$1 TARGET=$2 RAW MEDIA_PATH VERSION CONTAINERS
    mkdir -m 700 -- "$TARGET" || fail "Choose a new directory whose parent already exists."
    TARGET=$(cd "$TARGET" && pwd -P)
    RAW="$TARGET/.snapshot"
    restic restore "$SNAPSHOT" --tag stackpilot-immich --verify --target "$RAW"
    MEDIA_PATH=$(cat "$RAW/.stackpilot-immich/media-path")
    [[ "$MEDIA_PATH" = /* && "$MEDIA_PATH" != / ]] || fail "Unexpected media path in snapshot."
    mv "$RAW$MEDIA_PATH" "$TARGET/library"
    mv "$RAW"/docker-compose*.yaml "$TARGET/"
    VERSION=$(cat "$RAW/.stackpilot-immich/version")
    sed -e 's|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=./library|' \
        -e 's|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=./postgres|' \
        -e "s|^IMMICH_VERSION=.*|IMMICH_VERSION=$VERSION|" "$RAW/.env" > "$TARGET/.env"
    cd "$TARGET" || exit
    CONTAINERS=$(compose ps -aq)
    [ -z "$CONTAINERS" ] || fail "Remove the existing Compose project before starting this recovery."
    stack_config
    [ "$MEDIA" = "$TARGET/library" ] || fail "Expected the recovered media bind mount."
    [[ "$DB_PATH" = "$TARGET/postgres" && ! -e postgres ]] || fail "Recovery requires a fresh PostgreSQL directory."
    chmod u+w library
    mkdir -p library/thumbs library/encoded-video
    cp "$RAW/.stackpilot-immich/thumbs-marker" library/thumbs/.immich
    cp "$RAW/.stackpilot-immich/video-marker" library/encoded-video/.immich
    compose up -d database
    restore_database "$RAW/.stackpilot-immich/database.sql.gz"
    compose up -d --pull missing
    wait_for_immich "$VERSION"
    find "$RAW" -depth -delete
}

case "${1:-}" in
    run|check) [ "$#" -eq 1 ] || usage ;;
    restore) [ "$#" -eq 3 ] || usage ;;
    *) usage ;;
esac
CONFIG=${IMMICH_BACKUP_ENV:-$STACK_DIR/backup.env}
[ -r "$CONFIG" ] || fail "Create a private backup configuration at $CONFIG."
set -a
# shellcheck source=/dev/null
source "$CONFIG"
set +a
: "${RESTIC_REPOSITORY:?Set RESTIC_REPOSITORY in backup.env}"
: "${RESTIC_PASSWORD_FILE:?Set RESTIC_PASSWORD_FILE in backup.env}"
case "$1" in
    run) run_backup ;;
    check) restic check --read-data ;;
    restore) recover_snapshot "$2" "$3" ;;
esac
