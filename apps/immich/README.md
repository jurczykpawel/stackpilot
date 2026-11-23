# Immich

Self-hosted photo and video management — the Google Photos alternative.
Face recognition, CLIP semantic search, mobile backup, sharing.

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 4 GB (server ~0.9 GB + ML up to ~1.3 GB with face recognition + postgres ~0.5 GB + OS) | 4 GB |
| Disk (OS + app) | 40 GB | 40 GB |
| Disk (photos) | Separate recommended | Separate |
| CPU | 1 vCPU works (measured, slow first import); 2+ recommended | 2+ vCPU |

**Suitable hosts:** any 4 GB+ VPS (e.g. Mikrus 3.5, Hetzner CAX11) or home hardware with 8 GB+ (old laptop, Raspberry Pi 5 8 GB, mini-PC). Prices change, so check the provider's current price list before you buy. Official Immich requirements: https://docs.immich.app/install/requirements

For large libraries (200+ GB), add a separate disk and point `UPLOAD_LOCATION` at it. Immich has no native S3 storage backend (see "Storage" below).

## Recommended settings by hardware

Source tags: **measured** = tested by us (2026-11-22), **docs** = official Immich requirements, **untested** = reasoning only.

| Hardware | ML (faces, smart search, OCR) | ML container memory limit | Notes |
|---|---|---|---|
| 2 GB RAM (e.g. Mikrus 3.0) | **Off**: Administration → Settings → Machine Learning | n/a | docs: below 6 GB the docs only cover running with ML disabled. Timeline, upload and sharing still work. untested on 2 GB |
| 4 GB RAM, 1 vCPU (e.g. Mikrus 3.5) | On | **2048M** (installer default) | **measured**: with 1024M the ML worker is SIGKILLed every ~20 s when the face + CLIP + OCR models load together; 0 faces and a constant restart loop. With 2048M: 300/300 photos processed in ~12 min (~1500/h on small 250×250 px images), 20/20 people clustered correctly, ML peak 1.27 GB, lowest free host RAM 850 MB (with other apps on the box). The first import of a big library runs for days; after that, daily phone uploads are small |
| 4 GB RAM, no other apps, want max stability | On, but turn OCR off if you don't need text search | 2048M | untested. One model fewer means less memory per batch |
| 8 GB+ RAM (Mikrus 4.1, Raspberry Pi 5 8 GB, mini-PC) | On | 2048M is enough; raise to 3072M only if logs show SIGKILL | docs: 8 GB recommended. Raspberry Pi 5 runs the arm64 images; the docs call ML slow on a Pi, and that only matters for the first import |
| Weak device + a stronger PC on the same network | Run ML on the PC ("remote machine learning" in the docs) | on the PC | docs. Handy for a one-off big import on a Pi or small VPS |

**How to check:** `docker logs immich_machine_learning 2>&1 | grep -c SIGKILL`. Anything above 0 means the ML limit is too low: raise it in `docker-compose.override.yaml` and run `docker compose up -d immich-machine-learning`.

**Big first import (measured 2026-11-22/23, 207k photos 1200×800 px, 1 vCPU, ML capped at 0.6 core):**
- Throughput: smart search ~2500 photos/h, face detection ~1300 photos/h, so roughly a week for 200k. Day-to-day use at that size stays fast: timeline 0.3 s, a month of photos 0.15 s, thumbnails <0.02 s, search 0.02–0.08 s.
- Queue one ML job type at a time (Administration → Jobs). Queueing smart search, faces and OCR together created ~600k jobs and filled Redis to 199 of 256 MB.
- If the ML container is down, Immich marks queued ML jobs as failed and drops them. Re-run "missing" for that job once ML is back.
- On LXC VPSes (Mikrus), `/proc/loadavg` and `uptime` show the whole host, other tenants included. Judge your own box by container CPU (`docker stats`) and app response time, not load average.

**Phone media on 1 vCPU (measured 2026-11-23, default Immich ffmpeg settings: HEVC → H.264 720p):**
- 12 MP HEIC photos: thumbnail + preview take ~2.6 s per photo (19 photos in 52 s).
- 4K HEVC video (iPhone-like, 30 fps, ~45 Mbit/s): thumbnail ~20 s per clip. Transcoding takes ~2 min per 20 s clip, about **6× slower than real time**, so 1 minute of 4K video is ~6 minutes of CPU.
- immich-server memory peaked at 1.41 GB of its 1.5 GB limit during 4K thumbnails (1.28 GB during transcoding). Don't set the server limit below 1.5 GB.
- Video-heavy libraries on a 1 vCPU VPS: the backlog is mostly transcoding. To cut it, set Administration → Video Transcoding → Transcode policy to "Don't transcode any videos" (modern phones and browsers play HEVC), or accept that the first import takes longer. untested: playback of untranscoded HEVC in every browser

## Ports

| Service | Port |
|---------|------|
| Web UI + API | 2283 |

## Deploy

```bash
# With Cloudflare domain
./local/deploy.sh immich --ssh=vps --domain-type=cloudflare --domain=photos.example.com

# With Cytrus free subdomain (e.g. immich.byst.re)
./local/deploy.sh immich --ssh=vps --domain-type=cytrus

# Local only (SSH tunnel)
./local/deploy.sh immich --ssh=vps --domain-type=local --yes
```

> **Cytrus note:** The domain is registered automatically AFTER Immich is healthy (the installer waits for `/api/server/ping` to respond before calling the Cytrus API). Never register a Cytrus domain manually while the app is still starting up — the domain becomes permanently broken (502, cannot be deleted via API, only via Mikrus panel).

## Post-install

1. Open the URL and **register the first account** — it automatically becomes admin.
2. Install the Immich app on **iOS or Android** and enter a server URL the phone can reach. An SSH tunnel opened on your computer gives that computer access.
3. On Android, open **Photos → Backup → Select**, tap **Camera**, go back, and turn on the **Enable Backup** switch. Grant access to the photos and videos you want to back up. The app can prompt for notifications and a battery optimization exemption for background uploads.
4. ML models (~1-2 GB) download on first use. Face recognition activates after first upload.

## Migrating from Google Photos

1. Open [Google Takeout](https://takeout.google.com/), deselect everything, select **Google Photos**, and create a ZIP export. Download every part into one folder and keep the ZIPs intact. They contain the photos and the JSON files that hold dates and descriptions.
2. On your computer, download [immich-go](https://github.com/simulot/immich-go/releases/latest) for your operating system and extract the program into the same folder.
3. Sign in to the Immich account that should own the photos. Open **Account Settings → API Keys → New API Key** and create a temporary key with the [immich-go permissions](https://github.com/simulot/immich-go/blob/main/docs/installation.md#api-permissions). If you are importing as a regular user without an admin key for queue management, add `--pause-immich-jobs=false` to the command.
4. Open a terminal in that folder. On macOS or Linux, run the command below and enter the key when prompted. Replace the example URL with the one you use to open Immich. On Windows, use `immich-go.exe` from Command Prompt with the same options and the ZIP pattern as the final argument.

   ```bash
   bash -c '
       read -rs -p "Immich API key: " key
       printf "\n"
       ./immich-go upload from-google-photos --server https://photos.example.com \
           --api-key "$key" takeout-*.zip
   '
   ```

5. In Immich, check a few photos for their dates and descriptions and open an imported album. Revoke the temporary API key when you finish. Keep the original Takeout ZIPs until you have verified the import and backed up Immich. [Immich CLI documentation](https://docs.immich.app/features/command-line-interface/)

## Storage: photos on external disk / S3

For libraries larger than 20 GB, edit `.env` on the server:

```bash
# Local external disk
UPLOAD_LOCATION=/mnt/photos

# Immich has no native S3/B2 storage backend. To keep photos in B2 you need a
# filesystem layer (e.g. rclone mount, optionally rclone crypt) mounted at UPLOAD_LOCATION.
# "Storage Template" only controls file naming, not where files are stored.
```

## Backup & restore

Run these commands from the StackPilot checkout on your server. The examples use `sudo` because the installer makes the stack’s `.env` private to root. Before the first backup or restore, install the dependencies on Debian or Ubuntu and check that Docker Compose is available.

```bash
sudo apt-get install -y jq restic curl
sudo docker compose version
```

If the version check fails, install Docker and the [Compose plugin](https://docs.docker.com/compose/install/linux/).

1. Create `/opt/stacks/immich/backup.env` and set mode `600`. Use absolute paths. For a local repository, use a separate disk where possible.

   ```bash
   RESTIC_REPOSITORY=/mnt/backup/immich
   RESTIC_PASSWORD_FILE=/opt/stacks/immich/restic-password
   ```

   For Backblaze B2, use the bucket’s S3 endpoint and an application key scoped to the bucket. Give the key permission to read, write, and delete objects so retention can prune old data.

   ```bash
   RESTIC_REPOSITORY='s3:https://s3.<region>.backblazeb2.com/<bucket>/<prefix>'
   RESTIC_PASSWORD_FILE=/opt/stacks/immich/restic-password
   AWS_ACCESS_KEY_ID='your-application-key-id'
   AWS_SECRET_ACCESS_KEY='your-application-key'
   ```

   Put a strong password in the password file, set mode `600`, and keep a second copy with the repository details somewhere separate from the server. You need them to recover the encrypted snapshots. To get notifications, add `NOTIFY_URL` and optionally `NOTIFY_FAILURE_URL`. Healthchecks uses the same check URL with `/fail` for failures. For ntfy, set both variables to the same topic URL.

2. From the StackPilot checkout, initialize the repository once, then run and check a backup.

   ```bash
   sudo bash -c 'set -a; source /opt/stacks/immich/backup.env; set +a; restic init'
   sudo ./apps/immich/backup.sh run
   sudo ./apps/immich/backup.sh check
   ```

   A backup pauses Immich while it saves originals under `UPLOAD_LOCATION`, a fresh PostgreSQL dump, `.env`, and Compose configuration. It retains 7 daily, 4 weekly, and 6 monthly backups. `check` reads all stored data, which can take time and use bandwidth. If you schedule `run` with cron, use the script’s full path and choose a time when people are unlikely to be uploading. For separately mounted Immich external libraries, back up those files separately and recreate their mounts for recovery. [Immich backup documentation](https://docs.immich.app/administration/backup-and-restore/)

3. **To recover**, prepare the same backup configuration on a recovery server with Docker Compose. The command creates a new directory and starts the recovered stack with its original Compose project name and port, so use a server where those are free. A snapshot ID can replace `latest`.

   ```bash
   sudo mkdir -p /opt/stacks
   sudo ./apps/immich/backup.sh restore latest /opt/stacks/immich-recovered
   ```

   The script restores media to `library/` and the database to a fresh `postgres/` in that directory. Sign in with your old account and check albums and originals. Generated thumbnails and transcodes are omitted from backups. In **Administration → Jobs**, rerun thumbnail generation and video conversion for **All** to rebuild them. Point future backup and update runs at the recovered stack with `IMMICH_STACK_DIR=/opt/stacks/immich-recovered` and move your domain or tunnel over after verifying recovery.

## Safe update

1. On Debian or Ubuntu, run `sudo apt-get install -y jq restic curl` and confirm that `sudo docker compose version` works.
2. Pick a maintenance window, pause uploads and imports until the update finishes, and take a fresh restic backup with `sudo ./apps/immich/backup.sh run`.
3. From the StackPilot checkout, run the updater. It uses GitHub’s public release API without credentials. With no argument it checks the latest stable release. You can pass a specific stable release tag from the release page instead.

   ```bash
   sudo ./apps/immich/update.sh
   ```

   The script checks the release notes for “breaking” and stops at major-version changes. If it stops for either reason, follow the linked [Immich release notes](https://github.com/immich-app/immich/releases). For an eligible update, it pulls the new images before pausing Immich, saves a fresh database dump, and waits for the new version to answer. If startup or the health check fails, it restores the old images, database, and version setting. A rolled-back update exits with an error and prints the recovery directory. Keep that directory private.

4. Sign in and open a few photos and albums before resuming uploads.

## Useful commands

```bash
# Logs
docker compose logs -f
docker compose logs -f immich-machine-learning

# Status
docker compose ps

# Restart
docker compose restart immich-server
```
