import { existsSync, readFileSync } from "node:fs";
import { sshExec, sshExecWithStdin } from "./ssh.js";
import { localScript, systemScript, execLocalScript } from "./toolbox-paths.js";

export interface DomainResult {
  ok: boolean;
  url: string | null;
  domain: string | null;
  error: string | null;
}

const DOMAIN_REGEX = /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/i;

function validateDomainInput(domain: string): string | null {
  if (!DOMAIN_REGEX.test(domain) || domain.includes("..")) {
    return `Invalid domain: ${domain}. Use only letters, numbers, dots, and dashes.`;
  }
  return null;
}

/**
 * Set up a Caddy reverse proxy domain via sp-expose on the server.
 * Caddy automatically obtains a Let's Encrypt certificate.
 * Prerequisite: user must point their domain's A record to the server IP.
 */
export async function setupCaddyDomain(
  alias: string,
  port: number,
  domain: string
): Promise<DomainResult> {
  const domainErr = validateDomainInput(domain);
  if (domainErr) {
    return { ok: false, url: null, domain, error: domainErr };
  }

  // Ensure Caddy is installed
  const check = await sshExec(alias, "command -v sp-expose 2>/dev/null", 10_000);
  if (check.exitCode !== 0) {
    const caddyScript = systemScript("caddy-install.sh");
    if (existsSync(caddyScript)) {
      const installResult = await sshExecWithStdin(
        alias,
        "bash -s",
        readFileSync(caddyScript, "utf-8"),
        120_000
      );
      if (installResult.exitCode !== 0) {
        return {
          ok: false,
          url: null,
          domain,
          error: `Failed to install Caddy: ${installResult.stderr}`,
        };
      }
    } else {
      return {
        ok: false,
        url: null,
        domain,
        error: "Caddy (sp-expose) not found. Install Caddy first (system/caddy-install.sh).",
      };
    }
  }

  const result = await sshExec(
    alias,
    `sp-expose '${domain}' '${port}'`,
    15_000
  );
  if (result.exitCode === 0) {
    return { ok: true, url: `https://${domain}`, domain, error: null };
  }
  return {
    ok: false,
    url: null,
    domain,
    error: `sp-expose failed. Ensure the domain's A record points to the server. ${result.stderr}`,
  };
}

/**
 * Set up Cloudflare reverse proxy domain: local/dns-add.sh + sp-expose.
 */
export async function setupCloudflareProxy(
  alias: string,
  domain: string,
  port: number
): Promise<DomainResult> {
  const domainErr = validateDomainInput(domain);
  if (domainErr) {
    return { ok: false, url: null, domain, error: domainErr };
  }

  // Step 1: DNS record via dns-add.sh (runs locally, manages Cloudflare API)
  const dnsScript = localScript("dns-add.sh");
  if (existsSync(dnsScript)) {
    await execLocalScript(dnsScript, [domain, alias], 30_000);
  }

  // Step 2: Caddy reverse proxy via sp-expose on server
  const result = await sshExec(
    alias,
    `command -v sp-expose >/dev/null 2>&1 && sp-expose '${domain}' '${port}'`,
    15_000
  );
  if (result.exitCode === 0) {
    return { ok: true, url: `https://${domain}`, domain, error: null };
  }
  return {
    ok: false,
    url: null,
    domain,
    error: `sp-expose failed or not found. Install Caddy first (system/caddy-install.sh). ${result.stderr}`,
  };
}

/**
 * Set up Cloudflare static file domain: local/dns-add.sh + sp-expose static.
 */
export async function setupCloudflareStatic(
  alias: string,
  domain: string,
  webRoot: string
): Promise<DomainResult> {
  const domainErr = validateDomainInput(domain);
  if (domainErr) {
    return { ok: false, url: null, domain, error: domainErr };
  }

  const dnsScript = localScript("dns-add.sh");
  if (existsSync(dnsScript)) {
    await execLocalScript(dnsScript, [domain, alias], 30_000);
  }

  const result = await sshExec(
    alias,
    `command -v sp-expose >/dev/null 2>&1 && sp-expose '${domain}' '${webRoot}' static`,
    15_000
  );
  if (result.exitCode === 0) {
    return { ok: true, url: `https://${domain}`, domain, error: null };
  }
  return {
    ok: false,
    url: null,
    domain,
    error: `sp-expose failed or not found. ${result.stderr}`,
  };
}

export function localOnly(port: number | null): DomainResult {
  return {
    ok: true,
    url: port ? `http://localhost:${port}` : null,
    domain: null,
    error: null,
  };
}
