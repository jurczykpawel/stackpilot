#!/bin/bash

# StackPilot - Database Backup Setup
# Configures automatic PostgreSQL/MySQL database backup
# Author: Paweł (Lazy Engineer)
#
# Supports:
# - Bundled databases (auto-detected from docker-compose in /opt/stacks/*)
# - Dedicated/external databases (credentials saved locally)
#
# Usage:
#   On the server: ./setup-db-backup.sh

set -e

BACKUP_DIR="/opt/backups/db"
BACKUP_SCRIPT="/opt/stackpilot/scripts/db-backup.sh"
CREDENTIALS_DIR="/opt/stackpilot/config"
CREDENTIALS_FILE="$CREDENTIALS_DIR/db-credentials.conf"
CRON_FILE="/etc/cron.d/stackpilot-db-backup"
STACKS_DIR="/opt/stacks"

echo "--- 🗄️ Database Backup Configuration ---"
echo ""

# =============================================================================
# PHASE 1: Auto-detect bundled databases from docker-compose files
# =============================================================================

echo "🔍 Scanning for bundled databases in $STACKS_DIR..."

BUNDLED_DATABASES=()

if [ -d "$STACKS_DIR" ]; then
    for COMPOSE_FILE in "$STACKS_DIR"/*/docker-compose.yaml "$STACKS_DIR"/*/docker-compose.yml; do
        [ -f "$COMPOSE_FILE" ] || continue

        STACK_NAME=$(basename "$(dirname "$COMPOSE_FILE")")

        # Check for postgres service
        if grep -qE '^\s+image:\s*(postgres|postgresql)' "$COMPOSE_FILE" 2>/dev/null; then
            # Extract credentials from environment variables in the compose file
            local_db_user=$(grep -A20 'image:.*postgres' "$COMPOSE_FILE" | grep -oP 'POSTGRES_USER[=:]\s*\K[^\s"]+' | head -1)
            local_db_pass=$(grep -A20 'image:.*postgres' "$COMPOSE_FILE" | grep -oP 'POSTGRES_PASSWORD[=:]\s*\K[^\s"]+' | head -1)
            local_db_name=$(grep -A20 'image:.*postgres' "$COMPOSE_FILE" | grep -oP 'POSTGRES_DB[=:]\s*\K[^\s"]+' | head -1)

            # Fallback defaults
            local_db_user="${local_db_user:-app}"
            local_db_name="${local_db_name:-appdb}"

            if [ -n "$local_db_pass" ]; then
                # Detect the host port mapping for postgres (if exposed)
                local_db_port=$(grep -B5 -A5 '5432' "$COMPOSE_FILE" | grep -oP '127\.0\.0\.1:(\d+):5432' | grep -oP ':\K\d+(?=:)' | head -1)

                # For bundled DBs we exec into the container, so use internal port
                BUNDLED_DATABASES+=("${STACK_NAME}-pg:postgres:${STACK_NAME}:5432:${local_db_name}:${local_db_user}:${local_db_pass}")
                echo "   ✅ PostgreSQL (bundled): $STACK_NAME / $local_db_name"
            fi
        fi

        # Check for mysql/mariadb service
        if grep -qE '^\s+image:\s*(mysql|mariadb)' "$COMPOSE_FILE" 2>/dev/null; then
            local_db_user=$(grep -A20 'image:.*m[ay]' "$COMPOSE_FILE" | grep -oP 'MYSQL_USER[=:]\s*\K[^\s"]+' | head -1)
            local_db_pass=$(grep -A20 'image:.*m[ay]' "$COMPOSE_FILE" | grep -oP 'MYSQL_PASSWORD[=:]\s*\K[^\s"]+' | head -1)
            local_db_name=$(grep -A20 'image:.*m[ay]' "$COMPOSE_FILE" | grep -oP 'MYSQL_DATABASE[=:]\s*\K[^\s"]+' | head -1)
            local_db_root_pass=$(grep -A20 'image:.*m[ay]' "$COMPOSE_FILE" | grep -oP 'MYSQL_ROOT_PASSWORD[=:]\s*\K[^\s"]+' | head -1)

            # Use root if available, otherwise regular user
            if [ -n "$local_db_root_pass" ]; then
                local_db_user="root"
                local_db_pass="$local_db_root_pass"
            fi

            local_db_user="${local_db_user:-root}"
            local_db_name="${local_db_name:-appdb}"

            if [ -n "$local_db_pass" ]; then
                BUNDLED_DATABASES+=("${STACK_NAME}-mysql:mysql:${STACK_NAME}:3306:${local_db_name}:${local_db_user}:${local_db_pass}")
                echo "   ✅ MySQL (bundled): $STACK_NAME / $local_db_name"
            fi
        fi
    done
fi

if [ ${#BUNDLED_DATABASES[@]} -eq 0 ]; then
    echo "   No bundled databases found"
fi

# =============================================================================
# PHASE 2: Configure dedicated/external databases
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Do you have external/dedicated databases to back up?          ║"
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

read -p "Do you want to add/edit an external database? (y/N): " ADD_CUSTOM || true
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

if [ ${#BUNDLED_DATABASES[@]} -eq 0 ] && [ ${#CUSTOM_DATABASES[@]} -eq 0 ]; then
    echo ""
    echo "❌ No databases found to back up!"
    echo "   - Deploy an application with a bundled database"
    echo "   - Or add an external database by running this script again"
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
# - Bundled databases (docker exec into containers)
# - External databases (credentials from file)

BACKUP_DIR="/opt/backups/db"
CREDENTIALS_FILE="/opt/stackpilot/config/db-credentials.conf"
STACKS_DIR="/opt/stacks"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7
LOG_FILE="/var/log/db-backup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Remove old backups
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +$KEEP_DAYS -delete 2>/dev/null

BACKUP_HEADER

# Add bundled database backup (via docker exec)
if [ ${#BUNDLED_DATABASES[@]} -gt 0 ]; then
    cat >> "$BACKUP_SCRIPT" << 'BUNDLED_BACKUP'

# =============================================================================
# BUNDLED DATABASE BACKUP (docker exec into containers)
# =============================================================================

# Scan /opt/stacks/*/docker-compose.yaml for database containers
if [ -d "$STACKS_DIR" ]; then
    for COMPOSE_FILE in "$STACKS_DIR"/*/docker-compose.yaml "$STACKS_DIR"/*/docker-compose.yml; do
        [ -f "$COMPOSE_FILE" ] || continue

        STACK_NAME=$(basename "$(dirname "$COMPOSE_FILE")")
        COMPOSE_DIR=$(dirname "$COMPOSE_FILE")

        # Find postgres containers
        if grep -qE '^\s+image:\s*(postgres|postgresql)' "$COMPOSE_FILE" 2>/dev/null; then
            DB_USER=$(grep -A20 'image:.*postgres' "$COMPOSE_FILE" | grep -oP 'POSTGRES_USER[=:]\s*\K[^\s"]+' | head -1)
            DB_NAME=$(grep -A20 'image:.*postgres' "$COMPOSE_FILE" | grep -oP 'POSTGRES_DB[=:]\s*\K[^\s"]+' | head -1)
            DB_USER="${DB_USER:-app}"
            DB_NAME="${DB_NAME:-appdb}"

            # Find the DB service name (the key under 'services:' that has image: postgres)
            DB_SERVICE=$(grep -B10 'image:.*postgres' "$COMPOSE_FILE" | grep -oP '^\s+(\w+):' | tail -1 | tr -d ' :')
            DB_SERVICE="${DB_SERVICE:-db}"

            # Use docker compose exec to dump
            BACKUP_FILE="$BACKUP_DIR/${STACK_NAME}_postgres_${DATE}.sql.gz"
            if (cd "$COMPOSE_DIR" && docker compose exec -T "$DB_SERVICE" pg_dump -U "$DB_USER" "$DB_NAME" 2>/dev/null | gzip > "$BACKUP_FILE"); then
                log "✅ PostgreSQL ($STACK_NAME) backup OK - $(basename "$BACKUP_FILE")"
            else
                log "❌ PostgreSQL ($STACK_NAME) backup FAILED"
                rm -f "$BACKUP_FILE"
            fi
        fi

        # Find mysql/mariadb containers
        if grep -qE '^\s+image:\s*(mysql|mariadb)' "$COMPOSE_FILE" 2>/dev/null; then
            DB_USER=$(grep -A20 'image:.*m[ay]' "$COMPOSE_FILE" | grep -oP 'MYSQL_USER[=:]\s*\K[^\s"]+' | head -1)
            DB_PASS=$(grep -A20 'image:.*m[ay]' "$COMPOSE_FILE" | grep -oP 'MYSQL_PASSWORD[=:]\s*\K[^\s"]+' | head -1)
            DB_NAME=$(grep -A20 'image:.*m[ay]' "$COMPOSE_FILE" | grep -oP 'MYSQL_DATABASE[=:]\s*\K[^\s"]+' | head -1)
            DB_ROOT_PASS=$(grep -A20 'image:.*m[ay]' "$COMPOSE_FILE" | grep -oP 'MYSQL_ROOT_PASSWORD[=:]\s*\K[^\s"]+' | head -1)

            # Prefer root for full backup
            if [ -n "$DB_ROOT_PASS" ]; then
                DB_USER="root"
                DB_PASS="$DB_ROOT_PASS"
            fi

            DB_USER="${DB_USER:-root}"
            DB_NAME="${DB_NAME:-appdb}"

            DB_SERVICE=$(grep -B10 'image:.*m[ay]' "$COMPOSE_FILE" | grep -oP '^\s+(\w+):' | tail -1 | tr -d ' :')
            DB_SERVICE="${DB_SERVICE:-db}"

            BACKUP_FILE="$BACKUP_DIR/${STACK_NAME}_mysql_${DATE}.sql.gz"
            if (cd "$COMPOSE_DIR" && docker compose exec -T "$DB_SERVICE" mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>/dev/null | gzip > "$BACKUP_FILE"); then
                log "✅ MySQL ($STACK_NAME) backup OK - $(basename "$BACKUP_FILE")"
            else
                log "❌ MySQL ($STACK_NAME) backup FAILED"
                rm -f "$BACKUP_FILE"
            fi
        fi
    done
fi
BUNDLED_BACKUP
fi

# Add dedicated database backup (from credentials file)
if [ ${#CUSTOM_DATABASES[@]} -gt 0 ]; then
    cat >> "$BACKUP_SCRIPT" << 'CUSTOM_BACKUP'

# =============================================================================
# EXTERNAL DATABASE BACKUP (credentials from file)
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
