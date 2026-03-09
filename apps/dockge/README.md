# Dockge - Container Management Panel

Lightweight Docker Compose manager. Replaces the heavy Portainer.

## Installation

```bash
./local/deploy.sh dockge --ssh=ALIAS --domain-type=cloudflare --domain=dockge.example.com
# or locally (SSH tunnel):
./local/deploy.sh dockge --ssh=ALIAS --domain-type=local --yes
```

## Requirements

- **RAM:** ~150MB (container limit: not set in compose, image is very lightweight)
- **Disk:** ~150MB (Docker image)
- **Port:** 5001

## Why Dockge?

- **Low RAM usage:** Unlike Portainer (200MB+), Dockge is very lightweight.
- **Files > Database:** Dockge manages `compose.yaml` files directly in `/opt/stacks`. Edit them in the browser, terminal, or VS Code — nothing gets out of sync.
- **Agent mode:** Connect multiple servers to a single panel.

## After Installation

1. Open the URL in your browser.
2. On first visit, Dockge will ask you to create an administrator account. Save the credentials in a secure place.
3. Click "+ Compose", enter a name (e.g. `wordpress`) and paste a configuration. That is all.
