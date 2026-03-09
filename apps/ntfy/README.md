# ntfy - Your Notification Center

A server for sending PUSH notifications to phone and desktop. Replaces paid Pushover.

## Installation

```bash
./local/deploy.sh ntfy --ssh=ALIAS --domain-type=cloudflare --domain=notify.example.com
# or locally (SSH tunnel):
./local/deploy.sh ntfy --ssh=ALIAS --domain-type=local --yes
```

## Requirements

- **RAM:** ~128MB (container limit: 128MB)
- **Disk:** ~50MB (Docker image)
- **Port:** 8085

## How Does It Work?

1. Install the ntfy app on your phone (Android/iOS).
2. Subscribe to your topic, e.g. `my-secret-topic`.
3. In n8n, use an HTTP Request node to send a POST to your ntfy server.
4. **Done!** You get a notification on your phone: "New order in Sellf: $97".

## After Installation

### Create an Admin User

ntfy has its own user system (unrelated to the Linux system). Run locally:

```bash
ssh ALIAS 'docker exec -it ntfy-ntfy-1 ntfy user add --role=admin YOUR_USER'
```

The command will prompt for a password. This user is for logging into the ntfy web interface and authorizing topic subscriptions.

## Security

The script sets `deny-all` mode by default — nobody can read or write without a password. Creating an admin user (above) is mandatory before you can use the server.
