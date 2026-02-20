# Umami - Privacy-Friendly Analytics

Simple, fast and private alternative to Google Analytics. GDPR-compliant without annoying cookie banners.

## Installation

```bash
./local/deploy.sh umami
```

**Requirements:**
- PostgreSQL with the **pgcrypto** extension
- The bundled shared database does NOT work (no permissions to create extensions)
- Use a dedicated PostgreSQL instance

## Why Umami?
- **You own your data:** Google does not sell your stats to advertisers.
- **Lightweight:** The tracking script weighs < 2KB. Your site loads faster.
- **Sharing:** You can generate a public stats link for your client.
