#!/bin/bash

# StackPilot - Mikrus Provider: Shared Database
# Fetches shared database credentials from the Mikrus API.
# Supports PostgreSQL, MySQL, and MongoDB.

# =============================================================================
# fetch_shared_db DB_TYPE SSH_ALIAS
#
# Fetches credentials from https://api.mikr.us/db.bash
# using the API key from /klucz_api and the server hostname.
#
# Sets: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS (exported)
# Returns: 0 on success, 1 on failure
# =============================================================================

fetch_shared_db() {
    local DB_TYPE="$1"
    local SSH_ALIAS="${2:-${SSH_ALIAS:-vps}}"

    # Dry-run mode
    if [ "$DRY_RUN" = true ]; then
        msg "$MSG_MDB_DRYRUN" "$SSH_ALIAS"
        DB_HOST="[dry-run-host]"
        DB_PORT="5432"
        DB_NAME="[dry-run-db]"
        DB_USER="[dry-run-user]"
        DB_PASS="[dry-run-pass]"
        export DB_HOST DB_PORT DB_NAME DB_USER DB_PASS
        return 0
    fi

    msg "$MSG_MDB_FETCHING"

    # Fetch API key
    local API_KEY
    API_KEY=$(ssh "$SSH_ALIAS" 'cat /klucz_api 2>/dev/null' 2>/dev/null)

    if [ -z "$API_KEY" ]; then
        msg "$MSG_MDB_NO_KEY"
        msg "$MSG_MDB_NO_KEY2"
        return 1
    fi

    # Fetch server hostname
    local HOSTNAME
    HOSTNAME=$(ssh "$SSH_ALIAS" 'hostname' 2>/dev/null)

    if [ -z "$HOSTNAME" ]; then
        msg "$MSG_MDB_NO_HOST"
        return 1
    fi

    # Call API
    local RESPONSE
    RESPONSE=$(curl -s -d "srv=$HOSTNAME&key=$API_KEY" https://api.mikr.us/db.bash)

    if [ -z "$RESPONSE" ]; then
        msg "$MSG_MDB_NO_RESP"
        return 1
    fi

    # Parse response based on DB type
    if [ "$DB_TYPE" = "postgres" ]; then
        local SECTION
        SECTION=$(echo "$RESPONSE" | grep -A4 "^psql=")
        DB_HOST=$(echo "$SECTION" | grep 'Server:' | head -1 | sed 's/.*Server: *//' | tr -d '"')
        DB_USER=$(echo "$SECTION" | grep 'login:' | head -1 | sed 's/.*login: *//')
        DB_PASS=$(echo "$SECTION" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
        DB_NAME=$(echo "$SECTION" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//' | tr -d '"')
        DB_PORT="5432"

        if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ]; then
            msg "$MSG_MDB_PG_INACTIVE"
            echo ""
            msg "$MSG_MDB_PG_ENABLE"
            msg "$MSG_MDB_PG_URL"
            echo ""
            msg "$MSG_MDB_PG_RETRY"
            return 1
        fi

    elif [ "$DB_TYPE" = "mysql" ]; then
        local SECTION
        SECTION=$(echo "$RESPONSE" | grep -A4 "^mysql=")
        DB_HOST=$(echo "$SECTION" | grep 'Server:' | head -1 | sed 's/.*Server: *//' | tr -d '"')
        DB_USER=$(echo "$SECTION" | grep 'login:' | head -1 | sed 's/.*login: *//')
        DB_PASS=$(echo "$SECTION" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
        DB_NAME=$(echo "$SECTION" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//' | tr -d '"')
        DB_PORT="3306"

        if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ]; then
            msg "$MSG_MDB_MYSQL_INACTIVE"
            echo ""
            msg "$MSG_MDB_MYSQL_ENABLE"
            msg "$MSG_MDB_MYSQL_URL"
            echo ""
            msg "$MSG_MDB_MYSQL_RETRY"
            return 1
        fi

    elif [ "$DB_TYPE" = "mongo" ]; then
        local SECTION
        SECTION=$(echo "$RESPONSE" | grep -A6 "^mongo=")
        DB_HOST=$(echo "$SECTION" | grep 'Host:' | head -1 | sed 's/.*Host: *//')
        DB_PORT=$(echo "$SECTION" | grep 'Port:' | head -1 | sed 's/.*Port: *//')
        DB_USER=$(echo "$SECTION" | grep 'Login:' | head -1 | sed 's/.*Login: *//')
        DB_PASS=$(echo "$SECTION" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
        DB_NAME=$(echo "$SECTION" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//')

        if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ]; then
            msg "$MSG_MDB_MONGO_INACTIVE"
            echo ""
            msg "$MSG_MDB_MONGO_ENABLE"
            msg "$MSG_MDB_MONGO_URL"
            echo ""
            msg "$MSG_MDB_MONGO_RETRY"
            return 1
        fi
    else
        msg "$MSG_MDB_UNKNOWN_TYPE" "$DB_TYPE"
        msg "$MSG_MDB_UNKNOWN_HINT"
        return 1
    fi

    msg "$MSG_MDB_OK"

    export DB_HOST DB_PORT DB_NAME DB_USER DB_PASS

    return 0
}

export -f fetch_shared_db
