#!/bin/bash

# Mikrus Toolbox - Database Backup Setup
# Konfiguruje automatyczny backup bazy danych PostgreSQL/MySQL
# Author: Paweł (Lazy Engineer)
#
# Obsługuje:
# - Współdzielone bazy Mikrusa (credentials pobierane z API)
# - Dedykowane/kupione bazy (credentials zapisywane lokalnie)
#
# Użycie:
#   Na serwerze: ./setup-db-backup.sh

set -e

BACKUP_DIR="/opt/backups/db"
BACKUP_SCRIPT="/opt/mikrus-toolbox/scripts/db-backup.sh"
CREDENTIALS_DIR="/opt/mikrus-toolbox/config"
CREDENTIALS_FILE="$CREDENTIALS_DIR/db-credentials.conf"
CRON_FILE="/etc/cron.d/mikrus-db-backup"

echo "--- 🗄️ Konfiguracja backupu bazy danych ---"
echo ""

# =============================================================================
# FAZA 1: Wykrycie baz współdzielonych (z API)
# =============================================================================

API_KEY=$(cat /klucz_api 2>/dev/null || true)
HOSTNAME=$(hostname 2>/dev/null || true)

HAS_SHARED_POSTGRES=false
HAS_SHARED_MYSQL=false

if [ -n "$API_KEY" ]; then
    echo "🔑 Pobieram dane współdzielonych baz z API Mikrusa..."

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
    echo "⚠️  Brak klucza API - pominięto wykrywanie współdzielonych baz"
fi

# =============================================================================
# FAZA 2: Konfiguracja baz dedykowanych/kupionych
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Czy masz dedykowane/kupione bazy danych?                      ║"
echo "║  (np. z https://mikr.us/panel/?a=cloud)                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Wczytaj istniejące credentials jeśli są
CUSTOM_DATABASES=()
if [ -f "$CREDENTIALS_FILE" ]; then
    echo "📂 Znaleziono istniejący plik credentials"
    source "$CREDENTIALS_FILE"
    if [ ${#CUSTOM_DATABASES[@]} -gt 0 ]; then
        echo "   Skonfigurowane bazy: ${#CUSTOM_DATABASES[@]}"
    fi
fi

read -p "Czy chcesz dodać/edytować dedykowaną bazę? (t/N): " ADD_CUSTOM || true
if [[ "$ADD_CUSTOM" =~ ^[tTyY] ]]; then

    while true; do
        echo ""
        echo "Typ bazy:"
        echo "  1) PostgreSQL"
        echo "  2) MySQL"
        read -p "Wybierz [1-2]: " DB_TYPE_CHOICE

        case $DB_TYPE_CHOICE in
            1) CUSTOM_DB_TYPE="postgres" ;;
            2) CUSTOM_DB_TYPE="mysql" ;;
            *) echo "❌ Nieprawidłowy wybór"; continue ;;
        esac

        read -p "Nazwa (identyfikator, np. 'n8n-db'): " CUSTOM_DB_ID
        read -p "Host: " CUSTOM_DB_HOST
        read -p "Port [5432/3306]: " CUSTOM_DB_PORT
        CUSTOM_DB_PORT=${CUSTOM_DB_PORT:-$([ "$CUSTOM_DB_TYPE" = "postgres" ] && echo "5432" || echo "3306")}
        read -p "Nazwa bazy: " CUSTOM_DB_NAME
        read -p "Użytkownik: " CUSTOM_DB_USER
        read -sp "Hasło: " CUSTOM_DB_PASS
        echo ""

        # Dodaj do tablicy
        CUSTOM_DATABASES+=("$CUSTOM_DB_ID:$CUSTOM_DB_TYPE:$CUSTOM_DB_HOST:$CUSTOM_DB_PORT:$CUSTOM_DB_NAME:$CUSTOM_DB_USER:$CUSTOM_DB_PASS")

        echo "✅ Dodano: $CUSTOM_DB_ID ($CUSTOM_DB_TYPE)"

        read -p "Dodać kolejną bazę? (t/N): " ADD_MORE
        [[ ! "$ADD_MORE" =~ ^[tTyY] ]] && break
    done

    # Zapisz credentials do pliku
    echo ""
    echo "💾 Zapisuję credentials do $CREDENTIALS_FILE..."

    mkdir -p "$CREDENTIALS_DIR"

    cat > "$CREDENTIALS_FILE" << 'EOF'
# Mikrus Toolbox - Database Credentials
# Plik wygenerowany przez setup-db-backup.sh
# UWAGA: Zawiera hasła! Uprawnienia: 600 (tylko root)
#
# Format: ID:TYPE:HOST:PORT:DATABASE:USER:PASSWORD

CUSTOM_DATABASES=(
EOF

    for db in "${CUSTOM_DATABASES[@]}"; do
        echo "    \"$db\"" >> "$CREDENTIALS_FILE"
    done

    echo ")" >> "$CREDENTIALS_FILE"

    # Ustaw restrykcyjne uprawnienia
    chmod 600 "$CREDENTIALS_FILE"
    chown root:root "$CREDENTIALS_FILE"

    echo "✅ Credentials zapisane (uprawnienia: 600, właściciel: root)"
fi

# =============================================================================
# FAZA 3: Generowanie skryptu backupu
# =============================================================================

if [ "$HAS_SHARED_POSTGRES" = false ] && [ "$HAS_SHARED_MYSQL" = false ] && [ ${#CUSTOM_DATABASES[@]} -eq 0 ]; then
    echo ""
    echo "❌ Nie znaleziono żadnych baz danych do backupu!"
    echo "   - Włącz współdzieloną bazę: https://mikr.us/panel/?a=postgres"
    echo "   - Lub dodaj dedykowaną bazę uruchamiając ten skrypt ponownie"
    exit 1
fi

echo ""
echo "📁 Tworzę katalog backupów: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

echo "📝 Generuję skrypt backupu..."
mkdir -p "$(dirname "$BACKUP_SCRIPT")"

cat > "$BACKUP_SCRIPT" << 'BACKUP_HEADER'
#!/bin/bash
# Automatyczny backup baz danych Mikrus
# Wygenerowane przez setup-db-backup.sh
#
# Obsługuje:
# - Współdzielone bazy (credentials z API - zawsze aktualne)
# - Dedykowane bazy (credentials z pliku)

BACKUP_DIR="/opt/backups/db"
CREDENTIALS_FILE="/opt/mikrus-toolbox/config/db-credentials.conf"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7
LOG_FILE="/var/log/db-backup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Usuń stare backupy
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +$KEEP_DAYS -delete 2>/dev/null

BACKUP_HEADER

# Dodaj backup współdzielonych baz (z API)
if [ "$HAS_SHARED_POSTGRES" = true ] || [ "$HAS_SHARED_MYSQL" = true ]; then
    cat >> "$BACKUP_SCRIPT" << 'SHARED_API'

# =============================================================================
# BACKUP BAZ WSPÓŁDZIELONYCH (credentials z API)
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

# Dodaj backup dedykowanych baz (z pliku credentials)
if [ ${#CUSTOM_DATABASES[@]} -gt 0 ]; then
    cat >> "$BACKUP_SCRIPT" << 'CUSTOM_BACKUP'

# =============================================================================
# BACKUP BAZ DEDYKOWANYCH (credentials z pliku)
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

# Zakończenie skryptu
cat >> "$BACKUP_SCRIPT" << 'BACKUP_FOOTER'

log "Backup zakończony"
BACKUP_FOOTER

chmod +x "$BACKUP_SCRIPT"

# =============================================================================
# FAZA 4: Konfiguracja cron
# =============================================================================

echo "⏰ Konfiguruję automatyczny backup (codziennie o 3:00)..."

cat > "$CRON_FILE" << EOF
# Mikrus Toolbox - Automatyczny backup bazy danych
# Codziennie o 3:00
0 3 * * * root $BACKUP_SCRIPT >> /var/log/db-backup.log 2>&1
EOF

chmod 644 "$CRON_FILE"

# =============================================================================
# FAZA 5: Test
# =============================================================================

echo ""
echo "🧪 Wykonuję testowy backup..."
if $BACKUP_SCRIPT 2>&1 | tail -5; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ✅ Backup skonfigurowany pomyślnie!                           ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "📋 Konfiguracja:"
    echo "   Katalog backupów:  $BACKUP_DIR"
    echo "   Skrypt:            $BACKUP_SCRIPT"
    echo "   Cron:              codziennie o 3:00"
    echo "   Retencja:          7 dni"
    if [ -f "$CREDENTIALS_FILE" ]; then
        echo "   Credentials:       $CREDENTIALS_FILE (chmod 600)"
    fi
    echo ""
    echo "📦 Utworzone backupy:"
    ls -lh "$BACKUP_DIR"/*.sql.gz 2>/dev/null || echo "   (brak plików)"
    echo ""
    echo "💡 Komendy:"
    echo "   Ręczny backup:     $BACKUP_SCRIPT"
    echo "   Logi:              tail -f /var/log/db-backup.log"
    echo ""
    echo "💡 Przywracanie:"
    echo "   PostgreSQL: gunzip -c backup.sql.gz | psql -h HOST -U USER DB"
    echo "   MySQL:      gunzip -c backup.sql.gz | mysql -h HOST -u USER -p DB"
else
    echo ""
    echo "⚠️  Testowy backup mógł nie działać poprawnie."
    echo "   Sprawdź logi: /var/log/db-backup.log"
fi

echo ""
echo "⚠️  UWAGA: Backupy są przechowywane lokalnie na serwerze."
echo "   Dla pełnego bezpieczeństwa, rozważ kopiowanie na zewnętrzny storage:"
echo "   - Strych Mikrusa (200MB limit): setup-backup-mikrus.sh"
echo "   - Google Drive/Dropbox: rclone"
echo ""
