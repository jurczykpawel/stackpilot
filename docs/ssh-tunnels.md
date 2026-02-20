# SSH Tunnels - Access Apps Without a Domain

## What is it?

An SSH tunnel is a "magic portal" that connects a port on your local machine to a port on the server. This lets you open an application in your browser **without configuring a domain or DNS**.

## When is it useful?

- Testing an app before making it public
- You don't have a domain yet
- You want to quickly check if something works
- Accessing admin panels that shouldn't be public

## How to start a tunnel?

```bash
# Syntax: ssh -L local_port:localhost:remote_port server_alias
ssh -L 5001:localhost:5001 vps
```

Now open in your browser: `http://localhost:5001` - you'll see Dockge!

## Common ports

| Service | Port | Tunnel command |
|---------|------|----------------|
| Dockge | 5001 | `ssh -L 5001:localhost:5001 vps` |
| n8n | 5678 | `ssh -L 5678:localhost:5678 vps` |
| Uptime Kuma | 3001 | `ssh -L 3001:localhost:3001 vps` |
| ntfy | 8085 | `ssh -L 8085:localhost:8085 vps` |
| Vaultwarden | 8088 | `ssh -L 8088:localhost:8088 vps` |
| FileBrowser | 8095 | `ssh -L 8095:localhost:8095 vps` |

## Pro tip: multiple tunnels at once

```bash
ssh -L 5001:localhost:5001 -L 5678:localhost:5678 -L 3001:localhost:3001 vps
```

## How to exit a tunnel?

`exit`, `Ctrl+D`, or simply close the terminal.

> The tunnel only works while the terminal is open. Closing the terminal = tunnel closed.
