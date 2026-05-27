# stackpilot keystore

stackpilot stores provider credentials (API tokens, account IDs, etc.) in the OS keystore so they're encrypted at rest and not lying around as plain text in `~/.config/`.

## Backends

stackpilot auto-detects the best available backend on first use:

| Backend | Platform | How it stores | Notes |
|---|---|---|---|
| `keychain` | macOS | login Keychain via `security` CLI | Automatically unlocked when you log in to macOS. ACL set so `security` CLI reads silently — no popups during normal use. |
| `libsecret` | Linux | GNOME/KDE keyring via `secret-tool` (libsecret-tools) | Requires DBus session. Install: `apt install libsecret-tools` or `dnf install libsecret`. |
| `file` | fallback | plain text file in `~/.config/stackpilot/keys/` with mode `0600` | Used when no OS keystore is available (headless servers, containers, etc). A warning is shown once per session. |

Override the auto-detected backend:

```bash
export STACKPILOT_KEYSTORE=keychain    # or libsecret, or file
```

## CLI

```bash
./local/keys.sh add cloudflare         # interactive wizard for Cloudflare
./local/keys.sh list                   # see what's stored
./local/keys.sh get cloudflare_api_token   # print value (for scripts)
./local/keys.sh rm cloudflare          # remove all Cloudflare keys
./local/keys.sh test cloudflare        # re-verify stored keys against the API
./local/keys.sh backend                # which backend is active?
./local/keys.sh migrate cloudflare     # import ~/.config/cloudflare/config
```

## Inspecting raw storage

### macOS

Open **Keychain Access.app**, search for `stackpilot`. You'll see entries named after each canonical key (e.g. `cloudflare_api_token`). Clicking "Show password" will ask for your macOS login password — this is expected and normal (any GUI viewer triggers the prompt).

From the command line:

```bash
security find-generic-password -s stackpilot -a cloudflare_api_token -w
```

### Linux

```bash
secret-tool search --all app stackpilot
```

### Plain-file backend

Files at `~/.config/stackpilot/keys/<name>`, mode `0600`, one secret per file (no metadata).

## Security notes

**What this protects against:**
- Plain-text secrets in `~/.config/` readable by other local user accounts (mode 644 mistakes).
- Accidental git commits of secret files.
- Secrets logged in shell history or process listings.

**What this does NOT protect against:**
- Malicious processes running as your own user account — they can call `security` / `secret-tool` themselves. No user-space tool can prevent this.
- Compromised AI assistants — if you run an AI tool with shell access, it can read what you can read.
- Physical device theft — keychain/libsecret lock on user logout provides only partial protection.

## Upgrading from plain file to a real backend

If you started with the `file` backend (e.g. on a server) and later install libsecret or move to macOS:

```bash
# 1. Verify current backend
./local/keys.sh backend

# 2. Export keys to env (one at a time, never logged):
TOKEN=$(./local/keys.sh get cloudflare_api_token)
ACCOUNT=$(./local/keys.sh get cloudflare_account_id)

# 3. Remove from file backend
STACKPILOT_KEYSTORE=file ./local/keys.sh rm cloudflare

# 4. Re-add using new backend (auto-detected)
./local/keys.sh add cloudflare
# (paste the same TOKEN; the wizard validates and stores via the new backend)
```

## FAQ

**Q: Does this sync to iCloud Keychain?**
A: No. Items are stored in your local login Keychain without the iCloud sync attribute.

**Q: I see a popup asking for my password when I open Keychain Access.app — is something wrong?**
A: No. Keychain Access.app is a different program than `security` CLI, so it triggers the macOS authorization prompt by design. This is the expected user-facing security check.

**Q: How do I rotate a key?**
A: `./local/keys.sh rm <provider>` then `./local/keys.sh add <provider>` — paste the new token.

**Q: My token expired or was revoked — how do I tell?**
A: `./local/keys.sh test <provider>` — exits 2 if keys are present but invalid.

**Q: Can I use this without an AI assistant?**
A: Yes. The CLI works standalone with hardcoded prompts. The `stackpilot-keys` skill (for Claude Code / Cursor / etc.) is a conversational wrapper that adds intelligent error recovery — it never adds new functionality, only translates errors into friendlier language.
