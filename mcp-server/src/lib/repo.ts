import { existsSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const REPO_URL = "https://github.com/jurczykpawel/stackpilot.git";
const LOCAL_CLONE_DIR = join(homedir(), ".stackpilot");

let cachedRoot: string | null = null;

export function resolveRepoRoot(): string {
  if (cachedRoot) return cachedRoot;

  // 1. Check MIKRUS_TOOLBOX_PATH env var
  const envPath = process.env.MIKRUS_TOOLBOX_PATH;
  if (envPath && existsSync(join(envPath, "local", "deploy.sh"))) {
    cachedRoot = resolve(envPath);
    return cachedRoot;
  }

  // 2. Walk up from __dirname (mcp-server/dist/lib/) looking for local/deploy.sh
  let dir = __dirname;
  for (let i = 0; i < 10; i++) {
    if (existsSync(join(dir, "local", "deploy.sh"))) {
      cachedRoot = dir;
      return cachedRoot;
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }

  // 3. Check ~/.stackpilot (auto-cloned)
  if (existsSync(join(LOCAL_CLONE_DIR, "local", "deploy.sh"))) {
    cachedRoot = LOCAL_CLONE_DIR;
    return cachedRoot;
  }

  // 4. Auto-clone the repo (for npx users)
  try {
    console.error("stackpilot: First run — cloning toolbox scripts to ~/.stackpilot...");
    mkdirSync(LOCAL_CLONE_DIR, { recursive: true });
    execFileSync("git", ["clone", "--depth=1", REPO_URL, LOCAL_CLONE_DIR], {
      timeout: 60_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    console.error("stackpilot: Clone complete.");
    cachedRoot = LOCAL_CLONE_DIR;
    return cachedRoot;
  } catch {
    throw new Error(
      "Cannot find stackpilot scripts.\n\n" +
      "Option 1: Clone the repo and set MIKRUS_TOOLBOX_PATH:\n" +
      `  git clone ${REPO_URL}\n` +
      "  export MIKRUS_TOOLBOX_PATH=/path/to/stackpilot\n\n" +
      "Option 2: Clone to the default location:\n" +
      `  git clone ${REPO_URL} ~/.stackpilot`
    );
  }
}

/** Update the local clone if it exists (git pull). */
export function updateToolboxIfCloned(): void {
  if (!existsSync(join(LOCAL_CLONE_DIR, ".git"))) return;
  try {
    execFileSync("git", ["-C", LOCAL_CLONE_DIR, "pull", "--ff-only"], {
      timeout: 30_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch {
    // Non-fatal — use existing version
  }
}

export function getDeployShPath(): string {
  return join(resolveRepoRoot(), "local", "deploy.sh");
}

export function getAppsDir(): string {
  return join(resolveRepoRoot(), "apps");
}
