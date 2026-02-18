#!/bin/bash

# Mikrus Toolbox - Mikrus Backup Setup
# Konfiguruje wbudowany backup Mikrusa (200MB, darmowy)
# Author: Paweł (Lazy Engineer)

set -e

echo "--- 🛡️ Konfiguracja backupu Mikrusa ---"
echo ""
echo "⚠️  WAŻNE: Upewnij się, że aktywowałeś backup w panelu!"
echo "   👉 https://mikr.us/panel/?a=backup"
echo ""
echo "--- Instaluję wymagane zależności ---"
apt install -y -qq acl > /dev/null 2>&1 && echo "✅ acl zainstalowany" || echo "⚠️  acl już zainstalowany lub brak uprawnień"

echo ""
echo "--- Dodaję klucz serwera backupowego (strych.mikr.us) ---"
ssh-keyscan -H strych.mikr.us >> ~/.ssh/known_hosts 2>/dev/null
echo "✅ Klucz dodany"

echo ""
echo "--- Uruchamiam skrypt konfiguracyjny NOOBS ---"
curl -s https://raw.githubusercontent.com/unkn0w/noobs/main/scripts/chce_backup.sh | bash

echo ""
echo "--- Weryfikacja połączenia z serwerem backupowym ---"

# Test połączenia SSH do serwera backupowego
if ssh -i /backup_key -o BatchMode=yes -o ConnectTimeout=10 strych.mikr.us "echo ok" 2>/dev/null | grep -q "ok"; then
    echo "✅ Połączenie z serwerem backupowym działa!"
    echo ""
    echo "📋 Co się dzieje automatycznie:"
    echo "   - Codziennie backup jest wysyłany na serwer Mikrusa"
    echo "   - Backupowane katalogi: /etc, /home, /var/log"
    echo "   - Cron: /etc/cron.daily/backup"
    echo ""
    echo "🔄 Jak przywrócić dane?"
    echo "   1. Zaloguj się na serwer:  ssh <twój-alias>  (ten serwer: $(hostname))"
    echo "   2. Połącz ze strychem:     ssh -i /backup_key \$(whoami)@strych.mikr.us"
    echo "   3. Pliki są w ~/backup/"
    echo ""
    echo "   Kopiowanie plików ze strychu (uruchom na serwerze $(hostname)):"
    echo "   scp -i /backup_key \$(whoami)@strych.mikr.us:~/backup/etc/plik.conf /etc/"
    echo "   rsync -av -e 'ssh -i /backup_key' \$(whoami)@strych.mikr.us:~/backup/opt/ /opt/"
    echo ""
    echo "⚠️  Limit: 200MB. Dla większych danych użyj Opcji B (Google Drive/Dropbox)"
else
    echo ""
    echo "❌ BŁĄD: Nie można połączyć się z serwerem backupowym!"
    echo ""
    echo "Prawdopodobne przyczyny:"
    echo "   1. Nie aktywowałeś backupu w panelu: https://mikr.us/panel/?a=backup"
    echo "   2. Trzeba zaakceptować klucz serwera - uruchom ręcznie:"
    echo "      ssh -i /backup_key \$(whoami)@strych.mikr.us"
    echo "   3. Poczekaj 5 minut po aktywacji w panelu"
    echo ""
    exit 1
fi
