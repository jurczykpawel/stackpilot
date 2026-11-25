#!/bin/bash
# Real deployment, database persistence, and HTTP checks. Uses fresh stacks only.
set -euo pipefail
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
SSH_HOST="${E2E_SSH:-}"
APP_FILTER=""
DOMAIN_TYPE=local
DOMAIN_SUFFIX=""
CLEANUP="${E2E_CLEANUP:-always}"
for arg in "$@"; do
    case "$arg" in
        --ssh=*) SSH_HOST="${arg#*=}" ;;
        --app=*) APP_FILTER="${arg#*=}" ;;
        --domain-type=*) DOMAIN_TYPE="${arg#*=}" ;;
        --domain-suffix=*) DOMAIN_SUFFIX="${arg#*=}" ;;
        --cleanup=*) CLEANUP="${arg#*=}" ;;
        --suite=email-apps|--quick) ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done
case "$DOMAIN_TYPE" in local|cloudflare) ;; *) echo 'Domain type must be local or cloudflare' >&2; exit 2 ;; esac
if [ -n "$DOMAIN_SUFFIX" ]; then
    [[ "$DOMAIN_SUFFIX" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] && [ "${#DOMAIN_SUFFIX}" -lt 240 ] || { echo 'Invalid domain suffix' >&2; exit 2; }
fi
if [ "$DOMAIN_TYPE" = cloudflare ]; then
    [ -n "$DOMAIN_SUFFIX" ] || { echo 'Cloudflare requires --domain-suffix' >&2; exit 2; }
    command -v dig >/dev/null || { echo 'dig required for domain preflight' >&2; exit 2; }
fi
case "$APP_FILTER" in ''|notifuse|mailcheap|plunk) ;; *) echo 'Unknown email app' >&2; exit 2 ;; esac
case "$CLEANUP" in always|never) ;; *) echo 'Cleanup must be always or never' >&2; exit 2 ;; esac
[ -n "$SSH_HOST" ] && [[ "$SSH_HOST" != -* ]] || { echo '--ssh=HOST required' >&2; exit 2; }
RESULTS_DIR="${E2E_RESULTS_DIR:-$E2E_DIR/results}"
mkdir -p "$RESULTS_DIR"
printf 'TAP version 13\n' > "$RESULTS_DIR/results.tap"
RUN_TOKEN=$(openssl rand -hex 16)
OWNED_APP=""
OWNED_DOMAIN=""
cleanup_owned() {
    [ -n "$OWNED_APP" ] || return 0
    if [ "$CLEANUP" = never ]; then
        echo "Keeping owned stack: $OWNED_APP ($RUN_TOKEN)"
        return 0
    fi
    ssh "$SSH_HOST" "set -e; cd '/opt/stacks/$OWNED_APP'; sudo grep -qx '$RUN_TOKEN' .stackpilot-e2e-owner; if [ -f docker-compose.yaml ]; then sudo docker compose down -v; fi" || return 1
    if [ -n "$OWNED_DOMAIN" ]; then
        (source "$E2E_DIR/lib/assertions.sh"; E2E_SSH="$SSH_HOST"; cf_dns_delete "$OWNED_DOMAIN" && caddy_cleanup "$OWNED_DOMAIN") || return 1
    fi
    ssh "$SSH_HOST" "set -e; cd '/opt/stacks/$OWNED_APP'; sudo grep -qx '$RUN_TOKEN' .stackpilot-e2e-owner; cd /; sudo rm -rf '/opt/stacks/$OWNED_APP'" || return 1
    OWNED_APP=""
    OWNED_DOMAIN=""
}
EXIT_CODE=0
trap 'EXIT_CODE=$?; cleanup_owned || EXIT_CODE=1; exit "$EXIT_CODE"' EXIT
trap 'exit 1' INT TERM

run_app() {
    local app="$1" service inner health console expected port first_hash
    case "$app" in
        notifuse) service=notifuse; inner=8080; health=/healthz; console=/console; expected='Notifuse' ;;
        mailcheap) service=mailcheap; inner=3000; health=/api/health; console=/signin; expected='MailCheap' ;;
        plunk) service=gateway; inner=80; health=/api/health; console=/auth/login; expected='Plunk' ;;
    esac
    local domain="" domain_args=("--domain-type=$DOMAIN_TYPE") existing_dns
    if [ "$DOMAIN_TYPE" = cloudflare ]; then
        domain="$app-$DOMAIN_SUFFIX"
        existing_dns=$(dig @1.1.1.1 +short "$domain" A && dig @1.1.1.1 +short "$domain" AAAA && dig @1.1.1.1 +short "$domain" CNAME) || return 1
        [ -z "$existing_dns" ] || { echo "Domain already resolves: $domain" >&2; return 1; }
        domain_args+=("--domain=$domain")
    fi
    # Atomic reservation; existing containers or volumes also stop this run.
    if ! ssh "$SSH_HOST" "set -e; test ! -e '/opt/stacks/$app'; if [ -n '$domain' ]; then test ! -e '/etc/caddy/conf.d/$domain.caddy'; fi; if command -v docker >/dev/null 2>&1; then test -z \"\$(sudo docker ps -aq --filter label=com.docker.compose.project=$app)\"; test -z \"\$(sudo docker volume ls -q --filter label=com.docker.compose.project=$app)\"; fi; sudo mkdir -p /opt/stacks; sudo mkdir '/opt/stacks/$app'; echo '$RUN_TOKEN' | sudo tee '/opt/stacks/$app/.stackpilot-e2e-owner' >/dev/null"; then
        echo "Refusing to use an existing stack or unavailable server: $app" >&2
        return 1
    fi
    OWNED_APP="$app"
    OWNED_DOMAIN="$domain"
    if [ "$app" = plunk ]; then
        ssh "$SSH_HOST" 'test -s ~/.config/stackpilot/plunk.env' || { echo 'Plunk requires remote ~/.config/stackpilot/plunk.env' >&2; return 1; }
    fi
    "$REPO_ROOT/local/deploy.sh" "$app" --ssh="$SSH_HOST" "${domain_args[@]}" --yes || return 1
    port=$(ssh "$SSH_HOST" "cd '/opt/stacks/$app'; sudo docker compose port '$service' '$inner'" | tail -1 | sed 's/.*://') || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ssh "$SSH_HOST" "set -o pipefail; curl -fsS --max-time 15 'http://127.0.0.1:$port$health' >/dev/null && curl -fsSL --max-time 15 'http://127.0.0.1:$port$console' | grep -i '$expected' >/dev/null" || return 1
    check_public "$domain" "$health" "$console" "$expected" || return 1
    first_hash=$(ssh "$SSH_HOST" "sudo sha256sum '/opt/stacks/$app/.env'" | cut -d' ' -f1) || return 1
    case "$app" in
        notifuse|plunk)
            local dbuser=postgres dbname=postgres dbservice=postgres
            [ "$app" != plunk ] || { dbuser=plunk; dbname=plunk; }
            ssh "$SSH_HOST" "cd '/opt/stacks/$app'; sudo docker compose exec -T '$dbservice' psql -U '$dbuser' -d '$dbname' -v ON_ERROR_STOP=1 -c \"CREATE TABLE stackpilot_e2e_probe (value text); INSERT INTO stackpilot_e2e_probe VALUES ('$RUN_TOKEN');\"" >/dev/null || return 1
            ;;
        mailcheap)
            ssh "$SSH_HOST" "cd '/opt/stacks/$app'; sudo docker compose exec -T mongo sh -c 'mongosh --quiet \"mongodb://127.0.0.1:27017/mailcheap?serverSelectionTimeoutMS=20000&connectTimeoutMS=20000\" -u root -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin --eval '\"'\"'db.stackpilot_e2e_probe.insertOne({value: \"$RUN_TOKEN\"})'\"'\"''" >/dev/null || return 1
            ;;
    esac
    ssh "$SSH_HOST" "cd '/opt/stacks/$app'; sudo docker compose restart && sudo docker compose up -d --wait --wait-timeout 360" || return 1
    [ "$first_hash" = "$(ssh "$SSH_HOST" "sudo sha256sum '/opt/stacks/$app/.env'" | cut -d' ' -f1)" ] || return 1
    case "$app" in
        notifuse|plunk)
            ssh "$SSH_HOST" "cd '/opt/stacks/$app'; sudo docker compose exec -T '$dbservice' psql -U '$dbuser' -d '$dbname' -tAc 'SELECT value FROM stackpilot_e2e_probe'" | grep -qx "$RUN_TOKEN" || return 1
            ;;
        mailcheap)
            ssh "$SSH_HOST" "cd '/opt/stacks/$app'; sudo docker compose exec -T mongo sh -c 'mongosh --quiet \"mongodb://127.0.0.1:27017/mailcheap?serverSelectionTimeoutMS=20000&connectTimeoutMS=20000\" -u root -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin --eval '\"'\"'print(db.stackpilot_e2e_probe.findOne().value)'\"'\"''" | grep -qx "$RUN_TOKEN" || return 1
            ;;
    esac
    ssh "$SSH_HOST" "set -o pipefail; curl -fsS --max-time 15 'http://127.0.0.1:$port$health' >/dev/null" || return 1
    check_public "$domain" "$health" "$console" "$expected" || return 1
    cleanup_owned || return 1
}

check_public() {
    [ -n "$1" ] || return 0
    curl -fsS --max-time 15 --retry 12 --retry-delay 5 --retry-max-time 90 --retry-all-errors "https://$1$2" >/dev/null || return 1
    curl -fsSL --max-time 15 "https://$1$3" | grep -i "$4" >/dev/null
}

APPS=(notifuse mailcheap plunk)
[ -z "$APP_FILTER" ] || APPS=("$APP_FILTER")
FAILED=0
INDEX=0
for app in "${APPS[@]}"; do
    INDEX=$((INDEX + 1))
    if run_app "$app"; then
        echo "ok $INDEX - $app: deploy, HTTP and database persistence" | tee -a "$RESULTS_DIR/results.tap"
    else
        echo "not ok $INDEX - $app: deployment or persistence failed" | tee -a "$RESULTS_DIR/results.tap"
        FAILED=1
        if [ -n "$OWNED_APP" ]; then
            ssh "$SSH_HOST" "cd '/opt/stacks/$OWNED_APP' && sudo grep -qx '$RUN_TOKEN' .stackpilot-e2e-owner && sudo docker compose ps && sudo docker compose logs --tail 30" || true
        fi
        cleanup_owned || exit 1
    fi
    OWNED_APP=""
done
printf '1..%s\n' "$INDEX" >> "$RESULTS_DIR/results.tap"
exit "$FAILED"
