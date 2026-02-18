# Postiz - Planowanie Postów w Social Media

Alternatywa dla Buffer/Hootsuite. Planuj posty na Twitter/X, LinkedIn, Instagram, Facebook, TikTok i więcej.

## Instalacja

```bash
./local/deploy.sh postiz --ssh=mikrus --domain-type=cytrus --domain=auto
```

Deploy.sh automatycznie skonfiguruje bazę PostgreSQL (wymagana dedykowana).

## Wymagania

- **RAM:** zalecane 2GB (Mikrus 3.0+), ~1-1.5GB zużycia (Postiz + Redis)
- **Dysk:** ~3GB (obraz Docker)
- **Baza danych:** PostgreSQL (dedykowana — shared Mikrus nie działa, PG 12 nie ma `gen_random_uuid()`)
- **Redis:** Auto-detekcja external lub bundled (patrz niżej)

## Wersja

Pinujemy **v2.11.3** (pre-Temporal). Od v2.12+ Postiz wymaga Temporal + Elasticsearch + drugi PostgreSQL = 7 kontenerów, minimum 4GB RAM. Zbyt ciężkie na Mikrus.

## Po instalacji

1. Otwórz stronę w przeglądarce → utwórz konto administratora
2. **Wyłącz rejestrację** po utworzeniu konta:
   ```bash
   ssh mikrus 'cd /opt/stacks/postiz && grep -q DISABLE_REGISTRATION docker-compose.yaml || sed -i "/IS_GENERAL/a\      - DISABLE_REGISTRATION=true" docker-compose.yaml && docker compose up -d'
   ```
3. Podłącz konta social media (Settings → Integrations)
4. Zaplanuj pierwsze posty

## Zmienne środowiskowe

Install.sh ustawia automatycznie:

| Zmienna | Opis |
|---------|------|
| `MAIN_URL` | Główny URL aplikacji |
| `FRONTEND_URL` | URL frontendu |
| `NEXT_PUBLIC_BACKEND_URL` | Publiczny URL backendu API |
| `DATABASE_URL` | Connection string PostgreSQL |
| `REDIS_URL` | Connection string Redis |
| `JWT_SECRET` | Sekret JWT (generowany automatycznie) |
| `IS_GENERAL` | Tryb ogólny (true) |
| `STORAGE_PROVIDER` | local (pliki na dysku) |

Dodatkowe (dodaj ręcznie do docker-compose dla integracji):

| Zmienna | Opis |
|---------|------|
| `X_API_KEY`, `X_API_SECRET` | Twitter/X API |
| `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET` | LinkedIn |
| `FACEBOOK_APP_ID`, `FACEBOOK_APP_SECRET` | Facebook/Instagram |
| `OPENAI_API_KEY` | AI-generowanie treści postów |
| `DISABLE_REGISTRATION` | Wyłącz rejestrację (true po setup) |

Pełna lista: [docs.postiz.com/configuration/reference](https://docs.postiz.com/configuration/reference)

## Obsługiwane platformy

Twitter/X, LinkedIn, Instagram, Facebook, TikTok, YouTube, Pinterest, Reddit, Mastodon, Bluesky, Threads, Discord, Slack, Telegram i więcej (20+).

Każda platforma wymaga własnych kluczy API - konfiguracja w Settings → Integrations.

### Redis (external vs bundled)

Domyślnie auto-detekcja: jeśli port 6379 nasłuchuje na serwerze, Postiz łączy się z istniejącym Redis. W przeciwnym razie bundluje `redis:7.2-alpine`.

```bash
# Wymuś bundled Redis (nawet gdy istnieje external)
POSTIZ_REDIS=bundled ./local/deploy.sh postiz --ssh=mikrus

# Wymuś external Redis (host)
POSTIZ_REDIS=external ./local/deploy.sh postiz --ssh=mikrus

# External Redis z hasłem
REDIS_PASS=tajneHaslo POSTIZ_REDIS=external ./local/deploy.sh postiz --ssh=mikrus
```

## Ograniczenia

- **Pinowana wersja** - v2.11.3 (nowsze wymagają Temporal, za ciężkie na Mikrus)
- **Wolny start** - Next.js startuje ~60-90s
- **OAuth wymaga HTTPS** - większość platform wymaga HTTPS dla callback URL
- **SSH tunnel bez domeny** - Postiz ustawia secure cookies, logowanie przez HTTP nie zadziała. Dodaj `NOT_SECURED=true` do docker-compose (tylko dev/tunnel!)
- **Duży obraz** - ~3GB na dysku

## Backup

```bash
./local/setup-backup.sh mikrus
```

Dane w `/opt/stacks/postiz/`:
- `config/` - konfiguracja (.env)
- `uploads/` - przesłane pliki
- `redis-data/` - cache Redis
- Baza PostgreSQL - backup przez Mikrus panel lub pg_dump
