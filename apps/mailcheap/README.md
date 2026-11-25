# MailCheap

Newsletter editor, archives, contacts and API/MCP, self-hosted without cloud billing.

Upstream: [marclou/mailcheap](https://github.com/marclou/mailcheap), AGPL-3.0. The installer pins source commit `f8b0b7fbc93ce09c1221c8bdc073b729c0efe237` and bundles MongoDB 7.0.45. Default port: **3000**, app and database memory limits: **512 MiB each**. MongoDB data is kept in a named volume; its port is internal only.

## Prepare the application image

Upstream provides Node.js source rather than a published container. Build it **locally** with Docker, then pass the archive to StackPilot’s existing `--build-file` deployment option. No Node build runs on the VPS.

```bash
# Run from the StackPilot repository; amd64 is the default VPS architecture.
apps/mailcheap/build.sh /tmp/mailcheap-image.tar
./local/deploy.sh mailcheap --build-file=/tmp/mailcheap-image.tar --ssh=vps --domain-type=cloudflare --domain=mail.example.com --yes
```

For an ARM64 server, set `PLATFORM=linux/arm64` when building. Building requires enough local disk and RAM for Next.js and its dependencies. A custom `SOURCE_REF` must be a full upstream commit SHA; set the matching `MAILCHEAP_IMAGE=stackpilot/mailcheap:<SHA>` on the server when running the installer directly, or change the installer's pinned default for a release.

The existing StackPilot deployment flow handles DNS, Caddy and HTTPS. For tunnel access use `--domain-type=local`; Cytrus uses the existing provider support. Domain setup does not configure the separate sending-domain records required by SES/PostShiba.

## Configure sign-in and sending

The installer creates `/opt/stacks/mailcheap/.env` with mode `600` before writing independent random secrets and preserves them on subsequent runs. An incomplete configuration stops installation before containers start; restore its missing keys from backup instead of replacing existing ones. It starts the app with sending disabled. Before the first sign-in, edit this file on the server:

- `ADMIN_EMAILS`: your administrator email address, optionally `ALLOWED_EMAILS` for other users.
- `EMAIL_FROM`: an address on a domain verified by the sending provider.
- `RESEND_API_KEY` for sign-in codes, or the SES/PostShiba configuration described upstream. Generic SMTP is not supported by this app.

Apply changes with `cd /opt/stacks/mailcheap && sudo docker compose up -d`, then open `/signin`. An empty allowlist permits nobody to sign in. Container readiness and the installer require `/signin` to return the sign-in page, which initializes the app's database connection; the installer also verifies `/api/health`. These checks do not prove sign-in email delivery or a successful authenticated session.

Campaign delivery additionally needs SES or PostShiba, its webhook configuration, and Upstash QStash (`QSTASH_TOKEN`, `QSTASH_CURRENT_SIGNING_KEY`, `QSTASH_NEXT_SIGNING_KEY`). QStash calls the app's public HTTPS URL. Complete the [upstream self-hosting guide](https://github.com/marclou/mailcheap#self-hosting), configure sending-domain records, and set `SENDING_ENABLED=true` only when ready. Image uploads optionally use S3 or Vercel Blob; Upstash Redis optionally shares rate limits across instances.

`APP_URL` follows the domain selected by StackPilot on every install. Auth and suppression keys must remain stable: replacing them invalidates sessions, links in sent emails and suppression hashes. Back up `.env` together with the MongoDB volume.

MongoDB 7.0 remains supported until August 31, 2027 and runs on the tested VPS kernels. MongoDB 8.x is incompatible with Linux kernels 6.19 through 7.0.13 ([upstream platform notes](https://www.mongodb.com/docs/manual/administration/production-notes/)). Do not change the database major version on an existing data volume without following MongoDB's migration procedure.
