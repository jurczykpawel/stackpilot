#!/bin/bash
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR=$(mktemp -d)
trap 'rm -r "$DIR"' EXIT
server_exec() { printf '%s\n' "$1" >> "$DIR/calls"; }
msg() { :; }
block=$(sed -n '/^# Auto-install Docker/,/^# Upload script/{ /^# Upload script/d; p; }' "$ROOT/local/deploy.sh")
test -n "$block"
SCRIPT_PATH="$DIR/native.sh"
printf '# DOCKER_REQUIRED=false\n' > "$SCRIPT_PATH"
APP_NAME=example RUNTIME=pm2
export APP_NAME RUNTIME
eval "$block"
if [ -s "$DIR/calls" ]; then echo 'FAIL: native app still checks Docker'; exit 1; fi
printf '# normal app\n' > "$SCRIPT_PATH"
eval "$block"
test -s "$DIR/calls"
: > "$DIR/calls"
APP_NAME=sellf RUNTIME=pm2
eval "$block"
test ! -s "$DIR/calls"
RUNTIME=docker
eval "$block"
test -s "$DIR/calls"
echo 'PASS: native, default, Sellf PM2 and Docker runtimes'
