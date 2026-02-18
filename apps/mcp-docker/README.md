# 🤖 Docker MCP Server - Interfejs dla AI

Most łączący Twojego Agenta AI (Claude, Gemini, Cursor) z Twoim serwerem.

## 🚀 Instalacja

```bash
./local/deploy.sh mcp-docker
```

## Wymagania

- **RAM:** ~10MB
- **Dysk:** ~100MB
- **Port:** brak (protokół MCP przez SSH)
- **Baza danych:** Nie

## 🧠 Co to daje?
Dzięki temu narzędziu, Twój asystent AI na komputerze lokalnym może "widzieć" i kontrolować kontenery na Mikrusie przez bezpieczny tunel SSH.

**Przykłady poleceń dla Agenta:**
- "Sprawdź, dlaczego kontener n8n się zrestartował (pokaż logi)."
- "Wylistuj wszystkie kontenery, które zużywają więcej niż 100MB RAM."
- "Zrestartuj Caddy."

To jest prawdziwy **"God Mode"** dla zarządzania infrastrukturą.