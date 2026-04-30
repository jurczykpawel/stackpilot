#!/bin/bash

# StackPilot - Caddy Server & Helper Tool
# Installs Caddy (Modern Reverse Proxy) and a CLI helper for instant HTTPS.
# Author: Paweł (Lazy Engineer)

set -e

_CADDY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    # When piped via ssh (bash -s), paths won't resolve — define fallbacks
    if [ -n "$_CADDY_DIR" ] && [ -f "$_CADDY_DIR/../lib/i18n.sh" ]; then
        source "$_CADDY_DIR/../lib/i18n.sh"
    elif [ -f /opt/stackpilot/lib/i18n.sh ]; then
        source /opt/stackpilot/lib/i18n.sh
    else
        msg() { printf "%s\n" "$1"; }
        msg_n() { printf "%s" "$1"; }
    fi
fi

# --tools-only: skip Caddy install + Caddyfile rewrite, only refresh sp-expose / sp-redirect.
# Used when updating helper tools on a server that already has Caddy configured.
TOOLS_ONLY=false
for arg in "$@"; do
    [ "$arg" = "--tools-only" ] && TOOLS_ONLY=true
done

if [ "$TOOLS_ONLY" = false ]; then
    msg "$MSG_CADDY_STEP1"

    # Prerequisites
    sudo apt install -y -q debian-keyring debian-archive-keyring apt-transport-https curl

    # Add Key & Repo
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null

    # Install
    sudo apt update
    sudo apt install caddy -y

    # Replace default Caddyfile (default :80 block prevents self-signed certs for CF-proxied domains).
    # Per-domain configuration lives in /etc/caddy/conf.d/<domain>.caddy and is imported here.
    sudo mkdir -p /etc/caddy/conf.d
    sudo tee /etc/caddy/Caddyfile > /dev/null <<'CADDYFILE_EOF'
# Managed by StackPilot
# Per-domain configuration lives in /etc/caddy/conf.d/<domain>.caddy
import /etc/caddy/conf.d/*.caddy
CADDYFILE_EOF

    msg "$MSG_CADDY_STEP2"
else
    echo "🔧 Updating sp-expose and sp-redirect only (skipping Caddy install)..."
fi

# Creating a lazy wrapper script to add domains easily
cat <<'EOF' | sudo tee /usr/local/bin/sp-expose > /dev/null
#!/bin/bash
# Usage: sp-expose <domain> <port_or_path> [mode] [--cloudflare]
# Modes:
#   proxy (default) - reverse_proxy localhost:PORT
#   static          - file_server from PATH
#   php             - php_fastcgi + file_server from PATH
#
# Flags:
#   --cloudflare    - HTTP-only (SSL terminates at Cloudflare, prevents redirect loop)
#
# Examples:
#   sp-expose n8n.example.pl 5678                         # proxy mode
#   sp-expose static.example.pl /var/www/app static       # static mode
#   sp-expose app.example.pl /var/www/app php             # PHP + static files
#   sp-expose app.example.pl 5678 proxy --cloudflare      # behind Cloudflare

DOMAIN=$1
PORT_OR_PATH=$2
MODE="${3:-proxy}"
CLOUDFLARE=false
CONF_D="/etc/caddy/conf.d"

# Parse --cloudflare from any position
for arg in "$@"; do
    if [ "$arg" = "--cloudflare" ]; then
        CLOUDFLARE=true
    fi
done
# If mode got --cloudflare, reset to default
if [ "$MODE" = "--cloudflare" ]; then
    MODE="proxy"
fi

if [ -z "$DOMAIN" ] || [ -z "$PORT_OR_PATH" ]; then
    echo "Usage: sp-expose <domain> <port_or_path> [mode] [--cloudflare]"
    echo ""
    echo "Modes:"
    echo "  proxy  - reverse_proxy localhost:PORT (default)"
    echo "  static - file_server from PATH"
    echo ""
    echo "Flags:"
    echo "  --cloudflare - HTTP-only mode (Cloudflare Flexible SSL)"
    echo ""
    echo "Examples:"
    echo "  sp-expose n8n.example.pl 5678"
    echo "  sp-expose static.example.pl /var/www/app static"
    echo "  sp-expose app.example.pl 5678 proxy --cloudflare"
    exit 1
fi

# Validate domain (prevent Caddyfile injection)
if ! echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'; then
    echo "❌ Invalid domain: $DOMAIN (only letters, numbers, dots, dashes allowed)"
    exit 1
fi

# Validate port (proxy mode) or path (static mode)
if [ "$MODE" = "proxy" ]; then
    if ! echo "$PORT_OR_PATH" | grep -qE '^[0-9]+$'; then
        echo "❌ Invalid port: $PORT_OR_PATH (must be a number)"
        exit 1
    fi
else
    if ! echo "$PORT_OR_PATH" | grep -qE '^/[a-zA-Z0-9/_.-]+$'; then
        echo "❌ Invalid path: $PORT_OR_PATH (must be an absolute path with safe characters)"
        exit 1
    fi
fi

# Determine site address: http:// prefix for Cloudflare Flexible SSL (prevents redirect loop)
SITE_ADDR="$DOMAIN"
if [ "$CLOUDFLARE" = true ]; then
    SITE_ADDR="http://$DOMAIN"
fi

# Determine target file: /etc/caddy/conf.d/<primary-domain>.caddy
sudo mkdir -p "$CONF_D"
PRIMARY="${DOMAIN%%,*}"
PRIMARY="${PRIMARY// /}"
PRIMARY="${PRIMARY#http://}"
PRIMARY="${PRIMARY#https://}"
PRIMARY="${PRIMARY//\//_}"
TARGET_FILE="$CONF_D/$PRIMARY.caddy"

# Check if domain already exists to avoid duplicates (search all conf.d files)
if [ -d "$CONF_D" ] && grep -hE "^[[:space:]]*([^{}#]*[[:space:],])?${DOMAIN}([[:space:],{/]|$)" "$CONF_D"/*.caddy 2>/dev/null | grep -q '{[[:space:]]*$'; then
    echo "⚠️  Domain $DOMAIN already configured in $CONF_D/. Please edit manually."
    exit 1
fi

if [ "$MODE" = "php" ]; then
    PHP_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)
    if [ -z "$PHP_SOCK" ]; then
        echo "❌ PHP-FPM socket not found. Install php-fpm first."
        exit 1
    fi
    echo "🚀 Exposing $DOMAIN -> $PORT_OR_PATH (PHP + static files)"
    cat <<CONFIG | sudo tee -a "$TARGET_FILE"

$SITE_ADDR {
    root * $PORT_OR_PATH
    php_fastcgi unix/$PHP_SOCK
    file_server
}
CONFIG
elif [ "$MODE" = "static" ]; then
    echo "🚀 Exposing $DOMAIN -> $PORT_OR_PATH (static files)"
    cat <<CONFIG | sudo tee -a "$TARGET_FILE"

$SITE_ADDR {
    root * $PORT_OR_PATH
    file_server
    header Access-Control-Allow-Origin "*"
}
CONFIG
else
    echo "🚀 Exposing $DOMAIN -> localhost:$PORT_OR_PATH (reverse proxy)"
    cat <<CONFIG | sudo tee -a "$TARGET_FILE"

$SITE_ADDR {
    reverse_proxy localhost:$PORT_OR_PATH
}
CONFIG
fi

# Ensure Caddy is running and reload
if ! systemctl is-active --quiet caddy; then
    sudo systemctl start caddy
    sudo systemctl enable caddy 2>/dev/null
else
    sudo systemctl reload caddy
fi

echo "✅ Done! Your site should be live at https://$DOMAIN"
EOF

# Make it executable
sudo chmod +x /usr/local/bin/sp-expose

# Creating the redirect manager: sp-redirect
cat <<'EOF' | sudo tee /usr/local/bin/sp-redirect > /dev/null
#!/bin/bash
# Usage:
#   sp-redirect add <domain> <path> <target> [--code=301|302]
#   sp-redirect remove <domain> <path>
#   sp-redirect list [<domain>]
#
# The redirect is added INSIDE the existing site block for <domain>
# (so it inherits TLS settings like `tls internal`).
# The block must already be configured via sp-expose (or any conf.d/ file).
#
# Examples:
#   sp-redirect add techskills.academy /protocol-autonomy https://sellf.techskills.academy/protocol-autonomy
#   sp-redirect remove techskills.academy /protocol-autonomy
#   sp-redirect list techskills.academy

set -e

CONF_D="/etc/caddy/conf.d"

usage() {
    awk 'NR==1 {next} /^# ?/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
    exit 1
}

# Find the conf.d file whose top-level site block lists <domain> as a host.
# Output: full path of matching file, or empty string.
find_domain_file() {
    local dom="$1"
    for f in "$CONF_D"/*.caddy; do
        [ -f "$f" ] || continue
        if awk -v dom="$dom" '
            function check_site() {
                n = split(site, hosts, /[, ]+/)
                for (i = 1; i <= n; i++) {
                    h = hosts[i]
                    sub(/\/.*$/, "", h)
                    sub(/^https?:\/\//, "", h)
                    if (h == dom) { found = 1; exit }
                }
            }
            BEGIN { depth = 0; site = ""; found = 0 }
            /^[[:space:]]*$/ && depth == 0 { next }
            /^[[:space:]]*#/ && depth == 0 { next }
            {
                line = $0
                tmp = line; n_open = gsub(/\{/, "{", tmp)
                tmp = line; n_close = gsub(/\}/, "}", tmp)
                if (depth == 0 && site == "") {
                    site = line
                    sub(/[[:space:]]*\{.*$/, "", site)
                    check_site()
                    if (found) exit
                    depth = n_open - n_close
                    if (depth == 0) site = ""
                    next
                }
                depth += n_open - n_close
                if (depth == 0) site = ""
            }
            END { exit !found }
        ' "$f"; then
            echo "$f"
            return 0
        fi
    done
    echo ""
    return 1
}

# Validate path: must start with / and contain only safe characters.
validate_path() {
    if ! echo "$1" | grep -qE '^/[a-zA-Z0-9/_.-]*$'; then
        echo "❌ Invalid path: $1 (must start with /, only letters/numbers/. _ - / allowed)"
        exit 1
    fi
}

# Validate target URL.
validate_target() {
    if ! echo "$1" | grep -qE '^https?://[a-zA-Z0-9._/?&=#:%+-]+$'; then
        echo "❌ Invalid target URL: $1 (must be http(s)://...)"
        exit 1
    fi
}

# Validate domain.
validate_domain() {
    if ! echo "$1" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
        echo "❌ Invalid domain: $1"
        exit 1
    fi
}

cmd_add() {
    local DOMAIN="$1" RPATH="$2" TARGET="$3" CODE_ARG="$4"
    [ -z "$DOMAIN" ] || [ -z "$RPATH" ] || [ -z "$TARGET" ] && usage

    validate_domain "$DOMAIN"
    validate_path "$RPATH"
    validate_target "$TARGET"

    local CODE_WORD="permanent"
    case "$CODE_ARG" in
        --code=301|"") CODE_WORD="permanent" ;;
        --code=302)    CODE_WORD="temporary" ;;
        *) echo "❌ Unknown option: $CODE_ARG (expected --code=301 or --code=302)"; exit 1 ;;
    esac

    local FILE
    FILE=$(find_domain_file "$DOMAIN") || true
    if [ -z "$FILE" ]; then
        echo "❌ Domain $DOMAIN is not configured in $CONF_D/."
        echo "   Run sp-expose first, or add a base block manually."
        exit 1
    fi

    # Remove existing redirect for the same path (idempotent update).
    if grep -qF "# sp-redirect:$RPATH" "$FILE"; then
        echo "ℹ️  Replacing existing redirect for $DOMAIN$RPATH"
        sudo sed -i "\|# sp-redirect:${RPATH}\$|,\|# /sp-redirect:${RPATH}\$|d" "$FILE"
    fi

    # Insert 3 marker lines just before the closing brace of the matching site block.
    local TMP
    TMP=$(mktemp)
    awk -v dom="$DOMAIN" -v rpath="$RPATH" -v target="$TARGET" -v code="$CODE_WORD" '
        function check_site() {
            n = split(site, hosts, /[, ]+/)
            for (i = 1; i <= n; i++) {
                h = hosts[i]
                sub(/\/.*$/, "", h)
                sub(/^https?:\/\//, "", h)
                if (h == dom) { in_target = 1; return }
            }
        }
        BEGIN { depth = 0; site = ""; in_target = 0; inserted = 0 }
        {
            line = $0
            tmp = line; n_open = gsub(/\{/, "{", tmp)
            tmp = line; n_close = gsub(/\}/, "}", tmp)
            new_depth = depth + n_open - n_close

            if (depth == 0 && new_depth > 0 && site == "") {
                site = line
                sub(/[[:space:]]*\{.*$/, "", site)
                check_site()
            }

            if (in_target && new_depth == 0 && !inserted) {
                print "\t# sp-redirect:" rpath
                print "\tredir " rpath " " target " " code
                print "\t# /sp-redirect:" rpath
                inserted = 1
                in_target = 0
            }

            print line
            depth = new_depth
            if (depth == 0) { site = ""; in_target = 0 }
        }
        END { if (!inserted) exit 1 }
    ' "$FILE" > "$TMP" || { echo "❌ Could not locate closing brace of $DOMAIN block in $FILE"; rm -f "$TMP"; exit 1; }

    sudo cp "$TMP" "$FILE"
    rm -f "$TMP"

    if ! sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        echo "❌ Caddy validation failed. See: caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"
        exit 1
    fi
    sudo systemctl reload caddy

    echo "✅ Redirect added: https://$DOMAIN$RPATH -> $TARGET ($CODE_WORD)"
}

cmd_remove() {
    local DOMAIN="$1" RPATH="$2"
    [ -z "$DOMAIN" ] || [ -z "$RPATH" ] && usage

    validate_domain "$DOMAIN"
    validate_path "$RPATH"

    local FILE
    FILE=$(find_domain_file "$DOMAIN") || true
    if [ -z "$FILE" ]; then
        echo "❌ Domain $DOMAIN is not configured in $CONF_D/."
        exit 1
    fi

    if ! grep -qF "# sp-redirect:$RPATH" "$FILE"; then
        echo "ℹ️  No redirect found for $DOMAIN$RPATH"
        exit 0
    fi

    sudo sed -i "\|# sp-redirect:${RPATH}\$|,\|# /sp-redirect:${RPATH}\$|d" "$FILE"

    if ! sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        echo "❌ Caddy validation failed after removal."
        exit 1
    fi
    sudo systemctl reload caddy

    echo "✅ Redirect removed: $DOMAIN$RPATH"
}

cmd_list() {
    local FILTER="$1"
    local found=0
    for f in "$CONF_D"/*.caddy; do
        [ -f "$f" ] || continue
        # Extract redirect lines bounded by markers
        awk -v file="$f" -v filter="$FILTER" '
            BEGIN { in_redir = 0 }
            /# sp-redirect:/ {
                in_redir = 1
                # path is everything after "sp-redirect:"
                rpath = $0
                sub(/^.*# sp-redirect:/, "", rpath)
                next
            }
            in_redir && /^[[:space:]]*redir / {
                # parse: "redir <path> <target> <code>"
                target = $3
                code = $4
                # derive domain from filename
                fname = file
                sub(/^.*\//, "", fname)
                sub(/\.caddy$/, "", fname)
                if (filter == "" || index(fname, filter) > 0) {
                    printf "  %s%s -> %s (%s)\n", fname, rpath, target, code
                }
                in_redir = 0
            }
        ' "$f"
    done
}

ACTION="${1:-}"
shift || true

case "$ACTION" in
    add)
        cmd_add "$@"
        ;;
    remove|rm|del|delete)
        cmd_remove "$@"
        ;;
    list|ls)
        cmd_list "$@"
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        echo "❌ Unknown action: $ACTION"
        echo ""
        usage
        ;;
esac
EOF

# Make it executable
sudo chmod +x /usr/local/bin/sp-redirect

if [ "$TOOLS_ONLY" = true ]; then
    echo "✅ sp-expose and sp-redirect updated."
else
    msg "$MSG_CADDY_DONE_HDR"
    msg "$MSG_CADDY_DONE_CADDY"
    msg "$MSG_CADDY_DONE_EXPOSE"
    msg "$MSG_CADDY_DONE_USAGE"
fi
