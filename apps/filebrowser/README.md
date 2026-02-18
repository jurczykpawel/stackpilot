# FileBrowser - Tiiny.host Killer

Prywatny dysk + publiczny hosting plików. Zamiennik Tiiny.host za ułamek ceny.

**RAM:** ~160MB (FileBrowser + nginx) | **Dysk:** zależy od plików | **Plan:** Mikrus 2.1+

---

## Szybki start (jedna komenda)

### Cytrus - pełny setup

```bash
DOMAIN_PUBLIC=static.byst.re ./local/deploy.sh filebrowser \
  --ssh=mikrus \
  --domain-type=cytrus \
  --domain=files.byst.re \
  --yes
```

### Cloudflare - pełny setup

```bash
DOMAIN_PUBLIC=static.example.com ./local/deploy.sh filebrowser \
  --ssh=mikrus \
  --domain-type=cloudflare \
  --domain=files.example.com \
  --yes
```

Po instalacji masz:
- `https://files.byst.re` - panel admin (logowanie)
- `https://static.byst.re` - publiczne pliki (bez logowania)

---

## Scenariusze instalacji

### 1. Pełny setup (admin + public)

```bash
# Cytrus
DOMAIN_PUBLIC=static.byst.re ./local/deploy.sh filebrowser \
  --ssh=mikrus --domain-type=cytrus --domain=files.byst.re --yes

# Cloudflare
DOMAIN_PUBLIC=static.example.com ./local/deploy.sh filebrowser \
  --ssh=mikrus --domain-type=cloudflare --domain=files.example.com --yes
```

### 2. Tylko admin (bez public hosting)

```bash
./local/deploy.sh filebrowser --ssh=mikrus
```

Przydatne gdy:
- Chcesz tylko prywatny dysk
- Dodasz public hosting później
- Testujesz przed produkcją

### 3. Dodanie public hosting później

Jeśli zainstalowałeś bez DOMAIN_PUBLIC, możesz dodać go jedną komendą:

```bash
# Cytrus
./local/add-static-hosting.sh static.byst.re mikrus

# Cloudflare
./local/add-static-hosting.sh static.example.com mikrus
```

Skrypt automatycznie:
- Uruchomi nginx dla Cytrus lub skonfiguruje Caddy dla Cloudflare
- Zarejestruje domenę
- Skonfiguruje katalog /var/www/public

**Opcje:**
```bash
./local/add-static-hosting.sh DOMENA [SSH_ALIAS] [KATALOG] [PORT]

# Przykłady:
./local/add-static-hosting.sh static.byst.re                    # domyślne
./local/add-static-hosting.sh cdn.byst.re mikrus /var/www/cdn   # własny katalog
./local/add-static-hosting.sh assets.byst.re mikrus /var/www/assets 8097  # własny port
```

---

## Jak to działa

```
┌─────────────────────────────────────────────────────────────┐
│  files.example.com (ADMIN)                                  │
│  → FileBrowser z logowaniem                                 │
│  → Upload, edycja, kasowanie plików                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ pliki w /var/www/public/
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  static.example.com (PUBLIC)                                │
│  → Bezpośredni dostęp bez logowania                         │
│  → https://static.example.com/ebook.pdf                     │
└─────────────────────────────────────────────────────────────┘
```

---

## Przypadki użycia

### Lead Magnet
```
1. Wrzuć PDF przez FileBrowser
2. Link: https://static.example.com/ebook.pdf
3. Użyj w automatyzacji (n8n, Mailchimp)
```

### Landing Page
```
1. Stwórz index.html
2. Wrzuć przez FileBrowser
3. Gotowe: https://static.example.com/
```

### Oferty dla klientów
```
1. Wrzuć: oferta-kowalski.pdf
2. Wyślij: https://static.example.com/oferta-kowalski.pdf
```

---

## Porównanie kosztów

| Rozwiązanie | Cena/rok | Limity |
|-------------|----------|--------|
| Tiiny.host Pro | ~500 zł | 10 stron |
| Tiiny.host Business | ~1200 zł | 50 stron |
| **FileBrowser + Mikrus** | **~240 zł** | **bez limitów** |

---

## Architektura

### Cytrus
- FileBrowser → port 8095 → Cytrus API
- nginx:alpine → port 8096 → Cytrus API

### Cloudflare
- FileBrowser → port 8095 → Caddy reverse_proxy
- Caddy file_server → /var/www/public (bez dodatkowego portu)

---

## Zarządzanie

```bash
# Logi
ssh mikrus "docker logs -f filebrowser-filebrowser-1"

# Restart
ssh mikrus "cd /opt/stacks/filebrowser && docker compose restart"

# Aktualizacja
ssh mikrus "cd /opt/stacks/filebrowser && docker compose pull && docker compose up -d"

# Status
ssh mikrus "docker ps --filter name=filebrowser"
```

---

## Bezpieczeństwo

**Zmień hasło po pierwszym logowaniu!**
```
Domyślne: admin / admin
```

### Prywatność plików
- **Admin** (`files.*`) - wymaga logowania
- **Public** (`static.*`) - dostępne dla każdego

Dla "ukrytych" linków używaj losowych nazw: `oferta-x7k9m2.pdf`

---

## Troubleshooting

### Plik nie widoczny na public
```bash
ssh mikrus "sudo chmod -R o+r /var/www/public/"
```

### 403 Forbidden
```bash
ssh mikrus "sudo chown -R 1000:1000 /var/www/public/"
```

### Cytrus placeholder (3-5 min)
Poczekaj na propagację lub sprawdź:
```bash
ssh mikrus "curl -s localhost:8096/plik.txt"
```

### nginx nie startuje
```bash
ssh mikrus "docker logs filebrowser-static-1"
```
