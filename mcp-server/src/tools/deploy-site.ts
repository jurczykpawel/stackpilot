import { existsSync, statSync } from "node:fs";
import { basename, resolve } from "node:path";
import { getDefaultAlias } from "../lib/config.js";
import { detectProject, type ProjectAnalysis } from "../lib/project-detect.js";
import { deploy, type DeployConfig } from "../lib/deploy-strategies.js";
import { checkBackupStatus } from "../lib/backup-check.js";
import { checkServerHealth } from "../lib/resource-check.js";

type ToolResult = {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
};

export const deploySiteTool = {
  name: "deploy_site",
  description:
    "Deploy a LOCAL project (website, Node.js app, Python app, Docker project) directly to a Mikrus VPS. " +
    "Analyzes the project directory, detects the type, uploads files via rsync, and starts the service.\n\n" +
    "TWO MODES:\n" +
    "1. ANALYZE (analyze_only=true): Reads local directory, detects project type, shows recommendations. No deployment.\n" +
    "2. DEPLOY (confirmed=true): Actually uploads and deploys. Must be confirmed for safety.\n\n" +
    "Supported project types (auto-detected):\n" +
    "- docker-compose: has docker-compose.yaml → Docker Compose\n" +
    "- dockerfile: has Dockerfile → Docker build\n" +
    "- nextjs: package.json + next.config.* → Docker (may need build first)\n" +
    "- node: package.json with start script → PM2 process manager\n" +
    "- python: requirements.txt or pyproject.toml → auto-generated Docker\n" +
    "- static: index.html or HTML/CSS/JS files → instant deploy via Caddy/nginx\n\n" +
    "Static sites use the 'Tiiny.host Killer' fast path: if static hosting already exists " +
    "(FileBrowser or add-static-hosting.sh), files are synced to /var/www/public/ and are live instantly.\n\n" +
    "Typical flow: call with analyze_only first, then with confirmed=true after user agrees.",
  inputSchema: {
    type: "object" as const,
    properties: {
      project_path: {
        type: "string",
        description:
          "Absolute path to the local project directory to deploy.",
      },
      name: {
        type: "string",
        description:
          "Site/app name (lowercase, alphanumeric + dashes). Used for remote directory. Default: directory name.",
      },
      analyze_only: {
        type: "boolean",
        description:
          "Just detect project type and show recommendations. No deployment. Default: false.",
      },
      strategy: {
        type: "string",
        enum: ["static", "node", "docker", "auto"],
        description:
          "Deployment strategy. 'auto' detects from project type. Default: 'auto'.",
      },
      ssh_alias: {
        type: "string",
        description:
          "SSH alias for the Mikrus server. If omitted, uses the default configured server.",
      },
      domain_type: {
        type: "string",
        enum: ["cytrus", "cloudflare", "local"],
        description:
          "'cytrus' = free Mikrus subdomain (*.byst.re). 'cloudflare' = own domain via Caddy. 'local' = no external domain.",
      },
      domain: {
        type: "string",
        description:
          "'auto' for automatic Cytrus subdomain assignment. Full domain for cloudflare (e.g. 'app.example.com').",
      },
      port: {
        type: "number",
        description: "Override auto-detected port number.",
      },
      start_command: {
        type: "string",
        description:
          "Override start command for Node.js strategy (default: from package.json scripts.start).",
      },
      install_command: {
        type: "string",
        description:
          "Override install command for Node.js strategy (default: 'npm install --production').",
      },
      env_vars: {
        type: "object",
        description: "Environment variables to set on the server.",
        additionalProperties: { type: "string" },
      },
      confirmed: {
        type: "boolean",
        description:
          "User has explicitly confirmed deployment. MUST be true to proceed with actual deployment.",
      },
    },
    required: ["project_path"],
  },
};

export async function handleDeploySite(
  args: Record<string, unknown>
): Promise<ToolResult> {
  const projectPath = resolve(args.project_path as string);
  const analyzeOnly = (args.analyze_only as boolean) ?? false;
  const confirmed = (args.confirmed as boolean) ?? false;
  const alias = (args.ssh_alias as string) ?? getDefaultAlias();

  // 1. Validate path
  if (!existsSync(projectPath) || !statSync(projectPath).isDirectory()) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Project path does not exist or is not a directory: ${projectPath}`,
        },
      ],
    };
  }

  // 2. Detect project type
  const analysis = detectProject(projectPath);

  // 3. Determine name
  const rawName = (args.name as string) ?? basename(projectPath);
  const name = rawName
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!name.match(/^[a-z0-9][a-z0-9-]*$/)) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Invalid site name '${name}'. Use only lowercase letters, numbers, and dashes.`,
        },
      ],
    };
  }

  // 4. Analyze-only mode
  if (analyzeOnly) {
    return formatAnalysis(name, analysis);
  }

  // 5. Safety: require confirmation
  if (!confirmed) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text:
            "Deployment not confirmed. First use analyze_only=true to review, " +
            "then set confirmed=true after user agrees.",
        },
      ],
    };
  }

  // 6. Block if build required
  if (analysis.buildRequired) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Project requires building first. ${analysis.buildHint ?? "Build the project before deploying."}`,
        },
      ],
    };
  }

  // 7. Resolve strategy
  const requestedStrategy = (args.strategy as string) ?? "auto";
  const strategy: "static" | "node" | "docker" =
    requestedStrategy === "auto"
      ? analysis.strategy
      : (requestedStrategy as "static" | "node" | "docker");

  // 8. Build config
  const config: DeployConfig = {
    projectPath,
    name,
    alias,
    strategy,
    domainType:
      (args.domain_type as "cytrus" | "cloudflare" | "local") ?? "local",
    domain: args.domain as string | undefined,
    port: (args.port as number) ?? analysis.port ?? undefined,
    startCommand:
      (args.start_command as string) ?? analysis.startCommand ?? undefined,
    installCommand: args.install_command as string | undefined,
    envVars: args.env_vars as Record<string, string> | undefined,
  };

  // 9. Deploy
  const result = await deploy(config, analysis);

  if (!result.ok) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: [...result.lines, "", `Error: ${result.error}`].join("\n"),
        },
      ],
    };
  }

  // Check backup status and server health after successful deployment
  const [backupWarning, healthSummary] = await Promise.all([
    checkBackupStatus(alias),
    checkServerHealth(alias),
  ]);
  const text = result.lines.join("\n") + (backupWarning ?? "") + healthSummary;

  return {
    content: [{ type: "text", text }],
  };
}

function formatAnalysis(name: string, analysis: ProjectAnalysis): ToolResult {
  const lines: string[] = [
    `Project Analysis: ${name}`,
    "",
    `Type: ${analysis.type}`,
    `Recommended strategy: ${analysis.strategy}`,
    `Files: ${analysis.totalFiles} (${analysis.totalSizeKB}KB)`,
  ];

  if (analysis.port) lines.push(`Detected port: ${analysis.port}`);
  if (analysis.startCommand)
    lines.push(`Start command: ${analysis.startCommand}`);

  if (analysis.buildRequired) {
    lines.push("");
    lines.push(`BUILD REQUIRED: ${analysis.buildHint}`);
  }

  if (analysis.files.length > 0) {
    lines.push("");
    lines.push(`Key files: ${analysis.files.join(", ")}`);
  }

  if (analysis.warnings.length > 0) {
    lines.push("");
    lines.push("Warnings:");
    for (const w of analysis.warnings) {
      lines.push(`  - ${w}`);
    }
  }

  lines.push("");
  lines.push(analysis.summary);
  lines.push("");
  lines.push(
    "To deploy, call deploy_site with confirmed=true and the desired domain_type/domain."
  );

  return { content: [{ type: "text", text: lines.join("\n") }] };
}
