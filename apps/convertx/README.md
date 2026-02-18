# ConvertX - Uniwersalny Konwerter Plików

Self-hosted konwerter plików obsługujący 1000+ formatów: obrazy, dokumenty, audio, wideo, e-booki, modele 3D.

## Instalacja

```bash
./local/deploy.sh convertx --ssh=mikrus --domain-type=cytrus --domain=auto
```

## Wymagania

- **RAM:** ~70MB idle, ~150MB podczas konwersji (limit kontenera: 512MB)
- **Dysk:** ~5GB (obraz Docker z bundlowanymi narzędziami: LibreOffice, FFmpeg, texlive, Calibre...)
- **Baza danych:** SQLite (wbudowany, dane w `./data/`)

## Po instalacji

1. Otwórz stronę → utwórz konto administratora
2. **Wyłącz rejestrację** po utworzeniu konta:
   ```bash
   ssh mikrus 'cd /opt/stacks/convertx && sed -i "s/ACCOUNT_REGISTRATION=true/ACCOUNT_REGISTRATION=false/" docker-compose.yaml && docker compose up -d'
   ```

## Zmienne środowiskowe

| Zmienna | Domyślna | Opis |
|---------|----------|------|
| `JWT_SECRET` | (generowany) | Sekret JWT - install.sh generuje automatycznie |
| `ACCOUNT_REGISTRATION` | true | Rejestracja nowych kont (wyłącz po setup!) |
| `AUTO_DELETE_EVERY_N_HOURS` | 24 | Auto-usuwanie plików (0 = wyłącz) |
| `TZ` | Europe/Warsaw | Strefa czasowa |
| `ALLOW_UNAUTHENTICATED` | false | Dostęp bez logowania (nie używaj w produkcji!) |
| `HIDE_HISTORY` | false | Ukryj zakładkę historii |
| `WEBROOT` | / | Ścieżka bazowa (np. `/convert` dla subdirectory) |
| `FFMPEG_ARGS` | (puste) | Dodatkowe argumenty FFmpeg (np. `-hwaccel cuda`) |

## Backendy konwersji

ConvertX bundluje 20+ narzędzi w jednym obrazie Docker:

| Backend | Formaty |
|---------|---------|
| FFmpeg | Wideo, audio (MP4, WebM, MP3, FLAC...) |
| LibreOffice | Dokumenty Office (DOCX, XLSX, PPTX → PDF) |
| Vips + GraphicsMagick | Obrazy (PNG, JPG, WebP, AVIF, HEIC, TIFF) |
| Pandoc | Dokumenty tekstowe (Markdown, HTML, LaTeX) |
| Calibre | E-booki (EPUB, MOBI, AZW3, PDF) |
| Inkscape | Grafika wektorowa (SVG) |
| ImageMagick | Zaawansowana obróbka obrazów |

## Ograniczenia

- **Duże pliki** - ConvertX ładuje pliki do RAM podczas konwersji. Przy limicie 512MB, pliki >200MB mogą powodować problemy. Dla dużych plików zwiększ `memory` w docker-compose.yaml.
- **Wolny start** - Pierwszy start trwa ~60s (sprawdzanie wersji 20+ bundlowanych narzędzi)
- **Duży obraz** - ~5GB na dysku, na Mikrus 10GB to połowa dysku
- **Brak SSO/OAuth** - tylko lokalne konta z JWT
- **Jednowątkowy** - brak skalowalności horyzontalnej

## Backup

```bash
./local/setup-backup.sh mikrus
```

Dane w `/opt/stacks/convertx/data/`:
- Baza SQLite (konta, historia)
- Pliki w trakcie konwersji (auto-czyszczone co 24h)
