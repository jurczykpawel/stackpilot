# WordPress - Performance Edition

Najpopularniejszy CMS na świecie, zoptymalizowany pod małe serwery VPS.

**TTFB ~200ms** z cache (vs 2-5s na typowych hostingach). Zero konfiguracji — wszystko automatyczne.

## Co jest w środku?

Stack wydajnościowy — to co dostajesz u Kinsta ($35/mies) czy WP Engine ($25/mies):

```
Cytrus/Caddy (host) → Nginx (gzip, FastCGI cache, rate limiting, security)
                        └── PHP-FPM alpine (OPcache + JIT, redis ext, WP-CLI)
                        └── Redis (object cache, bundled)
                             └── MySQL (zewnętrzny) lub SQLite
```

### Optymalizacje (automatyczne, zero konfiguracji)

| Optymalizacja | Co daje | Na managed hostingu |
|---|---|---|
| Nginx FastCGI cache + auto-purge | Cached strony ~200ms TTFB (bez PHP i DB) | wliczone w plan $25-35/mies |
| Redis Object Cache (drop-in) | -70% zapytań do DB | Kinsta: addon $100/mies (!) |
| PHP-FPM alpine (nie Apache) | -35MB RAM, mniejszy obraz | standard |
| OPcache + JIT | 2-3x szybszy PHP | standard |
| Nginx Helper plugin (auto-purge) | Cache czyszczony przy edycji treści | wbudowane w Kinsta/WP Engine |
| WooCommerce-aware cache rules | Koszyk/checkout omija cache, reszta cachowana | WP Rocket ~$59/rok |
| session.cache_limiter bypass | Cache działa z Breakdance/Elementor (session_start fix) | ręczna konfiguracja |
| fastcgi_ignore_headers | Nginx cachuje mimo Set-Cookie z page builderów | ręczna konfiguracja |
| FastCGI cache lock | Ochrona przed thundering herd (1 req do PHP) | Nginx — darmowe, ale trzeba umieć |
| Gzip compression | -60-80% transferu | standard |
| Open file cache | -80% disk I/O na statycznych plikach | standard |
| Realpath cache 4MB | -30% response time (mniej stat() calls) | ręczna konfiguracja |
| FPM ondemand + RAM tuning | Dynamiczny profil na podstawie RAM serwera | managed hosting |
| tmpfs /tmp | 20x szybsze I/O dla temp files | ręczna konfiguracja |
| Security headers | X-Frame, X-Content-Type, Referrer-Policy | standard |
| Rate limiting wp-login | Ochrona brute force bez obciążania PHP | plugin lub ręcznie |
| Blokada xmlrpc.php | Zamknięty wektor DDoS | plugin lub ręcznie |
| Blokada user enumeration | ?author=N → 403 | plugin lub ręcznie |
| WP-Cron → system cron | Brak opóźnień dla odwiedzających | ręczna konfiguracja |
| Autosave co 5 min | -80% zapisów do DB (domyślne 60s) | ręczna konfiguracja |
| Blokada wrażliwych plików | wp-config.php, .env, uploads/*.php | plugin lub ręcznie |
| no-new-privileges | Kontener nie eskaluje uprawnień | Docker know-how |
| Log rotation | Logi nie zapchają dysku (max 30MB) | standard |
| Converter for Media (WebP) | Auto-konwersja obrazów do WebP (-25-35% vs JPEG) | plugin + ręczna konfig. |

**Porównanie cenowe:** Kinsta od $35/mies, WP Engine od $25/mies, Redis addon u Kinsta $100/mies.
Na Mikrusie: **75 PLN/rok** (~6 PLN/mies) za Mikrus 2.1 (1GB RAM) + darmowy shared MySQL.

### Benchmark: TTFB

| Metryka | Shared hosting | Mikrus WP |
|---|---|---|
| TTFB (strona główna) | 800-3000ms | **~200ms** (cache HIT) |
| TTFB (cold, bez cache) | 2000-5000ms | **300-400ms** |
| TTFB z Breakdance/Elementor | 2000-5000ms (session kill cache) | **~200ms** (session bypass) |

### Porównanie z polskimi hostingami WordPress

Ceny odnowienia (nie promocyjne pierwszego roku). Plany porównywalne z 1 GB RAM.

| Hosting | Cena/rok | RAM | Redis | Server cache | Auto-purge | WooCommerce rules |
|---|---|---|---|---|---|---|
| **Mikrus 2.1 + Toolbox** | **75 PLN** | 1 GB | wbudowany | FastCGI 24h | Nginx Helper | auto |
| Smarthost Pro Mini | ~170 PLN | 1 GB | tak | LSCache | plugin | ręcznie |
| LH.pl Orange | 199 PLN* | 1 GB | **brak** | **brak** | brak | brak |
| MyDevil MD1 | 200 PLN | 1 GB | tak (ręczna konfig.) | **brak** | brak | brak |
| dhosting EWH | 359 PLN* | auto-scale | tak | LSCache | plugin | ręcznie |
| cyber_Folks wp_START! | 328 PLN** | 2 GB NVMe | tak | LSCache | plugin | ręcznie |
| nazwa.pl WP Start | 360 PLN* | 8 GB | b/d | b/d | b/d | b/d |
| Zenbox Firma 10k | 648 PLN | b/d | **brak** | LSCache | plugin | ręcznie |

\* cena netto (bez VAT 23%) | \*\* 299 PLN plan + 29 PLN SSL, limit transferu 250 GB/mies

**Co Mikrus + Toolbox daje za 75 PLN/rok, a czego brak na shared hostingu:**
- Redis Object Cache — u LH.pl dopiero od planu Mango (399 PLN/rok netto), u Kinsta addon $100/mies
- Nginx FastCGI cache z auto-purge — na shared hostingach trzeba ręcznie konfigurować LiteSpeed Cache plugin
- WooCommerce skip rules — trzeba kupić WP Rocket (~$59/rok) albo konfigurować ręcznie
- Breakdance/Elementor session fix — na żadnym shared hostingu, trzeba wiedzieć co ustawić
- Nielimitowany transfer — np. cyber_Folks wp_START! (328 PLN/rok) ma limit 250 GB/mies
- Darmowy SSL (Cytrus/Caddy) — u cyber_Folks SSL to dodatkowe 29 PLN/rok
- Pełny root + Docker — na shared hostingach niedostępny
- **Serwer, nie tylko hosting WP** — na tym samym Mikrusie obok WordPressa postawisz strony statyczne, n8n, Uptime Kuma, Vaultwarden, NocoDB i [25 innych aplikacji](../../AGENTS.md). Shared hosting = tylko WordPress

## Instalacja

### Tryb MySQL (domyślny)

```bash
# Shared MySQL z Mikrusa (darmowy)
./local/deploy.sh wordpress --ssh=mikrus --domain-type=cytrus --domain=auto

# Własny MySQL
./local/deploy.sh wordpress --ssh=mikrus --db-source=custom --domain-type=cytrus --domain=auto
```

### Tryb SQLite (lekki, bez MySQL)

```bash
WP_DB_MODE=sqlite ./local/deploy.sh wordpress --ssh=mikrus --domain-type=cytrus --domain=auto
```

### Redis (external vs bundled)

Domyślnie auto-detekcja: jeśli port 6379 nasłuchuje na serwerze, WordPress łączy się z istniejącym Redis (bez nowego kontenera). W przeciwnym razie bundluje `redis:alpine`.

```bash
# Wymuś bundled Redis (nawet gdy istnieje external)
WP_REDIS=bundled ./local/deploy.sh wordpress --ssh=mikrus

# Wymuś external Redis (host)
WP_REDIS=external ./local/deploy.sh wordpress --ssh=mikrus

# External Redis z hasłem
REDIS_PASS=tajneHaslo WP_REDIS=external ./local/deploy.sh wordpress --ssh=mikrus

# Auto-detekcja (domyślne)
./local/deploy.sh wordpress --ssh=mikrus
```

## Wiele stron WordPress na jednym serwerze

Każdy deploy z osobną domeną tworzy niezależną instancję:

```bash
./local/deploy.sh wordpress --domain=blog.example.com    # → /opt/stacks/wordpress-blog/
./local/deploy.sh wordpress --domain=shop.example.com    # → /opt/stacks/wordpress-shop/
./local/deploy.sh wordpress --domain=news.example.com    # → /opt/stacks/wordpress-news/
```

Co jest współdzielone, a co osobne:

| Element | Współdzielony? |
|---|---|
| Redis | tak — jeden `redis-shared` na `127.0.0.1:6379` (instalowany automatycznie) |
| Nginx | nie — osobny per instancja |
| PHP-FPM | nie — osobny per instancja |
| Pliki WP | nie — osobny volume per instancja |
| Redis klucze | izolowane prefiksem (`wordpress-blog:`, `wordpress-shop:`) |

Każda dodatkowa strona to ~80MB RAM (PHP-FPM + Nginx). Redis współdzielony oszczędza ~96MB vs osobny per site.

## Wymagania

- **RAM:** ~80-100MB idle (WP + Nginx + Redis), działa na Mikrus 2.1 (1GB RAM)
- **Dysk:** ~550MB (obrazy Docker: WP+redis ext, Nginx, Redis)
- **MySQL:** Shared Mikrus (darmowy) lub własny. SQLite nie wymaga.

## Po instalacji

1. Otwórz stronę → kreator instalacji WordPress (jedyny ręczny krok)

Optymalizacje `wp-init.sh` uruchamiają się **automatycznie** po kreatorze. Nie trzeba nic robić ręcznie.

`wp-init.sh` automatycznie:
- Generuje `wp-config-performance.php` (HTTPS fix, limity, Redis config)
- Instaluje, aktywuje i **konfiguruje** plugin **Redis Object Cache** — włącza drop-in (`wp redis enable`), gotowy od razu
- Instaluje, aktywuje i **konfiguruje** plugin **Nginx Helper** — ustawia file-based purge, auto-purge przy edycji/usunięciu/komentarzu
- Instaluje i aktywuje plugin **Converter for Media** — nowe obrazy konwertowane do WebP automatycznie, nginx serwuje WebP bez dodatkowej konfiguracji
- Dodaje systemowy cron co 5 min (zastępuje wp-cron)
- Czyści FastCGI cache po konfiguracji

**Wszystkie pluginy działają od razu — zero konfiguracji w panelu WordPress.**

Jeśli WordPress nie jest jeszcze zainicjalizowany, wp-init.sh ustawia retry cron (co minutę, max 30 prób) i dokończy konfigurację automatycznie.

## FastCGI Cache

Strony są cache'owane przez Nginx na 24h. **TTFB ~200ms** z cache vs 300-3000ms bez.

### Automatyczny purge (Nginx Helper)

Plugin Nginx Helper automatycznie czyści cache gdy:
- Edytujesz/publikujesz stronę lub post
- Usuwasz stronę lub post
- Ktoś dodaje/usuwa komentarz
- Aktualizujesz menu lub widgety

Tryb: **file-based purge** (unlink_files) — najszybszy, bez HTTP requests.

### Skip cache rules

Cache jest automatycznie pomijany dla:
- Zalogowanych użytkowników (cookie `wordpress_logged_in`)
- Panelu admina (`/wp-admin/`)
- API (`/wp-json/`)
- Requestów POST
- **WooCommerce:** koszyk, checkout, my-account (cookie `woocommerce_cart_hash`)

### Kompatybilność z page builderami

Breakdance, Elementor i inne page buildery wywołują `session_start()`, co domyślnie wysyła `Cache-Control: no-store` i blokuje cachowanie. Nasze rozwiązanie:
- `session.cache_limiter =` — PHP nie wysyła nagłówka Cache-Control
- `fastcgi_ignore_headers Cache-Control Expires Set-Cookie` — Nginx cachuje mimo Set-Cookie

**Efekt:** strony z Breakdance cachowane normalnie (~200ms vs 2-5s na innych hostingach).

### Thundering herd protection

Gdy wielu użytkowników prosi o tę samą niecachowaną stronę, tylko 1 request trafia do PHP-FPM, reszta czeka na cache. `fastcgi_cache_background_update` serwuje stale content podczas odświeżania.

### Ręczne czyszczenie cache

```bash
ssh mikrus 'cd /opt/stacks/wordpress && ./flush-cache.sh'
```

Header `X-FastCGI-Cache` w odpowiedzi HTTP pokazuje status: `HIT`, `MISS`, `BYPASS`.

### Dlaczego Nginx, a nie LiteSpeed?

Wiele polskich hostingów reklamuje się "LiteSpeed Cache". To brzmi jak przewaga, ale niezależne benchmarki pokazują co innego:

**Z włączonym cache obie technologie dają praktycznie identyczny TTFB.** Obie serwują stronę z cache na poziomie serwera, bez dotykania PHP i bazy danych.

Niezależne testy (nie marketing hostingów):

| Test | Nginx | OpenLiteSpeed | Różnica | Źródło |
|---|---|---|---|---|
| Cached TTFB | 67ms | 68ms | **1ms** | [WPJohnny](https://wpjohnny.com/nginx-vs-openlitespeed-speed-comparison/) |
| Throughput (cached) | 26 880 hits | 26 748 hits | **0.5%** | [RunCloud](https://runcloud.io/blog/openlitespeed-vs-nginx-vs-apache) |
| Uncached req/sec | **40 req/s** | 23 req/s | **Nginx 1.75x szybszy** | [WPJohnny](https://wpjohnny.com/litespeed-vs-nginx/) |

Cytat z WPJohnny (niezależny konsultant WP): *"OpenLiteSpeed and NGINX are just about equal in performance with caching on. Anybody claiming one is incredibly superior than the other is either biased or hasn't tested them side-by-side."*

Co więcej — **na stronach bez cache (MISS) Nginx + PHP-FPM jest szybszy** niż OpenLiteSpeed.

| | Nginx FastCGI cache (my) | LiteSpeed LSCache |
|---|---|---|
| TTFB (cache HIT) | ~200ms | ~200ms |
| TTFB (cache MISS) | **szybszy** (PHP-FPM) | wolniejszy |
| Auto-purge | Nginx Helper (plugin) | LSCache (plugin) |
| Redis Object Cache | tak (bundled) | tak (jeśli hosting daje) |
| Gzip | tak (-82% transferu) | tak |
| WooCommerce rules | auto (skip_cache) | ręczna konfig. w plugin |
| Breakdance/Elementor fix | auto (session.cache_limiter) | ręczna konfig. |

Hostingi chwalą się LiteSpeed, bo mają go w infrastrukturze. My mamy Nginx z FastCGI cache — **ten sam TTFB na cached, szybszy na uncached**. "LiteSpeed" to nazwa serwera, nie magiczne przyspieszenie.

## Dodatkowa optymalizacja (ręczna)

### Cloudflare Edge Cache

Przy deploy z `--domain-type=cloudflare`, optymalizacja zone i cache rules uruchamia się **automatycznie**.

Ręczne uruchomienie (np. po zmianie domeny):
```bash
./local/setup-cloudflare-optimize.sh wp.mojadomena.pl --app=wordpress
```

Co ustawia:
- **Zone:** SSL Flexible, Brotli, Always HTTPS, HTTP/2+3, Early Hints
- **Bypass cache:** `/wp-admin/*`, `/wp-login.php`, `/wp-json/*`, `/wp-cron.php`
- **Cache 1 rok:** `/wp-content/uploads/*` (media), `/wp-includes/*` (core static)
- **Cache 1 tydzień:** `/wp-content/themes/*`, `/wp-content/plugins/*` (assets)

Cloudflare edge cache działa **nad** Nginx FastCGI cache - statyki serwowane z CDN bez dotykania serwera. Dla stron HTML FastCGI cache jest lepszy (zna kontekst zalogowanego usera).

### Converter for Media (WebP)

Plugin **Converter for Media** jest instalowany i aktywowany automatycznie. Nowe obrazy uploadowane do Media Library są konwertowane do WebP od razu.

Aby skonwertować istniejące obrazy, użyj bulk conversion w panelu WP (Media → Converter for Media → Start Bulk Optimization) lub WP-CLI:

```bash
ssh mikrus 'docker exec $(docker compose -f /opt/stacks/wordpress/docker-compose.yaml ps -q wordpress) wp converter-for-media regenerate --path=/var/www/html'
```

## Security

| Zabezpieczenie | Opis |
|---|---|
| Rate limiting wp-login.php | 1 req/s z burst 3 (429 Too Many Requests) |
| xmlrpc.php zablokowany | deny all (wektor DDoS i brute force) |
| User enumeration blocked | ?author=N → 403 |
| Edycja plików z panelu WP | Zablokowana (DISALLOW_FILE_EDIT) |
| PHP w uploads/ | Zablokowane (deny all) |
| no-new-privileges | Kontener nie może eskalować uprawnień |
| Security headers | X-Frame, X-Content-Type, Referrer-Policy, Permissions-Policy |

## Backup

```bash
./local/setup-backup.sh mikrus
```

Dane w `/opt/stacks/wordpress/`:
- `wp-content/` - wtyczki, motywy, uploady, baza SQLite
- `config/` - konfiguracja PHP/Nginx/FPM
- `redis-data/` - cache Redis
- `docker-compose.yaml`

## RAM Profiling

Skrypt automatycznie wykrywa RAM i dostosowuje PHP-FPM:

| RAM serwera | FPM workers | WP limit | Nginx limit |
|---|---|---|---|
| 512MB | 4 | 192M | 32M |
| 1GB | 8 | 256M | 48M |
| 2GB+ | 15 | 256M | 64M |

Redis: 64MB maxmemory (allkeys-lru) + 96MB Docker limit dla wszystkich profili.
