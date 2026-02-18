import { existsSync, readFileSync } from "node:fs";
import { sshExec, sshExecWithStdin, rsyncToServer } from "./ssh.js";
import {
  setupCytrusDomain,
  setupCloudflareProxy,
  localOnly,
  type DomainResult,
} from "./domain.js";
import {
  localScript,
  systemScript,
  execLocalScript,
} from "./toolbox-paths.js";
import type { ProjectAnalysis } from "./project-detect.js";

export interface DeployConfig {
  projectPath: string;
  name: string;
  alias: string;
  strategy: "static" | "node" | "docker";
  domainType: "cytrus" | "cloudflare" | "local";
  domain?: string;
  port?: number;
  startCommand?: string;
  installCommand?: string;
  envVars?: Record<string, string>;
}

export interface DeployResult {
  ok: boolean;
  lines: string[];
  url: string | null;
  error: string | null;
}

export async function deploy(
  config: DeployConfig,
  analysis: ProjectAnalysis
): Promise<DeployResult> {
  // --- Input validation (prevent command injection) ---
  const nameErr = validateName(config.name);
  if (nameErr) return { ok: false, lines: [], url: null, error: nameErr };

  const aliasErr = validateAlias(config.alias);
  if (aliasErr) return { ok: false, lines: [], url: null, error: aliasErr };

  if (config.domain && config.domain !== "auto") {
    const domainErr = validateDomain(config.domain);
    if (domainErr) return { ok: false, lines: [], url: null, error: domainErr };
  }

  if (config.installCommand) {
    const cmdErr = validateShellCommand(config.installCommand, "install_command");
    if (cmdErr) return { ok: false, lines: [], url: null, error: cmdErr };
  }

  if (config.startCommand) {
    const cmdErr = validateShellCommand(config.startCommand, "start_command");
    if (cmdErr) return { ok: false, lines: [], url: null, error: cmdErr };
  }

  // Python without Dockerfile → generate Dockerfile on server, then Docker flow
  if (analysis.type === "python" && !analysis.files.includes("Dockerfile")) {
    return deployPythonAsDocker(config);
  }
  switch (config.strategy) {
    case "static":
      return deployStatic(config);
    case "node":
      return deployNode(config);
    case "docker":
      return deployDocker(config);
  }
}

// ---------------------------------------------------------------------------
// Static deployment — uses local/add-static-hosting.sh
// The script handles:
//   Cytrus:     nginx container + cytrus-domain.sh
//   Cloudflare: Caddy file_server + dns-add.sh + mikrus-expose
// ---------------------------------------------------------------------------

async function deployStatic(config: DeployConfig): Promise<DeployResult> {
  const { projectPath, name, alias, domainType, domain } = config;
  const lines: string[] = [];
  const webRoot = `/var/www/public/${name}`;

  // 1. Upload files
  await sshExec(
    alias,
    `sudo mkdir -p ${webRoot} && sudo chown -R $(whoami) ${webRoot}`,
    10_000
  );
  lines.push(`Syncing files to ${webRoot}...`);
  const rsyncResult = await rsyncToServer(alias, projectPath, webRoot);
  if (rsyncResult.exitCode !== 0) {
    return err(lines, `rsync failed: ${rsyncResult.stderr}`);
  }
  await sshExec(alias, `sudo chmod -R o+rX ${webRoot}`, 10_000);
  lines.push("Files synced.");

  // 2. Check if this site is already being served (fast path: just update files)
  const servingCheck = await sshExec(
    alias,
    `docker ps --format '{{.Mounts}}' 2>/dev/null | grep -c '${webRoot}' || echo 0; ` +
      `grep -c '${webRoot}' /etc/caddy/Caddyfile 2>/dev/null || echo 0`,
    10_000
  );
  const counts = servingCheck.stdout.trim().split("\n").map(Number);
  const isAlreadyServed = counts.some((c) => c > 0);

  if (isAlreadyServed) {
    lines.push("");
    lines.push(
      `Static site '${name}' updated (hosting already configured).`
    );
    lines.push(`Files: ${webRoot}`);
    return { ok: true, lines, url: null, error: null };
  }

  // 3. New site — set up hosting (domain required for static sites)
  if (domainType === "local") {
    return err(
      lines,
      "Static sites require a domain (domain_type: 'cytrus' or 'cloudflare'). " +
        "Use domain_type='cytrus' for a free Mikrus subdomain (*.byst.re)."
    );
  }
  return setupStaticViaScript(config, lines, webRoot);
}

/**
 * Set up static hosting via local/add-static-hosting.sh.
 * The script auto-detects Cytrus vs Cloudflare from domain suffix.
 */
async function setupStaticViaScript(
  config: DeployConfig,
  lines: string[],
  webRoot: string
): Promise<DeployResult> {
  const { name, alias, domainType, domain } = config;

  const script = localScript("add-static-hosting.sh");
  if (!existsSync(script)) {
    return err(
      lines,
      "Toolbox script not found: local/add-static-hosting.sh. Clone the full mikrus-toolbox repo."
    );
  }

  // Determine domain name
  let siteDomain: string;
  if (domainType === "cytrus") {
    siteDomain =
      !domain || domain === "auto" ? `${name}.byst.re` : domain;
  } else {
    if (!domain) {
      return err(
        lines,
        "Cloudflare domain_type requires a domain parameter (e.g. 'static.example.com')."
      );
    }
    siteDomain = domain;
    // Ensure Caddy + mikrus-expose are installed on server
    await ensureCaddy(alias, lines);
  }

  // Find a free port (Cytrus needs it for nginx container; Cloudflare ignores it)
  const port = config.port ?? (await findFreePort(alias, 8096));

  lines.push(`Setting up static hosting for ${siteDomain}...`);
  const result = await execLocalScript(
    script,
    [siteDomain, alias, webRoot, String(port)],
    120_000
  );

  if (result.exitCode !== 0) {
    if (result.stdout) lines.push(result.stdout.trim());
    return err(
      lines,
      result.stderr.trim() || "add-static-hosting.sh failed"
    );
  }

  // Script succeeded — extract output
  if (result.stdout) lines.push(result.stdout.trim());
  lines.push("");
  lines.push(`Static site '${name}' deployed successfully.`);
  lines.push(`URL: https://${siteDomain}`);
  lines.push(`Files: ${webRoot}`);
  return { ok: true, lines, url: `https://${siteDomain}`, error: null };
}

// ---------------------------------------------------------------------------
// Node.js deployment (PM2) — uses system/pm2-setup.sh for installation
// ---------------------------------------------------------------------------

async function deployNode(config: DeployConfig): Promise<DeployResult> {
  const {
    projectPath,
    name,
    alias,
    domainType,
    domain,
    startCommand = "npm start",
    installCommand = "npm install --production",
  } = config;
  const port = config.port ?? 3000;
  const remoteDir = `/opt/sites/${name}`;
  const lines: string[] = [];

  // 1. Check/install PM2 using system/pm2-setup.sh
  const pm2Check = await sshExec(alias, "command -v pm2 && pm2 -v", 10_000);
  if (pm2Check.exitCode !== 0) {
    lines.push("PM2 not found. Installing Node.js + PM2...");
    const pm2Script = systemScript("pm2-setup.sh");
    if (existsSync(pm2Script)) {
      const installResult = await sshExecWithStdin(
        alias,
        "bash -s",
        readFileSync(pm2Script, "utf-8"),
        180_000
      );
      if (installResult.exitCode !== 0) {
        return err(lines, `PM2 setup failed: ${installResult.stderr}`);
      }
      lines.push("Node.js + PM2 installed via pm2-setup.sh.");
    } else {
      return err(
        lines,
        "PM2 not installed and system/pm2-setup.sh not found. Clone the full mikrus-toolbox repo."
      );
    }
  } else {
    lines.push(
      `PM2 found (v${pm2Check.stdout.trim().split("\n").pop()}).`
    );
  }

  // 2. Upload files
  await sshExec(
    alias,
    `sudo mkdir -p ${remoteDir} && sudo chown $(whoami) ${remoteDir}`,
    10_000
  );
  lines.push(`Syncing files to ${remoteDir}...`);
  const rsyncResult = await rsyncToServer(alias, projectPath, remoteDir);
  if (rsyncResult.exitCode !== 0) {
    return err(lines, `rsync failed: ${rsyncResult.stderr}`);
  }
  lines.push("Files synced.");

  // 3. Install dependencies
  lines.push(`Running: ${installCommand}...`);
  const depResult = await sshExec(
    alias,
    `cd ${remoteDir} && ${installCommand}`,
    300_000
  );
  if (depResult.exitCode !== 0) {
    return err(lines, `Install failed: ${depResult.stderr}`);
  }
  lines.push("Dependencies installed.");

  // 4. Write .env if provided
  if (config.envVars && Object.keys(config.envVars).length > 0) {
    const envContent = Object.entries(config.envVars)
      .map(([k, v]) => {
        // Reject newlines in env values (prevent injection of extra env vars)
        const safeVal = v.replace(/[\n\r]/g, "");
        return `${k}=${safeVal}`;
      })
      .join("\n");
    await sshExecWithStdin(
      alias,
      `cat > ${remoteDir}/.env`,
      envContent,
      10_000
    );
  }

  // 5. Start with PM2
  await sshExec(alias, `pm2 delete ${name} 2>/dev/null || true`, 10_000);
  const pm2Start = await sshExec(
    alias,
    `cd ${remoteDir} && PORT=${port} pm2 start "${startCommand}" --name ${name}`,
    30_000
  );
  if (pm2Start.exitCode !== 0) {
    return err(lines, `PM2 start failed: ${pm2Start.stderr}`);
  }
  await sshExec(alias, "pm2 save", 10_000);
  lines.push(`PM2 process '${name}' started on port ${port}.`);

  // 6. Domain setup using toolbox scripts
  const domainResult = await setupServiceDomain(
    alias,
    domainType,
    domain,
    port,
    lines
  );
  appendDomainResult(lines, domainResult);
  lines.push("");
  lines.push(`Node.js app '${name}' deployed successfully.`);
  lines.push("");
  lines.push("Management commands:");
  lines.push(`  ssh ${alias} "pm2 logs ${name}"`);
  lines.push(`  ssh ${alias} "pm2 restart ${name}"`);
  lines.push(`  ssh ${alias} "pm2 stop ${name}"`);
  return { ok: true, lines, url: domainResult.url, error: null };
}

// ---------------------------------------------------------------------------
// Docker deployment
// ---------------------------------------------------------------------------

async function deployDocker(config: DeployConfig): Promise<DeployResult> {
  const { projectPath, name, alias, domainType, domain } = config;
  const remoteDir = `/opt/stacks/${name}`;
  const lines: string[] = [];

  // 1. Upload files
  await sshExec(alias, `sudo mkdir -p ${remoteDir}`, 10_000);
  lines.push(`Syncing files to ${remoteDir}...`);
  const rsyncResult = await rsyncToServer(alias, projectPath, remoteDir);
  if (rsyncResult.exitCode !== 0) {
    return err(lines, `rsync failed: ${rsyncResult.stderr}`);
  }
  lines.push("Files synced.");

  // 2. Generate compose if only Dockerfile
  const hasCompose = await sshExec(
    alias,
    `ls ${remoteDir}/docker-compose.yaml ${remoteDir}/docker-compose.yml ${remoteDir}/compose.yaml ${remoteDir}/compose.yml 2>/dev/null | head -1`,
    10_000
  );
  const port = config.port ?? 3000;
  if (!hasCompose.stdout.trim()) {
    lines.push(
      "No docker-compose.yaml found. Generating from Dockerfile..."
    );
    const compose = `services:
  ${name}:
    build: .
    restart: always
    ports:
      - "${port}:${port}"
    deploy:
      resources:
        limits:
          memory: 256M
`;
    await sshExecWithStdin(
      alias,
      `cat > ${remoteDir}/docker-compose.yaml`,
      compose,
      15_000
    );
  }

  // 3. Write .env
  if (config.envVars && Object.keys(config.envVars).length > 0) {
    const envContent = Object.entries(config.envVars)
      .map(([k, v]) => {
        const safeVal = v.replace(/[\n\r]/g, "");
        return `${k}=${safeVal}`;
      })
      .join("\n");
    await sshExecWithStdin(
      alias,
      `cat > ${remoteDir}/.env`,
      envContent,
      10_000
    );
  }

  // 4. Build and start
  lines.push("Building and starting containers...");
  const upResult = await sshExec(
    alias,
    `cd ${remoteDir} && sudo docker compose up -d --build 2>&1`,
    600_000
  );
  if (upResult.exitCode !== 0) {
    lines.push(upResult.stdout);
    return err(lines, `Docker build/start failed: ${upResult.stderr}`);
  }
  lines.push("Containers started.");

  // 5. Health check
  await sshExec(alias, "sleep 3", 10_000);
  const health = await sshExec(
    alias,
    `curl -sf -o /dev/null -w '%{http_code}' http://localhost:${port}/ 2>/dev/null || echo UNREACHABLE`,
    15_000
  );
  const status = health.stdout.trim();
  lines.push(
    status === "UNREACHABLE" || !status
      ? `Health check: port ${port} not responding yet (app may still be starting).`
      : `Health check: HTTP ${status} on port ${port}.`
  );

  // 6. Domain setup using toolbox scripts
  const domainResult = await setupServiceDomain(
    alias,
    domainType,
    domain,
    port,
    lines
  );
  appendDomainResult(lines, domainResult);
  lines.push("");
  lines.push(`Docker app '${name}' deployed successfully.`);
  lines.push("");
  lines.push("Management commands:");
  lines.push(
    `  ssh ${alias} "cd ${remoteDir} && docker compose logs -f"`
  );
  lines.push(
    `  ssh ${alias} "cd ${remoteDir} && docker compose restart"`
  );
  lines.push(
    `  ssh ${alias} "cd ${remoteDir} && docker compose down"`
  );
  return { ok: true, lines, url: domainResult.url, error: null };
}

// ---------------------------------------------------------------------------
// Python → auto-Dockerfile → Docker flow
// ---------------------------------------------------------------------------

async function deployPythonAsDocker(
  config: DeployConfig
): Promise<DeployResult> {
  const { alias, name, projectPath } = config;
  const remoteDir = `/opt/stacks/${name}`;
  const port = config.port ?? 8000;
  const lines: string[] = [];

  // 1. Upload files
  await sshExec(alias, `sudo mkdir -p ${remoteDir}`, 10_000);
  const rsyncResult = await rsyncToServer(alias, projectPath, remoteDir);
  if (rsyncResult.exitCode !== 0) {
    return err(lines, `rsync failed: ${rsyncResult.stderr}`);
  }
  lines.push("Files synced.");

  // 2. Generate Dockerfile
  const dockerfile = `FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt* pyproject.toml* ./
RUN pip install --no-cache-dir -r requirements.txt 2>/dev/null || pip install --no-cache-dir . 2>/dev/null || true
COPY . .
EXPOSE ${port}
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "${port}"]
`;
  await sshExecWithStdin(
    alias,
    `cat > ${remoteDir}/Dockerfile`,
    dockerfile,
    10_000
  );
  lines.push("Generated Dockerfile for Python project.");

  // 3. Generate docker-compose.yaml
  const compose = `services:
  ${name}:
    build: .
    restart: always
    ports:
      - "${port}:${port}"
    deploy:
      resources:
        limits:
          memory: 256M
`;
  await sshExecWithStdin(
    alias,
    `cat > ${remoteDir}/docker-compose.yaml`,
    compose,
    15_000
  );

  // 4. Build and start
  lines.push("Building and starting containers...");
  const upResult = await sshExec(
    alias,
    `cd ${remoteDir} && sudo docker compose up -d --build 2>&1`,
    600_000
  );
  if (upResult.exitCode !== 0) {
    lines.push(upResult.stdout);
    return err(lines, `Docker build/start failed: ${upResult.stderr}`);
  }
  lines.push("Containers started.");

  // 5. Domain setup using toolbox scripts
  const domainResult = await setupServiceDomain(
    alias,
    config.domainType,
    config.domain,
    port,
    lines
  );
  appendDomainResult(lines, domainResult);
  lines.push("");
  lines.push(`Python app '${name}' deployed successfully.`);
  lines.push("");
  lines.push("Management commands:");
  lines.push(
    `  ssh ${alias} "cd ${remoteDir} && docker compose logs -f"`
  );
  lines.push(
    `  ssh ${alias} "cd ${remoteDir} && docker compose restart"`
  );
  return { ok: true, lines, url: domainResult.url, error: null };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/**
 * Set up a domain for a service (Node/Docker).
 * Ensures Caddy is installed for Cloudflare, then delegates to domain.ts.
 */
async function setupServiceDomain(
  alias: string,
  domainType: "cytrus" | "cloudflare" | "local",
  domain: string | undefined,
  port: number,
  lines: string[]
): Promise<DomainResult> {
  if (domainType === "cytrus") {
    return setupCytrusDomain(alias, port, domain);
  }
  if (domainType === "cloudflare") {
    if (!domain) {
      return {
        ok: false,
        url: null,
        domain: null,
        error:
          "Cloudflare domain_type requires a domain parameter.",
      };
    }
    await ensureCaddy(alias, lines);
    return setupCloudflareProxy(alias, domain, port);
  }
  return localOnly(port);
}

/**
 * Ensure Caddy + mikrus-expose are installed on the server.
 * Uses system/caddy-install.sh if available.
 */
async function ensureCaddy(
  alias: string,
  lines: string[]
): Promise<void> {
  const check = await sshExec(
    alias,
    "command -v mikrus-expose",
    10_000
  );
  if (check.exitCode === 0) return;

  const caddyScript = systemScript("caddy-install.sh");
  if (!existsSync(caddyScript)) {
    lines.push(
      "WARNING: Caddy not installed and system/caddy-install.sh not found."
    );
    return;
  }
  lines.push("Installing Caddy + mikrus-expose...");
  const result = await sshExecWithStdin(
    alias,
    "bash -s",
    readFileSync(caddyScript, "utf-8"),
    120_000
  );
  if (result.exitCode === 0) {
    lines.push("Caddy installed.");
  } else {
    lines.push(`Caddy install warning: ${result.stderr}`);
  }
}

/**
 * Find a free port on the server using ss (same approach as lib/port-utils.sh).
 */
async function findFreePort(
  alias: string,
  basePort: number
): Promise<number> {
  const result = await sshExec(
    alias,
    "ss -tlnp 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un",
    10_000
  );
  const usedPorts = new Set(
    result.stdout.trim().split("\n").filter(Boolean).map(Number)
  );
  let port = basePort;
  while (usedPorts.has(port)) port++;
  return port;
}

function err(lines: string[], error: string): DeployResult {
  return { ok: false, lines, url: null, error };
}

function appendDomainResult(
  lines: string[],
  result: DomainResult
): void {
  if (result.ok && result.url) {
    lines.push(`Domain configured: ${result.url}`);
  } else if (result.error) {
    lines.push(`Domain warning: ${result.error}`);
  }
}

/** Shell metacharacters that indicate command injection attempts. */
const SHELL_METACHARS = /[;|&`$(){}!<>\n\r\\"']/;

/**
 * Validate a shell command string (start_command, install_command).
 * Rejects anything containing shell metacharacters that could enable injection.
 */
function validateShellCommand(cmd: string, paramName: string): string | null {
  if (SHELL_METACHARS.test(cmd)) {
    return `${paramName} contains unsafe shell characters: ${cmd}. Only simple commands are allowed (e.g. 'npm start', 'npm install --production').`;
  }
  return null;
}

/**
 * Validate a domain string. Only allows [a-z0-9.-] to prevent shell injection.
 */
function validateDomain(domain: string): string | null {
  if (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/i.test(domain)) {
    return `Invalid domain format: ${domain}. Use only letters, numbers, dots, and dashes.`;
  }
  if (domain.includes("..")) {
    return `Invalid domain: ${domain}. Double dots not allowed.`;
  }
  return null;
}

/**
 * Validate an SSH alias. Only allows [a-zA-Z0-9_-] to prevent option injection.
 */
function validateAlias(alias: string): string | null {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(alias)) {
    return `Invalid SSH alias: ${alias}. Use only letters, numbers, dashes, and underscores.`;
  }
  return null;
}

/**
 * Validate a site/project name. Only allows [a-z0-9_-] to prevent path traversal
 * and command injection when used in remote paths like /opt/stacks/{name}.
 */
function validateName(name: string): string | null {
  if (!/^[a-z0-9][a-z0-9_-]*$/.test(name)) {
    return `Invalid name: ${name}. Use only lowercase letters, numbers, dashes, and underscores.`;
  }
  if (name.includes("..")) {
    return `Invalid name: ${name}. Path traversal not allowed.`;
  }
  return null;
}
