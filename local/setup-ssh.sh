#!/bin/bash

# StackPilot - SSH Configurator
# Konfiguruje połączenie SSH do serwera Mikrus (klucz + alias).
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   bash local/setup-ssh.sh
#   bash <(curl -s https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/local/setup-ssh.sh)

# Ten skrypt działa tylko na komputerze lokalnym (konfiguruje SSH DO serwera)
if [ -f /klucz_api ]; then
    echo "Ten skrypt działa tylko na komputerze lokalnym (nie na serwerze Mikrus)."
    exit 1
fi

GREEN='\x1b[0;32m'
BLUE='\x1b[0;34m'
YELLOW='\x1b[1;33m'
RED='\x1b[0;31m'
NC='\x1b[0m'

clear
echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}   🚀 MIKRUS SSH CONFIGURATOR                    ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""
echo -e "Ten skrypt skonfiguruje połączenie SSH z Mikrusem,"
echo -e "abyś mógł łączyć się wpisując tylko: ${GREEN}ssh mikrus${NC}"
echo -e "(bez hasła za każdym razem!)"
echo ""
echo -e "${YELLOW}Przygotuj dane z maila od  (Host, Port, Hasło).${NC}"
echo ""

# 1. Pobieranie danych
read -p "Podaj nazwę hosta (np. srv20.mikr.us): " HOST
read -p "Podaj numer portu SSH (np. 10107): " PORT
read -p "Podaj nazwę użytkownika (domyślnie: root): " USER
USER=${USER:-root}
read -p "Alias SSH - jak chcesz nazywać ten serwer? (domyślnie: mikrus): " ALIAS
ALIAS=${ALIAS:-mikrus}

if [[ -z "$HOST" || -z "$PORT" ]]; then
    echo -e "${RED}Błąd: Host i Port są wymagane!${NC}"
    exit 1
fi

echo ""

# 2. Generowanie klucza SSH (jeśli nie istnieje)
KEY_PATH="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY_PATH" ]; then
    echo -e "${YELLOW}Generuję nowy klucz SSH (Ed25519)...${NC}"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "mikrus_key"
    echo -e "${GREEN}✅ Klucz wygenerowany.${NC}"
else
    echo -e "${GREEN}✅ Klucz SSH już istnieje.${NC}"
fi

# 3. Kopiowanie klucza na serwer
echo ""
echo -e "${YELLOW}Teraz wpisz hasło do serwera (jednorazowo):${NC}"
echo ""

ssh-copy-id -i "$KEY_PATH.pub" -p "$PORT" "$USER@$HOST"

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Błąd wysyłania klucza. Sprawdź hasło i spróbuj ponownie.${NC}"
    exit 1
fi

# 4. Konfiguracja ~/.ssh/config
CONFIG_FILE="$HOME/.ssh/config"
[ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"

if grep -q "^Host $ALIAS$" "$CONFIG_FILE"; then
    echo -e "${YELLOW}Alias '$ALIAS' już istnieje w ~/.ssh/config. Pomijam.${NC}"
else
    cat >> "$CONFIG_FILE" <<EOF

Host $ALIAS
    HostName $HOST
    Port $PORT
    User $USER
    IdentityFile $KEY_PATH
    ServerAliveInterval 60
EOF
    echo -e "${GREEN}✅ Dodano alias '$ALIAS' do ~/.ssh/config${NC}"
fi

echo ""
echo -e "${GREEN}✅ Gotowe! Połącz się wpisując:${NC}"
echo ""
echo -e "   ${GREEN}ssh $ALIAS${NC}"
echo ""
