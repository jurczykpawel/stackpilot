#!/bin/bash
# Local Docker integration: gateway routing survives backend address changes.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKER=$(command -v docker)
TEST_DIR=$(mktemp -d)
PREFIX="stackpilot-plunk-gateway-test-$$"
cleanup() {
    "$DOCKER" rm -f "$PREFIX-gateway" "$PREFIX-backend" "$PREFIX-blocker" >/dev/null 2>&1 || true
    "$DOCKER" network rm "$PREFIX" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
mkdir -p "$TEST_DIR/bin"
printf '#!/bin/bash\nexec "$@"\n' > "$TEST_DIR/bin/sudo"
printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/docker"
chmod +x "$TEST_DIR/bin/"*
PATH="$TEST_DIR/bin:$PATH" STACK_DIR="$TEST_DIR/stack" XDG_CONFIG_HOME="$TEST_DIR/config" \
    AWS_SES_REGION=eu-west-1 AWS_SES_ACCESS_KEY_ID=test-key AWS_SES_SECRET_ACCESS_KEY=test-secret \
    bash "$REPO_ROOT/apps/plunk/install.sh" >/dev/null
cat > "$TEST_DIR/backend.conf" <<'NGINX'
server { listen 8080; return 200 "$server_port:$request_uri"; }
server { listen 3000; return 200 "$server_port:$request_uri"; }
server { listen 9000; return 200 "$server_port:$request_uri"; }
NGINX
"$DOCKER" image inspect nginx:alpine >/dev/null 2>&1 || "$DOCKER" pull nginx:alpine >/dev/null
"$DOCKER" network create "$PREFIX" >/dev/null
start_backend() {
    "$DOCKER" run -d --name "$PREFIX-backend" --network "$PREFIX" --network-alias plunk --network-alias minio \
        -v "$TEST_DIR/backend.conf:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
}
check_routes() {
    "$DOCKER" exec "$PREFIX-gateway" sh -c '
        for attempt in $(seq 1 30); do
            api=$(wget -qO- http://127.0.0.1/api/health 2>/dev/null) || api=""
            web=$(wget -qO- http://127.0.0.1/auth/login 2>/dev/null) || web=""
            asset=$(wget -qO- http://127.0.0.1/uploads/example.png 2>/dev/null) || asset=""
            if [ "$api" = "8080:/health" ] && [ "$web" = "3000:/auth/login" ] && [ "$asset" = "9000:/uploads/example.png" ]; then exit 0; fi
            sleep 1
        done
        echo "Unexpected responses: api=$api web=$web asset=$asset" >&2
        exit 1
    '
}
start_backend
"$DOCKER" run -d --name "$PREFIX-gateway" --network "$PREFIX" \
    -v "$TEST_DIR/stack/nginx.conf:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
check_routes
OLD_IP=$("$DOCKER" inspect "$PREFIX-backend" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
"$DOCKER" rm -f "$PREFIX-backend" >/dev/null
"$DOCKER" run -d --name "$PREFIX-blocker" --network "$PREFIX" --ip "$OLD_IP" nginx:alpine >/dev/null
start_backend
NEW_IP=$("$DOCKER" inspect "$PREFIX-backend" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
[ "$OLD_IP" != "$NEW_IP" ] || { echo 'Backend address did not change' >&2; exit 1; }
check_routes
printf 'Gateway routes recovered after backend IP change %s -> %s without gateway restart.\n' "$OLD_IP" "$NEW_IP"
