# Subtitle Burner

**Twórz, styluj i wypalaj animowane napisy na wideo.**

| | |
|---|---|
| **Obraz** | Build z repozytorium (~900MB) |
| **RAM** | ~1.5–2GB (6 kontenerów) |
| **Dysk** | ~2GB obrazy + dane wideo |
| **Port** | Konfigurowalny (domyślnie 3000) |
| **Baza** | PostgreSQL 16 (bundled) |
| **Plan** | Mikrus 3.0+ (2GB RAM) |

## Co to robi?

Subtitle Burner to pełna platforma do tworzenia napisów na wideo:

- **Edytor wizualny** z drag-and-drop timeline
- **8 szablonów** — Classic, Cinematic, Bold Box, Modern, Minimal Top, Neon, Yellow Box, Typewriter
- **6 animacji** — word-highlight, word-by-word, karaoke, bounce, typewriter, static
- **Transkrypcja AI** — Whisper bezpośrednio w przeglądarce (Transformers.js)
- **Dual rendering** — client-side (FFmpeg.wasm) lub server-side (FFmpeg na workerze)
- **REST API** — 21 endpointów do programowego użycia
- **Import/export SRT** — kompatybilność z innymi narzędziami

## Stack (6 kontenerów)

| Kontener | Obraz | Rola | RAM |
|----------|-------|------|-----|
| nginx | nginx:alpine | Reverse proxy + rate limiting | 64M |
| web | Build (Next.js/Bun) | Główna aplikacja | 512M |
| worker | Build (Bun + FFmpeg) | Renderowanie wideo | 512M |
| postgres | postgres:16-alpine | Baza danych | 256M |
| redis | redis:7-alpine | Kolejka zadań (BullMQ) | 64M |
| minio | minio/minio | Object storage (wideo) | 256M |

## Instalacja

```bash
./local/deploy.sh subtitle-burner --ssh=mikrus --domain-type=cytrus --domain=auto
```

## Konfiguracja email (opcjonalnie)

Dla magic link auth edytuj `.env` na serwerze:

```bash
ssh mikrus 'nano /opt/stacks/subtitle-burner/.env'
# Ustaw: SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, EMAIL_FROM
ssh mikrus 'cd /opt/stacks/subtitle-burner && docker compose restart web'
```

## Źródło

https://github.com/jurczykpawel/subtitle-burner
