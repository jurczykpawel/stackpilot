# Tunel SSH - dostęp do aplikacji bez domeny

## Co to jest?

Tunel SSH to "magiczny portal" który łączy port na Twoim komputerze z portem na serwerze. Dzięki temu możesz otworzyć aplikację w przeglądarce **bez konfigurowania domeny i DNS**.

## Kiedy to przydatne?

- Testujesz aplikację przed wystawieniem publicznym
- Nie masz jeszcze domeny
- Chcesz szybko zerknąć czy coś działa
- Dostęp do paneli administracyjnych które nie powinny być publiczne

## Jak uruchomić tunel?

```bash
# Składnia: ssh -L lokalny_port:localhost:zdalny_port alias_serwera
ssh -L 5001:localhost:5001 mikrus
```

Teraz otwórz w przeglądarce: `http://localhost:5001` - zobaczysz Dockge!

## Popularne porty

| Usługa | Port | Komenda tunelu |
|--------|------|----------------|
| Dockge | 5001 | `ssh -L 5001:localhost:5001 mikrus` |
| n8n | 5678 | `ssh -L 5678:localhost:5678 mikrus` |
| Uptime Kuma | 3001 | `ssh -L 3001:localhost:3001 mikrus` |
| ntfy | 8085 | `ssh -L 8085:localhost:8085 mikrus` |
| Vaultwarden | 8088 | `ssh -L 8088:localhost:8088 mikrus` |
| FileBrowser | 8095 | `ssh -L 8095:localhost:8095 mikrus` |

## Pro tip: wiele tuneli naraz

```bash
ssh -L 5001:localhost:5001 -L 5678:localhost:5678 -L 3001:localhost:3001 mikrus
```

## Jak wyjść z tunelu?

`exit`, `Ctrl+D`, lub po prostu zamknij terminal.

> Tunel działa tylko gdy terminal jest otwarty. Zamknięcie terminala = koniec tunelu.
