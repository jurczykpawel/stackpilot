# Watchtower

Monitors Docker containers for image updates. In monitor mode (default), sends notifications when updates are available but does not restart containers. In update mode, automatically pulls new images and restarts affected containers.

## Installation

```bash
# Monitor only (recommended) — sends notifications when updates are available
NOTIFICATION_URL="ntfy://:your-token@your-ntfy-host/topic" \
  ./local/deploy.sh watchtower --ssh=vps --yes

# Auto-update — automatically restarts containers when new images are released
WATCHTOWER_MODE=update \
  NOTIFICATION_URL="ntfy://:your-token@your-ntfy-host/topic" \
  ./local/deploy.sh watchtower --ssh=vps --yes

# With private registry (GHCR)
REPO_USER=yourusername \
  REPO_PASS=ghp_your_token \
  NOTIFICATION_URL="ntfy://:your-token@your-ntfy-host/topic" \
  ./local/deploy.sh watchtower --ssh=vps --yes
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WATCHTOWER_MODE` | `monitor` | `monitor` (notify only) or `update` (auto-restart) |
| `WATCHTOWER_SCHEDULE` | `0 0 9 * * 0` | Cron schedule for update checks (every Sunday 09:00) |
| `NOTIFICATION_URL` | *(none)* | Notification endpoint — runs silently if omitted |
| `REPO_USER` | *(none)* | Registry username for private image auth |
| `REPO_PASS` | *(none)* | Registry token/password for private image auth |
| `TZ` | `Europe/Warsaw` | Timezone for the schedule |

## Notification URL Format

Watchtower uses the [shoutrrr](https://containrrr.dev/shoutrrr/) library. Examples:

```
ntfy://:your-token@your-ntfy-host/your-topic
slack://token@channel
generic+https://your-webhook-url
```

> **Tip:** You can deploy ntfy on the same VPS with Stackpilot (`./local/deploy.sh ntfy --ssh=vps`) and use it as the notification endpoint.

## Requirements

- **RAM:** ~20MB runtime (image: ~25MB)
- **Port:** none (no web UI)
- **Domain:** not needed
- **Docker socket:** mounted read-write (`/var/run/docker.sock`)

## Private Registry Auth

Watchtower uses `REPO_USER` and `REPO_PASS` for registry authentication. For GitHub Container Registry (GHCR), use your GitHub username and a classic PAT with `read:packages` scope.

## After Installation

```bash
# Watch logs
docker logs -f watchtower

# Force an immediate check (without waiting for schedule)
docker exec watchtower /watchtower --run-once

# See what Watchtower is tracking
docker exec watchtower /watchtower --list-containers
```

## Notes

- Watchtower monitors ALL running containers by default (not just Stackpilot-managed ones)
- In `monitor` mode, containers are never restarted automatically — safe for production
- In `update` mode, containers are stopped, updated, and restarted — test on staging first
- The schedule uses 6-field cron format: `seconds minutes hours day month weekday`
