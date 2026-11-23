#!/bin/bash
# shellcheck source=apps/immich/maintenance.sh
source "$(dirname "${BASH_SOURCE[0]}")/maintenance.sh"

[ "$#" -le 1 ] || fail "Usage: $0 [vMAJOR.MINOR.PATCH]"
REPO=immich-app/immich
RELEASE_API="https://api.github.com/repos/$REPO/releases"
VERSION_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$'

review_releases() {
    local CATALOG BREAKING_TAG
    CATALOG=$(curl -qfsSL --max-time 30 "$RELEASE_API?per_page=100") ||
        fail "Could not fetch the Immich release catalog from GitHub."
    BREAKING_TAG=$(jq -er --arg old "$OLD" --arg new "$NEW" --arg pattern "$VERSION_PATTERN" '
        def version: ltrimstr("v") | split(".") | map(tonumber);
        map(select(.draft == false and .prerelease == false and (.tag_name | test($pattern)))) as $releases
        | if ($releases | map(.tag_name) | index($old) and index($new)) then
            $releases
            | map(select((.tag_name | version) > ($old | version) and (.tag_name | version) <= ($new | version)))
            | sort_by(.tag_name | version)
            | map(select((.body // "") | test("breaking"; "i")) | .tag_name)
            | first // ""
          else error("Both versions must appear in the release catalog") end
    ' <<< "$CATALOG")
    if [ -n "$BREAKING_TAG" ]; then
        fail "Review the breaking changes at https://github.com/$REPO/releases/tag/$BREAKING_TAG."
    fi
}

rollback() {
    local HOLD IMAGE
    echo "The update failed. Restoring $OLD." >&2
    while IFS=$'\t' read -r HOLD IMAGE; do
        docker image tag "$HOLD" "$IMAGE" || return 1
    done < "$RECOVERY/images.tsv"
    compose stop immich-server &&
        cp "$RECOVERY/previous.env" .env &&
        compose exec -T database dropdb --force --if-exists -U "$DB_USER" -- "$DB_NAME" &&
        compose exec -T database createdb -U "$DB_USER" -- "$DB_NAME" &&
        restore_database "$RECOVERY/database.sql.gz" &&
        compose up -d --pull never &&
        wait_for_immich "$OLD"
}

release_images() {
    local HOLD IMAGE
    while IFS=$'\t' read -r HOLD IMAGE; do
        docker image rm "$HOLD" >/dev/null || true
    done < "$RECOVERY/images.tsv"
}

finish_update() {
    local STATUS=$?
    trap - EXIT
    case "$PHASE" in
        database)
            if rollback; then
                release_images
                echo "Immich is back on $OLD. Recovery files: $RECOVERY" >&2
            else
                echo "Rollback needs attention. Recovery files: $RECOVERY" >&2
                STATUS=1
            fi
            ;;
        stopped)
            compose start immich-server || STATUS=1
            release_images
            ;;
        preflight|complete) release_images ;;
    esac
    rmdir "$STATE.lock"
    exit "$STATUS"
}

lock_stack
OLD=$(server_version)
NEW=${1:-}
if [ -z "$NEW" ]; then
    LATEST=$(curl -qfsSL --max-time 30 "$RELEASE_API/latest") ||
        fail "Could not fetch the latest Immich release from GitHub."
    NEW=$(jq -er '.tag_name' <<< "$LATEST")
fi
[[ "$NEW" =~ $VERSION_PATTERN ]] || fail "Use a stable version tag such as vMAJOR.MINOR.PATCH."
if [ "$NEW" = "$OLD" ]; then
    echo "Immich already runs $OLD."
    exit 0
fi
[ "${NEW%%.*}" = "${OLD%%.*}" ] || fail "Review the major upgrade at https://github.com/$REPO/releases/tag/$NEW."
jq -en --arg old "$OLD" --arg new "$NEW" '
    def version: ltrimstr("v") | split(".") | map(tonumber);
    ($new | version) > ($old | version)' >/dev/null || fail "Choose a version newer than $OLD."
review_releases
stack_config

RECOVERY=$(mktemp -d "$STATE/update.XXXXXX")
PHASE=preflight
: > "$RECOVERY/images.tsv"
trap finish_update EXIT
cp .env "$RECOVERY/previous.env"
COMPOSE_CONFIG=$(compose config --format json)
for SERVICE in immich-server immich-machine-learning; do
    CONTAINER=$(compose ps -aq "$SERVICE")
    IMAGE_ID=$(docker inspect --type container --format '{{.Image}}' "$CONTAINER")
    IMAGE=$(jq -er --arg service "$SERVICE" '.services[$service].image' <<< "$COMPOSE_CONFIG")
    HOLD="stackpilot/immich-rollback:${SERVICE}-${RECOVERY##*.}"
    docker image tag "$IMAGE_ID" "$HOLD"
    printf '%s\t%s\n' "$HOLD" "$IMAGE" >> "$RECOVERY/images.tsv"
done

echo "Updating Immich from $OLD to $NEW."
IMMICH_VERSION="$NEW" compose pull immich-server immich-machine-learning
PHASE=stopped
compose stop immich-server
dump_database "$RECOVERY/database.sql.gz"
sed "s/^IMMICH_VERSION=.*/IMMICH_VERSION=$NEW/" "$RECOVERY/previous.env" > "$RECOVERY/next.env"
PHASE=database
mv "$RECOVERY/next.env" .env
compose up -d --pull never
wait_for_immich "$NEW"
PHASE=complete
release_images
trap 'rmdir "$STATE.lock"' EXIT
find "$RECOVERY" -depth -delete
echo "Immich $NEW is healthy."
