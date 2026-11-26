#!/bin/bash
# Local Docker integration: the one-line installer on a clean server installs
# Docker and starts an application. Runs the installers and code of this checkout.
#
# Usage: ./tests/e2e/oneliner-docker.sh [image...]
#   E2E_EXTRA_PACKAGES="sudo"  — packages preinstalled on top of the clean image
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGES=("$@")
[ "${#IMAGES[@]}" -gt 0 ] || IMAGES=(debian:12 ubuntu:22.04 ubuntu:24.04)
NAME="stackpilot-oneliner-test-$$"
TEST_DIR=$(mktemp -d)
PULLED=()
FAILED=0

remove_server() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$NAME-docker" "$NAME-containerd" >/dev/null 2>&1 || true
}
cleanup() {
    remove_server
    [ "${#PULLED[@]}" -eq 0 ] || docker image rm "${PULLED[@]}" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The served endpoints plus a git repository the bootstrap can clone
bash "$REPO_ROOT/installers/build.sh" "$TEST_DIR/srv/installers" >/dev/null
mkdir -p "$TEST_DIR/srv/repo"
(cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar -cf -) \
    | tar -xf - -C "$TEST_DIR/srv/repo"
git -C "$TEST_DIR/srv/repo" init -q -b main
git -C "$TEST_DIR/srv/repo" add -A
git -C "$TEST_DIR/srv/repo" -c user.name=test -c user.email=test@localhost \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m snapshot

check() {
    local label="$1"
    shift
    if "$@"; then
        echo "  ✓ $IMAGE: $label"
    else
        echo "  ✗ $IMAGE: $label"
        FAILED=$((FAILED + 1))
    fi
}
on_server() { docker exec "$NAME" bash -c "$1"; }

run_oneliner() {
    docker exec \
        -e STACKPILOT_BOOTSTRAP_URL=file:///srv/stackpilot/installers/install \
        -e STACKPILOT_REPO=file:///srv/stackpilot/repo \
        "$NAME" bash -c 'set -o pipefail
            curl -fsSL file:///srv/stackpilot/installers/ntfy | bash -s -- --domain-type=local --yes'
}

for IMAGE in "${IMAGES[@]}"; do
    echo ""
    echo "=== $IMAGE ==="
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        docker pull -q "$IMAGE" >/dev/null
        PULLED+=("$IMAGE")
    fi
    # systemd, curl and CA certificates are what a fresh VPS ships and the base image lacks
    docker run -d --name "$NAME" --privileged --cgroupns=private \
        --tmpfs /run --tmpfs /run/lock -e container=docker \
        -v "$NAME-docker:/var/lib/docker" -v "$NAME-containerd:/var/lib/containerd" \
        "$IMAGE" bash -c "export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq &&
            apt-get install -y -qq --no-install-recommends systemd systemd-sysv dbus curl ca-certificates ${E2E_EXTRA_PACKAGES:-} >/dev/null &&
            exec /sbin/init" >/dev/null
    booted=false
    for _ in $(seq 1 180); do
        state=$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)
        case "$state" in running|degraded) booted=true; break ;; esac
        [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || break
        sleep 1
    done
    if [ "$booted" != true ]; then
        docker logs --tail 30 "$NAME"
        check "server booted" false
        remove_server
        continue
    fi
    check "starts without Docker" on_server '! command -v docker >/dev/null'
    docker cp "$TEST_DIR/srv" "$NAME:/srv/stackpilot"
    on_server 'chown -R root:root /srv/stackpilot'

    check "one-liner exits 0" run_oneliner
    check "docker --version" on_server 'docker --version'
    check "Docker service is active" on_server 'systemctl is-active --quiet docker'
    check "log rotation and live restore applied" on_server \
        '[ "$(docker info --format "{{.LoggingDriver}} {{.LiveRestoreEnabled}}")" = "json-file true" ]'
    check "ntfy answers its health check" on_server \
        'for _ in $(seq 1 60); do curl -fsS http://127.0.0.1:8085/v1/health 2>/dev/null | grep -q "\"healthy\":true" && exit 0; sleep 1; done; exit 1'
    remove_server
done

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "FAIL: $FAILED check(s) failed"
    exit 1
fi
echo "PASS: one-line installer on ${IMAGES[*]}"
