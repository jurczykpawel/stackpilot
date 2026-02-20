import { sshExec } from "../lib/ssh.js";
import { getDefaultAlias } from "../lib/config.js";

type ToolResult = {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
};

export const setupDomainTool = {
  name: "setup_domain",
  description:
    "Configure a public domain for an application running on a specific port. " +
    "Uses Caddy reverse proxy with automatic HTTPS (Let's Encrypt).\n\n" +
    "PREREQUISITES:\n" +
    "- The user must point their domain's A record to the server's IP address\n" +
    "- Caddy must be installed on the server (auto-installed if missing)\n\n" +
    "WHEN TO USE:\n" +
    "- After deploy_custom_app, to give the app a public URL\n" +
    "- To add a domain to an existing app that doesn't have one\n" +
    "- To change the domain for an app\n\n" +
    "WHEN NOT TO USE:\n" +
    "- After deploy_app with domain_type='caddy' or 'cloudflare' — deploy_app already handles domain setup automatically",
  inputSchema: {
    type: "object" as const,
    properties: {
      port: {
        type: "number",
        description:
          "Port number the application is listening on (1-65535). Required.",
      },
      domain: {
        type: "string",
        description:
          "Domain name to assign (e.g. 'myapp.example.com'). The domain's A record must point to the server IP.",
      },
      ssh_alias: {
        type: "string",
        description:
          "SSH alias. If omitted, uses the default configured server.",
      },
    },
    required: ["port", "domain"],
  },
};

const VALID_DOMAIN_PATTERN = /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$/i;

export async function handleSetupDomain(
  args: Record<string, unknown>
): Promise<ToolResult> {
  const port = args.port as number | undefined;
  const domain = args.domain as string | undefined;
  const alias = (args.ssh_alias as string) ?? getDefaultAlias();

  // 1. Validate inputs
  if (port == null || typeof port !== "number" || port < 1 || port > 65535) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: "Invalid or missing port. Provide a number between 1 and 65535.",
        },
      ],
    };
  }

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

  if (!domain || !VALID_DOMAIN_PATTERN.test(domain)) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text:
            `Invalid or missing domain '${domain ?? ""}'.\n` +
            "Provide a fully qualified domain name (e.g. 'myapp.example.com').\n" +
            "The domain's A record must point to the server's IP address.",
        },
      ],
    };
  }

  // 2. Check if Caddy/sp-expose is available
  const caddyCheck = await sshExec(alias, "command -v sp-expose 2>/dev/null");
  if (caddyCheck.exitCode !== 0) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text:
            `Caddy (sp-expose) is not installed on server '${alias}'.\n\n` +
            "Install it first by deploying any app with domain_type='caddy', or run:\n" +
            `  ssh ${alias} "curl -fsSL https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/system/caddy-install.sh | bash"`,
        },
      ],
    };
  }

  // 3. Configure domain via sp-expose
  const result = await sshExec(
    alias,
    `sp-expose '${domain}' '${port}'`,
    30_000
  );

  if (result.exitCode === 0) {
    const lines: string[] = [
      "Domain configured successfully!",
      "",
      `Domain: ${domain}`,
      `Port: ${port}`,
      `URL: https://${domain}`,
      "",
      "Caddy will automatically obtain a Let's Encrypt certificate.",
      "The domain should be active within a few seconds.",
    ];

    return { content: [{ type: "text", text: lines.join("\n") }] };
  }

  // Error
  return {
    isError: true,
    content: [
      {
        type: "text",
        text:
          `Failed to configure domain '${domain}' on port ${port}.\n\n` +
          `Error: ${(result.stderr || result.stdout || "sp-expose failed").trim()}\n\n` +
          "Check:\n" +
          "- Is the domain's A record pointing to the server IP?\n" +
          "- Is port 80/443 open on the server firewall?\n" +
          "- Is Caddy running? Check with: ssh " + alias + ' "systemctl status caddy"',
      },
    ],
  };
}
