# Mikrus Toolbox - Referencja operacyjna

> **Główne instrukcje dla AI → [`AGENTS.md`](AGENTS.md)**. Ten dokument to szczegółowa referencja - sięgaj tu gdy potrzebujesz konkretnych komend, procedur diagnostycznych lub szczegółów architektury.

Kompletna dokumentacja techniczna Mikrus Toolbox. Przeznaczona dla agentów AI i ludzi.

## Spis treści

1. [Połączenie z serwerem](#połączenie-z-serwerem)
2. [Dostępne aplikacje](#dostępne-aplikacje)
3. [Komendy deployment](#komendy-deployment)
4. [Backup i restore](#backup-i-restore)
5. [Diagnostyka i troubleshooting](#diagnostyka-i-troubleshooting)
6. [Brakujące narzędzia](#brakujące-narzędzia)
7. [Architektura](#architektura)
8. [Limity i ograniczenia](#limity-i-ograniczenia)

---

## Połączenie z serwerem

### SSH Alias

Serwery Mikrus są dostępne przez SSH. Alias jest skonfigurowany w `~/.ssh/config`:

```bash
# Sprawdź dostępne aliasy
grep "^Host " ~/.ssh/config

# Typowe aliasy: mikrus, mikrus, srv42, etc.
```

### Weryfikacja połączenia

```bash
# Test połączenia
ssh mikrus 'echo "OK: $(hostname)"'

# Sprawdź informacje o serwerze
ssh mikrus 'hostname && cat /etc/os-release | head -2'
```

### Klucz API Mikrusa

Klucz API znajduje się na serwerze w `/klucz_api`:

```bash
# Pobierz klucz API
ssh mikrus 'cat /klucz_api'

# Klucz jest wymagany do:
# - API bazy danych (https://api.mikr.us/db.bash)
# - API domen Cytrus (https://api.mikr.us/domain)
```

Jeśli klucz nie istnieje, użytkownik musi włączyć API w panelu:
https://mikr.us/panel/?a=api

### Pierwsza konfiguracja serwera (skrypt `start`)

Każdy serwer Mikrus ma wbudowany skrypt `start` do początkowej konfiguracji. Warto go uruchomić zaraz po zakupie:

```bash
ssh mikrus
start
```

Skrypt interaktywnie przeprowadza przez 5 kroków:

1. **Strefa czasowa** → `T` (Tak) — ustawia Europe/Warsaw
2. **Edytor** → `1` (nano) — najprostszy wybór
3. **Shell zsh + Oh My Zsh** → `T` (modern shell) lub `N` (zostaje bash)
4. **Docker** → `T` (**wymagane** do deployowania aplikacji toolboxem!)
5. **Aktualizacja systemu** → `T` (zalecane dla bezpieczeństwa)

Sprawdzenie czy Docker jest zainstalowany:
```bash
ssh mikrus 'docker --version'
# Jeśli nie: ssh mikrus → start → odpowiedz T na pytanie o Dockera
# Alternatywa: ssh mikrus 'curl -fsSL https://get.docker.com | sh'
```

### Uruchamianie skryptów na serwerze (Windows/PowerShell)

Użytkownicy Windows po konfiguracji SSH (`setup-ssh.ps1`) mogą uruchamiać skrypty bezpośrednio na serwerze:

```bash
# 1. Z komputera lokalnego - zainstaluj toolbox na serwerze:
./local/install-toolbox.sh mikrus

# 2. Połącz się z serwerem:
ssh mikrus

# 3. Uruchamiaj skrypty bezpośrednio:
deploy.sh uptime-kuma
cytrus-domain.sh - 3001
monitor-gateflow.sh mikrus 60
```

Detekcja środowiska: skrypty automatycznie wykrywają czy działają na serwerze (plik `/klucz_api`) i pomijają SSH — komendy wykonują się bezpośrednio.

Skrypty **tylko lokalne** (nie działają na serwerze): `setup-ssh.sh`, `sync.sh`

---

## Dostępne aplikacje

Aplikacje znajdują się w `apps/<nazwa>/install.sh`:

| Aplikacja | Opis | Baza danych | Port |
|-----------|------|-------------|------|
| **uptime-kuma** | Monitoring usług (jak UptimeRobot) | - | 3001 |
| **ntfy** | Powiadomienia push | - | 8085 |
| **filebrowser** | Menedżer plików web | - | 8095 |
| **dockge** | UI do zarządzania Docker Compose | - | 5001 |
| **stirling-pdf** | Narzędzia PDF online | - | 8087 |
| **n8n** | Automatyzacja workflow | PostgreSQL* | 5678 |
| **umami** | Web analytics (alt. Google Analytics) | PostgreSQL* | 3000 |
| **nocodb** | Baza danych (alt. Airtable) | PostgreSQL | 8080 |
| **listmonk** | Newsletter i mailing | PostgreSQL* | 9000 |
| **typebot** | Kreator chatbotów | PostgreSQL* | 8081/8082 |
| **vaultwarden** | Menedżer haseł (Bitwarden) | SQLite | 8088 |
| **linkstack** | Strona z linkami (alt. Linktree) | SQLite | 8090 |
| **redis** | Cache/baza klucz-wartość | - | 6379 |
| **wordpress** | CMS (Performance Edition: FPM+Nginx+Redis) | MySQL/SQLite | 8080 |
| **convertx** | Konwerter plików (100+ formatów) | SQLite | 3000 |
| **postiz** | Social media scheduler | PostgreSQL* | 5000 |
| **crawl4ai** | Web crawler z AI extraction | - | 8000 |
| **cap** | Screen recording i sharing | MySQL | 3000 |
| **gateflow** | Waitlist / launch page | PostgreSQL (Supabase) | 3333 |
| **minio** | Object storage (S3-compatible) | - | 9000 |
| **gotenberg** | API do konwersji dokumentów (PDF) | - | 3000 |
| **cookie-hub** | Consent management (GDPR) | - | 8091 |
| **littlelink** | Strona z linkami (prostsza alt.) | - | 8090 |
| **mcp-docker** | MCP server do zarządzania Docker | - | - |

*PostgreSQL z gwiazdką wymaga `gen_random_uuid()` (PG 13+) — NIE działa ze współdzieloną bazą Mikrusa (PG 12). Dotyczy: n8n, umami, listmonk, typebot, postiz. Wymagana dedykowana baza.

**WordPress** to specjalna aplikacja z własnym Dockerfile (PHP redis ext + WP-CLI), bundled Redis,
auto-tuning FPM na podstawie RAM i post-install skryptem `wp-init.sh`. Szczegóły: `apps/wordpress/README.md`.

---

## Komendy deployment

### Wszystkie skrypty lokalne (`local/`)

| Skrypt | Opis | Użycie |
|--------|------|--------|
| `deploy.sh` | Instalacja aplikacji | `./local/deploy.sh APP [opcje]` |
| `cytrus-domain.sh` | Dodanie domeny Cytrus | `./local/cytrus-domain.sh DOMENA PORT [SSH]` |
| `dns-add.sh` | Dodanie DNS Cloudflare | `./local/dns-add.sh DOMENA [SSH]` |
| `add-static-hosting.sh` | Hosting plików statycznych | `./local/add-static-hosting.sh DOMENA [SSH] [DIR] [PORT]` |
| `setup-backup.sh` | Konfiguracja backupów | `./local/setup-backup.sh [SSH]` |
| `restore.sh` | Przywracanie backupu | `./local/restore.sh [SSH]` |
| `setup-cloudflare.sh` | Konfiguracja Cloudflare API | `./local/setup-cloudflare.sh` |
| `setup-turnstile.sh` | Konfiguracja Turnstile (CAPTCHA) | `./local/setup-turnstile.sh DOMENA [SSH]` |
| `sync.sh` | Synchronizacja plików (rsync) | `./local/sync.sh up/down SRC DEST [--ssh=ALIAS]` |

---

### deploy.sh - Instalacja aplikacji

```bash
./local/deploy.sh APP [opcje]

# Opcje:
#   --ssh=ALIAS           SSH alias (domyślnie: mikrus)
#   --domain-type=TYPE    cytrus | cloudflare | local
#   --domain=DOMAIN       Domena lub "auto" dla Cytrus
#   --db-source=SOURCE    shared | custom (bazy danych)
#   --yes, -y             Pomiń wszystkie potwierdzenia
#   --dry-run             Tylko pokaż co zostanie zrobione

# Przykłady:
./local/deploy.sh n8n --ssh=mikrus --domain-type=cytrus --domain=auto
./local/deploy.sh uptime-kuma --ssh=mikrus --domain-type=local --yes
./local/deploy.sh gateflow --ssh=mikrus --domain-type=cloudflare --domain=gateflow.example.com
```

**Flow deploy.sh:**
1. Potwierdza deployment
2. Pyta o bazę danych (jeśli wymagana)
3. Pyta o domenę (Cytrus/Cloudflare/lokalnie)
4. Pokazuje "Teraz się zrelaksuj - pracuję..."
5. Wykonuje instalację
6. Konfiguruje domenę (po uruchomieniu usługi!)
7. Pokazuje podsumowanie

---

### sync.sh - Synchronizacja plików

```bash
./local/sync.sh up   <local_path> <remote_path> [--ssh=ALIAS]
./local/sync.sh down <remote_path> <local_path> [--ssh=ALIAS]

# Opcje:
#   --ssh=ALIAS    SSH alias (domyślnie: mikrus)
#   --dry-run      Pokaż co się wykona bez wykonania

# Przykłady:
./local/sync.sh up ./my-website /var/www/html --ssh=mikrus
./local/sync.sh down /opt/stacks/n8n/.env ./backup/ --ssh=hanna
./local/sync.sh up ./dist /var/www/public/app --dry-run
```

Prosty wrapper na rsync do szybkiego przesyłania plików. Idealne do:
- Edycji konfiguracji lokalnie (pobierz → edytuj → wyślij)
- Uploadu stron statycznych na serwer
- Backupu pojedynczych plików

---

### cytrus-domain.sh - Domeny Mikrusa

```bash
./local/cytrus-domain.sh <domena|-> <port> [ssh_alias]

# Przykłady:
./local/cytrus-domain.sh - 3001 mikrus              # automatyczna (xyz123.byst.re)
./local/cytrus-domain.sh mojapp.byst.re 3001 mikrus # własna subdomena
./local/cytrus-domain.sh app.bieda.it 8080 mikrus    # inna domena Mikrusa
```

Obsługiwane domeny Cytrus:
- `*.byst.re`
- `*.bieda.it`
- `*.toadres.pl`
- `*.tojest.dev`

---

### dns-add.sh - DNS Cloudflare

```bash
./local/dns-add.sh <subdomena.domena.pl> [ssh_alias] [mode]

# Wymaga: ./local/setup-cloudflare.sh (jednorazowa konfiguracja)
# Przykłady:
./local/dns-add.sh app.example.com mikrus        # rekord AAAA (IPv6)
./local/dns-add.sh api.mojadomena.pl mikrus ipv4  # rekord A (IPv4)
```

---

### add-static-hosting.sh - Hosting statyczny

```bash
./local/add-static-hosting.sh DOMENA [SSH_ALIAS] [KATALOG] [PORT]

# Przykłady:
./local/add-static-hosting.sh static.byst.re
./local/add-static-hosting.sh cdn.example.com mikrus /var/www/assets 8097
```

---

### sync.sh - Synchronizacja plików

```bash
./local/sync.sh up ./local-folder /remote/path    # Upload
./local/sync.sh down /remote/path ./local-folder  # Download
```

---

### Skrypty systemowe: `system/`

```bash
./local/deploy.sh system/docker-setup.sh   # Instalacja Docker
./local/deploy.sh system/caddy-install.sh  # Instalacja Caddy (reverse proxy)
./local/deploy.sh system/power-tools.sh    # CLI tools (yt-dlp, ffmpeg, pup)
./local/deploy.sh system/bun-setup.sh      # Instalacja Bun + PM2
```

---

## Backup i restore

### Jak działa backup

Wszystkie aplikacje przechowują dane w `/opt/stacks/<app>/` używając bind mounts.
Skrypt `backup-core.sh` używa rclone do synchronizacji tego katalogu z chmurą.

```
/opt/stacks/                    ☁️ Chmura (Google Drive, Dropbox, etc.)
├── uptime-kuma/data/     ───►  mikrus-backup/stacks/uptime-kuma/data/
├── ntfy/cache/           ───►  mikrus-backup/stacks/ntfy/cache/
├── vaultwarden/data/     ───►  mikrus-backup/stacks/vaultwarden/data/
└── ...
```

### Konfiguracja backupu (jednorazowo)

```bash
# Uruchom wizard - skonfiguruje rclone i cron
./local/setup-backup.sh mikrus

# Wizard:
# 1. Wybierz provider (Google Drive, Dropbox, OneDrive, S3...)
# 2. Zaloguj się przez przeglądarkę (OAuth)
# 3. Opcjonalnie włącz szyfrowanie
# 4. Gotowe - cron uruchomi backup codziennie o 3:00
```

### Ręczne uruchomienie backupu

```bash
# Uruchom backup teraz
ssh mikrus '~/backup-core.sh'

# Sprawdź logi
ssh mikrus 'tail -30 /var/log/mikrus-backup.log'

# Zobacz co jest w chmurze
ssh mikrus 'rclone ls backup_remote:mikrus-backupstacks/'
```

### Restore (przywracanie danych)

```bash
# Przywróć wszystkie dane z chmury
./local/restore.sh mikrus

# Lub ręcznie - przywróć konkretną aplikację
ssh mikrus 'rclone sync backup_remote:mikrus-backupstacks/uptime-kuma /opt/stacks/uptime-kuma'
ssh mikrus 'cd /opt/stacks/uptime-kuma && docker compose up -d'
```

### Weryfikacja backupu

```bash
# Sprawdź czy cron jest ustawiony
ssh mikrus 'crontab -l | grep backup'

# Sprawdź ostatni backup
ssh mikrus 'tail -10 /var/log/mikrus-backup.log'

# Porównaj lokalnie vs chmura
ssh mikrus 'rclone check /opt/stacks backup_remote:mikrus-backupstacks/'
```

---

## Diagnostyka i troubleshooting

### Status kontenerów

```bash
# Lista uruchomionych kontenerów
ssh mikrus 'docker ps'

# Szczegóły z portami
ssh mikrus 'docker ps --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}"'

# Wszystkie kontenery (także zatrzymane)
ssh mikrus 'docker ps -a'
```

### Logi aplikacji

```bash
# Logi konkretnej aplikacji
ssh mikrus 'cd /opt/stacks/uptime-kuma && docker compose logs --tail 50'

# Logi na żywo (follow)
ssh mikrus 'cd /opt/stacks/uptime-kuma && docker compose logs -f'

# Logi z czasem
ssh mikrus 'cd /opt/stacks/uptime-kuma && docker compose logs --tail 50 -t'
```

### Test lokalny

```bash
# Sprawdź czy aplikacja odpowiada na porcie
ssh mikrus 'curl -s localhost:3001 | head -5'

# Sprawdź nagłówki HTTP
ssh mikrus 'curl -sI localhost:3001'

# Test z zewnątrz (przez domenę)
curl -sI https://mojapp.byst.re
```

### Typowe problemy i rozwiązania

#### 1. Kontener nie startuje

```bash
# Sprawdź logi
ssh mikrus 'cd /opt/stacks/<app> && docker compose logs --tail 100'

# Sprawdź czy obraz się pobrał
ssh mikrus 'docker images | grep <app>'

# Restart kontenera
ssh mikrus 'cd /opt/stacks/<app> && docker compose restart'
```

#### 2. Brak połączenia z bazą danych

```bash
# Sprawdź czy baza jest dostępna
ssh mikrus 'nc -zv <db_host> 5432'

# Test połączenia PostgreSQL
ssh mikrus 'PGPASSWORD=<pass> psql -h <host> -U <user> -d <db> -c "SELECT 1"'
```

#### 3. Domena nie działa (502/504)

- Sprawdź czy kontener działa: `docker ps`
- Sprawdź czy port jest otwarty: `curl localhost:PORT`
- Dla Cytrus: poczekaj 3-5 minut na propagację
- Sprawdź czy port NIE jest bound do 127.0.0.1 (musi być 0.0.0.0 lub bez prefixu)

#### 4. Brak miejsca na dysku

```bash
# Sprawdź miejsce
ssh mikrus 'df -h /'

# Wyczyść nieużywane obrazy Docker
ssh mikrus 'docker system prune -af'

# Wyczyść logi kontenerów
ssh mikrus 'truncate -s 0 /var/lib/docker/containers/*/*-json.log'
```

#### 5. Aplikacja działa lokalnie ale nie przez domenę

Dla Cytrus: port musi być dostępny zewnętrznie (nie 127.0.0.1):
```yaml
# ŹLE - tylko localhost
ports:
  - "127.0.0.1:3000:3000"

# DOBRZE - wszystkie interfejsy
ports:
  - "3000:3000"
```

### Restart aplikacji

```bash
# Restart
ssh mikrus 'cd /opt/stacks/<app> && docker compose restart'

# Pełny restart (down + up)
ssh mikrus 'cd /opt/stacks/<app> && docker compose down && docker compose up -d'

# Restart z pobraniem nowego obrazu
ssh mikrus 'cd /opt/stacks/<app> && docker compose pull && docker compose up -d'
```

### Usunięcie aplikacji

```bash
# Zatrzymaj i usuń kontenery (zachowaj dane)
ssh mikrus 'cd /opt/stacks/<app> && docker compose down'

# Zatrzymaj, usuń kontenery i dane (volumes)
ssh mikrus 'cd /opt/stacks/<app> && docker compose down -v'

# Usuń całkowicie (kontenery + pliki)
ssh mikrus 'cd /opt/stacks/<app> && docker compose down -v && rm -rf /opt/stacks/<app>'
```

---

## Brakujące narzędzia

### Co jest dostępne na Mikrusie

Standardowo zainstalowane:
- `docker`, `docker compose` (po uruchomieniu docker-setup.sh)
- `curl`, `wget`
- `git`
- `nano`, `vim`
- `htop`, `ncdu`

### Instalacja brakujących narzędzi

```bash
# Aktualizacja pakietów (Debian/Ubuntu)
ssh mikrus 'apt update && apt install -y <package>'

# Przykłady:
ssh mikrus 'apt install -y jq'      # JSON processor
ssh mikrus 'apt install -y tree'    # Drzewo katalogów
ssh mikrus 'apt install -y ncdu'    # Disk usage analyzer
```

### Power Tools (opcjonalne)

Skrypt `system/power-tools.sh` instaluje:
- `yt-dlp` - pobieranie wideo
- `ffmpeg` - konwersja mediów
- `pup` - parsowanie HTML

```bash
./local/deploy.sh system/power-tools.sh
```

---

## Architektura

### Struktura katalogów na serwerze

```
/opt/stacks/           # Aplikacje Docker Compose
  ├── uptime-kuma/
  │   ├── docker-compose.yaml
  │   └── data/        # Dane aplikacji (volumes)
  ├── n8n/
  └── ...

/klucz_api             # Klucz API Mikrusa
```

### Dwa sposoby na domenę HTTPS

#### 1. Cytrus (domeny Mikrusa) - ZALECANE

- Automatyczne SSL
- Domeny: `*.byst.re`, `*.bieda.it`, `*.toadres.pl`, `*.tojest.dev`
- Konfiguracja przez API (bez DNS)
- Port musi być dostępny zewnętrznie (nie 127.0.0.1!)

```bash
./local/cytrus-domain.sh mojapp.byst.re 3000 mikrus
```

#### 2. Cloudflare + Caddy (własne domeny)

- Wymaga konfiguracji Cloudflare (`./local/setup-cloudflare.sh`)
- Rekord AAAA do IPv6 serwera
- Caddy jako reverse proxy z auto-SSL

### Bazy danych

#### Współdzielona baza Mikrusa (darmowa)

- Dane z API: `https://api.mikr.us/db.bash`
- PostgreSQL: `psql*.mikr.us`
- MySQL: `mysql*.mikr.us`
- MongoDB: `mongo*.mikr.us`
- **Ograniczenia:** brak uprawnień do rozszerzeń (np. pgcrypto)

#### Dedykowana baza (płatna)

- Panel: https://mikr.us/panel/?a=cloud
- Host: `mws*.mikr.us` (PostgreSQL)
- Pełne uprawnienia, własna baza

---

## Limity i ograniczenia

### Zasoby serwera

- RAM: ~512MB - 2GB (zależnie od pakietu)
- Dysk: ~10-20GB
- **Zawsze ustawiaj limity pamięci w docker-compose.yaml!**

```yaml
deploy:
  resources:
    limits:
      memory: 256M
```

### Rekomendowane limity pamięci

| Aplikacja | Limit RAM |
|-----------|-----------|
| uptime-kuma | 256M |
| ntfy | 128M |
| n8n | 512-768M |
| nocodb | 512M |
| vaultwarden | 128M |

### Porty

- Porty 80 i 443 są zajęte przez Cytrus/Caddy
- Używaj portów > 1024 dla aplikacji
- Unikaj konfliktów - sprawdź `docker ps` przed instalacją

---

## Przykłady sesji

### Instalacja nowej aplikacji

```bash
# 1. Sprawdź czy Docker jest zainstalowany
ssh mikrus 'docker --version' || ./local/deploy.sh system/docker-setup.sh

# 2. Zainstaluj aplikację
./local/deploy.sh uptime-kuma mikrus

# 3. Zweryfikuj
ssh mikrus 'docker ps | grep uptime'
curl -sI https://przydzielona-domena.byst.re
```

### Debug niedziałającej aplikacji

```bash
# 1. Sprawdź status
ssh mikrus 'docker ps -a | grep <app>'

# 2. Sprawdź logi
ssh mikrus 'cd /opt/stacks/<app> && docker compose logs --tail 50'

# 3. Sprawdź lokalnie
ssh mikrus 'curl -s localhost:<port> | head -10'

# 4. Restart jeśli potrzebny
ssh mikrus 'cd /opt/stacks/<app> && docker compose restart'
```

### Aktualizacja aplikacji

```bash
# Pobierz nowy obraz i zrestartuj
ssh mikrus 'cd /opt/stacks/<app> && docker compose pull && docker compose up -d'

# Wyczyść stare obrazy
ssh mikrus 'docker image prune -f'
```

---

## Kontakt i pomoc

- Panel Mikrus: https://mikr.us/panel/
- Dokumentacja API: https://api.mikr.us/
- Tickety support: przez panel Mikrus
