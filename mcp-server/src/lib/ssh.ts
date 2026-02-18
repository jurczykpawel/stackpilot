import { execFile, spawn } from "node:child_process";
import {
  existsSync,
  readFileSync,
  appendFileSync,
  mkdirSync,
} from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export function sshExec(
  alias: string,
  command: string,
  timeoutMs = 30_000
): Promise<ExecResult> {
  return new Promise((resolve) => {
    execFile(
      "ssh",
      ["-o", "ConnectTimeout=10", alias, command],
      { timeout: timeoutMs },
      (error, stdout, stderr) => {
        resolve({
          stdout: stdout?.toString() ?? "",
          stderr: stderr?.toString() ?? "",
          exitCode: error
            ? (typeof error.code === "number" ? error.code : 1)
            : 0,
        });
      }
    );
  });
}

interface ConnectionResult {
  ok: boolean;
  hostname?: string;
  user?: string;
  error?: string;
}

export async function testConnection(alias: string): Promise<ConnectionResult> {
  // First resolve SSH config locally (no network)
  const sshConfig = await getSSHConfig(alias);

  // Then test actual connectivity
  const result = await sshExec(alias, "echo OK", 15_000);
  if (result.exitCode !== 0 || !result.stdout.includes("OK")) {
    return {
      ok: false,
      ...sshConfig,
      error: result.stderr.trim() || "Connection failed",
    };
  }
  return { ok: true, ...sshConfig };
}

export function getSSHConfig(
  alias: string
): Promise<{ hostname?: string; user?: string }> {
  return new Promise((resolve) => {
    execFile(
      "ssh",
      ["-G", alias],
      { timeout: 5_000 },
      (error, stdout) => {
        if (error) {
          resolve({});
          return;
        }
        const lines = stdout.toString().split("\n");
        let hostname: string | undefined;
        let user: string | undefined;
        for (const line of lines) {
          const [key, ...rest] = line.split(" ");
          const val = rest.join(" ");
          if (key === "hostname") hostname = val;
          if (key === "user") user = val;
        }
        resolve({ hostname, user });
      }
    );
  });
}

// --- SSH Setup helpers ---

const SSH_DIR = join(homedir(), ".ssh");
const SSH_KEY_PATH = join(SSH_DIR, "id_ed25519");
const SSH_CONFIG_PATH = join(SSH_DIR, "config");

export function sshKeyExists(): boolean {
  return existsSync(SSH_KEY_PATH);
}

export function generateSSHKey(): Promise<{ ok: boolean; error?: string }> {
  return new Promise((resolve) => {
    mkdirSync(SSH_DIR, { recursive: true, mode: 0o700 });
    execFile(
      "ssh-keygen",
      ["-t", "ed25519", "-f", SSH_KEY_PATH, "-N", ""],
      { timeout: 10_000 },
      (error) => {
        if (error) {
          resolve({ ok: false, error: error.message });
        } else {
          resolve({ ok: true });
        }
      }
    );
  });
}

export function getPublicKey(): string | null {
  const pubPath = SSH_KEY_PATH + ".pub";
  if (!existsSync(pubPath)) return null;
  return readFileSync(pubPath, "utf-8").trim();
}

export function aliasExists(alias: string): boolean {
  if (!existsSync(SSH_CONFIG_PATH)) return false;
  const content = readFileSync(SSH_CONFIG_PATH, "utf-8");
  const regex = new RegExp(`^Host\\s+${alias}\\s*$`, "m");
  return regex.test(content);
}

/**
 * Validate SSH config parameter against injection (newline, control chars).
 * Throws on invalid input.
 */
function validateSSHParam(value: string, name: string): void {
  if (/[\n\r\0]/.test(value)) {
    throw new Error(`${name} contains invalid characters (newline/null).`);
  }
  if (name === "alias" && !/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(value)) {
    throw new Error(
      `Invalid SSH alias '${value}'. Use only letters, numbers, dashes, underscores.`
    );
  }
  if (name === "host" && !/^[a-zA-Z0-9._-]+$/.test(value)) {
    throw new Error(
      `Invalid hostname '${value}'. Use only letters, numbers, dots, dashes.`
    );
  }
  if (name === "user" && !/^[a-zA-Z0-9._-]+$/.test(value)) {
    throw new Error(
      `Invalid username '${value}'. Use only letters, numbers, dots, dashes, underscores.`
    );
  }
}

export function writeSSHConfig(opts: {
  alias: string;
  host: string;
  port: number;
  user: string;
}): void {
  validateSSHParam(opts.alias, "alias");
  validateSSHParam(opts.host, "host");
  validateSSHParam(opts.user, "user");

  mkdirSync(SSH_DIR, { recursive: true, mode: 0o700 });
  const entry = [
    "",
    `Host ${opts.alias}`,
    `    HostName ${opts.host}`,
    `    Port ${opts.port}`,
    `    User ${opts.user}`,
    `    IdentityFile ${SSH_KEY_PATH}`,
    `    ServerAliveInterval 60`,
    "",
  ].join("\n");
  appendFileSync(SSH_CONFIG_PATH, entry);
}

export function getSSHCopyIdCommand(opts: {
  host: string;
  port: number;
  user: string;
}): string {
  return `ssh-copy-id -p ${opts.port} ${opts.user}@${opts.host}`;
}

// --- Shared helpers ---

export function sshExecWithStdin(
  alias: string,
  command: string,
  stdinData: string,
  timeoutMs = 30_000
): Promise<ExecResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    const proc = spawn("ssh", ["-o", "ConnectTimeout=10", alias, command], {
      timeout: timeoutMs,
    });
    proc.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
    proc.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
    proc.on("close", (code) => {
      resolve({ stdout, stderr, exitCode: code ?? 1 });
    });
    proc.on("error", (err) => {
      resolve({ stdout, stderr: err.message, exitCode: 1 });
    });
    proc.stdin.write(stdinData);
    proc.stdin.end();
  });
}

const DEFAULT_RSYNC_EXCLUDES = [
  ".git",
  "node_modules",
  ".env",
  ".env.*",
  "__pycache__",
  ".next",
  ".DS_Store",
  "*.pyc",
  ".venv",
  "venv",
];

export function rsyncToServer(
  alias: string,
  localPath: string,
  remotePath: string,
  excludes: string[] = DEFAULT_RSYNC_EXCLUDES,
  timeoutMs = 300_000
): Promise<ExecResult> {
  return new Promise((resolve) => {
    const src = localPath.endsWith("/") ? localPath : localPath + "/";
    const args = [
      "-avz",
      "--delete",
      ...excludes.flatMap((e) => ["--exclude", e]),
      "-e",
      "ssh -o ConnectTimeout=10",
      src,
      `${alias}:${remotePath}/`,
    ];
    execFile("rsync", args, { timeout: timeoutMs }, (error, stdout, stderr) => {
      resolve({
        stdout: stdout?.toString() ?? "",
        stderr: stderr?.toString() ?? "",
        exitCode: error
          ? (typeof error.code === "number" ? error.code : 1)
          : 0,
      });
    });
  });
}
