# LinkStack - Link in Bio

Your own "Link in Bio" page (like Linktree), but on your own server.

## Installation

```bash
./local/deploy.sh linkstack --ssh=ALIAS --domain-type=cloudflare --domain=links.example.com
# or locally (SSH tunnel):
./local/deploy.sh linkstack --ssh=ALIAS --domain-type=local --yes
```

## Requirements

- **RAM:** ~256MB (container limit: 256MB)
- **Disk:** ~550MB (Docker image)
- **Port:** 8090

## After Installation

Open the URL and go through the setup wizard.

### Database Choice

**Solopreneur / single profile?**
Choose **SQLite** — zero configuration, works out of the box.

**Company with multiple employees editing profiles simultaneously?**
Choose **MySQL** — handles concurrent edits better.

<details>
<summary>Technical details</summary>

| Scenario | Recommendation |
|----------|----------------|
| One profile (personal branding) | SQLite |
| A few profiles, occasional edits | SQLite |
| 500+ users with their own profiles | MySQL |
| Frequent simultaneous edits | MySQL |

SQLite handles up to 100K visits/day. The official LinkStack hosting only uses MySQL for 500+ user instances.

> When using MySQL you must back up the database yourself (with SQLite, backups include the database automatically).

</details>

### Other Settings

- **Admin credentials** — save securely, you will need them to log in
- **App Name** — name displayed on the page
- **App URL** — full URL with https:// (e.g. `https://links.your-domain.com`)

## LinkStack vs LittleLink

| Feature | LinkStack | LittleLink |
|---------|-----------|------------|
| Admin panel | Yes | No |
| Edit from phone | Yes | No |
| Click stats | Yes | No |
| RAM usage | ~256MB | ~30MB |
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
