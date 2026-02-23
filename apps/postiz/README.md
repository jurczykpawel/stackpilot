# Postiz - Planowanie Postów w Social Media

Alternatywa dla Buffer/Hootsuite. Planuj posty na Twitter/X, LinkedIn, Instagram, Facebook, TikTok i więcej.

## Wymagania

- **Dedykowany serwer** — Postiz wymaga osobnego Mikrusa (nie instaluj obok innych ciężkich usług!)
- **RAM:** minimum 4GB (Mikrus 3.5+), zużycie ~3.5-4GB (4-6 kontenerów)
- **Dysk:** ~3.5GB (obrazy Docker)
- **Domena:** wymagana (HTTPS dla OAuth callback)

> Postiz od v2.12 wymaga Temporal (workflow engine) + osobny PostgreSQL.
> Postiz sam zużywa ~3GB RAM (webpack build peak ~2.2GB) — zbyt dużo żeby współdzielić serwer z innymi usługami.

## Instalacja

```bash
# Domyślnie — bundluje PostgreSQL + Redis (zero konfiguracji)
./local/deploy.sh postiz --ssh=<alias> --domain-type=cytrus --domain=auto

# Z własną bazą danych (jeśli masz kupiony dedykowany PostgreSQL)
./local/deploy.sh postiz --ssh=<alias> --db=custom --domain-type=cytrus --domain=auto

# Z istniejącym Redis na serwerze
POSTIZ_REDIS=external ./local/deploy.sh postiz --ssh=<alias> --domain-type=cytrus --domain=auto
```

Domyślnie PostgreSQL, Redis i Temporal są bundlowane automatycznie — nie trzeba kupować zewnętrznej bazy. Jeśli masz już wykupiony PostgreSQL lub Redis na serwerze, możesz je reużyć.

## Stack (4-6 kontenerów)

| Kontener | Obraz | RAM | Rola | Bundled? |
|----------|-------|-----|------|----------|
| postiz | ghcr.io/gitroomhq/postiz-app:latest | ~3GB | Aplikacja (Next.js + Nest.js + nginx) | zawsze |
| postiz-postgres | postgres:17-alpine | ~256MB | Baza danych Postiz | domyślnie (pomijany z `--db=custom`) |
| postiz-redis | redis:7.2-alpine | ~128MB | Cache + queues | domyślnie (pomijany z `POSTIZ_REDIS=external`) |
| temporal | temporalio/auto-setup:1.28.1 | ~512MB | Workflow engine | zawsze |
| temporal-postgresql | postgres:16-alpine | ~256MB | Baza danych Temporal | zawsze |
| temporal-ui | temporalio/ui:2.34.0 | ~256MB | Panel Temporal (localhost:8080) | zawsze |

## Po instalacji

1. Otwórz stronę w przeglądarce → utwórz konto administratora
2. **Wyłącz rejestrację** po utworzeniu konta:
   ```bash
   ssh <alias> 'cd /opt/stacks/postiz && sed -i "/IS_GENERAL/a\      - DISABLE_REGISTRATION=true" docker-compose.yaml && docker compose up -d'
   ```
3. Uzupełnij klucze API providerów w pliku `.env`:
   ```bash
   ssh <alias> 'nano /opt/stacks/postiz/.env'
   # po zapisaniu:
   ssh <alias> 'cd /opt/stacks/postiz && docker compose up -d'
   ```

Plik `.env` jest pobierany automatycznie z oficjalnego repozytorium Postiz przy instalacji.

## Obsługiwane platformy

Twitter/X, LinkedIn, Instagram, Facebook, TikTok, YouTube, Pinterest, Reddit, Mastodon, Bluesky, Threads, Discord, Slack, Telegram i więcej (20+).

Każda platforma wymaga własnych kluczy API — konfiguracja w pliku `.env`.

Ważne uwagi przy konfiguracji providerów:

- **Facebook/Instagram:** przełącz app z Development → Live (inaczej posty widoczne tylko dla Ciebie!)
- **LinkedIn:** dodaj produkt "Advertising API" (bez tego tokeny nie odświeżają się!)
- **TikTok:** domena z uploadami musi być zweryfikowana w TikTok Developer Account
- **YouTube:** po konfiguracji Brand Account poczekaj ~5h na propagację
- **Threads:** złożona konfiguracja — [docs.postiz.com/providers/threads](https://docs.postiz.com/providers/threads)
- **Discord/Slack:** ikona aplikacji jest wymagana (bez niej błąd 404)

Docs: [docs.postiz.com/providers](https://docs.postiz.com/providers)

## Wiele kont / zespoły

**Wiele kanałów na jednej platformie** — tak, możesz podłączyć np. 2 strony Facebook + 3 konta Instagram Business + 1 LinkedIn. Przy tworzeniu posta wybierasz, na które kanały opublikować i piszesz osobną wersję treści dla każdego kanału.

**Ograniczenia:**

- **YouTube:** jedno `YOUTUBE_CLIENT_ID/SECRET` w `.env` = wszystkie kanały muszą być pod tą samą aplikacją Google OAuth. Wiele kanałów z różnych kont Google to [otwarty feature request](https://github.com/gitroomhq/postiz-app/issues/1049)
- **Jeden user = jedna organizacja.** Nie da się być w wielu teamach ([#608, zamknięte jako "not planned"](https://github.com/gitroomhq/postiz-app/issues/608))
- **Brak granularnych uprawnień per kanał.** Każdy członek organizacji widzi wszystkie podłączone kanały — nie da się dać komuś dostępu tylko do jednego z kilku kont Instagram
- **Brak synchronizacji kalendarza z platformami.** Postiz tylko wypycha posty — nie widzi postów zaplanowanych w Meta Business Suite, LinkedIn Campaign Manager itp. Jeśli planujesz posty z wielu miejsc, Postiz musi być jedynym źródłem prawdy

**Workaround na oddzielne dostępy:** osobne konto (inny email) z własną organizacją. Obie organizacje mogą podłączyć to samo konto social media (osobna autoryzacja OAuth), ale nie widzą nawzajem swoich kalendarzy.

## API, MCP i automatyzacja

Postiz ma publiczne API, wbudowany MCP server i CLI do integracji z AI:

- **API:** `https://<domena>/api/public/v1` — scheduling, upload mediów, lista kanałów, find-slot
- **Auth:** klucz API z Settings, header `Authorization`
- **Rate limit:** 30 req/h (ale jeden request = wiele postów)
- **SDK:** `@postiz/node` (npm), integracja z n8n
- **MCP (wbudowany):** endpoint `https://<domena>/mcp/<API-KEY>/sse` — działa z Claude Desktop, Claude Code, Cursor
- **[Postiz Agent](https://postiz.com/agent)** — CLI dla agentów AI, structured JSON output

Konfiguracja MCP w Claude Desktop / Claude Code:
```json
{
  "mcpServers": {
    "postiz": {
      "url": "https://<domena>/mcp/<API-KEY>/sse"
    }
  }
}
```

Docs: [docs.postiz.com/public-api](https://docs.postiz.com/public-api/introduction)

## Ograniczenia

- **Dedykowany serwer** — 4-6 kontenerów, ~3.5-4GB RAM, nie współdziel z innymi usługami
- **Wolny start** — Temporal + Next.js startują ~90-120s
- **OAuth wymaga HTTPS** — większość platform wymaga HTTPS dla callback URL
- **SSH tunnel bez domeny** — Postiz ustawia secure cookies, logowanie przez HTTP nie zadziała. Dodaj `NOT_SECURED=true` do docker-compose (tylko dev/tunnel!)
- **Duże obrazy** — ~3.5GB na dysku (4-6 kontenerów)

## Backup

```bash
./local/setup-backup.sh <alias>
```

Dane w `/opt/stacks/postiz/`:
- `config/` - konfiguracja
- `uploads/` - przesłane pliki
- `postgres-data/` - baza danych Postiz
- `redis-data/` - cache Redis
- `temporal-postgres-data/` - baza danych Temporal
- `.env` - klucze API providerów
