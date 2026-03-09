# Refactor Plan: Merge mikrus-toolbox + stackpilot + Tests

Status: **COMPLETE — All phases done. E2E: 34 PASS, 2 SKIP, 0 FAIL. Phase 7.4 done. No remaining tasks.**
Base repo: `stackpilot/` (mikrus-toolbox code merges here)
Tracking: check boxes below — update as work progresses

---

## Phase 1: i18n Framework

Goal: Wydzielenie wszystkich user-facing stringów do plików locale, z domyślnym EN i opcjonalnym PL.

- [x] **1.1** Stworzyć `lib/i18n.sh` — loader tłumaczeń
  - `TOOLBOX_LANG` z configa (`~/.config/stackpilot/config`) lub env
  - Fallback: brak klucza w locale → angielski
  - Funkcja `msg()` z printf-style formatowaniem (`msg "$MSG_DEPLOYING" "$APP_NAME"`)
  - Funkcja `msg_n()` — bez trailing newline (dla progress dots)
  - ~~Funkcja `confirm()` (tak/nie z tłumaczeniem)~~ — zostaje w cli-parser.sh, i18n w Phase 1.6
- [x] **1.2** Stworzyć `locale/en.sh` — ekstrakcja stringów z istniejących skryptów
  - Zacząć od `lib/health-check.sh` jako proof of concept
  - Konwencja: `MSG_` prefix, SCREAMING_SNAKE_CASE
- [x] **1.3** Stworzyć `locale/pl.sh` — polskie tłumaczenia (z mikrus-toolbox)
- [x] **1.4** Proof of concept: przepisać `lib/health-check.sh` na i18n
  - Zweryfikowane: działa z `TOOLBOX_LANG=en`, `TOOLBOX_LANG=pl`, fallback na EN dla nieznanych locali
- [x] **1.5** Przepisać `local/deploy.sh` na i18n (największy plik — ~1118 linii)
- [x] **1.6** Przepisać pozostałe `lib/*.sh` na i18n
- [x] **1.7** Przepisać `local/*.sh` na i18n
- [x] **1.8** Przepisać `system/*.sh` na i18n
- [x] **1.9** Stworzyć `tests/static/test-locale-coverage.sh`
  - Każdy klucz w en.sh istnieje w pl.sh i odwrotnie

**Definicja "done":** Wszystkie skrypty używają `msg()`, zero hardcoded user-facing stringów, testy locale coverage przechodzą.

---

## Phase 2: Provider System (Mikrus jako plugin)

Goal: Wydzielenie kodu specyficznego dla Mikrusa do `lib/providers/mikrus/`, z hookami w core.

- [x] **2.1** Stworzyć `lib/providers/detect.sh` — auto-detekcja providera
  - `/klucz_api` → mikrus
  - Fallback: generic
  - Override: `TOOLBOX_PROVIDER=mikrus` w configu
- [x] **2.2** Stworzyć `lib/providers/mikrus/` z kodem z mikrus-toolbox:
  - [x] `cytrus.sh` — rejestracja domeny Cytrus (z `local/cytrus-domain.sh`)
  - [x] `shared-db.sh` — shared DB przez API mikr.us (z `lib/db-setup.sh`)
  - [x] `backup.sh` — backup Mikrusa 200MB (z `system/setup-backup-mikrus.sh`)
  - [x] `hooks.sh` — entry point z hookami: `provider_domain_options`, `provider_post_deploy`, `provider_db_options`, `provider_upgrade_suggestion`
- [x] **2.3** Dodać hook points w core:
  - [x] `lib/domain-setup.sh` — `provider_domain_options()` dodaje "cytrus"
  - [x] `lib/db-setup.sh` — `provider_db_options()` dodaje "shared"
  - [x] `local/deploy.sh` — `provider_post_deploy()` po instalacji (Cytrus domain update — via hooks.sh)
  - [x] `lib/resource-check.sh` — `provider_upgrade_suggestion()` (ceny Mikrusa vs generic)
- [x] **2.4** Dodać `contrib/mikrus/deploy-sellf.sh` (dual prod+demo, z mikrus-toolbox)
- [x] **2.5** Dodać tłumaczenia provider-specific do `locale/pl.sh` i `locale/en.sh`
- [x] **2.6** Zaktualizować `lib/server-exec.sh` — unified detekcja (server-marker + /klucz_api)
- [x] **2.7** Cleanup: usunąć stale mikrus references w stackpilot
  - `apps/postiz/install.sh` — cytrus, /opt/mikrus-toolbox/
  - `apps/routepix/install.sh` — /opt/mikrus-toolbox/, cytrus, polskie komentarze
  - `apps/subtitle-burner/install.sh` — cytrus, /opt/mikrus-toolbox/
  - READMEs: routepix, subtitle-burner, postiz
  - `local/setup-listmonk-mail.sh` — polskie przykłady

**Definicja "done":** Mikrus-specific kod tylko w `lib/providers/mikrus/` i `contrib/mikrus/`. Core jest provider-agnostic. Deploy na Mikrusie działa jak wcześniej (auto-detect). Deploy na generic VPS nie widzi Mikrus kodu.

---

## Phase 3: Unit Tests (lokalne, bez serwera)

Goal: Testy funkcji z `lib/` w izolacji, z mockami, <10s runtime.

- [x] **3.1** Stworzyć `tests/unit/test-runner.sh` — minimalny harness
  - `assert_eq`, `assert_contains`, `assert_exit_code`, `assert_not_contains`
  - `setup()`, `teardown()` (tmpdir per test)
  - Kolorowy output + podsumowanie passed/failed
  - Exit code 1 jeśli cokolwiek failed
- [x] **3.2** Stworzyć `tests/mocks/` — mockowane komendy systemowe
  - `ssh` — echo ok / configurable response
  - `docker` — basic compose ps mock
  - `curl` — configurable HTTP response codes
  - `ss` — configurable port listing
  - `free` — configurable RAM output
  - `df` — configurable disk output
- [x] **3.3** `tests/unit/test-cli-parser.sh` (18 tests)
  - Parsowanie: `--ssh=mikrus --domain-type=cloudflare --yes`
  - Domyślne wartości (ssh=vps, domain-type nie ustawiony)
  - Edge cases: brak argumentów, nieznane flagi
- [x] **3.4** `tests/unit/test-db-setup.sh` (11 tests)
  - Logika wyboru DB: bundled vs custom
  - Provider hook: shared DB (mikrus)
  - Walidacja env vars (DB_HOST, DB_USER, DB_PASS, DB_NAME)
- [x] **3.5** `tests/unit/test-domain-setup.sh` (9 tests)
  - Walidacja domen: poprawne, niepoprawne, edge cases
  - Domain type routing: cloudflare → caddy → local
  - Provider hook: cytrus
- [x] **3.6** `tests/unit/test-port-utils.sh` (5 tests)
  - `find_free_port` z mockowanym `ss`
  - Port conflict detection
- [x] **3.7** `tests/unit/test-resource-check.sh` (10 tests)
  - Parsowanie `free -m` i `df` output (mockowane)
  - Progi: OK, TIGHT, CRITICAL
- [x] **3.8** `tests/unit/test-i18n.sh` (8 tests)
  - Ładowanie EN, PL
  - Fallback na EN dla brakującego klucza
  - Brakujący plik locale → error
  - `msg()` z formatowaniem printf
- [x] **3.9** `tests/unit/test-provider-detect.sh` (5 tests)
  - Auto-detect: /klucz_api → mikrus, brak → generic
  - Override z configa: TOOLBOX_PROVIDER=mikrus
  - Ładowanie hooków providera

**Definicja "done":** `./tests/run.sh unit` przechodzi, <10s, 100% lokalne.

---

## Phase 4: Static Validation Tests (lokalne)

Goal: Automatyczna walidacja konwencji i poprawności bez uruchamiania czegokolwiek na serwerze.

- [x] **4.1** `tests/static/test-shellcheck.sh`
  - shellcheck na wszystkich `*.sh` (z excludes dla znanych false positives)
  - 95 files checked, all pass
- [x] **4.2** `tests/static/test-install-contract.sh`
  - Każdy `apps/*/install.sh` ma: `set -e`, `APP_NAME=`, `PORT=${PORT:-`, `STACK_DIR=`, `docker compose`
  - 25 checked, 5 exempt (coolify, sellf, littlelink, cookie-hub, dockge)
- [x] **4.3** `tests/static/test-compose-syntax.sh`
  - Ekstrakcja heredoc z install.sh → walidacja przez `docker compose config --quiet`
  - Mockowane env vars (PORT, DB_HOST, etc.)
  - 18 validated, best-effort skips for complex heredoc patterns
- [x] **4.4** `tests/static/test-locale-coverage.sh` (z Phase 1)
  - Symetryczność kluczy EN ↔ PL (1325 keys)

**Definicja "done":** `./tests/run.sh static` przechodzi, <30s, 100% lokalne.

---

## Phase 5: E2E Integration Tests (na serwerze)

Goal: Automatyczne testowanie deploymentu na prawdziwym serwerze — wszystkie warianty bez ręcznego klikania.

- [x] **5.1** Refaktor istniejącego `tests/test-apps.sh` → `tests/e2e/`
  - [x] `tests/e2e/config.sh` — SSH_HOST, timeouts, cleanup policy
  - [x] `tests/e2e/lib/assertions.sh` — assert_http, assert_container, assert_domain, assert_port
  - [x] `tests/e2e/lib/cleanup.sh` — cleanup per-app, cleanup-all
  - [x] `tests/e2e/test-runner-e2e.sh` — orchestrator z TAP output
- [x] **5.2** Suite: `deploy-no-db.sh`
  - Tested on hanna (Mikrus 1GB): ntfy ✓, uptime-kuma ✓, filebrowser ✓ (3/3 PASS)
  - --quick mode: 3 apps; full mode adds dockge, vaultwarden, stirling-pdf
- [x] **5.3** Suite: `deploy-postgres.sh`
  - Tested on hanna: umami (bundled) ✓, nocodb (bundled) ✓ (2/2 PASS, quick mode)
  - Full mode adds listmonk, n8n (not tested yet — RAM-constrained)
- [x] **5.4** Suite: `deploy-mysql.sh`
  - Tested on hanna: wordpress (SQLite mode) ✓ (1/1 PASS, HTTP 403 — setup page)
- [x] **5.5** Suite: `deploy-tcp-only.sh`
  - Tested on hanna: redis ✓ (1/1 PASS, port 6379 listening)
- [x] **5.6** Suite: `domain-cloudflare.sh`
  - Tested on hanna: ntfy with --domain-type=cloudflare --domain=e2etest.automagicznie.pl ✓
  - Full flow: deploy → Cloudflare DNS (AAAA, proxied) → Caddy reverse proxy → HTTPS 200 → cleanup
- [x] **5.7** Suite: `domain-caddy.sh`
  - Tested on hanna: ntfy with --domain-type=caddy --domain=e2ecaddy.automagicznie.pl ✓
  - Full flow: DNS (AAAA, unproxied) → deploy → Let's Encrypt cert → HTTPS 200 → cleanup
- [x] **5.8** Suite: `update-flow.sh`
  - Tested on hanna: ntfy deploy → stop → re-deploy ✓ (1/1 PASS)
- [x] **5.9** Suite: `provider-mikrus.sh`
  - Provider auto-detection: ✓ PASS (detected mikrus on hanna)
  - Shared DB deploy: nocodb with --db-source=shared ✓ PASS (2/2 total)
  - Cytrus domain: not yet tested (needs separate test)
- [x] **5.10** Resource pre-check
  - Implemented: RAM + disk check before each deploy, auto-skip if below threshold
  - n8n: custom 800MB guard (600M app + 200M postgres) — safe skip on 1GB VPS
- [x] **5.11** TAP/JUnit output do `tests/e2e/results/`
  - TAP v13 output generated after each suite run
- [x] **5.12** Dodatkowe suity (nowe, sesja 2):
  - `cytrus-domain`: deploy ntfy z `--domain-type=cytrus --domain=auto` ✓ PASS
  - `backup-flow`: umami+postgres → setup-db-backup.sh → weryfikacja `.sql.gz` ✓ PASS
  - `static-hosting`: add-static-hosting.sh + CF DNS + HTTPS 200 ✓ PASS
  - `php-hosting`: add-php-hosting.sh + CF DNS + PHP execution ✓ PASS
  - `health-check`: static analysis (10 apek z HEALTHCHECK) + runtime ntfy ✓ PASS (2/2)
  - deploy-no-db full: dockge ✓, vaultwarden ✓, stirling-pdf SKIP (2GB requirement)
  - deploy-postgres full: listmonk ✓, n8n SKIP (800MB guard, 1GB VPS za mały)
  - Łącznie: 21 E2E testów PASS, 3 SKIP (resource-constrained), 0 FAIL
- [x] **5.13** Bugfixy E2E infrastruktury:
  - `backup-flow`: `echo n | ssh host "bash /path/script"` zamiast `bash -s < file` (stdin conflict)
  - `caddy_cleanup`: przepisany z sed na Python3 (niezawodne usuwanie multi-line blocks)
  - `assert_https` → `assert_https_remote` dla static/php-hosting (lokalny macOS nie resolvuje CF proxy DNS)

**Definicja "done":** `./tests/run.sh e2e --ssh=test-vps` testuje wszystkie warianty, produkuje czytelny raport, exit code 0/1.

---

## Phase 6: Test Runner + CI

Goal: Jeden entry point + GitHub Actions.

- [x] **6.1** Stworzyć `tests/run.sh` — unified runner
  - `./tests/run.sh unit` — unit testy
  - `./tests/run.sh static` — statyczna walidacja
  - `./tests/run.sh e2e --ssh=HOST` — E2E
  - `./tests/run.sh e2e --ssh=HOST --suite=deploy-no-db` — jedna suite
  - `./tests/run.sh e2e --ssh=HOST --app=n8n` — jedna apka
  - `./tests/run.sh e2e --ssh=HOST --quick` — 1 wariant per app
  - `./tests/run.sh all --ssh=HOST` — wszystko
  - 70 local tests (unit + static), 0 failed, ~11s runtime
  - E2E: 12 tests on Mikrus VPS (hanna), all pass (incl. Cloudflare + Caddy domain suites)
- [x] **6.2** `.github/workflows/test-unit.yml`
  - Trigger: push, PR (on lib/, local/, system/, apps/, locale/, tests/ changes)
  - Runs: unit + static (free, szybkie)
- [x] **6.3** `.github/workflows/test-e2e.yml`
  - Trigger: manual (workflow_dispatch) lub nightly (3 AM UTC)
  - Wymaga secrets: E2E_SSH_KEY
  - Runs: e2e --quick (1 wariant per app)

**Definicja "done":** CI zielone, PRy blokowane na unit+static failure.

---

## Phase 7: Finalizacja

- [x] **7.1** Zaktualizować `AGENTS.md` / `CLAUDE.md`
  - Nowa architektura: i18n, providers, testy
  - Nowe komendy: `./tests/run.sh`
  - Informacja o Mikrus provider
- [x] **7.2** Zaktualizować `README.md`
  - Sekcja "Multi-language support"
  - Sekcja "Provider support" (generic + Mikrus)
  - Sekcja "Testing"
  - Updated Roadmap, FAQ, Repository Structure
- [x] **7.3** Zaktualizować `CONTRIBUTING.md`
  - Jak dodać nowy locale
  - Jak dodać nowy provider
  - Jak uruchomić testy
- [x] **7.4** mikrus-toolbox → archive
  - README.md replaced with migration notice (see README-ORIGINAL.md for old docs)
  - README-ARCHIVE.md removed (content moved to README.md)
  - apps/gateflow/ renamed to apps/sellf/ (rebranding in mikrus-toolbox)
  - Pushed to GitHub: commit 4b9a7f6
- [x] **7.5** Przetestować pełny flow na Mikrusie
  - i18n suite: ntfy with TOOLBOX_LANG=pl ✓ (Polish output confirmed)
  - Provider auto-detection ✓, shared DB (nocodb) ✓
  - deploy-no-db (ntfy, uptime-kuma, filebrowser) ✓, deploy-tcp (redis) ✓
  - deploy-postgres (umami, nocodb bundled) ✓, deploy-mysql (wordpress sqlite) ✓
  - update-flow (deploy → stop → re-deploy) ✓

---

## Kolejność pracy

```
Phase 1 (i18n) ──→ Phase 2 (providers) ──→ Phase 7 (finalizacja)
                                     ↘
Phase 3 (unit tests) ──→ Phase 4 (static) ──→ Phase 5 (E2E) ──→ Phase 6 (CI)
```

Phase 1 i 2 są zależne (providers potrzebują i18n).
Phase 3-6 mogą być realizowane równolegle z Phase 2 (testy pisze się do kodu który już jest).
Phase 7 po wszystkim.

**Estymacja:** ~5-7 dni roboczych (rozbite na sesje).

---

## Notatki

- Baza: stackpilot repo — mikrus-toolbox kod jest dodawany, nie odwrotnie
- Angielski = default, polski = locale
- mikrus = provider plugin, nie core
- Nie ruszamy MCP server (mcp-server/) w tym refaktorze — ma swoje testy
- Apps install.sh — minimalne zmiany (głównie health-check messages → i18n)
- Stale mikrus references w stackpilot do wyczyszczenia: postiz, routepix, subtitle-burner

## Post-Audyt Fixy (zrobione po zakończeniu refaktoru)

Audyt porównawczy mikrus-toolbox → stackpilot wykrył i naprawił:

1. **`apps/supabase/` przeniesiony** — self-hosted Supabase (10 kontenerów, ~4GB obrazów, 2GB+ RAM).
   Przetłumaczony na angielski, `mikrus-expose` → `sp-expose`, config w `~/.config/stackpilot/supabase/`.

2. **Ścieżka config sellf zmieniona** — `~/.config/sellf/` → `~/.config/stackpilot/sellf/`.
   Backwards-compatible fallback w `deploy.sh` i `sellf-setup.sh` (auto-migracja jeśli stary katalog istnieje).
   Pliki zaktualizowane: `lib/sellf-setup.sh`, `local/setup-sellf-config.sh`, `local/setup-supabase-sellf.sh`,
   `local/setup-stripe-sellf.sh`, `local/setup-supabase-migrations.sh`, `local/setup-turnstile.sh`,
   `local/deploy.sh`, `locale/en.sh`, `locale/pl.sh`, `apps/sellf/README.md`, `mcp-server/src/tools/setup-sellf.ts`.
