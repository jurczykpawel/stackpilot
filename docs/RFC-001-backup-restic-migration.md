# RFC-001: Migracja backup z rclone na restic

**Status:** Proposed
**Author:** Paweł Jurczyk
**Date:** 2026-05-11
**Decision deadline:** Q3 2026

---

## Summary

Stackpilot obecnie używa **rclone sync** + **pg_dump | gzip** + ręczna rotacja `find -mtime` jako stack backup. Proponuję migrację na **restic native** z Cloudflare R2 jako default backendem.

Driver: audyt dzisiejszego setupu produkcyjnego (Mikrus steve160) ujawnił że obecne podejście Stackpilot ma 5 luk które restic rozwiązuje by design.

## Motivation

### Problem 1: DB backupy NIE idą do cloud (bug)

Obecne `setup-db-backup.sh` generuje skrypt który robi:

```bash
docker compose exec -T db pg_dump | gzip > /opt/backups/db/${STACK}_postgres_${DATE}.sql.gz
find /opt/backups/db -mtime +7 -delete
```

Plik ląduje w `/opt/backups/db/`. Natomiast `backup-core.sh` SOURCE_DIRS to:

```bash
SOURCE_DIRS=(
    "/opt/dockge"
    "/opt/stacks"
)
```

**`/opt/backups` nie jest w SOURCE_DIRS**. Pożar VPS = utrata wszystkich DB. Bug, nie design.

> **🩹 HOTFIX 2026-05-11**: Dorzucono `/opt/backups` do `SOURCE_DIRS` w `backup-core.sh` (i do `TARGET_DIRS` w `restore-core.sh`) jako 1-token zmiana niezależna od pełnej migracji. To naprawia bug #1 ZANIM ten RFC zostanie zaimplementowany.
>
> **⚠️ DO NOT FORGET DURING MIGRATION**: Nowy `system/backup-core.sh` (restic-based) MUSI również mieć `/opt/backups` w SOURCES. Plus dorzucić `/opt/backups/sqlite-snapshots/` (subfolder dla SQLite hot dumps) jako oddzielny path z explicit komentarzem czemu. Patrz "Phase 2: System scripts" niżej — kod już to uwzględnia.

### Problem 2: rclone sync = mirror, nie versioned backup

`rclone sync` to **lustro** — jeśli plik został corrupted/usunięty na źródle, sync usuwa go też z cloud. Brak point-in-time recovery. "Wczoraj było OK, dziś popsute" → przepadło.

Stackpilot dziś polega na `find -mtime +7 -delete` dla DB dumps (local retention 7 dni), ale potem rclone sync usuwa też z cloud kiedy lokalny plik znika. Czyli cloud = 1 wersja (mirror), retention tylko lokalny przez 7 dni.

### Problem 3: SQLite WAL → silent corruption ryzyko

SQLite od wersji 3.7 używa Write-Ahead Logging. Live `rclone sync` na `db.sqlite3` w trakcie writes może produkować inconsistent backup. Restore lottery: sometimes works, sometimes silent loss, sometimes corruption.

Apki affected w typowym Stackpilot stack:
- Vaultwarden (password manager, **CRITICAL**)
- Pi-hole (DNS configs)
- Plausible Analytics (analytics)
- Home Assistant (sensor history)

Fix wymaga `sqlite3 db.sqlite3 ".backup '/path/safe.sqlite3'"` przed głównym backup — atomic snapshot. Nie ma tego w Stackpilot.

### Problem 4: Encryption opt-in only

Docs mówią "encryption (recommended)" — czyli defaultowe rclone setup **nie szyfruje**. User musi explicit skonfigurować `crypt` remote. Plus rclone crypt ma swoje ograniczenia:

| | rclone crypt | restic |
|---|---|---|
| Filename | encrypted (opt-in) | always encrypted |
| Folder structure | widoczna w cloud | hidden (random chunk hashes) |
| File sizes | widoczne | hidden |
| Modification times | widoczne | hidden |
| Encryption per | plik | chunk |
| Non-deterministic | TAK (każdy upload inny ciphertext) | NIE (deterministic chunks) |

Plus: rclone crypt z non-deterministic encryption **zabija dedup** nawet gdyby był (każdy upload to inny ciphertext, hash niezgodny).

### Problem 5: Brak deduplikacji + brak GFS retention

Daily pg_dump bazy 1 GB, 95% danych stabilne:

| | Storage po 30 dniach | Egress/dzień |
|---|---|---|
| rclone sync gzip | 1 GB (mirror, 1 wersja) | 1 GB |
| rclone sync gzip + history (`find -mtime`) | 30 × 1 GB = 30 GB | 1 GB |
| rclone crypt + history | 30 GB encrypted | 1 GB encrypted |
| **restic** | ~2.5 GB (base + delta chunks) | ~50 MB (incremental) |

Restic = ~12× mniej storage + ~20× mniej egress dla typowego DB backup case'u.

Plus brak GFS (Grandfather-Father-Son) — Stackpilot ma `find -mtime +7` (7 dni hard delete). Restic ma natywny `forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12` (~roczna historia w paru GB).

## Proposed solution

### Architecture

```
                          ┌──────────────────────┐
                          │  local/setup-backup  │
                          │    (wizard MAC)      │
                          │  R2 / B2 / S3 / SFTP │
                          └──────────┬───────────┘
                                     │
                                     │ ssh + restic init
                                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ VPS (Stackpilot-managed)                                        │
│                                                                  │
│  cron 03:55  system/sqlite-prebackup.sh                         │
│              auto-detect SQLite containers → sqlite3 .backup    │
│              → /opt/backups/sqlite-snapshots/                   │
│                                                                  │
│  cron 04:00  system/backup-core.sh                              │
│              restic backup /opt/stacks /opt/dockge              │
│              + retention forget+prune (14d/8w/12m)              │
│                                                                  │
│  cron 04:05  system/db-backup.sh                                │
│              docker compose exec | restic --stdin per DB        │
│              + container PG dump (jeśli ma)                     │
│                                                                  │
│  hourly :17  system/healthcheck-backup.sh                       │
│              heartbeat freshness + repo integrity               │
│              → ntfy/webhook alert jeśli stale                   │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         │ restic protocol (encrypted chunks)
                         ▼
              ┌──────────────────────┐
              │  Cloudflare R2       │  default
              │  / Backblaze B2      │  alt
              │  / AWS S3            │  alt
              │  / SFTP / local      │  advanced
              └──────────────────────┘
```

### Backend hierarchy

| Priority | Backend | Recommended for | Storage | Egress | Wizard label |
|---|---|---|---|---|---|
| 1 (default) | **Cloudflare R2** | większość user'ów, CF konto pewnie masz | $15/TB | **$0 (zero egress)** | ★ Default — Cloudflare R2 |
| 2 | **Backblaze B2** | tańszy storage jeśli OK z egress 3× cap | $6/TB | free do 3× storage/mies | Cheaper — Backblaze B2 |
| 3 | **AWS S3 STANDARD** | enterprise / już używasz AWS | $23/TB | $0.09/GB | AWS S3 |
| 3a | **AWS S3 Glacier Deep** | rzadko czytane archiwum | $1/TB | $0.09/GB + restore fee | AWS S3 Glacier (cold) |
| 4 | **SFTP** | self-hosted destination (drugi VPS, NAS) | $0 (self) | $0 | SFTP server |
| 5 | **Local filesystem** | testowanie / hardware backup | $0 | n/a | Local (testing) |

W docs sekcja "Advanced: rclone as restic backend" pokazuje jak doinstalować rclone i ustawić `RESTIC_REPOSITORY=rclone:gdrive:vps-backup` dla user'ów którzy uprą się na GDrive/Dropbox/Mega. **Nie wbudowane** w wizard.

### Defaults (opinionated)

```bash
# Cron schedule
03:55  system/sqlite-prebackup.sh        # hot SQLite dumps
04:00  system/backup-core.sh             # restic files
04:05  system/db-backup.sh               # restic DB stdin
04:15  system/db-backup-containers.sh    # container PG (if any)
:17 *  system/healthcheck-backup.sh     # heartbeat alerting (hourly)

# Retention (restic forget)
--keep-daily 14
--keep-weekly 8
--keep-monthly 12
--prune

# Excludes (zarówno files jak i dla DB)
**/.next
**/node_modules
**/dist
**/build
**/.turbo
**/.parcel-cache
**/*.old
**/admin-panel.old
**/.cache
.git

# Encryption: ZAWSZE on (restic default)
# Generowane przy setup, wyświetlone z silnym warning
```

### Implementation plan

**Phase 1: Wizard rewrite (local/, 4-6h)**

`local/setup-backup.sh`:
- Wybór providera (interactive prompt + numbered list)
- Per-provider creds collection (R2: account ID + access key + secret + bucket; B2: keyID + appKey + bucket; S3: standard AWS creds + region + bucket; SFTP: host + user + path; local: directory)
- Test connection (restic `restic init --no-cache` then `restic cat config` smoke test)
- Generate RESTIC_PASSWORD (openssl rand 50 chars), display z `IMPORTANT: Save this in your password manager NOW. Lost password = lost backups.`
- Write `/opt/stackpilot/config/restic.env` (chmod 600) z B2_ACCOUNT_ID/B2_ACCOUNT_KEY/etc + RESTIC_REPOSITORY + RESTIC_PASSWORD
- Install restic na VPS (`apt install -y restic` lub download binary z github releases — sprawdzić wersję)
- Initial `restic init`
- Verify z `restic snapshots` (empty list expected)

**Phase 2: System scripts (system/, 6-8h)**

`system/backup-core.sh`:
```bash
#!/bin/bash
set -uo pipefail
source /opt/stackpilot/config/restic.env

SOURCES=(
    /opt/stacks
    /opt/dockge
    /opt/backups   # ← FIX bug #1: DB dumps + SQLite hot snapshots tutaj
)

EXCLUDES=(
    --exclude='**/.next'
    --exclude='**/node_modules'
    --exclude='**/dist'
    --exclude='**/build'
    --exclude='**/.turbo'
    --exclude='**/.parcel-cache'
    --exclude='**/*.old'
)

restic backup --tag stackpilot --tag files "${EXCLUDES[@]}" --exclude-caches "${SOURCES[@]}"
restic forget --tag files --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune

touch /var/lib/stackpilot-backup/last-files-backup
```

`system/db-backup.sh` (generowany przez `setup-db-backup.sh`):
```bash
#!/bin/bash
source /opt/stackpilot/config/restic.env

for COMPOSE_DIR in /opt/stacks/*/; do
    STACK=$(basename "$COMPOSE_DIR")
    COMPOSE_FILE="${COMPOSE_DIR}docker-compose.yaml"
    [ -f "$COMPOSE_FILE" ] || continue

    # Postgres detection (existing logic z current setup-db-backup.sh)
    if grep -qE '^\s+image:\s*(postgres|postgresql)' "$COMPOSE_FILE"; then
        DB_USER=$(grep -oP 'POSTGRES_USER[=:]\s*\K[^\s"]+' "$COMPOSE_FILE" | head -1)
        DB_USER="${DB_USER:-postgres}"
        DB_SERVICE=$(...)
        (cd "$COMPOSE_DIR" && docker compose exec -T "$DB_SERVICE" pg_dumpall -U "$DB_USER") | \
            restic backup --stdin --stdin-filename "${STACK}-postgres-dumpall.sql" \
                --tag stackpilot --tag db --tag "$STACK"
    fi

    # MySQL detection analogicznie...
done

restic forget --tag db --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
touch /var/lib/stackpilot-backup/last-db-backup
```

**NOWY** `system/sqlite-prebackup.sh`:
```bash
#!/bin/bash
OUT_DIR="/opt/backups/sqlite-snapshots"
mkdir -p "$OUT_DIR"

# Auto-detect SQLite containers
# Wzorzec: docker inspect → volume mounts → find *.sqlite3 in mounted volumes
for container in $(docker ps --format '{{.Names}}'); do
    mount_src=$(docker inspect "$container" \
        --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')
    [ -z "$mount_src" ] && continue

    for db in $(find "$mount_src" -maxdepth 2 -name "*.sqlite3" -type f 2>/dev/null); do
        out_name="${container}-$(basename "$db")"
        sqlite3 "$db" ".backup '${OUT_DIR}/${out_name}'"
    done
done
```

**NOWY** `system/healthcheck-backup.sh`:
```bash
#!/bin/bash
HEARTBEAT_DIR="/var/lib/stackpilot-backup"
NOW=$(date +%s)
MAX_AGE_HOURS=36

for type in files db sqlite; do
    heartbeat="${HEARTBEAT_DIR}/last-${type}-backup"
    if [ ! -f "$heartbeat" ]; then
        notify "Stackpilot backup ${type} never ran" "high"
        continue
    fi
    age_h=$(( (NOW - $(stat -c %Y "$heartbeat")) / 3600 ))
    if [ "$age_h" -gt $MAX_AGE_HOURS ]; then
        notify "Stackpilot backup ${type} stale (${age_h}h old)" "high"
    fi
done

# Repo integrity (raz w tygodniu, niedziele)
if [ "$(date +%u)" = "7" ]; then
    source /opt/stackpilot/config/restic.env
    restic check --read-data-subset 5% || notify "Stackpilot restic repo integrity FAILED" "urgent"
fi
```

`system/restore-core.sh` rewrite:
- List snapshots (`restic snapshots --tag stackpilot`)
- Interactive picker (data, tag)
- `restic restore <snapshot> --target / --include <path>`
- Per-snapshot, per-path support
- Confirmation prompt z "this will overwrite existing files"

**Phase 3: MCP server (mcp-server/, 3-4h)**

Update `mcp-server/src/tools/setup-backup.ts`:
- New provider picker
- Returns: provider, repo URL, password (warned displayed-only)

Update `mcp-server/src/lib/backup-check.ts`:
- `restic snapshots --json` → parse → return last snapshot per tag
- Heartbeat file freshness
- Integrity check status

**NEW tools:**
- `list_snapshots(tag?)` — returns paginated list
- `restore_file(snapshot_id, path, target_dir)` — selective restore
- `backup_drill()` — random file restore test, returns checksum comparison

**Phase 4: Docs (3-4h)**

Rewrite `docs/backup.md`:
- "Quick start: 3 steps to bulletproof backups"
- Provider comparison table
- Restore guide (per-snapshot, per-path, full)
- Advanced: rclone backend dla GDrive/Dropbox

**NOWY** `docs/disaster-recovery.md`:
- Scenario 1: file lost → restore from latest
- Scenario 2: DB corrupted → restore from yesterday's snapshot
- Scenario 3: whole VPS lost → fresh VPS + restic restore everything
- Pre-DR checklist (passwords in vault, restic_password offsite, restore drill quarterly)

**NOWY** `docs/backup-architecture.md`:
- Encryption: AES-256-CTR + Poly1305-AES MAC per chunk
- Chunks: content-defined chunking (CDC) z rolling hash, ~512 KB-8 MB
- Dedup: per-chunk SHA-256 identity
- Retention: GFS via `restic forget`
- Repo structure: data/, index/, snapshots/, keys/, config

**Phase 5: i18n (2h)**

PL + EN messages dla wszystkich nowych UX flow w `lib/locale/`.

**Phase 6: Tests (4-6h)**

Manual tests na test VPS Mikrus (hanna):
- Wizard z każdym providerem (R2, B2, S3, SFTP, local)
- Backup → restore cycle dla każdego providera
- DB backup dla PG + MySQL + SQLite stacków
- Healthcheck alert flow
- MCP tools end-to-end

### Backward compatibility / migration

**Nikt jeszcze nie używa** Stackpilota produkcyjnie. Zero migration friction. Decyzja:

- Keep stary `local/setup-backup.sh` + `system/backup-core.sh` przez jeden release jako `*-rclone.sh` (legacy mode for emergency rollback)
- New default = restic
- Po 1-2 release'ach usunąć rclone files

Migration guide w docs: "Migrating from rclone (legacy)" — opisany ale nie automated (nikt tego nie potrzebuje).

## Alternatives considered

### Alternative B: Hybrid (rclone for files, restic for DB only)

Zachować rclone dla files SOURCES, dorzucić restic-stdin tylko dla DB. **Odrzucone** bo:
- Wciąż mamy rclone limitations (no dedup, no snapshots) dla files
- Dwa różne backup tools = większy MCP server + wizard complexity
- Mniejszy improvement vs full restic

### Alternative C: Restic + rclone as backend (`rclone:` repo)

Restic obsługuje natywny "rclone backend" — `RESTIC_REPOSITORY=rclone:gdrive:vps-backup`. **Odrzucone** bo:
- Wymaga 2 binary do utrzymania (restic + rclone)
- ~10-15% wolniejszy upload (rclone proxy overhead)
- Maintenance burden większy (debug ścieżką restic→rclone→provider)
- Nikt jeszcze nie używa Stackpilot, więc nie ma legacy user'ów na GDrive do migrowania
- GDrive użytkownicy mogą doinstalować rclone manualnie i użyć rclone backend (docs sekcja "Advanced")

Plus: większość self-hosters i tak nie używa GDrive dla backupów produkcyjnych — GDrive 15 GB free to za mało dla typowego VPS stack (DB + files = łatwo >15 GB), a paid GDrive jest droższy od R2/B2.

### Alternative D: Keep rclone, fix only the bugs

Minimum: dorzucić `/opt/backups` do SOURCE_DIRS w `backup-core.sh`. Naprawia bug #1 (DB do cloud). **Odrzucone** bo:
- Nie rozwiązuje bug #2 (mirror, nie versioned)
- Nie rozwiązuje bug #3 (SQLite WAL)
- Nie rozwiązuje bug #4 (encryption opt-in)
- Nie rozwiązuje bug #5 (no dedup, no GFS)

Może być wdrożone jako **hotfix** ZANIM RFC zostanie zaimplementowany (1-token zmiana). Nie wyklucza tej RFC.

## Risks

1. **Restic binary not on every VPS** — wymaga `apt install restic` (Debian/Ubuntu) lub manual download. Wizard musi handle. **Mitigation**: install step w wizardzie, fallback na manual instructions.

2. **R2 wymaga AWS-compat creds** — user musi w CF dashboard wygenerować "S3-compatible API token". **Mitigation**: docs link + step-by-step screenshots w wizard prompt.

3. **Restic learning curve** — user przyzwyczajony do `find files` może być stracony w `restic snapshots/restore`. **Mitigation**: `local/restore.sh` interactive picker hides CLI complexity; docs/backup.md ma "common operations" section.

4. **Lost RESTIC_PASSWORD = lost data** — restic encryption nie ma recovery. **Mitigation**: silne ostrzeżenie w wizardzie, instrukcja "save in password manager", dokumentacja DR scenario.

5. **Restic repo lock po crash** — restic locks repo podczas operacji, crash może zostawić stale lock. **Mitigation**: `restic unlock` w docs as troubleshooting, plus healthcheck wykryje "lock too old".

## Open questions

1. Czy MCP server update jest w scope tego RFC czy osobny? **Sugeruję ten sam** — całość spójna.
2. Czy support dla custom retention (user-configurable) w wizardzie czy tylko default? **Sugeruję default w wizard + advanced config w docs** (edit `restic.env` ręcznie).
3. Czy `system/healthcheck-backup.sh` integruje się z istniejącym `notify.sh` (ntfy/email) czy ma własny? **Sugeruję integrację** — single notify dispatcher across all Stackpilot.
4. Czy zachować `apps/n8n/backup.sh` (logical JSON export) czy zastąpić generic restic? **Sugeruję zachować** — JSON export to portable backup (możesz odtworzyć n8n od zera lub migrować między instancjami), restic to "snapshot raw state". **Dual layer**, oba mają sens.

## Decision

Proposed: **Migrate to restic native (Option A) with Cloudflare R2 as default backend.**

Awaiting review.

## Implementation tracking

Task: `vault/personal/_db-tasks/stackpilot-backup-restic-migration.md`

Effort estimate: **~22-30h (3-4 sesje robocze)**.

## References

- Restic documentation: https://restic.readthedocs.io
- Restic GitHub: https://github.com/restic/restic
- Cloudflare R2 docs: https://developers.cloudflare.com/r2/
- Backblaze B2 docs: https://www.backblaze.com/docs/cloud-storage
- Case study setup (Mikrus 2026-05-11): memory `mikrus-prod-backup-audit.md`
- Storage choice rule: memory `feedback_backup_storage_choice.md`
- Real-world examples on TrueNAS: memory `truenas-restic-glacier.md`, `immich-backup.md`
