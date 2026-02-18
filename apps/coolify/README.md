# Coolify - Twój Prywatny Heroku/Vercel

Open-source PaaS (Platform as a Service) z 280+ apkami do zainstalowania jednym kliknięciem. Automatyczny SSL, backupy, Git push deploy, monitoring.

**SUPER BONUS** - wymaga Mikrus 4.1+ (8GB RAM, 80GB dysk, 2x CPU).

## Co dostajesz

- **280+ apek** z katalogu (one-click deploy): WordPress, n8n, Nextcloud, Grafana, Gitea, Ghost, Jellyfin, Vaultwarden, Uptime Kuma, PostHog, Supabase, Minio, Ollama...
- **Automatyczny SSL** - Let's Encrypt dla każdej apki
- **Git push deploy** - podepnij repo z GitHub/GitLab, push = deploy
- **Backupy** - automatyczne do S3-compatible storage
- **Monitoring** - alerty na dysk, CPU, RAM, deployment status
- **Webowy terminal** - SSH do kontenerów z przeglądarki
- **Multi-serwer** - zarządzaj wieloma serwerami z jednego panelu

## Dlaczego Mikrus 4.1+

| Komponent | RAM |
|---|---|
| Coolify (Laravel app) | ~300-500 MB |
| PostgreSQL 15 (platforma) | ~50-100 MB |
| Redis 7 (cache/queues) | ~10-30 MB |
| Soketi (WebSocket) | ~30-50 MB |
| Traefik (reverse proxy) | ~50-100 MB |
| **Suma (platforma)** | **~500-800 MB** |

Na Mikrus 3.5 (4GB/40GB) byłoby na styk - platforma zjada ~800 MB, zostaje ~3 GB na apki, a dysk (40 GB) szybko się zapełni obrazami Docker.

Na Mikrus 4.1 (8GB/80GB) - komfortowo. ~7 GB na apki, 80 GB dysku na obrazy i dane.

## Instalacja

```bash
./local/deploy.sh coolify --ssh=mikrus
```

### Z pre-konfiguracją admina (bezpieczniej)

```bash
ROOT_USERNAME=admin ROOT_USER_EMAIL=admin@example.com ROOT_USER_PASSWORD=TajneHaslo123 \
  ./local/deploy.sh coolify --ssh=mikrus
```

Pomija ekran otwartej rejestracji - konto admina jest gotowe od razu.

### Wyłączenie auto-aktualizacji

```bash
AUTOUPDATE=false ./local/deploy.sh coolify --ssh=mikrus
```

Nie wymaga: `--domain-type`, `--domain`, bazy danych. Coolify zarządza tym sam.

## Po instalacji

### 1. Utwórz konto admina (NATYCHMIAST!)

Otwórz `http://<IP-serwera>:8000` i zarejestruj się. **Pierwszy zarejestrowany użytkownik = administrator.** Dopóki się nie zarejestrujesz, panel jest otwarty dla każdego!

### 2. Skonfiguruj domenę (opcjonalne)

W panelu Coolify: Settings → General → ustaw Instance's Domain (np. `https://panel.twojadomena.pl`).

DNS: dodaj rekord A `panel.twojadomena.pl` → IP serwera. Traefik automatycznie wystawi SSL.

### 3. Deploy pierwszej apki

Resources → + New → Service → wybierz z katalogu (np. WordPress) → Deploy.

Coolify automatycznie:
- Pobierze obraz Docker
- Skonfiguruje bazę danych (jeśli potrzebna)
- Wystawi SSL przez Let's Encrypt
- Skonfiguruje routing przez Traefik

## Architektura

```
Internet → Traefik (:80/:443) → apka1, apka2, apka3...
                                  ↕
Browser  → Coolify UI (:8000) → PostgreSQL, Redis (platforma)
```

### Porty

| Port | Usługa |
|---|---|
| 8000 | Panel Coolify (UI) |
| 80 | Traefik HTTP (redirect → HTTPS) |
| 443 | Traefik HTTPS (SSL, routing do apek) |
| 6001 | Soketi WebSocket (wewnętrzny) |

### Katalogi

| Ścieżka | Co zawiera |
|---|---|
| `/data/coolify/source/` | docker-compose i .env platformy |
| `/data/coolify/applications/` | dane zainstalowanych apek |
| `/data/coolify/databases/` | dane baz danych apek |
| `/data/coolify/backups/` | backupy |
| `/data/coolify/proxy/` | konfiguracja Traefik |
| `/data/coolify/ssh/keys/` | klucze SSH (container↔host) |

## Ważne

- **Coolify przejmuje serwer.** Traefik na portach 80/443 zarządza całym ruchem HTTP/HTTPS. Nie instaluj obok innych apek z stackpilot (deploy.sh) - będą konflikty portów.
- **Jeden panel, wszystkie apki.** Po zainstalowaniu Coolify, zarządzaj WSZYSTKIMI apkami przez panel (nie przez deploy.sh).
- **Auto-update.** Coolify domyślnie aktualizuje się automatycznie. Wyłącz w `/data/coolify/source/.env`: `AUTOUPDATE=false`.
- **Backup platformy.** Coolify ma wbudowane backupy dla apek (do S3). Sam Coolify = backup `/data/coolify/`.

## Przykładowe apki z katalogu

| Kategoria | Apki |
|---|---|
| AI | Ollama, Open WebUI, Flowise, Langflow, LibreChat, LobeChat |
| Automation | N8N, Activepieces, Trigger |
| CMS | WordPress, Ghost, Directus, Strapi, Drupal |
| Monitoring | Uptime Kuma, Grafana, Glances, PostHog, Plausible |
| Storage | Nextcloud, MinIO, Seafile |
| Dev | Gitea, Forgejo, GitLab, Supabase, Jupyter, Code Server |
| Security | Vaultwarden, Authentik, Pi-hole, WireGuard |
| Media | Jellyfin, Plex, Immich, Navidrome |
| Business | Odoo, Invoice Ninja, Cal.com, Chatwoot |

Pełna lista (280+): [coolify.io/docs/services](https://coolify.io/docs/services/)

## Przydatne komendy

```bash
# Logi platformy
cd /data/coolify/source && docker compose logs -f

# Restart platformy
cd /data/coolify/source && docker compose restart

# Status kontenerów
cd /data/coolify/source && docker compose ps

# Ręczna aktualizacja
cd /data/coolify/source && docker compose pull && docker compose up -d
```

## Ograniczenia

- **Wymaga dedykowanego serwera** - Coolify przejmuje porty 80/443, nie współgra z innymi apkami z toolboxa
- **Platforma zjada ~500-800 MB RAM** - overhead za webowy panel i infrastrukturę
- **Dysk** - każda apka to kolejny obraz Docker (500 MB - 3 GB), na 80 GB mieści się ~10-15 apek
- **Beta** - Coolify v4 jest w fazie beta (stabilna, ale zdarzają się regressions przy auto-update)
