import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { getDefaultAlias } from "../lib/config.js";
import { getAppsDir, getDeployShPath, resolveRepoRoot } from "../lib/repo.js";
import { parseAppMetadata } from "../lib/app-metadata.js";
import { checkBackupStatus } from "../lib/backup-check.js";
import { checkServerHealth } from "../lib/resource-check.js";

export const deployAppTool = {
  name: "deploy_app",
  description:
    "Deploy an application to a VPS server. Runs the local deploy.sh script with --yes flag (non-interactive). All required parameters must be provided. For apps requiring a database, specify db_source. For public access, specify domain_type and domain. Use list_apps first to see available apps and their requirements.\n\n" +
    "IMPORTANT: When domain_type is 'caddy' or 'cloudflare', this tool automatically configures the domain — no need to call setup_domain separately.\n\n" +
    "WORDPRESS: Before deploying WordPress, ALWAYS ask the user which database mode they prefer:\n" +
    "  - SQLite (recommended for small sites, blogs, portfolios) — pass extra_env: { WP_DB_MODE: 'sqlite' }, no db_source needed\n" +
    "  - MySQL bundled (auto-provisioned MySQL container) — pass db_source: 'bundled'\n" +
    "  - MySQL custom (own/external DB) — pass db_source: 'custom' with db_host, db_name, db_user, db_pass\n\n" +
    "GATEFLOW: GateFlow is a self-hosted digital products sales platform (Gumroad alternative). " +
    "It requires a Supabase project (free tier). Use setup_gateflow_config tool FIRST to configure Supabase keys securely " +
    "(opens browser, no secrets in conversation). After config is saved, deploy_app loads it automatically.\n" +
    "  If GateFlow repo is private, pass build_file with path to local gateflow-build.tar.gz.\n" +
    "  After deployment, the first registered user becomes admin. Stripe webhooks need manual setup in Stripe Dashboard.\n\n" +
    "NOTE: On Windows without bash, the user can install the toolbox on the server first " +
    "('./local/install-toolbox.sh <alias>'), then SSH in and run 'deploy.sh' directly on the server.",
  inputSchema: {
    type: "object" as const,
    properties: {
      app_name: {
        type: "string",
        description:
          "Application name (e.g. 'n8n', 'uptime-kuma', 'wordpress'). Use list_apps to see available apps.",
      },
      ssh_alias: {
        type: "string",
        description:
          "SSH alias. If omitted, uses the default configured server.",
      },
      domain_type: {
        type: "string",
        enum: ["cloudflare", "caddy", "local"],
        description:
          "'cloudflare' = own domain via Cloudflare DNS + Caddy. 'caddy' = own domain via Caddy auto-HTTPS (Let's Encrypt). 'local' = no domain (SSH tunnel access only).",
      },
      domain: {
        type: "string",
        description:
          "Full domain name (e.g. 'app.example.com'). Required for caddy and cloudflare domain types. Not needed for domain_type='local'.",
      },
      db_source: {
        type: "string",
        enum: ["bundled", "custom"],
        description:
          "'bundled' = auto-provisioned database container (PostgreSQL/MySQL) with generated credentials. 'custom' = external DB with explicit credentials. Always check the app's README first.",
      },
      db_host: { type: "string", description: "Custom database host." },
      db_port: {
        type: "string",
        description: "Custom database port. Default: 5432 (PostgreSQL) or 3306 (MySQL).",
      },
      db_name: { type: "string", description: "Database name." },
      db_user: { type: "string", description: "Database user." },
      db_pass: { type: "string", description: "Database password." },
      port: {
        type: "string",
        description:
          "Override default app port. Auto-increments if the port is occupied.",
      },
      dry_run: {
        type: "boolean",
        description: "Preview what would be done without executing. Default: false.",
      },
      extra_env: {
        type: "object",
        description:
          "Additional environment variables for specific apps. Examples: { DOMAIN_PUBLIC: 'static.example.com' } for filebrowser, { WP_DB_MODE: 'sqlite' } for wordpress.",
        additionalProperties: { type: "string" },
      },
      build_file: {
        type: "string",
        description:
          "Absolute path to a local build file (e.g. gateflow-build.tar.gz). Used for GateFlow when the GitHub repo is private.",
      },
    },
    required: ["app_name"],
  },
};

export async function handleDeployApp(
  args: Record<string, unknown>
): Promise<{ content: Array<{ type: string; text: string }>; isError?: boolean }> {
  const appName = args.app_name as string;
  const alias = (args.ssh_alias as string) ?? getDefaultAlias();
  const domainType = args.domain_type as string | undefined;
  const domain = args.domain as string | undefined;
  const dbSource = args.db_source as string | undefined;
  const dryRun = (args.dry_run as boolean) ?? false;
  const extraEnv = (args.extra_env as Record<string, string>) ?? {};

  // 0. Validate alias (prevent SSH option injection)
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(alias)) {
    return {
      isError: true,
      content: [
        { type: "text", text: `Invalid SSH alias '${alias}'. Use only letters, numbers, dashes, underscores.` },
      ],
    };
  }

  // 1. Validate app name (prevent path traversal)
  if (!/^[a-z0-9][a-z0-9_-]*$/.test(appName)) {
    return {
      isError: true,
      content: [
        { type: "text", text: `Invalid app name '${appName}'. Use only lowercase letters, numbers, dashes, underscores.` },
      ],
    };
  }

  const appDir = join(getAppsDir(), appName);
  if (!existsSync(appDir)) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `App '${appName}' not found. Use list_apps to see available applications.`,
        },
      ],
    };
  }

  // 2. Check app requirements (skip for WordPress SQLite mode)
  const meta = parseAppMetadata(appDir);
  const skipDbCheck = appName === "wordpress" && extraEnv.WP_DB_MODE === "sqlite";
  if (meta?.requiresDb && !dbSource && !skipDbCheck) {
    const dbType = meta.dbType === "mysql" ? "MySQL" : "PostgreSQL";
    const wpNote = appName === "wordpress"
      ? `\n\nALTERNATIVE: WordPress can run without MySQL using SQLite mode. Pass extra_env: { WP_DB_MODE: "sqlite" } to skip database requirement entirely.`
      : "";
    return {
      isError: true,
      content: [{
        type: "text",
        text: `This app requires ${dbType}. Ask the user which database to use:\n` +
          `- db_source: 'bundled' — auto-provisioned ${dbType} container with generated credentials\n` +
          `- db_source: 'custom' — external DB (ask user for db_host, db_port, db_name, db_user, db_pass)` +
          wpNote,
      }],
    };
  }

  // 2b. GateFlow: validate Supabase configuration exists
  if (appName === "gateflow") {
    const hasSupabaseKeys = extraEnv.SUPABASE_URL && extraEnv.SUPABASE_ANON_KEY && extraEnv.SUPABASE_SERVICE_KEY;
    const configPath = join(homedir(), ".config", "gateflow", "deploy-config.env");
    const hasSavedConfig = existsSync(configPath);
    if (!hasSupabaseKeys && !hasSavedConfig) {
      return {
        isError: true,
        content: [{
          type: "text",
          text: `GateFlow requires Supabase configuration.\n\n` +
            `Use the setup_gateflow_config tool first — it handles the entire Supabase login flow securely:\n` +
            `1. Opens browser for Supabase login\n` +
            `2. User provides a one-time verification code (not a secret)\n` +
            `3. Tool fetches API keys automatically and saves config to disk\n\n` +
            `No secret keys ever pass through the conversation.\n\n` +
            `Call: setup_gateflow_config()`,
        }],
      };
    }
  }

  // 3. Build deploy.sh arguments
  const deployArgs: string[] = [appName, "--yes", `--ssh=${alias}`];

  if (domainType) deployArgs.push(`--domain-type=${domainType}`);
  if (domain) deployArgs.push(`--domain=${domain}`);
  if (dbSource) deployArgs.push(`--db-source=${dbSource}`);
  if (args.db_host) deployArgs.push(`--db-host=${args.db_host}`);
  if (args.db_port) deployArgs.push(`--db-port=${args.db_port}`);
  if (args.db_name) deployArgs.push(`--db-name=${args.db_name}`);
  if (args.db_user) deployArgs.push(`--db-user=${args.db_user}`);
  if (args.db_pass) deployArgs.push(`--db-pass=${args.db_pass}`);
  if (args.port) deployArgs.push(`--port=${args.port}`);
  if (args.build_file) {
    const buildFile = args.build_file as string;
    if (!existsSync(buildFile)) {
      return {
        isError: true,
        content: [{ type: "text", text: `Build file not found: ${buildFile}` }],
      };
    }
    deployArgs.push(`--build-file=${buildFile}`);
  }
  if (dryRun) deployArgs.push("--dry-run");

  // 4. Build environment (block dangerous env var overrides)
  const BLOCKED_ENV_VARS = new Set([
    "PATH", "HOME", "USER", "SHELL", "LD_PRELOAD", "LD_LIBRARY_PATH",
    "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "BASH_ENV", "ENV",
    "SSH_AUTH_SOCK", "SSH_AGENT_PID", "TERM",
  ]);
  const safeExtraEnv: Record<string, string> = {};
  for (const [key, val] of Object.entries(extraEnv)) {
    if (!BLOCKED_ENV_VARS.has(key)) {
      safeExtraEnv[key] = val;
    }
  }

  const env: Record<string, string> = {
    ...process.env as Record<string, string>,
    TERM: "dumb",
    ...safeExtraEnv,
  };

  const deployPath = getDeployShPath();
  const repoRoot = resolveRepoRoot();

  // 5. Execute deploy.sh
  return new Promise((resolve) => {
    execFile(
      deployPath,
      deployArgs,
      {
        cwd: repoRoot,
        env,
        timeout: 600_000, // 10 minutes (large images like convertx ~5.3GB)
        maxBuffer: 5 * 1024 * 1024, // 5MB
      },
      (error, stdout, stderr) => {
        const output = [stdout?.toString() ?? "", stderr?.toString() ?? ""]
          .filter(Boolean)
          .join("\n");

        if (error) {
          // Timeout
          if (error.killed) {
            resolve({
              isError: true,
              content: [
                {
                  type: "text",
                  text: `Deployment timed out after 10 minutes.\n\nPartial output:\n${output}`,
                },
              ],
            });
            return;
          }

          resolve({
            isError: true,
            content: [
              {
                type: "text",
                text: `Deployment failed (exit code ${error.code ?? "?"}).\n\nOutput:\n${output}`,
              },
            ],
          });
          return;
        }

        if (dryRun) {
          resolve({
            content: [
              { type: "text", text: `[DRY RUN] Would deploy ${appName}:\n\n${output}` },
            ],
          });
          return;
        }

        // Check backup status and server health after successful deployment
        Promise.all([
          checkBackupStatus(alias),
          checkServerHealth(alias),
        ]).then(([backupWarning, healthSummary]) => {
          const text = `Deployment complete for ${appName}:\n\n${output}` +
            (backupWarning ?? "") +
            healthSummary;
          resolve({ content: [{ type: "text", text }] });
        });
      }
    );
  });
}
