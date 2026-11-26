#!/bin/bash
# Local Docker integration: --domain-type=caddy on a clean Debian 12 server
# installs Caddy and serves the application with a certificate from its local CA,
# also for an installer that needs Caddy (littlelink), with no rsync on the server
# and with no ss there while the default application port is taken.
# Runs the installers and code of this checkout.
#
# Two servers: the one-line installer run on the server, and deploy.sh run from
# this machine (ssh/scp replaced by docker exec/cp) with port 80 taken at first.
#
# Docker and sudo are preinstalled: this test is about Caddy.
#
# Usage: ./tests/e2e/caddy-domain-docker.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE=debian:12
DOMAIN=ntfy.internal
NAME="stackpilot-caddy-test-$$"
TEST_DIR=$(mktemp -d)
PULLED=false
# deploy.sh runs with a temporary HOME; the docker CLI keeps its context
DOCKER_CONFIG_DIR="${DOCKER_CONFIG:-$HOME/.docker}"
FAILED=0

remove_server() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$NAME-docker" "$NAME-containerd" >/dev/null 2>&1 || true
}
cleanup() {
    remove_server
    [ "$PULLED" != true ] || docker image rm "$IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

on_server() { docker exec "$NAME" bash -c "$1"; }
check() {
    local label="$1"
    shift
    if "$@"; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label"
        FAILED=$((FAILED + 1))
    fi
}

# systemd, curl and CA certificates are what a fresh VPS ships and the base image lacks.
# policy-rc.d is a container-only guard that stops packages from starting services.
start_server() {
    remove_server
    docker run -d --name "$NAME" --privileged --cgroupns=private \
        --tmpfs /run --tmpfs /run/lock -e container=docker \
        -v "$NAME-docker:/var/lib/docker" -v "$NAME-containerd:/var/lib/containerd" \
        "$IMAGE" bash -c 'export DEBIAN_FRONTEND=noninteractive
            rm -f /usr/sbin/policy-rc.d
            apt-get update -qq &&
            apt-get install -y -qq --no-install-recommends systemd systemd-sysv dbus curl ca-certificates sudo >/dev/null &&
            exec /sbin/init' >/dev/null
    local state
    for _ in $(seq 1 180); do
        state=$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)
        case "$state" in running|degraded) break ;; esac
        sleep 1
    done
    on_server 'set -o pipefail; curl -fsSL https://get.docker.com | sh >/tmp/docker-install.log 2>&1' \
        || { on_server 'tail -30 /tmp/docker-install.log'; exit 1; }
    on_server '! command -v caddy && ! command -v sp-expose && [ ! -e /etc/caddy ]' >/dev/null \
        || { echo "server is not clean"; exit 1; }
}

# serves DOMAIN PATH PATTERN
serves() {
    on_server "for _ in \$(seq 1 60); do
        curl -fsS --resolve $1:443:127.0.0.1 \
            --cacert /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt \
            https://$1$2 2>/dev/null | grep -qi '$3' && exit 0
        sleep 1
    done; exit 1"
}
served_through_caddy() { serves "$DOMAIN" /v1/health '"healthy":true'; }

# The served endpoints plus a git repository the bootstrap can clone
bash "$REPO_ROOT/installers/build.sh" "$TEST_DIR/srv/installers" >/dev/null
mkdir -p "$TEST_DIR/srv/repo" "$TEST_DIR/bin" "$TEST_DIR/home"
(cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar -cf -) \
    | tar -xf - -C "$TEST_DIR/srv/repo"
git -C "$TEST_DIR/srv/repo" init -q -b main
git -C "$TEST_DIR/srv/repo" add -A
git -C "$TEST_DIR/srv/repo" -c user.name=test -c user.email=test@localhost \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m snapshot

cat > "$TEST_DIR/bin/ssh" <<EOF
#!/bin/bash
while [ "\${1#-}" != "\$1" ]; do
    case "\$1" in
        -G) echo "hostname 127.0.0.1"; exit 0 ;;
        -o) shift 2 ;;
        *) shift ;;
    esac
done
shift
exec docker exec -i $NAME bash -c "\$*"
EOF
cat > "$TEST_DIR/bin/scp" <<EOF
#!/bin/bash
[ "\$1" != -q ] || shift
exec docker cp "\$1" "$NAME:\${2#*:}"
EOF
chmod +x "$TEST_DIR/bin/ssh" "$TEST_DIR/bin/scp"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker pull -q "$IMAGE" >/dev/null
    PULLED=true
fi

copy_served_files() {
    docker cp "$TEST_DIR/srv" "$NAME:/srv/stackpilot"
    on_server 'chown -R root:root /srv/stackpilot'
}

echo "=== one-line installer on the server ==="
start_server
copy_served_files
oneliner() {
    docker exec \
        -e STACKPILOT_BOOTSTRAP_URL=file:///srv/stackpilot/installers/install \
        -e STACKPILOT_REPO=file:///srv/stackpilot/repo \
        "$NAME" bash -c "set -o pipefail
            curl -fsSL file:///srv/stackpilot/installers/ntfy | bash -s -- --domain-type=caddy --domain=$DOMAIN --yes" \
        2>&1 | tee "$TEST_DIR/deploy.log"
    return "${PIPESTATUS[0]}"
}
check "install exits 0" oneliner
check "Caddy service is active" on_server 'systemctl is-active --quiet caddy'
check "package default Caddyfile replaced" on_server \
    'grep -q "Managed by StackPilot" /etc/caddy/Caddyfile && ! grep -q usr/share/caddy /etc/caddy/Caddyfile'
check "$DOMAIN answers through Caddy" served_through_caddy
check "second run exits 0" oneliner
check "$DOMAIN still answers" served_through_caddy

# The server image has no rsync, so the toolbox comes from the bootstrap clone
deploy_app() {
    local app="$1" domain="$2"
    env HOME="$TEST_DIR/home" PATH="$TEST_DIR/bin:$PATH" DOCKER_CONFIG="$DOCKER_CONFIG_DIR" \
        STACKPILOT_REPO=file:///srv/stackpilot/repo \
        "$REPO_ROOT/local/deploy.sh" "$app" --ssh=sp-e2e --domain-type=caddy --domain="$domain" --yes \
        2>&1 | tee "$TEST_DIR/deploy.log"
    return "${PIPESTATUS[0]}"
}
deploy() { deploy_app ntfy "$DOMAIN"; }
deploy_fails() { ! deploy; }
toolbox_installed() {
    ! grep -q 'Failed to install toolbox' "$TEST_DIR/deploy.log" && on_server 'test -f /opt/stackpilot/local/deploy.sh'
}

echo "=== deploy.sh from this machine, port 80 and the ntfy port taken, no ss ==="
start_server
copy_served_files
check "server starts without ss (iproute2)" on_server '! command -v ss'
on_server 'systemd-run --quiet --unit=port80 systemd-socket-activate -l 80 /bin/sleep infinity'
on_server 'systemd-run --quiet --unit=port8085 systemd-socket-activate -l 127.0.0.1:8085 /bin/sleep infinity'
check "deploy fails" deploy_fails
check "no success message" bash -c "! grep -qE 'Domain configured|Application available|DONE!' '$TEST_DIR/deploy.log'"
on_server 'systemctl stop port80.socket port80.service 2>/dev/null; systemctl reset-failed 2>/dev/null; true'
check "deploy succeeds once port 80 is free" deploy
check "toolbox installed without rsync on the server" toolbox_installed
check "ss installed and ntfy moved to the next free port" on_server \
    'command -v ss && curl -fsS http://127.0.0.1:8086/v1/health | grep -q healthy'
check "$DOMAIN answers through Caddy" served_through_caddy

echo "=== littlelink from this machine on a server without Caddy ==="
start_server
copy_served_files
check "littlelink deploy succeeds" deploy_app littlelink bio.internal
check "bio.internal serves LittleLink through Caddy" serves bio.internal / littlelink

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "FAIL: $FAILED check(s) failed"
    exit 1
fi
echo "PASS: --domain-type=caddy on a clean $IMAGE"
