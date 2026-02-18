# AGENTS.md

Instrukcje dla agentów AI (Claude Code, Cursor, Copilot, itp.) pracujących z tym repozytorium.

## Projekt i rola

Skrypty Bash do zarządzania serwerami [Mikrus](https://mikr.us/?r=pavvel) - tani polski VPS.
Toolbox automatyzuje instalację aplikacji Docker, konfigurację domen, backupy i diagnostykę.

Pomagasz użytkownikom zarządzać ich serwerami Mikrus. Możesz:
- Instalować aplikacje (`./local/deploy.sh`)
- Konfigurować backupy i domeny
- Synchronizować pliki z serwerem (`./local/sync.sh`)
- Diagnozować problemy (logi, porty, RAM)
- Tworzyć nowe instalatory (`apps/<app>/install.sh`)

**Zawsze komunikuj się po polsku.** Zrób za użytkownika co się da, resztę wytłumacz krok po kroku.

**WAŻNE:** Nigdy nie konstruuj ręcznie komend curl do API Mikrusa - zawsze używaj skryptów!

## Struktura repozytorium

```
local/           → Skrypty użytkownika (deploy, backup, setup)
apps/<app>/      → Instalatory aplikacji (install.sh + README.md)
lib/             → Biblioteki pomocnicze (cli-parser, db-setup, domain-setup, server-exec, port-utils)
system/          → Skrypty systemowe (docker, caddy, backup-core)
docs/            → Dokumentacja (Cloudflare, CLI reference)
```

## Tryb dual-mode (lokalne + na serwerze)

Skrypty działają **zarówno z komputera** (przez SSH) **jak i bezpośrednio na serwerze**.
Detekcja: plik `/klucz_api` istnieje TYLKO na serwerach Mikrusa.

```bash
# Z komputera (jak dotychczas):
./local/deploy.sh uptime-kuma --ssh=mikrus

# Na serwerze (po zainstalowaniu toolboxa):
ssh mikrus
deploy.sh uptime-kuma
```

Instalacja toolboxa na serwerze: `./local/install-toolbox.sh [ssh_alias]`

Biblioteka `lib/server-exec.sh` zapewnia transparentne wrappery:
- `server_exec "cmd"` → ssh lub bash -c
- `server_copy src dst` → scp lub cp
- `server_hostname` → ssh -G lub hostname

Skrypty local-only (nie działają na serwerze): `setup-ssh.sh`, `sync.sh`

## Pierwsza konfiguracja serwera (skrypt `start`)

Na świeżym serwerze Mikrus warto uruchomić wbudowany skrypt konfiguracyjny:

```bash
ssh mikrus
start
```

Skrypt interaktywnie pyta o 5 rzeczy — prowadź użytkownika krok po kroku:

| Krok | Pytanie | Zalecana odpowiedź | Uwagi |
|------|---------|---------------------|-------|
| 1 | Strefa czasowa → polska? | **T** (Tak) | Ustawia Europe/Warsaw |
| 2 | Wybierz edytor | **1** (nano) | Najprostszy dla początkujących |
| 3 | Zmienić shell na zsh? | **T** lub N | T = Oh My Zsh, ładniejszy terminal; N = zostaje bash |
| 4 | Zainstalować Dockera? | **T** (Tak) | **Wymagane** do deployowania aplikacji toolboxem |
| 5 | Aktualizacja systemu? | **T** (Tak) | Zalecane dla bezpieczeństwa |

**Ważne:** Docker jest niezbędny. Jeśli `docker --version` na serwerze nie działa → zasugeruj `start`.

Alternatywa bez `start`: `curl -fsSL https://get.docker.com | sh`

## Domeny Cytrus (MCP: `setup_domain`)

Konfiguracja darmowej subdomeny Mikrusa (*.byst.re, *.bieda.it, *.toadres.pl, *.tojest.dev):

- **Po `deploy_app` z `domain_type=cytrus`** — domena konfigurowana automatycznie, nie trzeba nic robić
- **Po `deploy_custom_app`** — użyj `setup_domain { port: PORT, domain: "auto" }` żeby przypisać domenę
- **Ręcznie** — `./local/cytrus-domain.sh DOMENA PORT [SSH]`

## Backup (MCP: `setup_backup`)

Po deploymencie sprawdzany jest status backupu. Jeśli nie ma żadnego — agent dostaje ostrzeżenie i powinien zasugerować konfigurację.

Typy backupu:
- `setup_backup(backup_type='db')` — automatyczny codzienny backup baz danych (cron na serwerze)
- `setup_backup(backup_type='mikrus')` — wbudowany backup Mikrusa (200MB, za darmo, wymaga aktywacji w panelu: https://mikr.us/panel/?a=backup)
- `setup_backup(backup_type='cloud')` — backup w chmurze (Google Drive, Dropbox, S3) — wymaga lokalnego uruchomienia `./local/setup-backup.sh` (OAuth w przeglądarce)

Toolbox jest automatycznie instalowany na serwerze (git clone z GitHub) jeśli jeszcze go tam nie ma.

## Deploy aplikacji

```bash
./local/deploy.sh APP [opcje]

# Opcje:
#   --ssh=ALIAS           SSH alias (domyślnie: mikrus)
#   --domain-type=TYPE    cytrus | cloudflare | local
#   --domain=DOMAIN       Domena lub "auto" dla Cytrus
#   --db-source=SOURCE    shared | custom (bazy danych)
#   --yes, -y             Pomiń wszystkie potwierdzenia

# Przykłady:
./local/deploy.sh n8n --ssh=mikrus --domain-type=cytrus --domain=auto
./local/deploy.sh uptime-kuma --ssh=mikrus --domain-type=local --yes
./local/deploy.sh wordpress --ssh=mikrus --domain-type=cytrus --domain=auto
```

**WordPress env vars** (przekazywane jako opcje lub env):
- `WP_DB_MODE=sqlite|mysql` - tryb bazy (domyślnie: mysql)
- `WP_REDIS=auto|external|bundled` - auto-detekcja Redisa na hoście

**Post-install WordPress** — `wp-init.sh` uruchamia się automatycznie podczas instalacji.
Jedyny ręczny krok: otworzyć stronę w przeglądarce → kreator WordPress.

### GateFlow (flagowy produkt)

Platforma sprzedaży produktów cyfrowych (alternatywa Gumroad/EasyCart). Nie używa Dockera — działa na Bun + PM2 (Next.js standalone).

**Wymagania:** Supabase (darmowe konto), opcjonalnie Stripe (płatności).

**MCP deployment** — pełny flow bez wklejania sekretów:
```
# Krok 1: Agent wywołuje setup_gateflow_config() → otwiera przeglądarkę do logowania Supabase
# Krok 2: User podaje jednorazowy kod weryfikacyjny (8 znaków, NIE jest sekretem)
# Krok 3: Agent wywołuje setup_gateflow_config(verification_code="ABCD1234") → pobiera projekty
# Krok 4: User wybiera projekt → agent wywołuje setup_gateflow_config(project_ref="xxx")
#          → klucze pobrane automatycznie i zapisane do ~/.config/gateflow/deploy-config.env
# Krok 5: Agent wywołuje deploy_app(app_name="gateflow") → config ładowany z pliku
```

**BEZPIECZEŃSTWO:** NIE proś użytkownika o wklejanie kluczy (service_role, Stripe SK) w rozmowie — trafiłyby przez API. Używaj `setup_gateflow_config` — sekrety nigdy nie trafiają do rozmowy.

**CLI deployment:**
```bash
# Interaktywny (prowadzi za rączkę)
./local/deploy.sh gateflow --ssh=mikrus --domain-type=cytrus --domain=auto

# Automatyczny (wymaga wcześniejszego setup-gateflow-config.sh)
./local/deploy.sh gateflow --ssh=mikrus --yes
```

**Po instalacji:**
- Pierwszy zarejestrowany użytkownik = admin
- Stripe webhooks: `https://DOMENA/api/webhooks/stripe` (events: checkout.session.completed, payment_intent.succeeded)
- Turnstile CAPTCHA: opcjonalny, `./local/setup-turnstile.sh DOMENA SSH_ALIAS`
- Multi-instance: każda domena = osobny katalog (`/opt/stacks/gateflow-{subdomena}/`)

## Synchronizacja plików (sync.sh)

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

Prosty wrapper na rsync — do szybkiego przesyłania plików bez pełnego deployu.

## Aplikacje (25)

Wszystkie w `apps/<nazwa>/install.sh`. Uruchamiane przez `deploy.sh`, nie ręcznie.

n8n, ntfy, uptime-kuma, filebrowser, dockge, stirling-pdf, vaultwarden, linkstack, littlelink, nocodb, umami, listmonk, typebot, redis, wordpress, convertx, postiz, crawl4ai, cap, gateflow, minio, gotenberg, cookie-hub, mcp-docker, coolify

Szczegóły konkretnej aplikacji (porty, wymagania, DB) → `apps/<app>/README.md` lub `GUIDE.md`

### Coolify (specjalny flow)

Coolify to pełny PaaS (prywatny Heroku) - **tylko dla Mikrus 4.1+** (8GB RAM, 80GB dysk).
Nie korzysta z `DOMAIN_TYPE`, `DB_*`, ani `/opt/stacks/`. Deleguje do oficjalnego instalatora Coolify (`curl | bash`), który sam instaluje Docker, Traefik, PostgreSQL, Redis i tworzy `/data/coolify/`.
Przejmuje porty 80/443 - **nie mieszać z innymi apkami z toolboxa.**

## WordPress - architektura

Najbardziej złożona aplikacja. Własny Dockerfile, 3 kontenery, auto-tuning na RAM.

```
wordpress (build: .) → wordpress:php8.3-fpm-alpine + pecl redis + WP-CLI
nginx:alpine          → gzip, FastCGI cache, rate limiting, security headers
redis:alpine          → object cache (bundled lub external, auto-detekcja)
```

**Pliki na serwerze (`/opt/stacks/wordpress/`):**
- `Dockerfile` - extends wordpress:fpm-alpine + redis ext + WP-CLI
- `docker-compose.yaml` - dynamiczny (zależy od DB i Redis mode)
- `config/` - php-opcache.ini, php-performance.ini, www.conf, nginx.conf
- `wp-init.sh` - post-install: wp-config tuning + Redis Object Cache (WP-CLI)
- `flush-cache.sh` - czyści FastCGI cache
- `.redis-host` - `redis` (bundled) lub `host-gateway` (external)

**DB detection:** install.sh zawiera literały `DB_HOST` i `mysql`, więc deploy.sh automatycznie wykrywa potrzebę MySQL. W trybie `WP_DB_MODE=sqlite` zmienne DB są ignorowane.

**wp-init.sh automatycznie:** HTTPS fix, WP-Cron→system cron, rewizje limit, autosave 5min, DISALLOW_FILE_EDIT, Redis config + plugin install/activate via WP-CLI.

## Code style

### Konwencje

- `set -e` w każdym skrypcie
- Zmienne: `UPPER_CASE`, funkcje: `snake_case()` (bez `function`)
- Pliki: `kebab-case.sh`, katalogi: `kebab-case`
- Komunikaty po polsku z emoji (✅ ❌ ⚠️)
- Zawsze `memory:` limit w docker-compose
- Porty: `127.0.0.1:$PORT:CONTAINER_PORT` (bezpieczeństwo, Cytrus wymaga `$PORT:CONTAINER_PORT` bez 127.0.0.1 - deploy.sh przekazuje `DOMAIN_TYPE`)

### Wzorzec install.sh

```bash
#!/bin/bash

# Mikrus Toolbox - Nazwa Aplikacji
# Opis.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=200  # Rozmiar obrazu Docker

set -e

APP_NAME="myapp"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}

# Walidacja (jeśli DB)
if [ -z "$DB_HOST" ]; then echo "❌ Brak danych DB!"; exit 1; fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  myapp:
    image: myimage:latest
    restart: always
    ports:
      - "127.0.0.1:$PORT:8080"
    deploy:
      resources:
        limits:
          memory: 256M
EOF

sudo docker compose up -d
```

### Kluczowe zasady

- Nie pytaj o domenę w install.sh - robi to deploy.sh
- Pliki w `/opt/stacks/<app>/`
- `|| { echo "❌ Error"; exit 1; }` dla obsługi błędów
- `|| true` dla opcjonalnych komend
- Nigdy nie loguj sekretów
- Sekrety w env vars, konfiguracje w `~/.config/mikrus/`

## Więcej informacji

Szczegółowa dokumentacja → **`GUIDE.md`** (referencja operacyjna):
- SSH, klucz API, konfiguracja połączenia
- Pełna tabela aplikacji z portami
- Szczegółowy flow deploy.sh (krok po kroku)
- Backup i restore (konfiguracja, ręczne uruchomienie, weryfikacja)
- Diagnostyka i troubleshooting (logi, porty, typowe problemy)
- Architektura (domeny Cytrus/Cloudflare, bazy danych)
- Limity i ograniczenia (RAM, dysk, porty)

Inne źródła:
- `apps/<app>/README.md` - szczegóły per aplikacja
- `docs/CLI-REFERENCE.md` - pełna referencja parametrów CLI
