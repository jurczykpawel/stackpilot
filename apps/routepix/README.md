# RoutePix

**Wizualizuj trasy podróży ze zdjęć geotagowanych.**

| | |
|---|---|
| **Obraz** | Build z repozytorium (~600MB) |
| **RAM** | ~256–512MB |
| **Dysk** | ~1GB + zdjęcia |
| **Port** | Konfigurowalny (domyślnie 3000) |
| **Baza** | SQLite (bundled, zero config) |
| **Plan** | Mikrus 2.1+ (1GB RAM) |

## Co to robi?

RoutePix zamienia zdjęcia z podróży w interaktywne mapy z trasami:

- **Upload zdjęć** → automatyczna ekstrakcja EXIF (GPS, data, orientacja)
- **Interaktywna mapa** z markerami, trasą i zdjęciami (Leaflet)
- **Import Google Photos** — OAuth2, wybierz album → mapa gotowa
- **Import KML** — trasy z Organic Maps, Google Earth
- **AI rozpoznawanie scen** — Groq, OpenRouter lub Ollama (opcjonalnie)
- **Road-snapping** — OSRM dopasowuje trasę do rzeczywistych dróg
- **Udostępnianie** — publiczne linki z opcjonalnym hasłem i wygaśnięciem
- **Magic link auth** — jeden admin, bez haseł

## Stack

| Komponent | Technologia |
|-----------|-------------|
| Frontend | Next.js 16 + Tailwind + Leaflet |
| Backend | Next.js API Routes + Prisma 7 |
| Baza | SQLite (domyślnie) lub PostgreSQL |
| Obrazy | sharp + vips |
| Auth | Magic links (JWT) |

## Instalacja

```bash
./local/deploy.sh routepix --ssh=mikrus --domain-type=cytrus --domain=auto
```

## Konfiguracja (opcjonalnie)

Edytuj `.env` na serwerze:

```bash
ssh mikrus 'nano /opt/stacks/routepix/.env'

# SMTP (wymagane do logowania):
# SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM

# AI (rozpoznawanie scen):
# AI_GROQ_API_KEY — darmowy tier na groq.com

# Google Photos:
# GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET

ssh mikrus 'cd /opt/stacks/routepix && docker compose restart'
```

## Źródło

https://github.com/jurczykpawel/routepix
