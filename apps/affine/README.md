# AFFiNE - Self-hosted Notion + Miro Alternative

Open-source knowledge base that combines documents, whiteboards, and databases in a single tool. AFFiNE gives you the flexibility of Notion for structured docs, the visual freedom of Miro for brainstorming, and a database layer for organizing everything -- all self-hosted on your own server with full data ownership.

## Installation

```bash
./local/deploy.sh affine
```

The script will ask for:
- Database configuration (bundled PostgreSQL with pgvector is the default)
- Domain (e.g. `wiki.example.com`)

## Requirements

- **PostgreSQL 16 with pgvector extension** -- bundled by default (pgvector/pgvector:pg16 image). If using an external database, ensure pgvector is installed.
- **Redis** -- bundled (redis:alpine).
- **Minimum 2GB free RAM** -- AFFiNE (1GB) + PostgreSQL (256MB) + Redis (128MB). 4GB recommended for comfortable usage.
- **Port:** 3010 (configurable)
- **Memory:** ~1.5GB total (app + postgres + redis)

## Why AFFiNE?

- **All-in-one workspace:** Docs, whiteboards, and databases in a single app. No need to switch between Notion, Miro, and Airtable.
- **Privacy-first:** Self-hosted means your notes, designs, and data never leave your server. No third-party tracking or data harvesting.
- **Block-based editor:** Rich text, code blocks, tables, Markdown support, and a canvas mode for visual thinking.
- **Open-source and free:** No per-user pricing, no feature gates. MIT-licensed with an active community.

## Architecture

AFFiNE runs as 4 containers:

| Container | Image | Purpose | Memory |
|---|---|---|---|
| affine | ghcr.io/toeverything/affine:stable | Main application | 1024MB |
| affine_migration | ghcr.io/toeverything/affine:stable | One-shot DB migration | -- |
| postgres | pgvector/pgvector:pg16 | Database with vector search | 256MB |
| redis | redis:alpine | Cache and sessions | 128MB |

## Post-Installation

1. Open your AFFiNE URL in the browser
2. Create your admin account (first registered user becomes workspace owner)
3. Optionally configure Caddy for HTTPS:

```bash
sp-expose wiki.example.com 3010
```

## FAQ

**Q: How much RAM does AFFiNE use?**
A: Around 1-1.5GB total for all containers. The main app uses ~700-900MB, PostgreSQL ~150-200MB, Redis ~30-50MB.

**Q: Can I use an external PostgreSQL database?**
A: Yes. Pass your database credentials during deployment. Make sure the pgvector extension is available -- AFFiNE requires it for vector search functionality.

**Q: How do I update AFFiNE?**
A: Run `deploy.sh affine` again. It pulls the latest `stable` image and restarts containers. Data in Docker volumes is preserved.
