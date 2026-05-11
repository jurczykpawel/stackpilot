# Deploy Static Sites to Cloudflare Pages

One-command deployment of any supported static framework (Astro, Next.js static export, Hugo, Eleventy, SvelteKit static, Gatsby, Docusaurus, VitePress, MkDocs) to **Cloudflare Pages**.

Zero hosting cost, global CDN, free TLS, no VPS required.

If you'd rather host on your own VPS, see [`deploy-static.sh`](../GUIDE.md#static-site-deployment-deploy-static-sites-astro-nextjs-hugo--in-one-command). The two scripts share the same framework auto-detection.

---

## TL;DR

```bash
# First time — interactive wizard (token + Account ID, ~2 min):
./local/setup-cloudflare-pages.sh

# Every time — deploy:
cd your-site
./local/deploy-static-cf.sh your-domain.com
```

---

## What the deploy script does

```
[1] Load CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID
    (env vars first, then ~/.config/cloudflare/config)
[2] Verify token is valid                      → GET /user/tokens/verify
[3] Verify Pages:Edit scope                    → GET /accounts/{id}/pages/projects
[4] Verify npx is available
[5] Auto-detect framework + build
[6] Create Pages project if missing            → POST /pages/projects
[7] Upload build output                        → npx wrangler@latest pages deploy
[8] Attach custom domain (idempotent)          → POST /pages/projects/{name}/domains
```

If anything in steps 1–4 fails, the script prints a step-by-step setup guide and exits **before** running a build. You never waste time building only to fail at upload.

---

## One-time setup — three options

### Option A: Interactive wizard (recommended for first-time users)

```bash
./local/setup-cloudflare-pages.sh
```

The wizard:

1. Opens your browser at the Cloudflare token-creation page with the right scope template preselected.
2. Asks you to paste the token (hidden input).
3. Verifies the token against `/user/tokens/verify`.
4. Auto-detects your Account ID if the token has `Account:Read`. Otherwise prompts for it and validates the format.
5. Probes `Pages:Edit` permission to confirm the token actually works.
6. Asks where to save credentials — shell rc (recommended), `~/.config/cloudflare/config`, or just print them.

You can re-run the wizard any time. If credentials already work, it tells you and exits.

### Option B: Manual env vars

If you'd rather skip the wizard:

```bash
# In your ~/.zshenv (zsh) or ~/.bashrc (bash):
export CLOUDFLARE_API_TOKEN='your-token-here'
export CLOUDFLARE_ACCOUNT_ID='your-account-id-here'
```

Then `source ~/.zshenv` and re-run `deploy-static-cf.sh`.

### Option C: Config file

```bash
mkdir -p ~/.config/cloudflare && chmod 700 ~/.config/cloudflare
cat >> ~/.config/cloudflare/config <<EOF
API_TOKEN=your-token-here
ACCOUNT_ID=your-account-id-here
EOF
chmod 600 ~/.config/cloudflare/config
```

This file is also used by `setup-cloudflare.sh` (for DNS automation), so you can keep one shared token if you want — see [Token reuse with `setup-cloudflare.sh`](#token-reuse-with-setup-cloudflaresh) below.

---

## Creating the API token by hand (without the wizard)

1. Open <https://dash.cloudflare.com/profile/api-tokens>
2. Click **Create Token → Create Custom Token**
3. Name: `stackpilot-pages`
4. Permissions:
   - **Account → Cloudflare Pages → Edit** (required)
   - **User → User Details → Read** (auto-added)
   - **Account → Account Settings → Read** (optional — improves error messages)
   - **Zone → DNS → Edit** (optional — only if you want the script to auto-create the CNAME record for your custom domain)
5. Account Resources: Include → your account
6. Zone Resources: Include → the specific zone (only if you added `Zone:DNS`)
7. **Create Token** → copy it.

Then find your Account ID:

1. Open <https://dash.cloudflare.com>
2. Click any domain (or stay on the overview)
3. Copy **Account ID** from the right sidebar (32 hex chars).

---

## Deploying

```bash
./local/deploy-static-cf.sh DOMAIN [PROJECT_NAME] [PROJECT_DIR]
```

| Argument       | Required | Default                                              |
| -------------- | -------- | ---------------------------------------------------- |
| `DOMAIN`       | yes      | —                                                    |
| `PROJECT_NAME` | no       | Derived from `DOMAIN` (`.` → `-`, lowercase, ≤58 ch) |
| `PROJECT_DIR`  | no       | `.` (current directory)                              |

Examples:

```bash
# Deploy current directory to a custom domain:
cd my-astro-site
./local/deploy-static-cf.sh my-site.com

# Custom project slug:
./local/deploy-static-cf.sh my-site.com my-cf-slug

# Build from a different directory:
./local/deploy-static-cf.sh my-site.com my-cf-slug ~/code/my-astro-site

# Deploy only to the default Cloudflare subdomain (no custom domain):
./local/deploy-static-cf.sh my-slug.pages.dev
```

When the `DOMAIN` ends in `.pages.dev`, the script skips the custom-domain attach step (`.pages.dev` is Cloudflare's reserved default — you don't attach it, it just exists).

---

## Attaching a custom domain

After the upload, the script tries to attach `DOMAIN` to the Pages project via `POST /pages/projects/{name}/domains`. The call is idempotent — re-running the deploy doesn't re-attach a domain that's already there.

For HTTPS to work, Cloudflare must (a) know `DOMAIN` belongs to your Pages project, and (b) receive traffic for it. Which means **DNS for `DOMAIN` must resolve to `{PROJECT_NAME}.pages.dev`** (via CNAME). Cloudflare handles cert issuance once that's true.

There are three common scenarios. The script handles all of them; the only thing that differs is who edits the DNS record.

### Scenario 1 — Your domain is already on Cloudflare DNS

This is the easiest path. You bought the domain somewhere (Namecheap, Porkbun, OVH, etc.), then added it to Cloudflare and switched your registrar's nameservers to the two CF nameservers (e.g. `aria.ns.cloudflare.com`, `brett.ns.cloudflare.com`). Cloudflare is now your authoritative DNS.

**If your token has `Zone:DNS:Edit` on this zone**, the script's API call to `/domains` triggers Cloudflare to auto-create the CNAME. Wait ~30 seconds for the cert and you're done.

**If your token has only `Pages:Edit`** (no DNS scope), the script attaches the domain to the project but cannot write DNS. The script prints the exact record to add manually in the CF dashboard:

```
Type:    CNAME
Name:    your-domain.com    (or just 'www' if it's www.your-domain.com)
Target:  your-project.pages.dev
Proxy:   ON (orange cloud)
TTL:     Auto
```

Cert issues within ~30s after the CNAME exists.

### Scenario 2 — Your domain is at a different DNS provider

Your registrar (or a separate DNS provider) holds your nameservers — Cloudflare is not your authoritative DNS for this domain.

This still works for Cloudflare Pages, but **you have to add the CNAME at your existing DNS provider**, not on Cloudflare. Examples:

| DNS provider     | Where to add the CNAME                                |
| ---------------- | ----------------------------------------------------- |
| Namecheap        | Domain List → Manage → Advanced DNS → Add New Record  |
| Porkbun          | Domain → DNS Records                                  |
| OVH              | Domain → Zone DNS                                     |
| Google Domains   | DNS → Custom records                                  |
| AWS Route 53     | Hosted zone → Create record                           |

In all cases the record itself is the same:

```
Type:    CNAME
Host:    your-domain.com    (or '@' for apex on providers that support it, or 'www')
Value:   your-project.pages.dev
TTL:     Auto / 300         (let provider default)
```

After saving the CNAME, Cloudflare Pages will detect it (usually within a minute), issue a TLS cert, and start serving the site.

> **Apex domains and CNAME flattening:** RFC technically forbids `CNAME` at the zone apex (`your-domain.com` without a subdomain). Some DNS providers (Cloudflare itself, Route 53, DNSimple) support **CNAME flattening** as a workaround. If yours doesn't, use a subdomain (`www.your-domain.com`) — most providers redirect the apex to it automatically.

### Scenario 3 — Subdomain on an already-managed apex

Common case: your `your-domain.com` is on Cloudflare DNS, and you want to deploy a project at `blog.your-domain.com` or `docs.your-domain.com`.

```bash
./local/deploy-static-cf.sh blog.your-domain.com
```

The script will:

1. Create the Pages project (`blog-your-domain-com` slug by default).
2. Attach `blog.your-domain.com` as a custom domain.
3. If token has `Zone:DNS:Edit`, auto-create the CNAME. Otherwise, print the manual record.

No special handling needed — the script treats subdomains and apexes the same way.

### What if the domain attach fails?

The script's attach step is non-blocking — if it fails, you still see `🎉 Done` and the deploy is live at the default `.pages.dev` URL. The custom-domain step just won't have completed.

Most common failure messages:

| Cloudflare error code | What it means                                       | Fix                                                                                       |
| --------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `8000015`             | Domain is reserved (you passed a `.pages.dev` URL)  | Use a real custom domain, or drop the custom-domain step entirely (it's optional).        |
| `8000016`             | Domain belongs to a different Cloudflare account    | Move the domain to this account, or use a domain in this account.                         |
| `8000018`             | Domain not registered in Cloudflare                 | Either add the domain to CF DNS (Scenario 1) or attach via dashboard and add CNAME (Scenario 2). |
| `8000013`             | Domain already attached to a different project      | Detach it from the other project first, or use a different subdomain.                     |

You can always attach the domain manually in the dashboard:

```
https://dash.cloudflare.com/{ACCOUNT_ID}/pages/view/{PROJECT_NAME}/domains
```

---

## Supported frameworks

Detection is config-file based — the same logic as `deploy-static.sh`. See the [GUIDE.md table](../GUIDE.md#option-1-deploy-staticsh-one-command-auto-detects-framework) for the full list.

If your project uses one of the listed frameworks but with a non-standard config filename, build manually and call wrangler directly:

```bash
npx wrangler@latest pages deploy ./your-output-dir \
    --project-name=your-slug --branch=main
```

---

## Token reuse with `setup-cloudflare.sh`

StackPilot has two Cloudflare-related setups:

| Wizard                                  | Token scopes needed                                              | Used by                          |
| --------------------------------------- | ---------------------------------------------------------------- | -------------------------------- |
| `./local/setup-cloudflare.sh`           | `Zone:Read` + `Zone:DNS:Edit`                                    | `dns-add.sh` (VPS DNS records)   |
| `./local/setup-cloudflare-pages.sh`     | `Account:Pages:Edit` (+ optional `Zone:DNS:Edit` for auto-CNAME) | `deploy-static-cf.sh`            |

Both store credentials in `~/.config/cloudflare/config`. You can:

- **Use one combined token** — create a single token with `Zone:DNS:Edit` + `Account:Pages:Edit`. Run either wizard with that token.
- **Use separate tokens** — re-run a wizard to overwrite the stored token. Whichever wizard ran last wins.
- **Use env vars only** — `CLOUDFLARE_API_TOKEN` always wins over the config file, so you can keep different tokens per shell.

---

## Troubleshooting

**Script exits with "missing CLOUDFLARE_API_TOKEN"**
Run `./local/setup-cloudflare-pages.sh`, or export the env vars manually.

**"Token is missing 'Account → Cloudflare Pages → Edit' permission"**
Your token has other scopes (e.g. `Zone:DNS`) but not Pages. Re-run the wizard or create a new token with the right scope.

**"Account ID '...' not found"**
The Account ID is wrong, or the token is restricted to a different account. Double-check both.

**Custom domain attach fails with HTTP 400, code 8000015 (reserved)**
You passed a `.pages.dev` domain. Use any other domain, or omit the custom-domain step (the deploy itself still succeeds at `https://{project}.pages.dev`).

**Build succeeds but deploy says "0 files"**
The output directory matched but is empty. Check that the framework's build actually produced files in the expected output directory.

**"npx is not installed"**
Install Node.js LTS from <https://nodejs.org/> or via your package manager (`brew install node`, `nvm install --lts`, etc.).

---

## Related

- [`deploy-static.sh`](../GUIDE.md#static-site-deployment-deploy-static-sites-astro-nextjs-hugo--in-one-command) — same auto-detection but deploys to your VPS via Caddy
- [`setup-cloudflare.sh`](./cloudflare-domain-setup.md) — DNS automation for the VPS-Caddy path
- [Cloudflare Pages docs](https://developers.cloudflare.com/pages/) — official upstream docs
