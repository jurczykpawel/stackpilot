import { sshExec, sshExecWithStdin } from "../lib/ssh.js";
import { getDefaultAlias } from "../lib/config.js";
import { checkBackupStatus } from "../lib/backup-check.js";
import { checkServerHealth } from "../lib/resource-check.js";

type ToolResult = {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
};

export const deployCustomAppTool = {
  name: "deploy_custom_app",
  description:
    "Deploy ANY Docker application to a VPS - not limited to the built-in app list. " +
    "The AI model researches the app, generates a docker-compose.yaml, and deploys it.\n\n" +
    "IMPORTANT: Before calling this tool, you MUST:\n" +
    "1. Explain to the user what the app does\n" +
    "2. Show them the docker-compose.yaml you generated\n" +
    "3. Get their explicit confirmation to proceed\n" +
    "4. Set confirmed: true only after user says yes\n\n" +
    "The compose file is uploaded to /opt/stacks/{name}/ on the server and started with docker compose.\n\n" +
    "IMPORTANT: This tool does NOT configure a public domain. After deployment, use the setup_domain tool " +
    "to assign a Cytrus subdomain (e.g. setup_domain with port and domain='auto'). " +
    "If the user wants a public URL, you MUST call setup_domain as a follow-up step.",
  inputSchema: {
    type: "object" as const,
    properties: {
      name: {
        type: "string",
        description:
          "Stack name (lowercase, alphanumeric + dashes). Used for /opt/stacks/{name}/.",
      },
      compose: {
        type: "string",
        description: "Full docker-compose.yaml content to deploy.",
      },
      ssh_alias: {
        type: "string",
        description: "SSH alias. If omitted, uses the default configured server.",
      },
      port: {
        type: "number",
        description:
          "Expected app port on the host (for health check after deployment).",
      },
      confirmed: {
        type: "boolean",
        description:
          "User has explicitly confirmed deployment. MUST be true to proceed.",
      },
    },
    required: ["name", "compose", "confirmed"],
  },
};

export async function handleDeployCustomApp(
  args: Record<string, unknown>
): Promise<ToolResult> {
  const name = args.name as string;
  const compose = args.compose as string;
  const alias = (args.ssh_alias as string) ?? getDefaultAlias();
  const port = args.port as number | undefined;
  const confirmed = args.confirmed as boolean;

  // 0. Validate alias (prevent SSH option injection)
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(alias)) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Invalid SSH alias '${alias}'. Use only letters, numbers, dashes, and underscores.`,
        },
      ],
    };
  }

  // 1. Require explicit confirmation
  if (!confirmed) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: "Deployment not confirmed. Show the user the docker-compose.yaml and get their explicit confirmation before setting confirmed: true.",
        },
      ],
    };
  }

  // 2. Validate name
  if (!name.match(/^[a-z0-9][a-z0-9-]*$/)) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Invalid stack name '${name}'. Use only lowercase letters, numbers, and dashes. Must start with a letter or number.`,
        },
      ],
    };
  }

  // 3. Validate compose content
  if (!compose.includes("services:") && !compose.includes("services :")) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: "Invalid docker-compose.yaml: missing 'services:' section.",
        },
      ],
    };
  }

  const stackDir = `/opt/stacks/${name}`;

  // 4. Upload docker-compose.yaml
  const mkdirResult = await sshExec(
    alias,
    `sudo mkdir -p ${stackDir}`,
    15_000
  );
  if (mkdirResult.exitCode !== 0) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Failed to create directory ${stackDir}: ${mkdirResult.stderr}`,
        },
      ],
    };
  }

  // Write compose file via stdin
  const writeResult = await sshExecWithStdin(
    alias,
    `cat > ${stackDir}/docker-compose.yaml`,
    compose,
    15_000
  );
  if (writeResult.exitCode !== 0) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Failed to write docker-compose.yaml: ${writeResult.stderr}`,
        },
      ],
    };
  }

  // 5. Pull images (can take long for large images)
  const pullResult = await sshExec(
    alias,
    `cd ${stackDir} && sudo docker compose pull 2>&1`,
    600_000 // 10 min for large images
  );

  const lines: string[] = [];

  if (pullResult.exitCode !== 0) {
    lines.push(`Image pull failed for '${name}':`);
    lines.push("");
    lines.push(pullResult.stdout);
    if (pullResult.stderr) lines.push(pullResult.stderr);
    return { isError: true, content: [{ type: "text", text: lines.join("\n") }] };
  }

  lines.push("Images pulled successfully.");

  // 6. Start containers (fast after pull)
  const startResult = await sshExec(
    alias,
    `cd ${stackDir} && sudo docker compose up -d 2>&1`,
    60_000 // 1 min - images already pulled
  );

  if (startResult.exitCode !== 0) {
    lines.push("");
    lines.push(`Container start failed for '${name}':`);
    lines.push(startResult.stdout);
    if (startResult.stderr) lines.push(startResult.stderr);
    return { isError: true, content: [{ type: "text", text: lines.join("\n") }] };
  }

  lines.push(`Custom app '${name}' deployed successfully.`);
  lines.push("");
  lines.push("Docker Compose output:");
  lines.push(startResult.stdout);

  // 6. Health check (optional)
  if (port) {
    // Wait a moment for container startup
    await sshExec(alias, "sleep 3", 10_000);
    const healthResult = await sshExec(
      alias,
      `curl -sf -o /dev/null -w '%{http_code}' http://localhost:${port}/ 2>/dev/null || echo 'UNREACHABLE'`,
      15_000
    );
    const status = healthResult.stdout.trim();
    if (status === "UNREACHABLE" || status === "") {
      lines.push("");
      lines.push(`Health check: port ${port} not responding yet (app may still be starting).`);
      lines.push(`  Check manually: ssh ${alias} "curl -s http://localhost:${port}/"`);
    } else {
      lines.push("");
      lines.push(`Health check: HTTP ${status} on port ${port}`);
    }
  }

  lines.push("");
  lines.push("Management commands:");
  lines.push(`  ssh ${alias} "cd ${stackDir} && docker compose logs -f"`);
  lines.push(`  ssh ${alias} "cd ${stackDir} && docker compose restart"`);
  lines.push(`  ssh ${alias} "cd ${stackDir} && docker compose down"`);

  // Check backup status and server health after successful deployment
  const [backupWarning, healthSummary] = await Promise.all([
    checkBackupStatus(alias),
    checkServerHealth(alias),
  ]);
  if (backupWarning) {
    lines.push(backupWarning);
  }
  lines.push(healthSummary);

  return { content: [{ type: "text", text: lines.join("\n") }] };
}

