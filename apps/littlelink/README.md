# LittleLink - Link in Bio (Lightweight Version)

Extremely lightweight Linktree alternative. Pure HTML + CSS, zero database, zero PHP.

## Installation

```bash
./local/deploy.sh littlelink --ssh=ALIAS --domain-type=caddy --domain=auto
```

## Requirements

- **RAM:** ~5MB (nginx:alpine)
- **Disk:** ~50MB (Docker image)
- **Database:** none
- **Port:** 8090

## How to Edit?

LittleLink has no admin panel. You edit the `index.html` file directly.

**Workflow:**
1. Download files to your computer:
   ```bash
   ./local/sync.sh down /opt/stacks/littlelink/html ./my-bio --ssh=ALIAS
   ```
2. Edit `index.html` in VS Code (add your links, avatar, colors)
3. Upload changes to the server:
   ```bash
   ./local/sync.sh up ./my-bio /opt/stacks/littlelink/html --ssh=ALIAS
   ```

Works blazingly fast even on the smallest VPS.
