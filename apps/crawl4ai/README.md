# Crawl4AI - AI Web Crawler i Scraper

REST API do crawlowania stron z headless Chromium. Ekstrakcja danych przez AI, output w Markdown/JSON.

## Instalacja

```bash
./local/deploy.sh crawl4ai --ssh=mikrus --domain-type=cytrus --domain=auto
```

## Wymagania

- **RAM:** minimum 2GB (Mikrus 3.0+), ~1-1.5GB zużycia w runtime
- **Dysk:** ~3.5GB (obraz Docker z Chromium + Python + ML deps)
- **Baza danych:** Nie wymaga (bezstanowy)

**Crawl4AI NIE zadziała na Mikrus 2.1 (1GB RAM)!** Headless Chromium potrzebuje ~1-1.5GB RAM. Install.sh blokuje instalację przy <1800MB RAM.

## Po instalacji

API, Playground i Monitor dostępne od razu:
- **API:** `https://domena/crawl`
- **Playground:** `https://domena/playground` - interaktywne testowanie
- **Monitor:** `https://domena/monitor` - dashboard z metrykami (RAM, browser pool, requesty)

## Zmienne środowiskowe

| Zmienna | Domyślna | Opis |
|---------|----------|------|
| `CRAWL4AI_API_TOKEN` | (generowany) | Token API - install.sh generuje automatycznie |
| `CRAWL4AI_MODE` | api | Tryb pracy (api dla Docker) |
| `PLAYWRIGHT_MAX_CONCURRENCY` | 2 | Max równoległych przeglądarek (więcej = więcej RAM) |

Opcjonalne (LLM extraction - dodaj ręcznie do docker-compose):

| Zmienna | Opis |
|---------|------|
| `OPENAI_API_KEY` | Klucz OpenAI dla ekstrakcji LLM |
| `ANTHROPIC_API_KEY` | Klucz Anthropic |

## API Endpoints

| Endpoint | Metoda | Opis |
|----------|--------|------|
| `/health` | GET | Health check |
| `/crawl` | POST | Crawlowanie synchroniczne |
| `/crawl/stream` | POST | Crawlowanie ze streamingiem |
| `/crawl/job` | POST | Crawlowanie asynchroniczne (zwraca task_id) |
| `/job/{task_id}` | GET | Status jobu async |
| `/md` | POST | Konwersja strony do Markdown |
| `/screenshot` | POST | Screenshot strony (PNG) |
| `/pdf` | POST | Generowanie PDF |
| `/playground` | GET | Interaktywny playground |
| `/monitor` | GET | Dashboard monitoringu |

## Użycie

```bash
# Crawluj stronę
curl -X POST https://twoja-domena/crawl \
  -H "Authorization: Bearer $(cat /opt/stacks/crawl4ai/.api_token)" \
  -H "Content-Type: application/json" \
  -d '{"urls": ["https://example.com"]}'
```

### Z n8n

Crawl4AI integruje się z n8n do automatycznego scrapingu:
1. HTTP Request node → POST do Crawl4AI API
2. Parsuj odpowiedź (Markdown/JSON)
3. Zapisz dane lub wyślij powiadomienie

## API Token

Token jest generowany automatycznie podczas instalacji i zapisany w:
```
/opt/stacks/crawl4ai/.api_token
```

## Wersja

Kontener uruchomiony jako non-root (UID 1000).

## Ograniczenia

- **Memory leak** - Przy intensywnym użyciu pamięć rośnie (Chrome procesy się kumulują). `PLAYWRIGHT_MAX_CONCURRENCY=2` ogranicza problem. Przy dużym ruchu dodaj codzienny restart:
  ```bash
  # crontab -e na serwerze
  0 4 * * * cd /opt/stacks/crawl4ai && docker compose restart
  ```
- **Wolny start** - Chromium startuje ~60-90s
- **Duży obraz** - ~3.5GB na dysku
- **JWT auth broken** - Wbudowany JWT nie wymaga credentials (znany bug). Używaj `CRAWL4AI_API_TOKEN` lub reverse proxy z auth.
- **RAM na Mikrus** - Na 2GB VPS limit kontenera to 1536MB, wystarczy na 1-2 równoległe crawle

## Backup

Crawl4AI jest bezstanowy - nie przechowuje danych. Wystarczy backup `docker-compose.yaml` i `.api_token`.
