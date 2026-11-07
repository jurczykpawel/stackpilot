#!/bin/bash

# StackPilot - Mailstack (server part)
# Forms and transactional email API with an encrypted delivery log, the Pro panel and webhooks.
# Profile a: API and panel on Cloudflare Workers, this server runs cloudflared, egress and backup.
# Profile b: API on a Worker, the panel here. Profile c: API and panel here.
# Run ./local/deploy.sh mailstack on your computer: apps/mailstack/deploy.mjs prepares keys, Cloudflare and this
# directory, then calls this script with MAILSTACK_SERVICES. MAILSTACK_ACTION=status|uninstall for the other steps.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=900

set -e
set +x

APP_NAME="mailstack"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
ACTION="${MAILSTACK_ACTION:-install}"
PROJECT="$(basename "$STACK_DIR")"
SBIN="${MAILSTACK_SBIN:-/usr/local/sbin}"
UNIT_NAME="mailstack-egress-firewall.service"
UNIT="${MAILSTACK_UNIT_DIR:-/etc/systemd/system}/$UNIT_NAME"
FIREWALL="$SBIN/mailstack-egress-firewall"

compose() { sudo docker compose -p "$PROJECT" --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.yml" "$@"; }

if [ "$ACTION" = uninstall ]; then
    if sudo test -f "$STACK_DIR/compose.yml"; then compose down -v --rmi local --remove-orphans; fi
    if sudo test -f "$UNIT" && sudo grep -qx "EnvironmentFile=$STACK_DIR/.env" "$UNIT"; then
        if sudo test -x "$FIREWALL"; then sudo "$FIREWALL" remove; sudo rm -f "$FIREWALL"; fi
        sudo systemctl disable --now "$UNIT_NAME" || true
        sudo rm -f "$UNIT"
        sudo systemctl daemon-reload
    fi
    sudo rm -rf "$STACK_DIR"
    echo "Mailstack removed from this server."
    exit 0
fi

sudo test -f "$STACK_DIR/compose.yml" || { echo "Run ./local/deploy.sh mailstack from your computer; it prepares $STACK_DIR first."; exit 1; }
if [ "$ACTION" = status ]; then compose ps; exit 0; fi
SERVICES="${MAILSTACK_SERVICES:-}"
[ -n "$SERVICES" ] || { echo "MAILSTACK_SERVICES is empty."; exit 1; }
has() { [[ " $SERVICES " == *" $1 "* ]]; }

sudo find "$STACK_DIR" -type d -path "$STACK_DIR/secrets*" -exec chmod 700 {} +
sudo find "$STACK_DIR" -maxdepth 1 -name '*.env' -exec chmod 600 {} +
sudo chmod 600 "$STACK_DIR/.env"
sudo python3 "$STACK_DIR/network-subnets.py" "$STACK_DIR" "$PROJECT"

if has panel && ! sudo test -s "$STACK_DIR/secrets/panel/tls.key"; then
    PANEL_HOST=$(sudo grep -m1 '^PANEL_ORIGIN=' "$STACK_DIR/.env" | sed 's|^PANEL_ORIGIN=https://||')
    # Private origin certificate: only cloudflared connects, with the panel host as server name.
    sudo openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$PANEL_HOST" -addext "subjectAltName=DNS:$PANEL_HOST" \
        -keyout "$STACK_DIR/secrets/panel/tls.key" -out "$STACK_DIR/secrets/panel/tls.crt" >/dev/null 2>&1
fi
sudo find "$STACK_DIR/secrets" -type f -exec chmod 600 {} +
sudo chown -R 1000:1000 "$STACK_DIR/secrets"
if sudo test -d "$STACK_DIR/config"; then sudo chown -R 1000:1000 "$STACK_DIR/config"; fi

if has egress; then
    if sudo test -f "$UNIT" && ! sudo grep -qx "EnvironmentFile=$STACK_DIR/.env" "$UNIT"; then
        echo "Another Mailstack egress uses this host's firewall: $(sudo grep -m1 '^EnvironmentFile=' "$UNIT" | cut -d= -f2-). One egress per host."
        exit 1
    fi
    # The egress must not reach this host through its own public addresses. Private, CGNAT, link-local, loopback and
    # ULA addresses are left out: the firewall denies those ranges anyway, and Docker bridges created by Compose would
    # otherwise change the list on the next run and recreate the egress container.
    DENY=$( {
        for family in 4 6; do
            target=1.1.1.1; [ "$family" = 6 ] && target='[2606:4700:4700::1111]'
            curl -"$family" -fsS --max-time 5 "https://$target/cdn-cgi/trace" 2>/dev/null | sed -n 's/^ip=//p'
        done
        ip -o addr show scope global | awk '{ split($4, a, "/"); print a[1] }'
    } | grep -viE '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|f[cd][0-9a-f]{2}:|fe[89ab][0-9a-f]:)' \
      | awk 'NF { print ($0 ~ /:/) ? $0 "/128" : $0 "/32" }' | sort -u | paste -sd, - )
    [ -n "$DENY" ] || { echo "Cannot determine this host's addresses for the egress firewall."; exit 1; }
    sudo sed -i.bak '/^EGRESS_DENY_CIDRS=/d' "$STACK_DIR/.env" && sudo rm -f "$STACK_DIR/.env.bak"
    echo "EGRESS_DENY_CIDRS=$DENY" | sudo tee -a "$STACK_DIR/.env" >/dev/null
    sudo install -m 0755 "$STACK_DIR/egress-firewall.sh" "$FIREWALL"
    sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Mailstack egress firewall
After=docker.service
PartOf=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=$STACK_DIR/.env
ExecStart=$FIREWALL
[Install]
WantedBy=multi-user.target docker.service
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$UNIT_NAME"
    sudo systemctl restart "$UNIT_NAME" || { echo "Egress firewall failed; nothing was started. Check: journalctl -u $UNIT_NAME"; exit 1; }
fi

BUILD=$(for s in $SERVICES; do [ "$s" = cloudflared ] || printf '%s ' "$s"; done)
# Unchanged sources keep the running images: a rebuild would produce new image ids and recreate every container.
CONTEXT_SHA=$(sudo cat "$STACK_DIR/context.sha256" 2>/dev/null || true)
if [ -z "$CONTEXT_SHA" ] || [ "$CONTEXT_SHA" != "$(sudo cat "$STACK_DIR/.built-context" 2>/dev/null || true)" ]; then
    # shellcheck disable=SC2086
    compose build $BUILD
    echo "$CONTEXT_SHA" | sudo tee "$STACK_DIR/.built-context" >/dev/null
fi
# shellcheck disable=SC2086
compose up -d --wait --wait-timeout 180 $SERVICES || {
    echo "Services not ready. Logs: cd $STACK_DIR && sudo docker compose -p $PROJECT logs --tail 50"
    exit 1
}
echo "Mailstack services running: $SERVICES"
