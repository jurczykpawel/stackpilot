# ConvertX - Universal File Converter

Self-hosted file converter supporting 1000+ formats: images, documents, audio, video, e-books, 3D models.

## Installation

```bash
./local/deploy.sh convertx --ssh=ALIAS --domain-type=caddy --domain=convertx.your-domain.com
```

## Requirements

- **RAM:** ~70MB idle, ~150MB during conversion (container limit: 512MB)
- **Disk:** ~5GB (Docker image with bundled tools: LibreOffice, FFmpeg, texlive, Calibre...)
- **Database:** SQLite (built-in, data in `./data/`)

## After Installation

1. Open the page and create an admin account
2. **Disable registration** after creating your account:
   ```bash
   ssh ALIAS 'cd /opt/stacks/convertx && sed -i "s/ACCOUNT_REGISTRATION=true/ACCOUNT_REGISTRATION=false/" docker-compose.yaml && docker compose up -d'
   ```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `JWT_SECRET` | (generated) | JWT secret - install.sh generates automatically |
| `ACCOUNT_REGISTRATION` | true | New account registration (disable after setup!) |
| `AUTO_DELETE_EVERY_N_HOURS` | 24 | Auto-delete files (0 = disable) |
| `TZ` | Europe/Warsaw | Timezone |
| `ALLOW_UNAUTHENTICATED` | false | Access without login (do not use in production!) |
| `HIDE_HISTORY` | false | Hide history tab |
| `WEBROOT` | / | Base path (e.g. `/convert` for subdirectory) |
| `FFMPEG_ARGS` | (empty) | Extra FFmpeg arguments (e.g. `-hwaccel cuda`) |

## Conversion Backends

ConvertX bundles 20+ tools in a single Docker image:

| Backend | Formats |
|---------|---------|
| FFmpeg | Video, audio (MP4, WebM, MP3, FLAC...) |
| LibreOffice | Office documents (DOCX, XLSX, PPTX to PDF) |
| Vips + GraphicsMagick | Images (PNG, JPG, WebP, AVIF, HEIC, TIFF) |
| Pandoc | Text documents (Markdown, HTML, LaTeX) |
| Calibre | E-books (EPUB, MOBI, AZW3, PDF) |
| Inkscape | Vector graphics (SVG) |
| ImageMagick | Advanced image processing |

## Limitations

- **Large files** - ConvertX loads files into RAM during conversion. With a 512MB limit, files >200MB may cause issues. For large files, increase `memory` in docker-compose.yaml.
- **Slow start** - First start takes ~60s (checking versions of 20+ bundled tools)
- **Large image** - ~5GB on disk; on a 10GB VPS that is half the disk
- **No SSO/OAuth** - only local accounts with JWT
- **Single-threaded** - no horizontal scalability

## Backup

```bash
./local/setup-backup.sh ALIAS
```

Data in `/opt/stacks/convertx/data/`:
- SQLite database (accounts, history)
- Files during conversion (auto-cleaned every 24h)
