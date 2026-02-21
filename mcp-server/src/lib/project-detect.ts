import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

export type ProjectType =
  | "docker-compose"
  | "dockerfile"
  | "nextjs"
  | "node"
  | "python"
  | "php"
  | "static"
  | "unknown";

export interface ProjectAnalysis {
  type: ProjectType;
  strategy: "docker" | "node" | "static";
  files: string[];
  totalFiles: number;
  totalSizeKB: number;
  port: number | null;
  startCommand: string | null;
  buildRequired: boolean;
  buildHint: string | null;
  warnings: string[];
  summary: string;
}

function hasFile(dir: string, name: string): boolean {
  return existsSync(join(dir, name));
}

function readJson(path: string): Record<string, unknown> | null {
  try {
    return JSON.parse(readFileSync(path, "utf-8"));
  } catch {
    return null;
  }
}

function countFiles(
  dir: string,
  excludeDirs: string[] = [".git", "node_modules", ".next", "dist", ".venv", "venv", "__pycache__"]
): { count: number; sizeKB: number } {
  let count = 0;
  let size = 0;
  try {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (excludeDirs.includes(entry.name)) continue;
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        const sub = countFiles(fullPath, excludeDirs);
        count += sub.count;
        size += sub.sizeKB;
      } else {
        count++;
        try {
          size += statSync(fullPath).size / 1024;
        } catch {
          /* skip unreadable */
        }
      }
    }
  } catch {
    /* skip unreadable dirs */
  }
  return { count, sizeKB: Math.round(size) };
}

function parsePortFromCompose(content: string): number | null {
  const match = content.match(/ports:\s*\n\s*-\s*"?(\d+):\d+"?/);
  return match ? parseInt(match[1], 10) : null;
}

function detectNodePort(projectPath: string): number | null {
  const envExample = join(projectPath, ".env.example");
  if (existsSync(envExample)) {
    const content = readFileSync(envExample, "utf-8");
    const portMatch = content.match(/PORT\s*=\s*(\d+)/);
    if (portMatch) return parseInt(portMatch[1], 10);
  }
  return null;
}

export function detectProject(projectPath: string): ProjectAnalysis {
  if (!existsSync(projectPath) || !statSync(projectPath).isDirectory()) {
    return {
      type: "unknown",
      strategy: "static",
      files: [],
      totalFiles: 0,
      totalSizeKB: 0,
      port: null,
      startCommand: null,
      buildRequired: false,
      buildHint: null,
      warnings: [`Path does not exist or is not a directory: ${projectPath}`],
      summary: "Invalid project path.",
    };
  }

  const warnings: string[] = [];
  const files: string[] = [];
  const { count, sizeKB } = countFiles(projectPath);

  // 1. docker-compose
  const composeFile = [
    "docker-compose.yaml",
    "docker-compose.yml",
    "compose.yaml",
    "compose.yml",
  ].find((f) => hasFile(projectPath, f));

  if (composeFile) {
    files.push(composeFile);
    const content = readFileSync(join(projectPath, composeFile), "utf-8");
    const port = parsePortFromCompose(content);
    if (hasFile(projectPath, "Dockerfile")) files.push("Dockerfile");
    return {
      type: "docker-compose",
      strategy: "docker",
      files,
      totalFiles: count,
      totalSizeKB: sizeKB,
      port,
      startCommand: null,
      buildRequired: false,
      buildHint: null,
      warnings,
      summary: `Docker Compose project (${composeFile}). Will be deployed with 'docker compose up -d'.${port ? ` Port: ${port}.` : ""}`,
    };
  }

  // 2. Dockerfile
  if (hasFile(projectPath, "Dockerfile")) {
    files.push("Dockerfile");
    return {
      type: "dockerfile",
      strategy: "docker",
      files,
      totalFiles: count,
      totalSizeKB: sizeKB,
      port: 3000,
      startCommand: null,
      buildRequired: false,
      buildHint: null,
      warnings,
      summary:
        "Dockerfile found. Will generate docker-compose.yaml and build on server.",
    };
  }

  // 3. package.json
  const pkgJson = readJson(join(projectPath, "package.json"));
  if (pkgJson) {
    files.push("package.json");

    // 3a. Next.js
    const hasNextConfig = ["next.config.js", "next.config.mjs", "next.config.ts"].some(
      (f) => hasFile(projectPath, f)
    );
    if (
      hasNextConfig ||
      (pkgJson.dependencies as Record<string, string>)?.next
    ) {
      const hasStandalone = existsSync(
        join(projectPath, ".next", "standalone")
      );
      return {
        type: "nextjs",
        strategy: "docker",
        files,
        totalFiles: count,
        totalSizeKB: sizeKB,
        port: 3000,
        startCommand: "node server.js",
        buildRequired: !hasStandalone,
        buildHint: hasStandalone
          ? null
          : "Run 'npm run build' first. Ensure next.config.js has output: 'standalone'.",
        warnings,
        summary: hasStandalone
          ? "Next.js app with standalone build. Ready to deploy via Docker."
          : "Next.js app detected but needs building first.",
      };
    }

    // 3b. Regular Node.js
    const scripts = pkgJson.scripts as Record<string, string> | undefined;
    const startCommand = scripts?.start ?? null;
    if (startCommand) {
      const port = detectNodePort(projectPath) ?? 3000;
      return {
        type: "node",
        strategy: "node",
        files,
        totalFiles: count,
        totalSizeKB: sizeKB,
        port,
        startCommand,
        buildRequired: false,
        buildHint: null,
        warnings,
        summary: `Node.js app (start: '${startCommand}'). Will be deployed with PM2 on port ${port}.`,
      };
    }

    // package.json without start script
    warnings.push(
      "package.json found but no 'start' script. Add scripts.start or provide start_command."
    );
  }

  // 4. Python
  if (
    hasFile(projectPath, "requirements.txt") ||
    hasFile(projectPath, "pyproject.toml")
  ) {
    const reqFile = hasFile(projectPath, "requirements.txt")
      ? "requirements.txt"
      : "pyproject.toml";
    files.push(reqFile);
    warnings.push(
      "Python project detected. Default CMD assumes 'uvicorn main:app'. Override with env_vars or provide a Dockerfile."
    );
    return {
      type: "python",
      strategy: "docker",
      files,
      totalFiles: count,
      totalSizeKB: sizeKB,
      port: 8000,
      startCommand: null,
      buildRequired: false,
      buildHint: null,
      warnings,
      summary: `Python project (${reqFile}). Will generate Dockerfile and deploy via Docker.`,
    };
  }

  // 5. PHP
  if (hasFile(projectPath, "index.php")) {
    files.push("index.php");
    return {
      type: "php",
      strategy: "static",
      files,
      totalFiles: count,
      totalSizeKB: sizeKB,
      port: null,
      startCommand: null,
      buildRequired: false,
      buildHint: null,
      warnings,
      summary: `PHP site (${count} files, ${sizeKB}KB). Deploy via Caddy + PHP-FPM.`,
    };
  }

  // 5b. Check for any .php files in root directory
  try {
    const entries = readdirSync(projectPath);
    const phpFiles = entries.filter((f) => f.endsWith(".php"));
    if (phpFiles.length > 0) {
      files.push(...phpFiles.slice(0, 3));
      return {
        type: "php",
        strategy: "static",
        files,
        totalFiles: count,
        totalSizeKB: sizeKB,
        port: null,
        startCommand: null,
        buildRequired: false,
        buildHint: null,
        warnings,
        summary: `PHP site with ${phpFiles.length} PHP file(s) (${sizeKB}KB). Deploy via Caddy + PHP-FPM.`,
      };
    }
  } catch {
    /* ignore */
  }

  // 6. Static HTML
  if (hasFile(projectPath, "index.html")) {
    files.push("index.html");
    return {
      type: "static",
      strategy: "static",
      files,
      totalFiles: count,
      totalSizeKB: sizeKB,
      port: null,
      startCommand: null,
      buildRequired: false,
      buildHint: null,
      warnings,
      summary: `Static site (${count} files, ${sizeKB}KB). Instant deploy via Caddy/nginx.`,
    };
  }

  // 6b. Check if directory has any HTML files
  try {
    const entries = readdirSync(projectPath);
    const htmlFiles = entries.filter((f) => f.endsWith(".html"));
    if (htmlFiles.length > 0) {
      files.push(...htmlFiles.slice(0, 3));
      return {
        type: "static",
        strategy: "static",
        files,
        totalFiles: count,
        totalSizeKB: sizeKB,
        port: null,
        startCommand: null,
        buildRequired: false,
        buildHint: null,
        warnings,
        summary: `Static site with ${htmlFiles.length} HTML file(s) (${sizeKB}KB). Instant deploy via Caddy/nginx.`,
      };
    }
  } catch {
    /* ignore */
  }

  warnings.push("Could not detect project type. Specify strategy manually.");
  return {
    type: "unknown",
    strategy: "static",
    files,
    totalFiles: count,
    totalSizeKB: sizeKB,
    port: null,
    startCommand: null,
    buildRequired: false,
    buildHint: null,
    warnings,
    summary: "Unknown project type. Provide strategy parameter.",
  };
}
