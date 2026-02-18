import { sshExec } from "../lib/ssh.js";
import { getDefaultAlias } from "../lib/config.js";

type ToolResult = {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
};

export const setupDomainTool = {
  name: "setup_domain",
  description:
    "Configure a Cytrus domain (free Mikrus subdomain) for an application running on a specific port. " +
    "Calls the Mikrus API to assign a *.byst.re / *.bieda.it / *.toadres.pl / *.tojest.dev subdomain.\n\n" +
    "WHEN TO USE:\n" +
    "- After deploy_custom_app, to give the app a public URL\n" +
    "- To add a domain to an existing app that doesn't have one\n" +
    "- To change the domain for an app\n\n" +
    "WHEN NOT TO USE:\n" +
    "- After deploy_app with domain_type='cytrus' — deploy_app already handles domain setup automatically\n\n" +
    "Set domain to 'auto' for a random subdomain, or specify a name like 'myapp.byst.re'.",
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
          "Domain name to assign. Use 'auto' for automatic random subdomain (e.g. 'cool-fox123.byst.re'). " +
          "Or specify: 'myapp.byst.re', 'myapp.bieda.it', 'myapp.toadres.pl', 'myapp.tojest.dev'. Default: 'auto'.",
      },
      ssh_alias: {
        type: "string",
        description:
          "SSH alias. If omitted, uses the default configured server.",
      },
    },
    required: ["port"],
  },
};

const VALID_DOMAIN_PATTERN =
  /^[a-z0-9][a-z0-9-]*\.(byst\.re|bieda\.it|toadres\.pl|tojest\.dev)$/;

export async function handleSetupDomain(
  args: Record<string, unknown>
): Promise<ToolResult> {
  const port = args.port as number | undefined;
  const domain = (args.domain as string) ?? "auto";
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

  if (domain !== "auto" && !VALID_DOMAIN_PATTERN.test(domain)) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text:
            `Invalid domain '${domain}'. Use 'auto' or a subdomain like 'myapp.byst.re'.\n` +
            "Supported TLDs: *.byst.re, *.bieda.it, *.toadres.pl, *.tojest.dev",
        },
      ],
    };
  }

  // 2. Get API key from server
  const keyResult = await sshExec(alias, "cat /klucz_api 2>/dev/null");
  const apiKey = keyResult.stdout.trim();

  if (!apiKey || keyResult.exitCode !== 0) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text:
            `Could not read API key from server '${alias}'.\n` +
            "File /klucz_api not found or empty.\n\n" +
            "The user must enable API in Mikrus panel: https://mikr.us/panel/?a=api",
        },
      ],
    };
  }

  // 3. Get server hostname (SRV identifier)
  const hostnameResult = await sshExec(alias, "hostname");
  const srv = hostnameResult.stdout.trim();

  if (!srv) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Could not determine server hostname for '${alias}'.`,
        },
      ],
    };
  }

  // 4. Call Mikrus API
  const apiDomain = domain === "auto" ? "-" : domain;
  const params = new URLSearchParams({
    key: apiKey,
    srv,
    domain: apiDomain,
    port: String(port),
  });

  let response: Response;
  try {
    response = await fetch("https://api.mikr.us/domain", {
      method: "POST",
      body: params,
    });
  } catch (err) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Failed to reach Mikrus API: ${err instanceof Error ? err.message : String(err)}`,
        },
      ],
    };
  }

  const responseText = await response.text();

  // 5. Parse response
  // Success: contains "gotowe" or "domain" field
  if (/("status".*gotowe|"domain")/i.test(responseText)) {
    const domainMatch = responseText.match(/"domain"\s*:\s*"([^"]+)"/);
    const assignedDomain =
      domainMatch?.[1] ?? (domain !== "auto" ? domain : null);

    const lines: string[] = [
      "Domain configured successfully!",
      "",
      `Server: ${srv}`,
      `Port: ${port}`,
    ];

    if (assignedDomain) {
      lines.push(`Domain: ${assignedDomain}`);
      lines.push(`URL: https://${assignedDomain}`);
    }

    lines.push("", "The domain should be active within a few seconds.");

    return { content: [{ type: "text", text: lines.join("\n") }] };
  }

  // Domain taken
  if (/już istnieje|already exists/i.test(responseText)) {
    const requestedName = domain !== "auto" ? domain.split(".")[0] : "app";
    return {
      isError: true,
      content: [
        {
          type: "text",
          text:
            `Domain '${domain}' is already taken.\n\n` +
            `Suggestions:\n` +
            `- ${requestedName}-2.byst.re\n` +
            `- my-${requestedName}.byst.re\n` +
            `- Use domain='auto' for a random subdomain`,
        },
      ],
    };
  }

  // Other error
  if (/error|błąd|fail/i.test(responseText)) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text:
            `Mikrus API error:\n${responseText}\n\n` +
            "Check:\n" +
            "- Is the domain name valid?\n" +
            "- Is the port correct and not already mapped?\n" +
            "- Is the API active? https://mikr.us/panel/?a=api",
        },
      ],
    };
  }

  // Unknown response
  return {
    content: [
      {
        type: "text",
        text:
          `API response (check if domain was configured):\n${responseText}\n\n` +
          "Verify in Mikrus panel: https://mikr.us/panel/?a=hosting_domeny",
      },
    ],
  };
}
