# How to Contribute to StackPilot

Thanks for wanting to help! Every contribution is welcome - from fixing a typo to adding a new application.

## How to Add a New Application

### 1. Create the directory structure

```
apps/your-app/
|-- install.sh     # Install script (required)
+-- README.md      # Documentation (required)
```

### 2. install.sh header

Every `install.sh` must start with a standard header:

```bash
#!/bin/bash

# StackPilot - Application Name
# Short description in English (1 line)
# Author: Your Name
#
# IMAGE_SIZE_MB=XXX  # image-name:tag (estimated disk size)
#
# Optional comments about requirements
```

**IMAGE_SIZE_MB** is required - `deploy.sh` uses it to check if the server has enough disk space.

### 3. install.sh pattern

```bash
#!/bin/bash

# StackPilot - MyApp
# Description in English
# Author: Your Name
#
# IMAGE_SIZE_MB=300  # myapp:latest

set -e

APP_NAME="myapp"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8080}

# Create directory
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Docker Compose
cat <<EOF | sudo tee docker-compose.yaml
services:
  app:
    image: myapp:latest
    restart: always
    ports:
      - "$PORT:8080"
    volumes:
      - ./data:/data
EOF

# Start
sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 60
fi
```

### 4. Application README.md

Minimum content:

```markdown
# Application Name

Description of what it does and what it replaces.

## Installation

\`\`\`bash
./local/deploy.sh app-name
\`\`\`

## Requirements

- **RAM:** ~XXX MB
- **Disk:** ~XXX MB
- **Port:** XXXX
- **Database:** None / PostgreSQL / MySQL

## After Installation

Instructions for first-run configuration.
```

### 5. Register in AGENTS.md

Add your app to the list in the "Applications" section in `AGENTS.md`.

---

## Reporting Bugs

Open an [Issue](https://github.com/jurczykpawel/stackpilot/issues) with:
- Application name
- Server specs (RAM, OS)
- Error logs (`docker compose logs --tail 30`)
- Command you ran

## Pull Requests

1. Fork the repo
2. Create a branch (`git checkout -b feat/new-app`)
3. Test on a real server (or via `tests/test-apps.sh`)
4. Open a PR with a description of what and why

## Code Style

- **Bash** with `set -e` at the top
- **User-facing messages in English**
- **Variables** in `UPPER_CASE`
- Use `sudo` before `docker compose` and operations on `/opt/stacks/`
- Use libraries in `lib/` (health-check, db-setup, domain-setup) instead of writing from scratch

## Testing

```bash
# Test a single app on a server
SSH_HOST=your-server ./tests/test-apps.sh app-name

# Test all apps
SSH_HOST=your-server ./tests/test-apps.sh
```

---

## Security

Found a vulnerability? **Do not create a public Issue!**

Instead, use [GitHub Security Advisories](https://github.com/jurczykpawel/stackpilot/security/advisories/new)
or contact the author privately. Details in [SECURITY.md](SECURITY.md).

---

## License

By contributing, you agree to release your code under the [MIT](LICENSE) license.
