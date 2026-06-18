#!/bin/bash

# StackPilot - Firewall Setup
# Configures default-deny INPUT iptables policy on VPS.
#
# Designed for IPv6-only VPS (Mikrus, Hetzner Cloud IPv6-only) behind Caddy
# reverse proxy. Blocks all direct port access except:
#   - loopback, established connections, ICMPv6
#   - WireGuard/Cytrus VPN (UDP port detected automatically)
#   - SSH (TCP 22)
#   - HTTP/HTTPS (TCP 80, TCP/UDP 443)
#
# Docker ports (n8n, app containers) are blocked automatically by INPUT DROP —
# no need to list them explicitly. docker-proxy on IPv6 uses INPUT, not FORWARD.
#
# Usage:
#   ./local/setup-firewall.sh [ssh_alias]
#   ./local/setup-firewall.sh mikrus
#   ./local/setup-firewall.sh --check mikrus      # only check, don't apply
#
# Author: Paweł (Lazy Engineer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CHECK_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--check] [ssh_alias]"
            echo ""
            echo "Configures default-deny iptables INPUT policy on VPS."
            echo "Allows: loopback, established, ICMPv6, WireGuard, SSH 22, HTTP 80, HTTPS 443."
            echo "Blocks: all Docker ports, app ports (3333/3334/5678/etc) automatically."
            echo ""
            echo "Options:"
            echo "  --check    Only check current status, do not apply changes"
            echo ""
            echo "Arguments:"
            echo "  ssh_alias  SSH alias for server (default: vps)"
            exit 0
            ;;
    esac
done

VPS_HOST="${!#}"
if [[ "$VPS_HOST" == --* ]] || [ -z "$VPS_HOST" ]; then
    VPS_HOST="vps"
fi
SSH_ALIAS="$VPS_HOST"

echo ""
echo -e "${BLUE}🔒 StackPilot — Firewall Setup${NC}"
echo -e "${BLUE}   Server: $SSH_ALIAS${NC}"
echo ""

# =============================================================================
# 1. CHECK CURRENT STATE
# =============================================================================

echo "📋 Checking current firewall state..."

CURRENT_POLICY=$(server_exec "ip6tables -S INPUT 2>/dev/null | grep '^-P INPUT' | awk '{print \$3}'" 2>/dev/null || echo "UNKNOWN")
echo "   ip6tables INPUT policy: $CURRENT_POLICY"

WG_PORT=$(server_exec "cat /etc/wireguard/wg0.conf 2>/dev/null | grep ListenPort | awk '{print \$3}'" 2>/dev/null || echo "")
echo "   WireGuard port: ${WG_PORT:-not found}"

if [ "$CURRENT_POLICY" = "DROP" ]; then
    echo ""
    echo -e "${GREEN}✅ Firewall already configured (INPUT policy = DROP)${NC}"

    echo ""
    echo "Current INPUT rules:"
    server_exec "ip6tables -L INPUT -v -n --line-numbers 2>/dev/null | head -20"

    if $CHECK_ONLY; then
        exit 0
    fi

    echo ""
    read -r -p "Re-apply rules anyway? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[YyTt]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

if $CHECK_ONLY; then
    echo ""
    echo -e "${YELLOW}⚠️  Firewall NOT configured (INPUT policy = $CURRENT_POLICY)${NC}"
    echo "   Run without --check to apply."
    exit 1
fi

# =============================================================================
# 2. CONFIRM
# =============================================================================

echo ""
echo -e "${YELLOW}⚠️  This will change iptables INPUT policy to DROP.${NC}"
echo "   The following will be allowed:"
echo "   • Loopback (lo)"
echo "   • Established/related connections"
echo "   • ICMPv6 (IPv6 neighbor discovery)"
if [ -n "$WG_PORT" ]; then
echo "   • UDP $WG_PORT (WireGuard/Cytrus VPN)"
fi
echo "   • wg0 interface (all VPN traffic)"
echo "   • TCP 22 (SSH)"
echo "   • TCP/UDP 80, 443 (HTTP/HTTPS for Caddy)"
echo ""
echo "   Everything else will be DROPPED (Docker ports, app ports, etc.)"
echo ""
read -r -p "Proceed? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[YyTt]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# =============================================================================
# 3. APPLY RULES
# =============================================================================

echo ""
echo "🔧 Applying firewall rules..."

server_exec "
set -e

# Helper: add rule only if not already present
ip6t_add() {
    ip6tables -C \"\$@\" 2>/dev/null || ip6tables -A \"\$@\"
}
ipt_add() {
    iptables -C \"\$@\" 2>/dev/null || iptables -A \"\$@\"
}

# Flush INPUT (clean slate)
ip6tables -F INPUT
iptables -F INPUT 2>/dev/null || true

# --- ALLOW rules (must be added BEFORE setting DROP policy) ---

# Loopback
ip6tables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true

# Established/related — keeps current SSH session alive during setup
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

# ICMPv6 — essential for IPv6 (neighbor discovery, ping, etc.)
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

# WireGuard/Cytrus VPN — allow re-establishment after reboot
WG_PORT=\$(cat /etc/wireguard/wg0.conf 2>/dev/null | grep ListenPort | awk '{print \$3}')
if [ -n \"\$WG_PORT\" ]; then
    ip6tables -A INPUT -p udp --dport \"\$WG_PORT\" -j ACCEPT
    iptables -A INPUT -p udp --dport \"\$WG_PORT\" -j ACCEPT 2>/dev/null || true
    echo \"  + WireGuard UDP \$WG_PORT\"
fi

# All traffic from WireGuard interface (SSH via Cytrus, internal services)
ip6tables -A INPUT -i wg0 -j ACCEPT
iptables -A INPUT -i wg0 -j ACCEPT 2>/dev/null || true

# SSH on public interface (backup if VPN breaks)
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true

# HTTP + HTTPS for Caddy
ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
ip6tables -A INPUT -p udp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true

# --- DEFAULT DENY ---
ip6tables -P INPUT DROP
iptables -P INPUT DROP 2>/dev/null || true

echo 'Rules applied.'
"

# =============================================================================
# 4. PERSIST
# =============================================================================

echo "💾 Persisting rules..."

server_exec "
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
ip6tables-save > /etc/iptables/rules.v6

# Add cron restore if not already there
CRON_LINE='@reboot /usr/sbin/iptables-restore < /etc/iptables/rules.v4 2>/dev/null; /usr/sbin/ip6tables-restore < /etc/iptables/rules.v6'
(crontab -l 2>/dev/null | grep -qF 'iptables-restore') || \
  (crontab -l 2>/dev/null; echo \"\$CRON_LINE\") | crontab -
echo 'Saved to /etc/iptables/rules.v4 and rules.v6, cron @reboot added.'
"

# =============================================================================
# 5. VERIFY
# =============================================================================

echo ""
echo "✅ Verifying..."

server_exec "
echo 'INPUT policy:' \$(ip6tables -S INPUT | grep '^-P INPUT' | awk '{print \$3}')
echo ''
ip6tables -L INPUT -v -n
"

echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Firewall configured!${NC}"
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo ""
echo "⚠️  Test SSH access from a NEW terminal before closing this one."
echo ""
echo "To verify from an external host (e.g. frog):"
echo "  ssh frog \"curl -sf 'http://[<server-ipv6>]:5678' -m 5\""
echo ""
echo "Restore rules manually if needed:"
echo "  ssh $SSH_ALIAS 'ip6tables-restore < /etc/iptables/rules.v6'"
