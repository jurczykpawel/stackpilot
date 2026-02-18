import { sshExec } from "./ssh.js";

const TOOLBOX_REPO_URL = "https://github.com/jurczykpawel/mikrus-toolbox.git";
const TOOLBOX_SERVER_PATH = "/opt/mikrus-toolbox";
const TOOLBOX_MARKER = `${TOOLBOX_SERVER_PATH}/local/deploy.sh`;

/**
 * Ensure mikrus-toolbox is installed on the server.
 * Idempotent — fast check if already installed, git clone if not.
 */
export async function ensureToolboxOnServer(
  alias: string
): Promise<{ ok: boolean; error?: string; installed?: boolean }> {
  // Already installed?
  const check = await sshExec(
    alias,
    `test -f ${TOOLBOX_MARKER} && echo OK || echo MISSING`,
    15_000
  );

  if (check.stdout.includes("OK")) {
    return { ok: true, installed: false };
  }

  // Git clone from GitHub (remove stale directory if exists)
  const result = await sshExec(
    alias,
    `command -v git >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq git > /dev/null 2>&1) && ` +
      `rm -rf ${TOOLBOX_SERVER_PATH} && ` +
      `git clone --depth 1 ${TOOLBOX_REPO_URL} ${TOOLBOX_SERVER_PATH} 2>&1`,
    120_000
  );

  if (result.exitCode === 0) {
    return { ok: true, installed: true };
  }

  return {
    ok: false,
    error:
      `Failed to install toolbox on server.\n` +
      `Output: ${result.stdout}\n${result.stderr}`.trim(),
  };
}
