# Jak kontrybuować do StackPilot

Dzięki, że chcesz pomóc! Każdy wkład jest mile widziany - od poprawki literówki po nową aplikację.

## Jak dodać nową aplikację

### 1. Utwórz strukturę

```
apps/twoja-appka/
├── install.sh     # Skrypt instalacyjny (wymagany)
└── README.md      # Dokumentacja (wymagany)
```

### 2. Header install.sh

Każdy `install.sh` musi zaczynać się od standardowego nagłówka:

```bash
#!/bin/bash

# StackPilot - Nazwa Aplikacji
# Krótki opis po angielsku (1 linia)
# Author: Twoje Imię
#
# IMAGE_SIZE_MB=XXX  # nazwa-obrazu:tag (szacowany rozmiar na dysku)
#
# Opcjonalne komentarze o wymaganiach
```

**IMAGE_SIZE_MB** jest wymagany - `deploy.sh` używa go do sprawdzania czy serwer ma dość miejsca na dysku.

### 3. Wzorzec install.sh

```bash
#!/bin/bash

# StackPilot - MojaAppka
# Description in English
# Author: Your Name
#
# IMAGE_SIZE_MB=300  # myapp:latest

set -e

APP_NAME="mojaappka"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8080}

# Tworzenie katalogu
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Docker Compose
cat <<EOF | sudo tee docker-compose.yaml
services:
  app:
    image: myapp:latest
    restart: always
    ports:
      - "$PORT:8080"
    volumes:
      - ./data:/data
EOF

# Start
sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 60
fi
```

### 4. README.md aplikacji

Minimum:

```markdown
# Nazwa Aplikacji

Opis co to robi i co zastępuje.

## Instalacja

\`\`\`bash
./local/deploy.sh nazwa-appki
\`\`\`

## Wymagania

- **RAM:** ~XXX MB
- **Dysk:** ~XXX MB
- **Port:** XXXX
- **Baza danych:** Nie / PostgreSQL / MySQL

## Po instalacji

Instrukcje konfiguracji po pierwszym uruchomieniu.
```

### 5. Zarejestruj w AGENTS.md

Dodaj swoją appkę do listy w sekcji "Dostępne aplikacje" w `AGENTS.md`.

---

## Zgłaszanie bugów

Otwórz [Issue](https://github.com/jurczykpawel/stackpilot/issues) z:
- Nazwa aplikacji
- Serwer (plan Mikrusa, RAM)
- Logi błędu (`docker compose logs --tail 30`)
- Komenda, którą uruchomiłeś

## Pull Requesty

1. Forkuj repo
2. Utwórz branch (`git checkout -b feat/nowa-appka`)
3. Przetestuj na prawdziwym serwerze (lub przez `tests/test-apps.sh`)
4. Otwórz PR z opisem co i dlaczego

## Styl kodu

- **Bash** z `set -e` na początku
- **Komunikaty dla użytkownika po polsku** (komentarze w kodzie mogą być po angielsku)
- **Zmienne** w `UPPER_CASE`
- Używaj `sudo` przed `docker compose` i operacjami na `/opt/stacks/`
- Korzystaj z bibliotek w `lib/` (health-check, db-setup, domain-setup) zamiast pisać od nowa

## Testowanie

```bash
# Test pojedynczej appki na serwerze
SSH_HOST=twoj-serwer ./tests/test-apps.sh nazwa-appki

# Test wszystkich appek
SSH_HOST=twoj-serwer ./tests/test-apps.sh
```

---

## Bezpieczenstwo

Znalazles podatnosc? **Nie twórz publicznego Issue!**

Zamiast tego uzyj [GitHub Security Advisories](https://github.com/jurczykpawel/stackpilot/security/advisories/new)
lub napisz prywatnie do autora. Szczegoly w [SECURITY.md](SECURITY.md).

---

## Licencja

Kontrybuując, zgadzasz się na udostępnienie swojego kodu na licencji [MIT](LICENSE).
