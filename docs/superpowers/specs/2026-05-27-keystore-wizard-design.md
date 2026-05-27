# Keystore + Wizard System — Design Spec

**Date:** 2026-05-27
**Author:** Pawel Jurczyk + Claude (collaborative)
**Status:** Approved for implementation
**Scope MVP:** Cloudflare provider only; framework must be extensible to all current and future providers.

---

## 1. Goal

stackpilot user (CLI or via AI) declares *"I need Cloudflare"*, the system detects missing keys, walks them through minimal provider-UI steps, validates against the provider's API, and stores secrets securely. Plain-text on disk only when the OS keystore is unavailable.

**Success criteria:**
- Zero hardcoded secrets in user's home dir when macOS Keychain / libsecret is available.
- Zero macOS popups during routine `stackpilot deploy` calls (ACL configured so `security` CLI reads silently).
- New providers added with one `lib/wizards/X.sh` file — zero changes to keystore core or skill core.
- Works deterministically without AI (raw CLI); AI skill adds recovery UX on top.
- All public functions covered by tests written **before** their implementation (TDD).

---

## 2. Architecture

Two layers, both standalone:

```
USER (CLI or AI)
  │
  ├─ direct CLI: `stackpilot keys add cloudflare`
  │
  └─ via Claude / Cursor: skill `stackpilot-keys`
        │
        └─ calls same CLI under the hood

────────────────────────────────────────────────────────────
LAYER 1 — bash core (deterministic, no AI required)

lib/wizards/<provider>.sh                Provider-specific UX + validation
  ├ wizard_required_keys                  (lists canonical key names)
  ├ wizard_check                          (all present and valid?)
  ├ wizard_validate KEY VALUE             (stateless test)
  └ wizard_run                            (interactive flow)

lib/keystore/core.sh                     Provider-agnostic key API
  ├ keystore_set NAME VALUE
  ├ keystore_get NAME
  ├ keystore_has NAME
  ├ keystore_rm NAME
  ├ keystore_list
  ├ keystore_backend
  └ keystore_require_keys NAME...

lib/keystore/detect.sh                   Backend selection at runtime

lib/keystore/backend-keychain.sh         macOS `security` CLI
lib/keystore/backend-libsecret.sh        Linux `secret-tool`
lib/keystore/backend-file.sh             Plain file fallback (chmod 600)

local/keys.sh                            Public CLI entry point

────────────────────────────────────────────────────────────
LAYER 2 — AI skill (wraps Layer 1)

vault/skills/stackpilot-keys/SKILL.md    Intent detection, conversational recovery,
                                         PL/EN dialog, cross-source migration
```

**Strict rules:**
- Skill has zero provider-specific knowledge — calls bash CLI, parses stderr.
- Wizard has zero backend decisions — calls `keystore_set`.
- Backend has zero validation — stores opaque bytes.

---

## 3. Keystore library (`lib/keystore/`)

### 3.1 Public API (`core.sh`)

```bash
keystore_set NAME VALUE
keystore_get NAME                        # stdout: value
keystore_has NAME                        # exit 0/1
keystore_rm NAME                         # idempotent
keystore_list                            # stdout: NAMEs, one per line
keystore_backend                         # stdout: keychain|libsecret|file
keystore_require_keys NAME [NAME ...]    # stdout: missing names; exit = count missing
```

Input validation in `keystore_set`:
- `NAME` must match `^[a-z][a-z0-9_]*$` (lowercase snake_case).
- `VALUE` must be non-empty.
- Reject names not in `lib/keystore/names.sh` canonical list (prevents typos).

### 3.2 Naming

Single namespace `stackpilot.*` in storage. Canonical names live in `lib/keystore/names.sh`:

```bash
# Cloudflare
KEYSTORE_NAMES+=(cloudflare_api_token)
KEYSTORE_NAMES+=(cloudflare_account_id)

# Future (placeholder, not implemented in MVP):
# KEYSTORE_NAMES+=(stripe_secret_key)
# KEYSTORE_NAMES+=(resend_api_key)
# KEYSTORE_NAMES+=(supabase_service_role_key)
# KEYSTORE_NAMES+=(turnstile_secret_key)
# KEYSTORE_NAMES+=(mikrus_api_key)
# KEYSTORE_NAMES+=(backblaze_b2_application_key)
# KEYSTORE_NAMES+=(github_pat)
```

### 3.3 Backend selection (`detect.sh`)

Priority:
1. `STACKPILOT_KEYSTORE` env override → use that backend (error if unavailable).
2. macOS + `security` CLI present → `keychain`.
3. Linux + `secret-tool` present + `DBUS_SESSION_BUS_ADDRESS` set → `libsecret`.
4. Fallback → `file` (with warning banner once per session).

Cached in `STACKPILOT_KEYSTORE_ACTIVE` for the lifetime of the shell process.

### 3.4 Backend contract

Each `backend-*.sh` exports 5 functions:

```bash
_backend_available    # 0 if usable
_backend_set NAME VALUE
_backend_get NAME     # stdout: value
_backend_has NAME
_backend_rm NAME      # idempotent
_backend_list         # stdout: NAMEs
```

### 3.5 macOS Keychain backend

```bash
security add-generic-password \
  -U \
  -a "$NAME" \
  -s "stackpilot" \
  -w "$VALUE" \
  -T /usr/bin/security
```

`-T /usr/bin/security`: only `security` CLI can read silently. Keychain Access.app prompts on "Show password" (intentional user action, OK).

Read:
```bash
security find-generic-password -s "stackpilot" -a "$NAME" -w 2>/dev/null
```

List (filter to `stackpilot` service only):
```bash
security dump-keychain 2>/dev/null \
  | awk '/"svce"<blob>="stackpilot"/{p=1; next} p && /"acct"<blob>="([^"]+)"/{match($0,/"acct"<blob>="([^"]+)"/,a); print a[1]; p=0}'
```

### 3.6 libsecret backend

```bash
secret-tool store --label="stackpilot:$NAME" app stackpilot key "$NAME"
secret-tool lookup app stackpilot key "$NAME"
secret-tool clear app stackpilot key "$NAME"
secret-tool search --all --unlock app stackpilot 2>/dev/null | awk '/^attribute.key = /{print $3}'
```

### 3.7 Plain-file fallback

Location: `~/.config/stackpilot/keys/`
Permissions: dir `0700`, files `0600`.
First-use banner (once per shell session, suppressible via `STACKPILOT_KEYSTORE_FILE_ACK=1`):

```
⚠  Using plain-file keystore — keys stored unencrypted at:
    ~/.config/stackpilot/keys/

   Reason: no OS keystore detected (macOS Keychain / libsecret).
   File permissions: 0600 (owner read/write only)
   To upgrade: see docs/keystore.md
```

### 3.8 Session cache

`keystore_get` caches values in env (`STACKPILOT_KEY_CACHE_<NAME_UPPER>`) for the lifetime of the subprocess. Invalidated on `keystore_set` / `keystore_rm` for the same name. Scope is subprocess only — never persisted between invocations.

---

## 4. Wizard system (`lib/wizards/`)

### 4.1 Wizard contract (`_contract.sh`)

Each `lib/wizards/<provider>.sh` MUST export 4 functions:

```bash
wizard_required_keys()           # stdout: canonical names, one per line
wizard_check()                   # 0 = all present+valid, 1 = missing, 2 = invalid
wizard_validate KEY VALUE        # stateless; 0 ok, 2 invalid, 3 unreachable, 4 missing scope
wizard_run()                     # interactive; idempotent
```

`wizard_run` is idempotent: 10 invocations with all valid keys end in "already configured" within ~1 sec.

### 4.2 Shared helpers (`_helpers.sh`)

```bash
open_browser URL
prompt_secret MSG_KEY            # read -s, returns value via stdout
prompt_continue MSG_KEY
print_step N TOTAL MSG_KEY
http_get_json URL HEADER...      # curl, 10s timeout, 1 retry
emit_error CODE PROVIDER KEY DETAIL HINT
```

### 4.3 Error protocol (bash → skill contract)

On non-zero exit, the wizard emits exactly one line to stderr:

```
STACKPILOT_ERR code=<int> provider=<name> key=<name|-> detail="<human>" hint="<short>"
```

Examples:
```
STACKPILOT_ERR code=2 provider=cloudflare key=cloudflare_api_token detail="API returned 401" hint="token revoked or wrong value"
STACKPILOT_ERR code=4 provider=cloudflare key=cloudflare_api_token detail="missing scope: Zone:DNS:Edit" hint="recreate token with DNS Edit permission"
STACKPILOT_ERR code=3 provider=cloudflare key=- detail="curl timeout to api.cloudflare.com" hint="network issue or cloudflare api outage"
```

### 4.4 Exit code map

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | user cancelled (Ctrl-C / empty input) |
| 2 | invalid credential value (API rejected) |
| 3 | API unreachable (network / outage) |
| 4 | insufficient permissions (token works, missing scope) |
| 5 | keystore backend error |
| 10+ | provider-specific |

### 4.5 Cloudflare wizard (`cloudflare.sh`)

**Required keys:**
- `cloudflare_api_token`
- `cloudflare_account_id`

**Excluded from MVP** (fetched on-demand later):
- `cloudflare_zone_id` (per-domain, not per-user)

**Token permissions (instructions hardcoded in wizard):**
```
Account → Cloudflare Pages       → Edit
Account → Workers R2 Storage     → Edit
Zone    → DNS                    → Edit
Zone    → Zone                   → Read

Account Resources: All accounts (or specific)
Zone Resources:    All zones from all accounts (or specific)
TTL: no expiry
```

**Validation calls (in order):**
1. `GET https://api.cloudflare.com/client/v4/user/tokens/verify` (Bearer auth).
   - 200 + `result.status=active` → continue.
   - 401/403 → exit 2.
   - timeout → exit 3.
2. `GET https://api.cloudflare.com/client/v4/accounts`.
   - 1 account → auto-fill `cloudflare_account_id`.
   - Many accounts → prompt user to pick.
   - 0 accounts → exit 4 (token has no account access).
3. Scope smoke tests (parallelize OK):
   - `GET /accounts/$ACC/pages/projects?per_page=1` — Pages:Edit
   - `GET /accounts/$ACC/r2/buckets?per_page=1` — R2:Edit
   - `GET /zones?per_page=1` — Zone:Read
   - DNS:Edit: skip if user has no zones (verified on first use); otherwise list one zone and check.

**Save only after all validations pass.**

---

## 5. Public CLI (`local/keys.sh`)

stackpilot today uses the `./local/<script>.sh` convention (no top-level `stackpilot` binary dispatcher). The keystore CLI follows the same pattern:

```bash
./local/keys.sh add <provider>          # runs wizard_run for provider
./local/keys.sh get <name>              # prints value to stdout (for shell scripting)
./local/keys.sh list                    # lists all stored stackpilot.* keys + backend
./local/keys.sh rm <name|provider>      # removes single key or all provider keys
./local/keys.sh test <provider>         # runs wizard_check; clear status output
./local/keys.sh migrate <provider>      # imports legacy config file to keystore
./local/keys.sh backend                 # prints active backend name + reasoning
```

When installed on a server via `install-toolbox.sh`, the script is reachable as `keys.sh` on `$PATH`.

`get` writes value as-is to stdout (no newline). Used by other scripts:

```bash
export CF_API_TOKEN="$(./local/keys.sh get cloudflare_api_token)"
```

If key missing, exit 1 with stderr hint *"key not found; run: ./local/keys.sh add cloudflare"*.

(Documentation and skill UX may refer to the conceptual `stackpilot keys ...` form; the actual invocation in v1 is `./local/keys.sh`.)

### `migrate`

Reads existing `~/.config/cloudflare/config` (current stackpilot format) and imports into keystore. Deletes source file ONLY after confirming all values readable from keystore. Idempotent.

---

## 6. AI skill (`vault/skills/stackpilot-keys/SKILL.md`)

### 6.1 Triggers

- `/stackpilot-keys`, `/keys add cloudflare`, "skonfiguruj cloudflare", "ustaw klucze stackpilot"
- Implicit: when another stackpilot action fails with `STACKPILOT_ERR code=2|4|5` → suggest invoking this skill
- "potrzebuję klucza X", "gdzie wziąć token Y", "co stackpilot wie o moim cloudflare"

### 6.2 Decision flow

```
1. User signals provider need (explicit or via failed deploy).
2. Run: `stackpilot keys test <provider>`
3. Parse exit code:
   - 0 → "Already configured ✓" + show `keys list` summary
   - 1 → run wizard via `stackpilot keys add <provider>`
   - 2 → parse stderr STACKPILOT_ERR; explain in user's language; suggest action
   - 4 → parse missing scope; provide URL + exact menu path; offer to retry
   - 3 → check network; if user offline, defer
4. After wizard exits 0: announce save + show how to inspect.
```

### 6.3 Language

Polish for Pawel and Polish-speaking users; English fallback. Skill detects from conversation context — no flag needed.

### 6.4 What skill does NOT do

- Does NOT call `security` / `secret-tool` / file ops directly. All keystore ops via `stackpilot keys ...` CLI.
- Does NOT hardcode provider URLs or permissions. Those live in `lib/wizards/`. Skill only reads stderr and translates.
- Does NOT proactively read keys. Only when user asks.

---

## 7. Migration & backwards-compat

### 7.1 Existing config files in stackpilot

- `~/.config/cloudflare/config` — current `setup-cloudflare.sh` output. Format: shell-sourceable `CF_API_TOKEN="..."` lines.

### 7.2 Migration strategy

`stackpilot keys migrate cloudflare` auto-detects `~/.config/cloudflare/config`, parses, imports to keystore, then prompts for confirmation to delete source file.

`setup-cloudflare.sh` continues to work but emits a deprecation note pointing to `stackpilot keys add cloudflare`. Both write to the keystore through the new core API (one source of truth).

Scripts that read CF credentials (e.g., `dns-add.sh`) get a 3-line shim:
```bash
if [ -z "$CF_API_TOKEN" ]; then
  CF_API_TOKEN="$(stackpilot keys get cloudflare_api_token 2>/dev/null)"
fi
# Legacy fallback for unmigrated users:
if [ -z "$CF_API_TOKEN" ] && [ -f "$HOME/.config/cloudflare/config" ]; then
  source "$HOME/.config/cloudflare/config"
fi
```

---

## 8. i18n (`locale/`)

New MSG_* keys added to `locale/en.sh` and `locale/pl.sh`:

```
MSG_KEYSTORE_BACKEND_KEYCHAIN
MSG_KEYSTORE_BACKEND_LIBSECRET
MSG_KEYSTORE_BACKEND_FILE_WARN
MSG_KEYSTORE_NAME_INVALID
MSG_KEYSTORE_VALUE_EMPTY
MSG_KEYSTORE_KEY_NOT_FOUND
MSG_KEYSTORE_SAVED
MSG_KEYSTORE_REMOVED

MSG_WIZARD_CF_HEADER
MSG_WIZARD_CF_OPENING
MSG_WIZARD_CF_STEP1_TITLE
MSG_WIZARD_CF_STEP2_TITLE
MSG_WIZARD_CF_PERMS_HEADER
MSG_WIZARD_CF_PERMS_PAGES
MSG_WIZARD_CF_PERMS_R2
MSG_WIZARD_CF_PERMS_DNS
MSG_WIZARD_CF_PERMS_ZONE_READ
MSG_WIZARD_CF_RESOURCES_ACCOUNTS
MSG_WIZARD_CF_RESOURCES_ZONES
MSG_WIZARD_CF_PASTE_TOKEN
MSG_WIZARD_CF_VERIFYING
MSG_WIZARD_CF_TOKEN_OK
MSG_WIZARD_CF_TOKEN_INVALID
MSG_WIZARD_CF_NO_ACCOUNTS
MSG_WIZARD_CF_MULTIPLE_ACCOUNTS
MSG_WIZARD_CF_SCOPE_OK
MSG_WIZARD_CF_SCOPE_MISSING
MSG_WIZARD_CF_SAVED
```

`emit_error` writes English (STACKPILOT_ERR line is the machine-readable contract — never localized).

---

## 9. Testing strategy (TDD)

**Pre-existing infrastructure:** `tests/run.sh unit|static|e2e` (66 unit tests today).

### 9.1 New test directories

```
tests/unit/keystore/         # API + detect tests
tests/unit/backends/         # contract test parameterized per backend
tests/unit/wizards/          # contract + cloudflare-specific
tests/integration/wizards/   # real-API tests (opt-in via env)
```

### 9.2 Order of writing (test first, code second)

Each function below: write failing test → write minimal code → green → next.

1. **keystore core** — name validation, value validation, set/get roundtrip (with mock backend).
2. **backend-file** (simplest backend, no system deps) — file perms, set/get/list/rm.
3. **backend-keychain** (macOS only) — gated by `command -v security`, full contract.
4. **backend-libsecret** (Linux only) — gated by `command -v secret-tool` + DBus availability.
5. **detect** — env override, auto-pick logic, error when override unavailable.
6. **wizard contract compliance** — generic test loaded once per wizard.
7. **cloudflare wizard validate** — against mock HTTP (`nc`/python http.server) for offline CI; opt-in real API test gated by `$CF_TEST_TOKEN`.
8. **public CLI** — argument parsing, exit codes, stderr format.
9. **end-to-end migrate** — fixture with old config file → run migrate → assert keystore + source deleted.

### 9.3 Mock backend for unit tests

`tests/_helpers/mock-backend.sh` — in-memory associative-array implementation. Used by keystore core tests that should not touch real keychain.

### 9.4 Mock Cloudflare API for wizard tests

`tests/_helpers/mock-cf-server.sh` — runs `python3 -m http.server` with response-table fixtures. Tests set `STACKPILOT_CF_API_URL` env override to redirect the wizard.

### 9.5 Static checks

`tests/static/`:
- shellcheck on all new files (zero warnings)
- locale parity check (all MSG_* keys present in both en.sh and pl.sh)
- contract check: every `wizards/*.sh` defines the 4 required functions
- contract check: every `backends/backend-*.sh` defines the 5 required functions

---

## 10. Security posture

**Threat model — what we protect against:**
- Plain-text secrets readable by other local user accounts (mode 644 mistakes).
- Plain-text secrets accidentally committed to git (none in working tree).
- Secrets logged in shell history / process listings (`ps`, `set -x`).

**Threat model — what we do NOT protect against:**
- Malicious processes running as the same user (they can call `security`/`secret-tool` themselves — no way to prevent in user-space).
- Compromised AI subprocess (skill itself could exfiltrate; that's the trust model of running AI on local files).
- Physical device theft (keychain/libsecret lock on user logout — partial protection).

**Defensive choices:**
- `keystore_get` uses `printf` (not `echo`) and never tees to log. Callers responsible for not echoing.
- macOS ACL: `-T /usr/bin/security` (specific allow), NOT `-A` (any-app allow).
- File backend: explicit chmod 600; dir chmod 700; `.gitignore` template in `docs/` warns users.
- Wizard validates before save — invalid token never reaches keystore.
- `keystore_list` shows names only, never values. Reading values requires explicit `get NAME`.

---

## 11. File layout summary

```
projects/stackpilot/
├── lib/
│   ├── keystore/
│   │   ├── core.sh
│   │   ├── detect.sh
│   │   ├── names.sh
│   │   ├── backend-keychain.sh
│   │   ├── backend-libsecret.sh
│   │   └── backend-file.sh
│   └── wizards/
│       ├── _contract.sh
│       ├── _helpers.sh
│       └── cloudflare.sh
├── local/
│   └── keys.sh
├── locale/
│   ├── en.sh   (extended)
│   └── pl.sh   (extended)
├── tests/
│   ├── unit/
│   │   ├── keystore/   (new)
│   │   ├── backends/   (new)
│   │   └── wizards/    (new)
│   ├── integration/
│   │   └── wizards/    (new)
│   └── _helpers/
│       ├── mock-backend.sh
│       └── mock-cf-server.sh
├── docs/
│   ├── keystore.md     (new — user-facing: backends, upgrade paths, FAQ)
│   └── superpowers/specs/2026-05-27-keystore-wizard-design.md  (this file)
└── (in vault, not stackpilot repo:)
    vault/skills/stackpilot-keys/SKILL.md
```

---

## 12. Out of scope (explicit non-goals)

- Windows native backend (uses file fallback for v1; Windows Credential Manager in v2).
- Key rotation automation (manual `keys rm` + `keys add` for v1).
- Multi-account support per provider (one CF token per machine for v1).
- iCloud Keychain sync (explicitly opted out; items stored without `-l` label).
- MCP server tools for keystore (no new MCP commands; user can still call CLI from MCP-driven flows).
- Encrypted file backend with passphrase (age/gpg). Plain file is the only fallback; users wanting more upgrade to keychain or libsecret.

---

## 13. Open questions resolved during brainstorming

| Q | Resolved as |
|---|---|
| MVP scope | Cloudflare only; framework extensible. |
| Platforms v1 | macOS + Linux libsecret + plain-file fallback. |
| AI vs bash | Hybrid: bash core does all logic; AI skill is conversational wrapper. |
| MCP changes | None — out of scope for v1. |
| TDD | Mandatory — tests first for every keystore + wizard function. |
| Existing `setup-cloudflare.sh` | Stays, emits deprecation; uses new keystore under the hood. |

---

## 14. Acceptance checklist

Implementation is "done" when:

- [ ] All test suites pass: `./tests/run.sh unit` AND `./tests/run.sh static`
- [ ] `shellcheck` returns zero warnings on every new file
- [ ] `stackpilot keys add cloudflare` runs end-to-end on macOS (Keychain) and on Linux (libsecret in CI Docker)
- [ ] `stackpilot keys add cloudflare` on a system without keychain/libsecret falls back to file with a warning
- [ ] `stackpilot keys get cloudflare_api_token` returns the stored token to stdout
- [ ] `stackpilot keys list` returns exactly the keys saved by the wizard
- [ ] `stackpilot keys rm cloudflare` removes both `cloudflare_api_token` and `cloudflare_account_id`
- [ ] `stackpilot keys migrate cloudflare` imports an existing `~/.config/cloudflare/config`
- [ ] Skill MD lives at `vault/skills/stackpilot-keys/SKILL.md` and triggers on intent phrases
- [ ] `docs/keystore.md` exists and documents backends + upgrade paths
- [ ] `STACKPILOT_ERR` lines are emitted on every non-zero wizard exit
- [ ] Zero macOS popups during `keys get` after first `keys add` (verified manually)
