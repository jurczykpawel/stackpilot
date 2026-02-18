import { existsSync } from "node:fs";
import { sshExec } from "./ssh.js";
import { localScript, execLocalScript } from "./toolbox-paths.js";

export interface DomainResult {
  ok: boolean;
  url: string | null;
  domain: string | null;
  error: string | null;
}

const DOMAIN_REGEX = /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/i;

function validateDomainInput(domain: string): string | null {
  if (domain === "-") return null; // auto-assign sentinel
  if (!DOMAIN_REGEX.test(domain) || domain.includes("..")) {
    return `Invalid domain: ${domain}. Use only letters, numbers, dots, and dashes.`;
  }
  return null;
}

/**
 * Register a Cytrus domain using local/cytrus-domain.sh.
 * The script handles: SSH → get API key + hostname, curl Mikrus API, parse response.
 */
export async function setupCytrusDomain(
  alias: string,
  port: number,
  requestedDomain?: string
): Promise<DomainResult> {
  const script = localScript("cytrus-domain.sh");
  if (!existsSync(script)) {
    return {
      ok: false,
      url: null,
      domain: null,
      error:
        "Toolbox script not found: local/cytrus-domain.sh. Clone the full stackpilot repo.",
    };
  }

  const domain =
    !requestedDomain || requestedDomain === "auto" ? "-" : requestedDomain;

  const domainErr = validateDomainInput(domain);
  if (domainErr) {
    return { ok: false, url: null, domain: null, error: domainErr };
  }

  const result = await execLocalScript(
    script,
    [domain, String(port), alias],
    60_000
  );

  if (result.exitCode === 0) {
    // Parse URL from script output (e.g. "https://xyz.byst.re")
    const urlMatch = result.stdout.match(/https:\/\/\S+/);
    const assignedDomain =
      urlMatch?.[0]?.replace("https://", "") ??
      (domain !== "-" ? domain : null);
    return {
      ok: true,
      url:
        urlMatch?.[0] ??
        (assignedDomain ? `https://${assignedDomain}` : null),
      domain: assignedDomain,
      error: null,
    };
  }

  return {
    ok: false,
    url: null,
    domain: null,
    error:
      (result.stdout || result.stderr || "cytrus-domain.sh failed").trim(),
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
