# Crawl4AI - AI Web Crawler and Scraper

REST API for crawling pages with headless Chromium. Data extraction via AI, output in Markdown/JSON.

## Installation

```bash
./local/deploy.sh crawl4ai --ssh=ALIAS --domain-type=caddy --domain=crawl4ai.your-domain.com
```

## Requirements

- **RAM:** minimum 2GB VPS, ~1-1.5GB usage at runtime
- **Disk:** ~3.5GB (Docker image with Chromium + Python + ML deps)
- **Database:** Not required (stateless)

**Crawl4AI will NOT work on a 1GB RAM VPS!** Headless Chromium needs ~1-1.5GB RAM. install.sh blocks installation when <1800MB RAM is available.

## After Installation

API, Playground and Monitor are available immediately:
- **API:** `https://domain/crawl`
- **Playground:** `https://domain/playground` - interactive testing
- **Monitor:** `https://domain/monitor` - dashboard with metrics (RAM, browser pool, requests)

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CRAWL4AI_API_TOKEN` | (generated) | API token - install.sh generates automatically |
| `CRAWL4AI_MODE` | api | Working mode (api for Docker) |
| `PLAYWRIGHT_MAX_CONCURRENCY` | 2 | Max parallel browsers (more = more RAM) |

Optional (LLM extraction - add manually to docker-compose):

| Variable | Description |
|----------|-------------|
| `OPENAI_API_KEY` | OpenAI key for LLM extraction |
| `ANTHROPIC_API_KEY` | Anthropic key |

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/crawl` | POST | Synchronous crawling |
| `/crawl/stream` | POST | Crawling with streaming |
| `/crawl/job` | POST | Async crawling (returns task_id) |
| `/job/{task_id}` | GET | Async job status |
| `/md` | POST | Convert page to Markdown |
| `/screenshot` | POST | Page screenshot (PNG) |
| `/pdf` | POST | Generate PDF |
| `/playground` | GET | Interactive playground |
| `/monitor` | GET | Monitoring dashboard |

## Usage

```bash
# Crawl a page
curl -X POST https://your-domain.com/crawl \
  -H "Authorization: Bearer $(cat /opt/stacks/crawl4ai/.api_token)" \
  -H "Content-Type: application/json" \
  -d '{"urls": ["https://example.com"]}'
```

### With n8n

Crawl4AI integrates with n8n for automated scraping:
1. HTTP Request node -> POST to Crawl4AI API
2. Parse response (Markdown/JSON)
3. Save data or send notification

## API Token

The token is generated automatically during installation and saved in:
```
/opt/stacks/crawl4ai/.api_token
```

## Version

Container runs as non-root (UID 1000).

## Limitations

- **Memory leak** - Under intensive use, memory grows (Chrome processes accumulate). `PLAYWRIGHT_MAX_CONCURRENCY=2` mitigates the problem. For heavy traffic, add a daily restart:
  ```bash
  # crontab -e on the server
  0 4 * * * cd /opt/stacks/crawl4ai && docker compose restart
  ```
- **Slow start** - Chromium starts in ~60-90s
- **Large image** - ~3.5GB on disk
- **JWT auth broken** - Built-in JWT does not require credentials (known bug). Use `CRAWL4AI_API_TOKEN` or reverse proxy with auth.
- **RAM on small VPS** - On a 2GB VPS the container limit is 1536MB, sufficient for 1-2 concurrent crawls

## Backup

Crawl4AI is stateless - it does not store data. Just back up `docker-compose.yaml` and `.api_token`.
