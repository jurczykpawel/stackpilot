#!/bin/bash

# Mikrus Toolbox - Server Execution Abstraction
# Transparentnie uruchamia komendy lokalnie lub przez SSH.
#
# Detekcja: /klucz_api istnieje TYLKO na serwerach Mikrusa.
# Na lokalnym kompie → ssh, scp (jak dotychczas).
# Na serwerze → bash -c, cp (bezpośrednio, bez SSH).
#
# Użycie:
#   source "$SCRIPT_DIR/../lib/server-exec.sh"
#   server_exec "cat /klucz_api"
#   server_exec_tty "bash install.sh"
#   server_copy "/tmp/file" "/opt/dest"

# Detekcja środowiska
if [ -f /klucz_api ]; then
    _MIKRUS_ON_SERVER=true
else
    _MIKRUS_ON_SERVER=false
fi

# Czy skrypt działa na serwerze Mikrusa?
is_on_server() { [ "$_MIKRUS_ON_SERVER" = true ]; }

# Uruchom komendę na serwerze
# Użycie: server_exec "polecenie"
server_exec() {
    if is_on_server; then
        bash -c "$1"
    else
        ssh "${SSH_ALIAS:-mikrus}" "$1"
    fi
}

# Uruchom komendę z alokacją TTY (dla interaktywnych poleceń)
# Użycie: server_exec_tty "polecenie"
server_exec_tty() {
    if is_on_server; then
        bash -c "$1"
    else
        ssh -t "${SSH_ALIAS:-mikrus}" "$1"
    fi
}

# Uruchom komendę z timeoutem połączenia
# Użycie: server_exec_timeout SEKUNDY "polecenie"
server_exec_timeout() {
    local timeout="$1"
    local cmd="$2"
    if is_on_server; then
        bash -c "$cmd"
    else
        ssh -o "ConnectTimeout=$timeout" "${SSH_ALIAS:-mikrus}" "$cmd" 2>/dev/null
    fi
}

# Skopiuj plik NA serwer
# Użycie: server_copy LOCAL_PATH REMOTE_PATH
server_copy() {
    local src="$1"
    local dst="$2"
    if is_on_server; then
        cp "$src" "$dst"
    else
        scp -q "$src" "${SSH_ALIAS:-mikrus}:$dst"
    fi
}

# Prześlij plik na serwer (odpowiednik: cat FILE | ssh "cat > DEST")
# Użycie: server_pipe_to LOCAL_FILE REMOTE_PATH
server_pipe_to() {
    local src="$1"
    local dst="$2"
    if is_on_server; then
        cp "$src" "$dst"
        chmod +x "$dst" 2>/dev/null || true
    else
        cat "$src" | ssh "${SSH_ALIAS:-mikrus}" "cat > '$dst' && chmod +x '$dst'"
    fi
}

# Pobierz hostname serwera
# Użycie: HOSTNAME=$(server_hostname)
server_hostname() {
    if is_on_server; then
        hostname
    else
        ssh -G "${SSH_ALIAS:-mikrus}" 2>/dev/null | grep "^hostname " | cut -d' ' -f2
    fi
}

# Pobierz username na serwerze
# Użycie: USER=$(server_user)
server_user() {
    if is_on_server; then
        whoami
    else
        ssh -G "${SSH_ALIAS:-mikrus}" 2>/dev/null | grep "^user " | cut -d' ' -f2
    fi
}

export _MIKRUS_ON_SERVER
export -f is_on_server server_exec server_exec_tty server_exec_timeout
export -f server_copy server_pipe_to server_hostname server_user
