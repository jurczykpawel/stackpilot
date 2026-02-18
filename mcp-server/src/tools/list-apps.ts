import { listAllApps, type AppMetadata } from "../lib/app-metadata.js";

export const listAppsTool = {
  name: "list_apps",
  description:
    "List all available applications that can be deployed to a Mikrus VPS. Shows app name, description, Docker image size, database requirements, default port, and special notes. Use this before deploy_app to understand what's available and what parameters each app needs.",
  inputSchema: {
    type: "object" as const,
    properties: {
      category: {
        type: "string",
        enum: ["all", "no-db", "postgres", "mysql", "lightweight"],
        description:
          "Filter apps. 'no-db' = no database needed, 'postgres'/'mysql' = apps requiring that DB, 'lightweight' = IMAGE_SIZE_MB <= 200. Default: 'all'",
      },
    },
  },
};

export async function handleListApps(
  args: Record<string, unknown>
): Promise<{ content: Array<{ type: string; text: string }> }> {
  const category = (args.category as string) ?? "all";
  let apps = listAllApps();

  // Filter
  switch (category) {
    case "no-db":
      apps = apps.filter((a) => !a.requiresDb);
      break;
    case "postgres":
      apps = apps.filter((a) => a.dbType === "postgres");
      break;
    case "mysql":
      apps = apps.filter((a) => a.dbType === "mysql");
      break;
    case "lightweight":
      apps = apps.filter((a) => a.imageSizeMb !== null && a.imageSizeMb <= 200);
      break;
  }

  if (apps.length === 0) {
    return {
      content: [{ type: "text", text: `No apps found for category: ${category}` }],
    };
  }

  // Group by DB requirement
  const noDb = apps.filter((a) => !a.requiresDb);
  const postgres = apps.filter((a) => a.dbType === "postgres");
  const mysql = apps.filter((a) => a.dbType === "mysql");

  const lines: string[] = [
    `Available Apps (${apps.length} total)${category !== "all" ? ` [filter: ${category}]` : ""}`,
    "",
  ];

  const formatApp = (a: AppMetadata): string => {
    const parts: string[] = [
      `  ${a.name.padEnd(16)}`,
      a.description ? `${a.description.slice(0, 50)}` : "",
    ];
    const meta: string[] = [];
    if (a.defaultPort) meta.push(`Port: ${a.defaultPort}`);
    if (a.imageSizeMb) meta.push(`~${a.imageSizeMb}MB`);
    if (meta.length > 0) parts.push(`| ${meta.join(" | ")}`);
    if (a.specialNotes.length > 0) parts.push(`| ${a.specialNotes[0]}`);
    return parts.join(" ");
  };

  if (noDb.length > 0 && category !== "postgres" && category !== "mysql") {
    lines.push("== No Database Required ==");
    for (const a of noDb) lines.push(formatApp(a));
    lines.push("");
  }

  if (postgres.length > 0 && category !== "no-db" && category !== "mysql") {
    lines.push("== Requires PostgreSQL ==");
    for (const a of postgres) lines.push(formatApp(a));
    lines.push("");
  }

  if (mysql.length > 0 && category !== "no-db" && category !== "postgres") {
    lines.push("== Requires MySQL ==");
    for (const a of mysql) lines.push(formatApp(a));
    lines.push("");
  }

  lines.push("---");
  lines.push("Deploy with: deploy_app { app_name: '...', domain_type: 'cytrus|cloudflare|local' }");
  lines.push("Apps requiring a database need: db_source: 'shared' or 'custom' with credentials.");
  lines.push("IMPORTANT: Shared PostgreSQL is v12 - apps using Prisma/pgcrypto (n8n, umami, listmonk, postiz, typebot) need db_source: 'custom'. Always read the app's README first.");

  return { content: [{ type: "text", text: lines.join("\n") }] };
}
