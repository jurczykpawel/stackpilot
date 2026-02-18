# Security Policy

## Zgłaszanie podatnosci / Reporting Vulnerabilities

**Nie zgłaszaj podatności bezpieczeństwa przez publiczne Issues!**

Zamiast tego:

1. Użyj [GitHub Security Advisories](https://github.com/jurczykpawel/stackpilot/security/advisories/new) (prywatne)
2. Lub napisz e-mail na adres podany w profilu autora

### Co zawrzeć w zgłoszeniu

- Opis podatności
- Kroki do reprodukcji
- Potencjalny wpływ
- Sugerowana naprawa (opcjonalnie)

### Czas reakcji

- Potwierdzenie zgłoszenia: **48h**
- Pierwsza ocena: **7 dni**
- Naprawa krytycznych podatności: **14 dni**

## Wspierane wersje

| Wersja | Wsparcie |
|--------|----------|
| main   | Aktywne  |

## Zakres

Projekt obejmuje:
- Skrypty bash (lib/, local/, system/, apps/)
- Serwer MCP (mcp-server/)
- Konfiguracje Docker (apps/*/install.sh)

### Poza zakresem
- Podatności w upstream aplikacjach (n8n, Uptime Kuma, etc.)
- Problemy wynikające z niepoprawnej konfiguracji SSH
- Ataki wymagające fizycznego dostępu do serwera

## Dobre praktyki

Jeśli używasz StackPilot:
- Zawsze aktualizuj do najnowszej wersji
- Nie przechowuj haseł w zmiennych środowiskowych w historii shella
- Używaj SSH kluczy zamiast haseł
- Ogranicz dostęp do panelu admina aplikacji
