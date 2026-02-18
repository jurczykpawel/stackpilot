#!/bin/bash

# StackPilot - Database Backup Setup
# Configures automatic PostgreSQL/MySQL database backup
# Author: Paweł (Lazy Engineer)
#
# Supports:
# - Shared databases (credentials fetched from API)
# - Dedicated/purchased databases (credentials saved locally)
#
# Usage:
#   On the server: ./setup-db-backup.sh

set -e

BACKUP_DIR="/opt/backups/db"
BACKUP_SCRIPT="/opt/stackpilot/scripts/db-backup.sh"
CREDENTIALS_DIR="/opt/stackpilot/config"
CREDENTIALS_FILE="$CREDENTIALS_DIR/db-credentials.conf"
CRON_FILE="/etc/cron.d/stackpilot-db-backup"

echo "--- 🗄️ Database Backup Configuration ---"
echo ""

# =============================================================================
# PHASE 1: Detect shared databases (from API)
# =============================================================================

API_KEY=$(cat /klucz_api 2>/dev/null || true)
HOSTNAME=$(hostname 2>/dev/null || true)

HAS_SHARED_POSTGRES=false
HAS_SHARED_MYSQL=false

if [ -n "$API_KEY" ]; then
    echo "🔑 Fetching shared database credentials from API..."

    RESPONSE=$(curl -s -d "srv=$HOSTNAME&key=$API_KEY" https://api.mikr.us/db.bash 2>/dev/null)

    if [ -n "$RESPONSE" ]; then
        # PostgreSQL shared
        if echo "$RESPONSE" | grep -q "^psql="; then
            SHARED_PSQL_HOST=$(echo "$RESPONSE" | grep -A4 "^psql=" | grep 'Server:' | head -1 | sed 's/.*Server: *//' | tr -d '"')
            SHARED_PSQL_USER=$(echo "$RESPONSE" | grep -A4 "^psql=" | grep 'login:' | head -1 | sed 's/.*login: *//')
            SHARED_PSQL_PASS=$(echo "$RESPONSE" | grep -A4 "^psql=" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
            SHARED_PSQL_NAME=$(echo "$RESPONSE" | grep -A4 "^psql=" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//' | tr -d '"')

            if [ -n "$SHARED_PSQL_HOST" ] && [ -n "$SHARED_PSQL_USER" ]; then
                HAS_SHARED_POSTGRES=true
                echo "   ✅ PostgreSQL (shared): $SHARED_PSQL_HOST / $SHARED_PSQL_NAME"
            fi
        fi

        # MySQL shared
        if echo "$RESPONSE" | grep -q "^mysql="; then
            SHARED_MYSQL_HOST=$(echo "$RESPONSE" | grep -A4 "^mysql=" | grep 'Server:' | head -1 | sed 's/.*Server: *//' | tr -d '"')
            SHARED_MYSQL_USER=$(echo "$RESPONSE" | grep -A4 "^mysql=" | grep 'login:' | head -1 | sed 's/.*login: *//')
            SHARED_MYSQL_PASS=$(echo "$RESPONSE" | grep -A4 "^mysql=" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
            SHARED_MYSQL_NAME=$(echo "$RESPONSE" | grep -A4 "^mysql=" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//' | tr -d '"')

            if [ -n "$SHARED_MYSQL_HOST" ] && [ -n "$SHARED_MYSQL_USER" ]; then
                HAS_SHARED_MYSQL=true
                echo "   ✅ MySQL (shared): $SHARED_MYSQL_HOST / $SHARED_MYSQL_NAME"
            fi
        fi
    fi
else
    echo "⚠️  No API key found - skipping shared database detection"
fi

# =============================================================================
# PHASE 2: Configure dedicated/purchased databases
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Do you have dedicated/purchased databases?                    ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Load existing credentials if available
CUSTOM_DATABASES=()
if [ -f "$CREDENTIALS_FILE" ]; then
    echo "📂 Found existing credentials file"
    source "$CREDENTIALS_FILE"
    if [ ${#CUSTOM_DATABASES[@]} -gt 0 ]; then
        echo "   Configured databases: ${#CUSTOM_DATABASES[@]}"
    fi
fi

read -p "Do you want to add/edit a dedicated database? (y/N): " ADD_CUSTOM || true
if [[ "$ADD_CUSTOM" =~ ^[yYtT] ]]; then

    while true; do
        echo ""
        echo "Database type:"
        echo "  1) PostgreSQL"
        echo "  2) MySQL"
        read -p "Choose [1-2]: " DB_TYPE_CHOICE

        case $DB_TYPE_CHOICE in
            1) CUSTOM_DB_TYPE="postgres" ;;
            2) CUSTOM_DB_TYPE="mysql" ;;
            *) echo "❌ Invalid choice"; continue ;;
        esac

        read -p "Name (identifier, e.g. 'n8n-db'): " CUSTOM_DB_ID
        read -p "Host: " CUSTOM_DB_HOST
        read -p "Port [5432/3306]: " CUSTOM_DB_PORT
        CUSTOM_DB_PORT=${CUSTOM_DB_PORT:-$([ "$CUSTOM_DB_TYPE" = "postgres" ] && echo "5432" || echo "3306")}
        read -p "Database name: " CUSTOM_DB_NAME
        read -p "User: " CUSTOM_DB_USER
        read -sp "Password: " CUSTOM_DB_PASS
        echo ""

        # Add to array
        CUSTOM_DATABASES+=("$CUSTOM_DB_ID:$CUSTOM_DB_TYPE:$CUSTOM_DB_HOST:$CUSTOM_DB_PORT:$CUSTOM_DB_NAME:$CUSTOM_DB_USER:$CUSTOM_DB_PASS")

        echo "✅ Added: $CUSTOM_DB_ID ($CUSTOM_DB_TYPE)"

        read -p "Add another database? (y/N): " ADD_MORE
        [[ ! "$ADD_MORE" =~ ^[yYtT] ]] && break
    done

    # Save credentials to file
    echo ""
    echo "💾 Saving credentials to $CREDENTIALS_FILE..."

    mkdir -p "$CREDENTIALS_DIR"

    cat > "$CREDENTIALS_FILE" << 'EOF'
# StackPilot - Database Credentials
# Generated by setup-db-backup.sh
# WARNING: Contains passwords! Permissions: 600 (root only)
#
# Format: ID:TYPE:HOST:PORT:DATABASE:USER:PASSWORD

CUSTOM_DATABASES=(
EOF

    for db in "${CUSTOM_DATABASES[@]}"; do
        echo "    \"$db\"" >> "$CREDENTIALS_FILE"
    done

    echo ")" >> "$CREDENTIALS_FILE"

    # Set restrictive permissions
    chmod 600 "$CREDENTIALS_FILE"
    chown root:root "$CREDENTIALS_FILE"

    echo "✅ Credentials saved (permissions: 600, owner: root)"
fi

# =============================================================================
# PHASE 3: Generate backup script
# =============================================================================

if [ "$HAS_SHARED_POSTGRES" = false ] && [ "$HAS_SHARED_MYSQL" = false ] && [ ${#CUSTOM_DATABASES[@]} -eq 0 ]; then
    echo ""
    echo "❌ No databases found to back up!"
    echo "   - Enable a shared database in your hosting panel"
    echo "   - Or add a dedicated database by running this script again"
    exit 1
fi

echo ""
echo "📁 Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

echo "📝 Generating backup script..."
mkdir -p "$(dirname "$BACKUP_SCRIPT")"

cat > "$BACKUP_SCRIPT" << 'BACKUP_HEADER'
#!/bin/bash
# Automatic database backup
# Generated by setup-db-backup.sh
#
# Supports:
# - Shared databases (credentials from API - always up to date)
# - Dedicated databases (credentials from file)

BACKUP_DIR="/opt/backups/db"
CREDENTIALS_FILE="/opt/stackpilot/config/db-credentials.conf"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7
LOG_FILE="/var/log/db-backup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Remove old backups
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +$KEEP_DAYS -delete 2>/dev/null

BACKUP_HEADER

# Add shared database backup (from API)
if [ "$HAS_SHARED_POSTGRES" = true ] || [ "$HAS_SHARED_MYSQL" = true ]; then
    cat >> "$BACKUP_SCRIPT" << 'SHARED_API'

# =============================================================================
# SHARED DATABASE BACKUP (credentials from API)
# =============================================================================

API_KEY=$(cat /klucz_api 2>/dev/null)
HOSTNAME=$(hostname 2>/dev/null)

if [ -n "$API_KEY" ]; then
    RESPONSE=$(curl -s -d "srv=$HOSTNAME&key=$API_KEY" https://api.mikr.us/db.bash 2>/dev/null)

SHARED_API
fi

if [ "$HAS_SHARED_POSTGRES" = true ]; then
    cat >> "$BACKUP_SCRIPT" << 'SHARED_PSQL'
    # PostgreSQL shared
    if echo "$RESPONSE" | grep -q "^psql="; then
        PSQL_HOST=$(echo "$RESPONSE" | grep -A4 "^psql=" | grep 'Server:' | head -1 | sed 's/.*Server: *//' | tr -d '"')
        PSQL_USER=$(echo "$RESPONSE" | grep -A4 "^psql=" | grep 'login:' | head -1 | sed 's/.*login: *//')
        PSQL_PASS=$(echo "$RESPONSE" | grep -A4 "^psql=" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
        PSQL_NAME=$(echo "$RESPONSE" | grep -A4 "^psql=" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//' | tr -d '"')

        if [ -n "$PSQL_HOST" ] && [ -n "$PSQL_USER" ]; then
            export PGPASSWORD="$PSQL_PASS"
            if pg_dump -h "$PSQL_HOST" -U "$PSQL_USER" "$PSQL_NAME" 2>/dev/null | gzip > "$BACKUP_DIR/shared_postgres_$DATE.sql.gz"; then
                log "✅ PostgreSQL (shared) backup OK - shared_postgres_$DATE.sql.gz"
            else
                log "❌ PostgreSQL (shared) backup FAILED"
            fi
            unset PGPASSWORD
        fi
    fi
SHARED_PSQL
fi

if [ "$HAS_SHARED_MYSQL" = true ]; then
    cat >> "$BACKUP_SCRIPT" << 'SHARED_MYSQL'
    # MySQL shared
    if echo "$RESPONSE" | grep -q "^mysql="; then
        MYSQL_HOST=$(echo "$RESPONSE" | grep -A4 "^mysql=" | grep 'Server:' | head -1 | sed 's/.*Server: *//' | tr -d '"')
        MYSQL_USER=$(echo "$RESPONSE" | grep -A4 "^mysql=" | grep 'login:' | head -1 | sed 's/.*login: *//')
        MYSQL_PASS=$(echo "$RESPONSE" | grep -A4 "^mysql=" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
        MYSQL_NAME=$(echo "$RESPONSE" | grep -A4 "^mysql=" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//' | tr -d '"')

        if [ -n "$MYSQL_HOST" ] && [ -n "$MYSQL_USER" ]; then
            if mysqldump -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_NAME" 2>/dev/null | gzip > "$BACKUP_DIR/shared_mysql_$DATE.sql.gz"; then
                log "✅ MySQL (shared) backup OK - shared_mysql_$DATE.sql.gz"
            else
                log "❌ MySQL (shared) backup FAILED"
            fi
        fi
    fi
SHARED_MYSQL
fi

if [ "$HAS_SHARED_POSTGRES" = true ] || [ "$HAS_SHARED_MYSQL" = true ]; then
    echo "fi" >> "$BACKUP_SCRIPT"
fi

# Add dedicated database backup (from credentials file)
if [ ${#CUSTOM_DATABASES[@]} -gt 0 ]; then
    cat >> "$BACKUP_SCRIPT" << 'CUSTOM_BACKUP'

# =============================================================================
# DEDICATED DATABASE BACKUP (credentials from file)
# =============================================================================

if [ -f "$CREDENTIALS_FILE" ]; then
    source "$CREDENTIALS_FILE"

    for db_entry in "${CUSTOM_DATABASES[@]}"; do
        IFS=':' read -r DB_ID DB_TYPE DB_HOST DB_PORT DB_NAME DB_USER DB_PASS <<< "$db_entry"

        BACKUP_FILE="$BACKUP_DIR/${DB_ID}_${DATE}.sql.gz"

        if [ "$DB_TYPE" = "postgres" ]; then
            export PGPASSWORD="$DB_PASS"
            if pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" 2>/dev/null | gzip > "$BACKUP_FILE"; then
                log "✅ PostgreSQL ($DB_ID) backup OK - ${DB_ID}_${DATE}.sql.gz"
            else
                log "❌ PostgreSQL ($DB_ID) backup FAILED"
            fi
            unset PGPASSWORD

        elif [ "$DB_TYPE" = "mysql" ]; then
            if mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>/dev/null | gzip > "$BACKUP_FILE"; then
                log "✅ MySQL ($DB_ID) backup OK - ${DB_ID}_${DATE}.sql.gz"
            else
                log "❌ MySQL ($DB_ID) backup FAILED"
            fi
        fi
    done
fi
CUSTOM_BACKUP
fi

# Script footer
cat >> "$BACKUP_SCRIPT" << 'BACKUP_FOOTER'

log "Backup completed"
BACKUP_FOOTER

chmod +x "$BACKUP_SCRIPT"

# =============================================================================
# PHASE 4: Configure cron
# =============================================================================

echo "⏰ Configuring automatic backup (daily at 3:00 AM)..."

cat > "$CRON_FILE" << EOF
# StackPilot - Automatic database backup
# Daily at 3:00 AM
0 3 * * * root $BACKUP_SCRIPT >> /var/log/db-backup.log 2>&1
EOF

chmod 644 "$CRON_FILE"

# =============================================================================
# PHASE 5: Test
# =============================================================================

echo ""
echo "🧪 Running test backup..."
if $BACKUP_SCRIPT 2>&1 | tail -5; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ✅ Backup configured successfully!                            ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "📋 Configuration:"
    echo "   Backup directory:  $BACKUP_DIR"
    echo "   Script:            $BACKUP_SCRIPT"
    echo "   Cron:              daily at 3:00 AM"
    echo "   Retention:         7 days"
    if [ -f "$CREDENTIALS_FILE" ]; then
        echo "   Credentials:       $CREDENTIALS_FILE (chmod 600)"
    fi
    echo ""
    echo "📦 Created backups:"
    ls -lh "$BACKUP_DIR"/*.sql.gz 2>/dev/null || echo "   (no files)"
    echo ""
    echo "💡 Commands:"
    echo "   Manual backup:     $BACKUP_SCRIPT"
    echo "   Logs:              tail -f /var/log/db-backup.log"
    echo ""
    echo "💡 Restore:"
    echo "   PostgreSQL: gunzip -c backup.sql.gz | psql -h HOST -U USER DB"
    echo "   MySQL:      gunzip -c backup.sql.gz | mysql -h HOST -u USER -p DB"
else
    echo ""
    echo "⚠️  Test backup may not have worked correctly."
    echo "   Check logs: /var/log/db-backup.log"
fi

echo ""
echo "⚠️  NOTE: Backups are stored locally on the server."
echo "   For full safety, consider copying to external storage:"
echo "   - Google Drive/Dropbox: rclone"
echo ""
