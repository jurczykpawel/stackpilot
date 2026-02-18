import {
  testConnection,
  sshExec,
  sshKeyExists,
  generateSSHKey,
  getPublicKey,
  aliasExists,
  writeSSHConfig,
  getSSHCopyIdCommand,
} from "../lib/ssh.js";
import { setServer } from "../lib/config.js";

type ToolResult = {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
};

export const setupServerTool = {
  name: "setup_server",
  description:
    "Set up or test SSH connection to a VPS server.\n\n" +
    "TWO MODES:\n" +
    "1. SETUP (new connection): Provide host + port to generate SSH key, write ~/.ssh/config, " +
    "and get the ssh-copy-id command for the user to run (they type their password once in terminal).\n" +
    "2. TEST (existing connection): Provide ssh_alias to test connectivity and check server resources.\n\n" +
    "Typical flow: setup_server with host+port → user runs ssh-copy-id → setup_server with ssh_alias to verify.\n\n" +
    "WINDOWS USERS: After SSH setup, Windows users can install the toolbox ON the server " +
    "with './local/install-toolbox.sh <alias>', then SSH in and run scripts directly " +
    "(e.g. 'ssh vps' → 'deploy.sh uptime-kuma'). This avoids needing bash on Windows.\n\n" +
    "FRESH SERVER: When testing a new server, check if Docker is installed. If not, " +
    "suggest the user run the built-in 'start' script (ssh <alias> then 'start'). " +
    "It sets timezone, installs Docker, updates the system, and optionally sets up zsh. " +
    "Guide the user step by step: T for timezone, 1 for nano, T/N for zsh, T for Docker (required!), T for updates.",
  inputSchema: {
    type: "object" as const,
    properties: {
      // Setup mode
      host: {
        type: "string",
        description: "Server address (e.g. 'srv20.mikr.us'). Triggers SETUP mode.",
      },
      port: {
        type: "number",
        description: "SSH port number (e.g. 2222).",
      },
      user: {
        type: "string",
        description: "SSH username. Default: root",
      },
      alias: {
        type: "string",
        description: "SSH alias name. Default: vps",
      },
      // Test mode
      ssh_alias: {
        type: "string",
        description:
          "Test existing SSH alias. Checks connectivity, RAM, disk, containers.",
      },
      set_as_default: {
        type: "boolean",
        description: "Set as default server. Default: true",
      },
    },
  },
};

export async function handleSetupServer(
  args: Record<string, unknown>
): Promise<ToolResult> {
  // Decide mode: SETUP if host provided, TEST if ssh_alias provided
  if (args.host) {
    return handleSetup(args);
  }
  if (args.ssh_alias) {
    return handleTest(args);
  }
  return {
    isError: true,
    content: [
      {
        type: "text",
        text: "Provide either:\n- host + port for new SSH setup\n- ssh_alias to test existing connection",
      },
    ],
  };
}

// --- SETUP MODE ---
async function handleSetup(args: Record<string, unknown>): Promise<ToolResult> {
  const host = args.host as string;
  const port = args.port as number | undefined;
  const user = (args.user as string) ?? "root";
  const alias = (args.alias as string) ?? "vps";

  // Validate inputs (prevent SSH config injection)
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(alias)) {
    return {
      isError: true,
      content: [
        { type: "text", text: `Invalid alias '${alias}'. Use only letters, numbers, dashes, underscores.` },
      ],
    };
  }
  if (/[\n\r\0]/.test(host) || !/^[a-zA-Z0-9._-]+$/.test(host)) {
    return {
      isError: true,
      content: [
        { type: "text", text: `Invalid hostname '${host}'. Use only letters, numbers, dots, dashes.` },
      ],
    };
  }
  if (/[\n\r\0]/.test(user) || !/^[a-zA-Z0-9._-]+$/.test(user)) {
    return {
      isError: true,
      content: [
        { type: "text", text: `Invalid username '${user}'. Use only letters, numbers, dots, dashes, underscores.` },
      ],
    };
  }

  if (!port) {
    return {
      isError: true,
      content: [{ type: "text", text: "SSH port is required (e.g. port: 2222)." }],
    };
  }

  const lines: string[] = [];

  // 1. Generate SSH key if needed
  if (!sshKeyExists()) {
    lines.push("Generating SSH key (ed25519)...");
    const keyResult = await generateSSHKey();
    if (!keyResult.ok) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: `Failed to generate SSH key: ${keyResult.error}`,
          },
        ],
      };
    }
    lines.push("  SSH key generated: ~/.ssh/id_ed25519");
  } else {
    lines.push("SSH key already exists: ~/.ssh/id_ed25519");
  }

  // 2. Check for alias conflict
  if (aliasExists(alias)) {
    lines.push("");
    lines.push(`Alias '${alias}' already exists in ~/.ssh/config.`);
    lines.push("Skipping config write to avoid duplicate.");
    lines.push("");
    lines.push("To test the existing connection, call setup_server with:");
    lines.push(`  { ssh_alias: "${alias}" }`);
    return { content: [{ type: "text", text: lines.join("\n") }] };
  }

  // 3. Write SSH config
  writeSSHConfig({ alias, host, port, user });
  lines.push(`SSH config written for alias '${alias}'`);

  // 4. Save MCP config
  setServer(alias, { sshAlias: alias, hostname: host, user }, true);
  lines.push(`Default server set to: ${alias}`);

  // 5. Return ssh-copy-id command
  const copyCmd = getSSHCopyIdCommand({ host, port, user });
  const pubKey = getPublicKey();

  lines.push("");
  lines.push("--- NEXT STEP ---");
  lines.push("");
  lines.push("Run this command in your terminal and enter your server password:");
  lines.push("");
  lines.push(`  ${copyCmd}`);
  lines.push("");
  lines.push("This copies your public key to the server (one-time operation).");
  lines.push("After that, tell me and I'll verify the connection.");

  if (pubKey) {
    lines.push("");
    lines.push("Your public key (if you prefer to add it manually on the server):");
    lines.push(`  ${pubKey}`);
  }

  return { content: [{ type: "text", text: lines.join("\n") }] };
}

// --- TEST MODE ---
async function handleTest(args: Record<string, unknown>): Promise<ToolResult> {
  const alias = args.ssh_alias as string;
  const setDefault = (args.set_as_default as boolean) ?? true;

  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(alias)) {
    return {
      isError: true,
      content: [
        { type: "text", text: `Invalid SSH alias '${alias}'. Use only letters, numbers, dashes, underscores.` },
      ],
    };
  }

  // 1. Test connectivity
  const conn = await testConnection(alias);
  if (!conn.ok) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: [
            `Connection FAILED to SSH alias '${alias}'`,
            "",
            `Error: ${conn.error}`,
            "",
            "If you just ran ssh-copy-id, make sure:",
            "  1. The command completed without errors",
            "  2. You entered the correct password",
            "",
            "To set up a new connection, call setup_server with:",
            "  { host: 'srvXX.mikr.us', port: 2222 }",
          ].join("\n"),
        },
      ],
    };
  }

  // 2. Gather server resources + initial setup detection
  const resourceCmd = [
    'echo "RAM_TOTAL=$(free -m 2>/dev/null | awk \'/^Mem:/ {print $2}\')"',
    'echo "RAM_AVAILABLE=$(free -m 2>/dev/null | awk \'/^Mem:/ {print $7}\')"',
    'echo "DISK_TOTAL=$(df -m / 2>/dev/null | awk \'NR==2 {print $2}\')"',
    'echo "DISK_AVAILABLE=$(df -m / 2>/dev/null | awk \'NR==2 {print $4}\')"',
    'echo "DOCKER_OK=$(docker --version 2>/dev/null && echo YES || echo NO)"',
    'echo "TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo unknown)"',
    'echo "===CONTAINERS==="',
    "docker ps --format '{{.Names}}\\t{{.Status}}\\t{{.Ports}}' 2>/dev/null || echo 'NO_DOCKER'",
    'echo "===STACKS==="',
    "ls -1 /opt/stacks/ 2>/dev/null || echo 'NONE'",
  ].join("; ");

  const res = await sshExec(alias, resourceCmd);
  const output = res.stdout;

  const ramTotal = output.match(/RAM_TOTAL=(\d+)/)?.[1] ?? "?";
  const ramAvail = output.match(/RAM_AVAILABLE=(\d+)/)?.[1] ?? "?";
  const diskTotal = output.match(/DISK_TOTAL=(\d+)/)?.[1] ?? "?";
  const diskAvail = output.match(/DISK_AVAILABLE=(\d+)/)?.[1] ?? "?";
  const hasDocker = output.includes("DOCKER_OK=Docker version");
  const timezone = output.match(/TIMEZONE=(.+)/)?.[1]?.trim() ?? "unknown";

  const containerSection =
    output.split("===CONTAINERS===")[1]?.split("===STACKS===")[0] ?? "";
  const containerLines = containerSection
    .trim()
    .split("\n")
    .filter((l) => l && l !== "NO_DOCKER");

  const stacksSection = output.split("===STACKS===")[1] ?? "";
  const stacks = stacksSection
    .trim()
    .split("\n")
    .filter((l) => l && l !== "NONE");

  // 3. Save config
  setServer(
    alias,
    { sshAlias: alias, hostname: conn.hostname, user: conn.user },
    setDefault
  );

  // 4. Format response
  const lines: string[] = [
    `Connection OK: ${alias}`,
    `  Host: ${conn.user ?? "?"}@${conn.hostname ?? "?"}`,
    "",
    "Resources:",
    `  RAM:  ${ramAvail}MB available / ${ramTotal}MB total`,
    `  Disk: ${diskAvail}MB available / ${diskTotal}MB total`,
  ];

  if (containerLines.length > 0) {
    lines.push("", `Running Containers (${containerLines.length}):`);
    for (const c of containerLines) {
      lines.push(`  ${c}`);
    }
  } else {
    lines.push("", "No running containers.");
  }

  if (stacks.length > 0) {
    lines.push("", `Installed Stacks: ${stacks.join(", ")}`);
  }

  if (setDefault) {
    lines.push("", `Default server set to: ${alias}`);
  }

  // 5. Detect if initial setup needed (no Docker = fresh server)
  const needsSetup = !hasDocker;
  const nonPolishTz = timezone !== "Europe/Warsaw" && timezone !== "unknown";

  if (needsSetup || nonPolishTz) {
    lines.push("", "--- RECOMMENDED: Initial Server Setup ---");
    lines.push("");
    lines.push("This looks like a fresh server. Mikrus provides a built-in 'start' script");
    lines.push("that configures essential settings. Tell the user to run it via SSH:");
    lines.push("");
    lines.push(`  ssh ${alias}`);
    lines.push("  start");
    lines.push("");
    lines.push("The script is interactive and asks about:");
    lines.push("  1. Timezone → answer T (Tak/Yes) to set Europe/Warsaw");
    lines.push("  2. Default editor → type 1 (nano, easiest for beginners)");
    lines.push("  3. Shell → zsh with Oh My Zsh: T if user wants a modern shell, N to keep bash");
    lines.push("  4. Docker → answer T (required for deploying apps with the toolbox)");
    lines.push("  5. System update → answer T (recommended for security)");
    lines.push("");
    lines.push("Guide the user through each step — explain what each question means.");
    if (!hasDocker) {
      lines.push("");
      lines.push("IMPORTANT: Docker is NOT installed. Most toolbox apps require Docker.");
      lines.push("The user MUST answer T (Yes) to the Docker question in 'start',");
      lines.push("or install it manually: curl -fsSL https://get.docker.com | sh");
    }
  }

  return { content: [{ type: "text", text: lines.join("\n") }] };
}
