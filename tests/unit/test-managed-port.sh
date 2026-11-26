#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'python3 -c "import shutil,sys;shutil.rmtree(sys.argv[1])" "$WORK"' EXIT
sed -n '/^DEFAULT_PORT=/,/^# PHASE 1/p' "$ROOT/local/deploy.sh" > "$WORK/phase.sh"
for managed in true false; do
    printf 'PORT=31878\n' > "$WORK/install.sh"
    [ "$managed" = false ] || printf '# PORT_MANAGED=true\n' >> "$WORK/install.sh"
    result=$(bash -s -- "$WORK" <<'CASE'
set -e
SCRIPT_PATH="$1/install.sh"
DOMAIN=''
APP_NAME='native'
SSH_ALIAS='test'
MSG_PORT_IN_USE=''
MSG_PORT_OVERRIDE=''
read_existing_app_port() { return 1; }
listening_ports() { echo 31878; }
next_free_port() { echo 31879; }
app_published_ports() { :; }
msg() { :; }
source "$1/phase.sh" > /dev/null
[ "$DEFAULT_PORT" = 31878 ]
printf '%s' "$PORT_OVERRIDE"
CASE
)
    if [ "$managed" = true ]; then
        [ -z "$result" ] || { echo 'Installer-managed port was replaced'; exit 1; }
    else
        [ "$result" = 31879 ] || { echo 'Ordinary port discovery did not run'; exit 1; }
    fi
done

export DEFAULT_PORT=31878
initializer=$(sed -n '/^APP_PORT=/p' "$ROOT/local/deploy.sh" | head -1)
eval "$initializer"
[ "$APP_PORT" = 31878 ] || { echo 'Local access port was lost after discovery'; exit 1; }
