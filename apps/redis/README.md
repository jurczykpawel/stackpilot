# ⚡ Redis - Pamięć Podręczna

Szybki magazyn danych w pamięci RAM (In-Memory Key-Value Store).

## 🚀 Instalacja

```bash
./local/deploy.sh redis
```

## Wymagania

- **RAM:** ~30MB typical usage (container limit: 128MB)
- **Dysk:** ~130MB
- **Port:** 6379 (TCP, brak interfejsu HTTP)
- **Baza danych:** Nie

## 💡 Do czego Ci się przyda?
Redis to "wspomagacz" dla innych aplikacji.
- **Cache dla n8n:** Przyspiesza działanie workflowów.
- **Kolejki:** Jeśli używasz Chatwoot lub innych zaawansowanych narzędzi, często wymagają Redisa do kolejkowania zadań w tle.
- **Pamięć tymczasowa:** Możesz używać Redisa w n8n do przechowywania stanu między wykonaniami workflowu (np. "czy wysłałem już maila do tego usera w ciągu ostatniej godziny?").