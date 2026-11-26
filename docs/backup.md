# Backup - Protect Your Data

StackPilot backs up the whole server with [restic](https://restic.net): one encrypted, deduplicated
snapshot every night, kept with daily, weekly and monthly history.

## What is backed up

| Data | How |
| :--- | :--- |
| `/opt/stacks` (every app: compose files, `.env`, bind-mounted data) | files |
| Named Docker volumes of those apps (e.g. `notifuse-data`, `picoclaw-workspace`) | files from the volume |
| PostgreSQL, MySQL/MariaDB and MongoDB running in app containers | consistent dump (`pg_dumpall`, `mysqldump`/`mariadb-dump`, `mongodump`) taken from the running container; the live database files are left out |
| SQLite files in app folders and volumes (`*.sqlite`, `*.sqlite3`, `*.db`) | consistent copy made with SQLite's online backup, next to the live file |
| Databases on other hosts listed in `/opt/stackpilot/config/db-credentials.conf` | `pg_dump` / `mysqldump` in a temporary container |
| `/opt/dockge`, `/etc/caddy` (domains), `/var/www` (static and PHP sites), `/opt/backups` | files |

Databases are found automatically from the running containers (by image: `postgres`, `pgvector`,
`postgis`, `mysql`, `mariadb`, `mongo`), whatever the service is called. A database container that
is stopped is copied as plain files, which is consistent because nothing writes to it.

Dumps and SQLite copies are prepared in `/opt/backups/stackpilot` and deleted once the snapshot is saved,
so the server does not keep a second copy of its databases on disk.

Every snapshot is encrypted on the server before upload. The storage provider sees only random chunks.

## Set up

```bash
./local/setup-backup.sh vps
```

The wizard asks where to keep the backups, generates the repository password, installs restic
(and `sqlite3`) on the server, creates or opens the repository and schedules the backup for 03:00 every day.

| Choice | Destination | You need |
| :--- | :--- | :--- |
| 1 (default) | Cloudflare R2 | account ID, bucket, R2 API token with Object Read & Write (access key ID + secret) |
| 2 | Backblaze B2 | bucket, application key for it, the bucket's S3 endpoint (`s3.<region>.backblazeb2.com`) |
| 3 | Any S3-compatible storage (AWS, Wasabi, MinIO...) | endpoint URL, bucket, access key, secret, region |
| 4 | SFTP (another server, NAS) | `user@host:/path`; the server's root must log in there with an SSH key |
| 5 | Directory on the server | an absolute path; for testing or a separate disk only |

A bucket that does not exist yet is created by the wizard when the key is allowed to create buckets
(an R2 token with Object Read & Write is not: create the bucket in the dashboard first). Wrong keys or a
missing bucket stop the wizard with restic's error message.

B2 is used through its S3-compatible API, as the restic documentation recommends. Set the bucket's
lifecycle rule to "Keep only the last version of the file" so pruned data is really deleted.

**The repository password is shown once.** Save it in your password manager. Without it no one,
including you, can read the backups. It is stored on the server in `/opt/stackpilot/config/backup.env`
(mode 600) together with the storage keys.

### Alerts when backups stop

Give the wizard a heartbeat URL from [healthchecks.io](https://healthchecks.io) or an Uptime Kuma
**Push** monitor. Each successful run calls the URL; a failed run calls `<URL>/fail`. The service
alerts you when the success call is missing, so you also hear about a server that stopped running backups.
To use a different failure URL, add `BACKUP_PING_FAIL_URL=...` to `backup.env`.

## Everyday commands

```bash
ssh vps '/usr/local/sbin/stackpilot-backup run'         # back up now
ssh vps '/usr/local/sbin/stackpilot-backup snapshots'   # list snapshots
ssh vps 'tail -50 /var/log/stackpilot-backup.log'       # last runs
```

Retention: 14 daily, 8 weekly and 12 monthly snapshots (`BACKUP_KEEP_DAILY`, `BACKUP_KEEP_WEEKLY`,
`BACKUP_KEEP_MONTHLY` in `backup.env` change it). On Sundays the run also checks the repository
with `restic check`.

## Restore

```bash
./local/restore.sh vps          # choose a snapshot, then one app or everything
./local/restore.sh vps n8n      # restore only n8n
```

Restoring an app stops it, puts back its folder in `/opt/stacks` and its Docker volumes, replaces its
SQLite files with the consistent copies, recreates each database from the dump (the old database data is
removed first) and starts the app. Restoring everything also brings back `/opt/dockge`, `/etc/caddy`
and `/var/www`. Changes made after the snapshot are lost; the script asks you to type `YES` first.

While a PostgreSQL dump loads you will see `ERROR: role "..." already exists` and
`database "..." already exists`. That is expected: the fresh database container creates its user and
database on first start, and the dump then fills them.

### On a new server

1. Install Docker on the new server.
2. Run `./local/setup-backup.sh new-vps` with the **same** storage details and paste the existing
   repository password when asked. The wizard reuses the repository and does not start a backup.
3. Run `./local/restore.sh new-vps` and restore everything.
4. Point your domains at the new server.

Apps that run without Docker Compose (Sellf with PM2) get their files back; start them again with
`./local/deploy.sh`.

## Databases on other hosts

Databases outside the server (for example a Mikrus shared database) are dumped when they are listed in
`/opt/stackpilot/config/db-credentials.conf` (mode 600) on the server:

```bash
CUSTOM_DATABASES=(
    "my-db:postgres:db.example.com:5432:appdb:appuser:password"
    "shop:mysql:mysql.example.com:3306:shop:shopuser:password"
)
```

The dumps land in the snapshot under `/opt/backups/stackpilot/external/`. They are not restored
automatically; load one by hand, for example:

```bash
ssh vps 'set -a; . /opt/stackpilot/config/backup.env; restic dump latest /opt/backups/stackpilot/external/my-db.postgres' > my-db.sql
```

## App notes

- **Immich** has its own backup (`apps/immich/backup.sh`) that pauses the server so photos and
  database match exactly. Use it for large libraries; the server backup also includes Immich.
- **n8n**: `apps/n8n/backup.sh` writes a portable workflow and credential export to
  `/opt/stacks/n8n/backups`, which the server backup picks up.

## Troubleshooting

- `repository is already locked`: a run was interrupted. Check that no backup is running, then
  `ssh vps 'set -a; . /opt/stackpilot/config/backup.env; restic unlock'`.
- `Wrong password for the existing repository` in the wizard: the storage already holds a repository;
  enter its password, or choose another folder in the bucket.
- SFTP fails with a host key error: run `ssh user@host` once as root on the server.
