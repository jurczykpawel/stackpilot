# Backup - Protect Your Data

## Option A: Database Backup (automatic, daily)

Automatic daily backup of databases running on your server. Auto-detects PostgreSQL and MySQL containers.

**What is backed up:**
- PostgreSQL database dumps (all detected containers)
- MySQL database dumps (all detected containers)

**When to use:**
- You have apps with database containers (n8n, listmonk, WordPress, etc.)
- You want automated daily backups without manual intervention

**Setup:**
```bash
# Via MCP:
setup_backup(backup_type='db')

# Or via CLI:
./local/setup-backup.sh vps
```

The script auto-detects running database containers and creates a cron job for daily dumps.

**Manual backup run:**
```bash
ssh vps '/opt/stackpilot/system/setup-db-backup.sh'
```

---

## Option B: Cloud Backup (Google Drive / Dropbox / S3)

Encrypted backup to your own cloud storage - no limits, full control.

**What is backed up:**
- `/opt/stacks/` - all Docker applications (n8n, Listmonk, data volumes)
- `/opt/dockge/` - container management panel (if installed)

**Supported providers:**
Google Drive (15GB free), Dropbox, OneDrive, Amazon S3, Wasabi, MinIO, Mega

**Local requirements:**
- Terminal with SSH access
- Rclone: Mac `brew install rclone` | Linux `curl https://rclone.org/install.sh | sudo bash` | Windows `winget install rclone`

**Setup:**
```bash
./local/setup-backup.sh           # uses default SSH alias
./local/setup-backup.sh vps       # or specify the server
```

The wizard guides you through: choose provider -> log in via browser -> encryption (recommended).
The server will run the backup every night at 3:00 AM via cron.

**Restore:**
```bash
./local/restore.sh           # uses default SSH alias
./local/restore.sh vps       # or specify the server
```

**Manual backup / verification:**
```bash
ssh vps '~/backup-core.sh'
ssh vps 'tail -50 /var/log/stackpilot-backup.log'
```

**See what is in the cloud:**
```bash
ssh vps 'rclone ls backup_remote:vps-backup/stacks/'
```

**Customize backed-up directories:**
```bash
ssh vps 'nano ~/backup-core.sh'
```
Find the `SOURCE_DIRS` section and add/remove directories:
```bash
SOURCE_DIRS=(
    "/opt/dockge"
    "/opt/stacks"
    "/home"
    "/etc/caddy"
)
```

> Backups are encrypted on the server before upload. Even your cloud provider cannot read your data.
