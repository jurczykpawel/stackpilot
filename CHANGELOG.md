# Changelog

User-facing changes to StackPilot. Entries are dated; the project follows the `main` branch.

## 2026-11-26

### Changed

- **Application ports listen on `127.0.0.1` for new installations** of affine, cap, dockge, gotenberg, linkstack, listmonk, minio, n8n, nocodb, ntfy, sgtm, stirling-pdf, supabase (HTTP gateway), typebot, umami, uptime-kuma and vaultwarden. Reach them through a domain or an SSH tunnel. `--domain-type=cytrus` still publishes them on all interfaces. Containers that used the host IP to talk to another application need its domain or a shared Docker network. The Supabase database pooler (5432/6543) is unchanged, see `apps/supabase/README.md`.
- **MinIO:** `PORT` now sets the Console port (default 9001), `API_PORT` the S3 API port (default 9000). `CONSOLE_PORT` is no longer read.
- **Shared WordPress cache:** the shared Redis now requires a password and is published only on the Docker bridge address. Sites receive the password automatically. Anything you connected to it by hand needs the password too.
- **Postiz** uses its own Redis (`noeviction`) by default. `POSTIZ_REDIS=external` or `auto` selects the Redis on the host. Existing installations keep the Redis they use.
- **`--domain-type=caddy`** installs Caddy when it is missing. If Caddy or the domain cannot be set up, including after a successful Cloudflare DNS step, the deploy now exits with an error and does not report success. An existing custom Caddyfile is kept: only the `conf.d` import is added, and the previous file is saved as `Caddyfile.before-stackpilot`.
- The one-line installer installs `sudo` when the system has none.

### Removed

- **RoutePix** is no longer in the catalog: its source repository is private, so the installer could not work for anyone (#35).

### Fixed

- **MinIO** (also the MinIO bundled with Cap and Plunk) installs again: the `minio/minio` image no longer exists, so the installers now use the maintained fork `pgsty/silo`, pinned to `RELEASE.2026-11-12T00-00-00Z`. Reasons and upgrade steps: `apps/minio/README.md` (#36).
- The n8n installer no longer says it uses an external PostgreSQL when it starts the bundled one, and the README memory guidance matches the n8n requirements (#27).
- Docker installation on a clean Debian server through the one-line installer (#28).
- `--domain-type=caddy` reporting a configured domain without Caddy on the server (#25).
- Application ports published on all interfaces although the documentation says `127.0.0.1` (#26).
- The domain was not passed to the MinIO and Typebot installers because `deploy.sh` could not detect their ports.
- `system/caddy-install.sh` failing when `TOOLBOX_LANG` is set.
- `deploy.sh` now passes `WP_REDIS`, `POSTIZ_REDIS` and, for WordPress and Postiz, `REDIS_PASS` to the installer.

### Existing installations

1. **Update the toolbox first.**
   - On your computer: `git pull` in your StackPilot clone.
   - On a server with a git checkout (set up by the one-line installer): `git -C /opt/stackpilot pull` (with `sudo` if you are not root). The application one-liners do not update an existing checkout.
   - On a server set up with `./local/install-toolbox.sh`: run that script again from your updated clone.
2. **WordPress with the shared Redis:** run the update once.
   - From your computer: `./local/deploy.sh wordpress --ssh=ALIAS --update`
   - On the server: `deploy.sh wordpress --update`

   Cached data and site content are kept; sites may report a Redis connection error for a few seconds. Details: `apps/wordpress/README.md`.
3. **Ports of other applications:** `--update` keeps the existing Compose file. To bind an older installation to localhost, prefix each web entry under `ports:` with `127.0.0.1:` and run `sudo docker compose up -d` in `/opt/stacks/<app>/`. Skip this for `--domain-type=cytrus`. Do not re-run the installer for this: for some applications it generates new secrets.
4. **Postiz on the shared Redis:** the WordPress update adds the password to its configuration. To move it to its own Redis, follow `apps/postiz/README.md`.
5. **If a Docker installation failed on Debian before:** update the checkout (step 1), or run `curl -fsSL https://stackpilot.techskills.academy/install | bash`, then repeat the application one-liner.
