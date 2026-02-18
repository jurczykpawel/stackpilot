import { execFile } from "node:child_process";
import { join } from "node:path";
import { existsSync } from "node:fs";
import { resolveRepoRoot } from "./repo.js";

export function localScript(name: string): string {
  return join(resolveRepoRoot(), "local", name);
}

export function systemScript(name: string): string {
  return join(resolveRepoRoot(), "system", name);
}

export function hasToolboxScripts(): boolean {
  return existsSync(localScript("cytrus-domain.sh"));
}

interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

/**
 * Run a local toolbox script (from local/ directory) via bash.
 * These scripts run locally and SSH into the server themselves.
 */
export function execLocalScript(
  scriptPath: string,
  args: string[] = [],
  timeoutMs = 120_000
): Promise<ExecResult> {
  return new Promise((resolve) => {
    execFile(
      "bash",
      [scriptPath, ...args],
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
