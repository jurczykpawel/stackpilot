# Backup - Zabezpiecz swoje dane

## Opcja A: Backup Mikrusa (darmowy, 200MB)

Najprostszy start - wbudowany serwer backupowy Mikrusa (`strych.mikr.us`).

**Co jest backupowane:**
- `/etc/` - konfiguracje systemowe
- `/home/` - pliki użytkowników
- `/var/log/` - logi

**Kiedy to wystarczy:**
- Masz tylko konfiguracje aplikacji (docker-compose, nginx, cron)
- Dane trzymasz w zewnętrznej bazie (PostgreSQL Mikrusa/Cloud)
- Pliki użytkowników są małe

**Instalacja:**
1. Aktywuj backup w [Panelu Mikrus → Backup](https://mikr.us/panel/?a=backup)
2. Uruchom konfigurację:
   ```bash
   ./local/setup-backup.sh mikrus
   ```
3. Gotowe! Codziennie backup leci na `strych.mikr.us`.

**Restore:**
```bash
ssh mikrus
ssh -i /backup_key $(whoami)@strych.mikr.us "ls ~/backup/"
scp -i /backup_key $(whoami)@strych.mikr.us:~/backup/etc/plik.conf /etc/
```

> Limit 200MB. Dla większych danych użyj Opcji B.

---

## Opcja B: Backup do chmury (Google Drive / Dropbox)

Szyfrowany backup do własnej chmury - bez limitu, pełna kontrola.

**Co jest backupowane:**
- `/opt/stacks/` - wszystkie aplikacje Docker (n8n, Listmonk, dane)
- `/opt/dockge/` - panel zarządzania kontenerami

**Wspierani providerzy:**
Google Drive (15GB free), Dropbox, OneDrive, Amazon S3, Wasabi, MinIO, Mega

**Wymagania lokalne:**
- Terminal z SSH
- Rclone: Mac `brew install rclone` | Linux `curl https://rclone.org/install.sh | sudo bash` | Windows `winget install rclone`

**Instalacja:**
```bash
./local/setup-backup.sh           # domyślnie 'mikrus'
./local/setup-backup.sh mikrus     # lub inny serwer
```

Kreator poprowadzi Cię przez: wybór providera → logowanie → szyfrowanie (zalecane).
Serwer co noc o 3:00 wysyła dane do chmury.

**Restore:**
```bash
./local/restore.sh           # domyślnie 'mikrus'
./local/restore.sh mikrus     # lub inny serwer
```

**Ręczny backup / sprawdzenie:**
```bash
ssh mikrus '~/backup-core.sh'
ssh mikrus 'tail -50 /var/log/mikrus-backup.log'
```

**Zmiana backupowanych katalogów:**
```bash
ssh mikrus 'nano ~/backup-core.sh'
```
Znajdź sekcję `SOURCE_DIRS` i dodaj/usuń katalogi:
```bash
SOURCE_DIRS=(
    "/opt/dockge"
    "/opt/stacks"
    "/home"
    "/etc/caddy"
)
```

> Backup jest szyfrowany na serwerze przed wysłaniem. Nawet Google nie widzi Twoich danych.
