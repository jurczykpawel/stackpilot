# LinkStack - Link in Bio (Admin Version)

Your own "Link in Bio" page (like Linktree), but on your server.

**RAM:** ~200MB | **Disk:** ~600MB | **Plan:** 1GB+ RAM VPS

## Installation

```bash
# Caddy (auto domain)
./local/deploy.sh linkstack --ssh=ALIAS --domain-type=caddy --domain=links.your-domain.com --yes

# Cloudflare (own domain)
./local/deploy.sh linkstack --ssh=ALIAS --domain-type=cloudflare --domain=links.example.com --yes

# No domain (access via SSH tunnel)
./local/deploy.sh linkstack --ssh=ALIAS --domain-type=local --yes
```

## Configuration (Setup Wizard)

After installation, open the URL and go through the wizard. **Important choice:**

### Database

**Are you a solopreneur / building a page for yourself?**

Choose **SQLite** and do not think twice. Zero configuration, works out of the box.

**Building this for a company where multiple people will edit profiles?**

Choose **MySQL** - handles concurrent edits better.

<details>
<summary>Technical details</summary>

| Scenario | Recommendation |
|----------|----------------|
| One profile (personal branding) | SQLite |
| A few profiles, occasional edits | SQLite |
| 500+ users with their own profiles | MySQL |
| Frequent simultaneous edits | MySQL |

SQLite handles up to 100K visits/day. The official LinkStack hosting only uses MySQL for 500+ user instances.

> When using MySQL you must back up the database yourself (with SQLite, backups before updates include the database automatically).

</details>

<details>
<summary>MySQL configuration</summary>

If using an external MySQL database, you will need:
- **Host** - database server address
- **Database** - database name
- **User** - username
- **Password** - password

In the wizard, select MySQL and enter your database credentials.

</details>

### Other settings

- **Admin credentials** - save securely, you will need them to log in
- **App Name** - name displayed on the page
- **App URL** - full URL with https:// (e.g. `https://links.your-domain.com`)

## LinkStack vs LittleLink

| Feature | LinkStack | LittleLink |
|---------|-----------|------------|
| Admin panel | Yes | No |
| Edit from phone | Yes | No |
| Click stats | Yes | No |
| RAM usage | ~200MB | ~30MB |
| Configuration | Wizard | HTML editing |

**Choose LinkStack** if you want a convenient panel and stats.
**Choose LittleLink** if you prefer a super-lightweight static page.

## Data Location

```
/opt/stacks/linkstack/
+-- data/              # All app data (back up this folder!)
|   +-- database/      # SQLite database
|   +-- .env           # Configuration
|   +-- ...            # App files
+-- docker-compose.yaml
```

## Management

```bash
# Logs
ssh ALIAS "docker logs -f linkstack-linkstack-1"

# Restart
ssh ALIAS "cd /opt/stacks/linkstack && docker compose restart"

# Update
ssh ALIAS "cd /opt/stacks/linkstack && docker compose pull && docker compose up -d"

# Backup
ssh ALIAS "tar -czf linkstack-backup.tar.gz -C /opt/stacks/linkstack data"
```

## Useful Links

- [LinkStack Docker](https://linkstack.org/docker/)
- [LinkStack Docs](https://docs.linkstack.org/)
