# 🐳 Dockge - Panel Sterowania Kontenerami

Dockge to ultralekki interfejs do zarządzania Docker Compose. Zastępuje ciężkiego Portainera.

## 🚀 Instalacja

```bash
./local/deploy.sh dockge
```

## 💡 Dlaczego Kamil go kocha?
- **Zjada mało RAM-u:** W przeciwieństwie do Portainera, który potrafi zjeść 200MB+, Dockge bierze tyle co nic.
- **Pliki > Baza danych:** Dockge nie chowa Twoich konfiguracji w wewnętrznej bazie danych. Zarządza bezpośrednio plikami `compose.yaml` w katalogu `/opt/stacks`. Dzięki temu możesz edytować je zarówno w przeglądarce, jak i przez terminal/VS Code, i nic się nie rozjedzie.
- **Agent:** Możesz podpiąć inne serwery Mikrusa do jednego panelu.

## 🌐 Po instalacji - konfiguracja domeny

### 1. Skonfiguruj DNS
Dodaj rekord A w panelu swojego rejestratora domen (np. OVH, Cloudflare, home.pl):
- **Typ:** `A`
- **Nazwa:** `dockge` (lub inna subdomena, np. `docker`, `panel`)
- **Wartość:** IP Twojego serwera Mikrus (znajdziesz w panelu mikr.us)
- **TTL:** 3600 (lub "Auto")

> ⏳ Propagacja DNS może zająć od kilku minut do 24h. Sprawdź: `ping dockge.twojadomena.pl`

### 2. Wystaw aplikację przez HTTPS
Uruchom **na swoim komputerze** (nie na serwerze!):
```bash
ssh mikrus 'mikrus-expose dockge.twojadomena.pl 5001'
```
Zamień `mikrus` na swój alias SSH jeśli używasz innego, oraz `dockge.twojadomena.pl` na swoją domenę.

### 3. Utwórz konto admina
Przy pierwszym wejściu na `https://dockge.twojadomena.pl` Dockge poprosi o utworzenie konta administratora. Zapisz dane logowania w bezpiecznym miejscu!

## 🛠️ Jak używać?
Po konfiguracji domeny wejdź na `https://dockge.twojadomena.pl`.
Kliknij "+ Compose", wpisz nazwę (np. `wordpress`) i wklej konfigurację. To tyle.