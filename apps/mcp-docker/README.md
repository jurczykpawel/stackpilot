# Docker MCP Server - AI Interface

A bridge connecting your AI Agent (Claude, Gemini, Cursor) with your server.

## Installation

```bash
./local/deploy.sh mcp-docker
```

## Requirements

- **RAM:** ~10MB
- **Disk:** ~100MB
- **Port:** none (MCP protocol over SSH)
- **Database:** No

## What Does It Do?
With this tool, your local AI assistant can "see" and control containers on your VPS through a secure SSH tunnel.

**Example commands for the Agent:**
- "Check why the n8n container restarted (show logs)."
- "List all containers using more than 100MB RAM."
- "Restart Caddy."

This is a true **"God Mode"** for infrastructure management.
