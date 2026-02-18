import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { getAppsDir } from "./repo.js";

export interface AppMetadata {
  name: string;
  description: string;
  imageSizeMb: number | null;
  defaultPort: number | null;
  requiresDb: boolean;
  dbType: "postgres" | "mysql" | "mongo" | null;
  envVars: string[];
  specialNotes: string[];
}

export function parseAppMetadata(appDir: string): AppMetadata | null {
  const installSh = join(appDir, "install.sh");
  if (!existsSync(installSh)) return null;

  const content = readFileSync(installSh, "utf-8");
  const lines = content.split("\n");

  // Parse description from header comments (lines 3-4, after "# Mikrus Toolbox - Name")
  let description = "";
  for (let i = 0; i < Math.min(lines.length, 15); i++) {
    const line = lines[i];
    // Skip shebang, empty comments, "Mikrus Toolbox" line, "Author" line
    if (
      line.startsWith("#!") ||
      line === "#" ||
      line.includes("Mikrus Toolbox") ||
      line.includes("Author:") ||
      line.includes("IMAGE_SIZE_MB") ||
      line.includes("WYMAGA") ||
      line.includes("http")
    ) {
      continue;
    }
    // Description is usually the first meaningful comment line
    const match = line.match(/^#\s+(.{10,})$/);
    if (match && !description) {
      description = match[1].trim();
    }
  }

  // IMAGE_SIZE_MB from comment: # IMAGE_SIZE_MB=XXX
  const sizeMatch = content.match(/IMAGE_SIZE_MB[=:]?\s*(\d+)/);
  const imageSizeMb = sizeMatch ? parseInt(sizeMatch[1], 10) : null;

  // Default PORT from: PORT=${PORT:-XXXX} or PORT=XXXX
  let defaultPort: number | null = null;
  const portMatch = content.match(/PORT=\$\{PORT:-(\d+)\}/);
  if (portMatch) {
    defaultPort = parseInt(portMatch[1], 10);
  } else {
    const portDirect = content.match(/^PORT=(\d+)/m);
    if (portDirect) defaultPort = parseInt(portDirect[1], 10);
  }

  // Database detection
  const requiresDb =
    content.includes("DB_HOST") || content.includes("DATABASE_URL");
  let dbType: AppMetadata["dbType"] = null;
  if (requiresDb) {
    if (content.toLowerCase().includes("mysql") || content.includes("3306")) {
      dbType = "mysql";
    } else if (content.toLowerCase().includes("mongo")) {
      dbType = "mongo";
    } else {
      dbType = "postgres";
    }
  }

  // Environment variables from "# Zmienne" or "# Opcjonalne zmienne" blocks
  const envVars: string[] = [];
  let inEnvBlock = false;
  for (const line of lines) {
    if (line.match(/^#\s*(Zmienne|Opcjonalne zmienne|Environment)/i)) {
      inEnvBlock = true;
      continue;
    }
    if (inEnvBlock) {
      const envMatch = line.match(/^#\s+([A-Z_]+)\s/);
      if (envMatch) {
        envVars.push(envMatch[1]);
      } else if (!line.startsWith("#")) {
        inEnvBlock = false;
      }
    }
  }

  // Special notes (WYMAGA, UWAGA, warnings)
  const specialNotes: string[] = [];
  for (const line of lines.slice(0, 20)) {
    if (line.match(/^#.*WYMAG/i)) {
      specialNotes.push(line.replace(/^#\s*/, "").trim());
    }
    if (line.match(/^#.*pgcrypto/i)) {
      specialNotes.push("Requires pgcrypto extension (custom DB only)");
    }
  }

  const name = appDir.split("/").pop()!;
  return {
    name,
    description,
    imageSizeMb,
    defaultPort,
    requiresDb,
    dbType,
    envVars,
    specialNotes,
  };
}

export function listAllApps(): AppMetadata[] {
  const appsDir = getAppsDir();
  const dirs = readdirSync(appsDir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();

  const apps: AppMetadata[] = [];
  for (const dir of dirs) {
    const meta = parseAppMetadata(join(appsDir, dir));
    if (meta) apps.push(meta);
  }
  return apps;
}
