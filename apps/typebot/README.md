# Typebot - Chatbots and Forms

Typebot is a visual chatbot builder that replaces expensive tools like Typeform.

## Installation

```bash
./local/deploy.sh typebot
```

## "Lazy Engineer" Integration
Typebot is the "entry point" to your system.
1. Client fills out the bot.
2. Bot sends data to **n8n** via webhook.
3. n8n saves data in **NocoDB** and sends a proposal via **Listmonk**.

## Requirements

- **RAM:** ~600MB (Builder + Viewer)
- **Disk:** ~3GB (2x Next.js image)
- **Database:** PostgreSQL (dedicated -- bundled shared DB does not work, PG 12 lacks `gen_random_uuid()`)

> **The bundled shared database does NOT work!** Typebot uses Prisma, which requires `gen_random_uuid()` -- not available on shared PostgreSQL 12. You need a dedicated PostgreSQL database.

## Resource Note
Typebot consists of two parts: Builder (for creating) and Viewer (what the client sees). Both need ~600MB RAM combined, so keep this in mind when planning services on a single VPS.
