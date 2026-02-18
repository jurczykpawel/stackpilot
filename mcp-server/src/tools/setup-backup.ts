import { sshExec } from "../lib/ssh.js";
import { getDefaultAlias } from "../lib/config.js";
import { ensureToolboxOnServer } from "../lib/ensure-toolbox.js";

type ToolResult = {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
};

export const setupBackupTool = {
  name: "setup_backup",
  description:
    "Configure automatic backups on a Mikrus VPS server. " +
    "Run this after deploying apps to protect user data.\n\n" +
    "Backup types:\n" +
    "  - 'db': Automatic daily database backup (PostgreSQL/MySQL). " +
    "Auto-detects shared Mikrus databases. Runs on server via cron.\n" +
    "  - 'mikrus': Built-in Mikrus backup (200MB, free). " +
    "Backs up /etc, /home, /var/log to Mikrus backup server (strych.mikr.us). " +
    "User must first activate backup in panel: https://mikr.us/panel/?a=backup\n" +
    "  - 'cloud': Cloud backup (Google Drive, Dropbox, S3). " +
    "Requires local setup with rclone — cannot be done via MCP. " +
    "Returns instructions for the user to run locally.\n\n" +
    "NOTE: 'db' and 'mikrus' types auto-install the toolbox on the server if needed " +
    "(via rsync from local repo or git clone from GitHub). " +
    "'cloud' only returns instructions.",
  inputSchema: {
    type: "object" as const,
    properties: {
      backup_type: {
        type: "string",
        enum: ["db", "mikrus", "cloud"],
        description:
          "'db' = database backup (auto-detect shared DBs, daily cron). " +
          "'mikrus' = built-in Mikrus backup (200MB free, needs panel activation). " +
          "'cloud' = cloud backup via rclone (returns local setup instructions only).",
      },
      ssh_alias: {
        type: "string",
        description:
          "SSH alias. If omitted, uses the default configured server.",
      },
    },
    required: ["backup_type"],
  },
};

export async function handleSetupBackup(
  args: Record<string, unknown>
): Promise<ToolResult> {
  const backupType = args.backup_type as string;
  const alias = (args.ssh_alias as string) ?? getDefaultAlias();

  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(alias)) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Invalid SSH alias '${alias}'. Use only letters, numbers, dashes, underscores.`,
        },
      ],
    };
  }

  switch (backupType) {
    case "db":
      return runBackupScript(alias, "system/setup-db-backup.sh");
    case "mikrus":
      return runBackupScript(alias, "system/setup-backup-mikrus.sh");
    case "cloud":
      return cloudBackupInstructions(alias);
    default:
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: `Unknown backup type '${backupType}'. Use 'db', 'mikrus', or 'cloud'.`,
          },
        ],
      };
  }
}

/**
 * Ensure toolbox is on the server, then run a backup script from it.
 */
async function runBackupScript(
  alias: string,
  scriptPath: string
): Promise<ToolResult> {
  // Auto-install toolbox if needed (git clone from GitHub)
  const toolbox = await ensureToolboxOnServer(alias);
  if (!toolbox.ok) {
    return {
      isError: true,
      content: [{ type: "text", text: toolbox.error! }],
    };
  }

  const lines: string[] = [];
  if (toolbox.installed) {
    lines.push("Toolbox installed on server.");
    lines.push("");
  }

  // Run script non-interactively (< /dev/null skips interactive questions)
  const result = await sshExec(
    alias,
    `bash /opt/mikrus-toolbox/${scriptPath} < /dev/null 2>&1`,
    120_000
  );

  const output = result.stdout.trim();

  if (result.exitCode !== 0) {
    if (output.includes("Nie można połączyć") || output.includes("backup_key")) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text:
              `Backup setup failed — backup may not be activated in the panel.\n\n` +
              `The user must first activate backup at: https://mikr.us/panel/?a=backup\n` +
              `Then wait a few minutes and try again.\n\n` +
              `Full output:\n${output}`,
          },
        ],
      };
    }

    return {
      isError: true,
      content: [{ type: "text", text: `Backup setup failed:\n\n${output}` }],
    };
  }

  lines.push(output);

  return {
    content: [{ type: "text", text: lines.join("\n") }],
  };
}

function cloudBackupInstructions(alias: string): ToolResult {
  return {
    content: [
      {
        type: "text",
        text:
          "Cloud backup requires local setup (OAuth browser login for Google Drive/Dropbox).\n" +
          "It cannot be configured remotely via MCP.\n\n" +
          "The user should run this command on their local machine:\n" +
          `  ./local/setup-backup.sh ${alias}\n\n` +
          "This will:\n" +
          "  1. Authenticate with a cloud provider (Google Drive, Dropbox, OneDrive, Mega, S3)\n" +
          "  2. Optionally encrypt backups\n" +
          "  3. Upload the config to the server\n" +
          "  4. Set up daily cron (backs up /opt/stacks, /opt/dockge)",
      },
    ],
  };
}
