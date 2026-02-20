#!/bin/bash

# StackPilot - Cookie Hub (Klaro!)
# Centralized Cookie Consent Manager for all your domains.
# Uses Caddy file_server mode (static files).
# Author: Pawel (Lazy Engineer)

set -e

APP_NAME="cookie-hub"
echo "--- Cookie Hub Setup (Klaro!) ---"
echo "Centralized server for Cookie Consent scripts."

# Required: DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "Missing required variable: DOMAIN"
    echo "   Usage: DOMAIN=assets.example.com ./install.sh"
    exit 1
fi
echo "Domain: $DOMAIN"

# Prerequisites: npm
if ! command -v npm &> /dev/null; then
    echo "NPM not found. Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# Caddy file_server mode
echo "Mode: Caddy file_server"
STACK_DIR="/var/www/$APP_NAME"
PUBLIC_DIR="$STACK_DIR"

# Setup directory
sudo mkdir -p "$PUBLIC_DIR"
cd "$STACK_DIR"

# Install Klaro via NPM (if not already installed)
if [ ! -f "$PUBLIC_DIR/klaro.js" ]; then
    echo "Installing Klaro via NPM..."

    # Create temp directory for npm
    TEMP_NPM=$(mktemp -d)
    cd "$TEMP_NPM"
    npm init -y > /dev/null
    npm install klaro

    # Copy dist files to public
    sudo cp node_modules/klaro/dist/klaro.js "$PUBLIC_DIR/"
    sudo cp node_modules/klaro/dist/klaro.css "$PUBLIC_DIR/"

    # Cleanup
    cd /
    rm -rf "$TEMP_NPM"
fi

# Create config template if not exists
if [ ! -f "$PUBLIC_DIR/config.js" ]; then
    echo "Generating default config.js..."
    cat <<'CONFIGJS' | sudo tee "$PUBLIC_DIR/config.js" > /dev/null
// Klaro Configuration - Centralized
// Edit this file to add/remove services across ALL your sites.

var klaroConfig = {
    elementID: 'klaro',
    storageMethod: 'cookie',
    cookieName: 'stackpilot_consent',
    cookieExpiresAfterDays: 365,
    default: false,
    mustConsent: false,
    acceptAll: true,
    hideDeclineAll: false,
    hideLearnMore: false,
    lang: 'en',

    translations: {
        en: {
            consentModal: {
                title: 'We respect your privacy',
                description: 'We use cookies and other technologies to ensure the best experience on our site.'
            },
            consentNotice: {
                description: 'We use cookies for analytics and content personalization.',
                learnMore: 'Customize preferences'
            },
            purposes: {
                analytics: 'Analytics',
                security: 'Security',
                marketing: 'Marketing'
            },
            ok: 'Accept all',
            save: 'Save selection',
            decline: 'Decline'
        }
    },

    services: [
        {
            name: 'googleAnalytics',
            default: true,
            title: 'Google Analytics / Umami',
            purposes: ['analytics'],
            cookies: [[/^_ga/], [/^_gid/], [/^umami/]]
        }
    ]
};
CONFIGJS
fi

# Caddy will be configured by deploy.sh via sp-expose
# Just store the path for later
echo "$PUBLIC_DIR" > /tmp/cookiehub_webroot

echo ""
echo "Cookie Hub installed!"
echo "   Config: $PUBLIC_DIR/config.js"

echo ""
echo "HOW TO USE:"
echo "Paste this in <head> of every website:"
echo ""
if [ -n "$DOMAIN" ]; then
    echo "<link rel=\"stylesheet\" href=\"https://$DOMAIN/klaro.css\" />"
    echo "<script defer src=\"https://$DOMAIN/config.js\"></script>"
    echo "<script defer src=\"https://$DOMAIN/klaro.js\"></script>"
else
    echo "(domain will be displayed after configuration)"
fi
