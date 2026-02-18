import { createECDH, randomUUID, createDecipheriv } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { execSync } from "node:child_process";

const CONFIG_DIR = join(homedir(), ".config", "gateflow");
const CONFIG_PATH = join(CONFIG_DIR, "deploy-config.env");
const STATE_PATH = join(CONFIG_DIR, ".setup-state.json");
const SUPABASE_TOKEN_PATH = join(homedir(), ".config", "supabase", "access_token");

export const setupGateflowTool = {
  name: "setup_gateflow_config",
  description:
    "Configure GateFlow deployment credentials (Supabase keys) securely — without exposing secrets in the conversation.\n\n" +
    "This is a multi-step tool:\n" +
    "  1. Call with no params → opens browser for Supabase login, returns instructions\n" +
    "  2. Call with verification_code → exchanges code for token, returns project list\n" +
    "  3. Call with project_ref → fetches API keys and saves config to ~/.config/gateflow/deploy-config.env\n\n" +
    "After setup is complete, deploy_app(app_name='gateflow') will use the saved config automatically.\n" +
    "The only user input needed in conversation is a one-time verification code (not a secret) and project selection.",
  inputSchema: {
    type: "object" as const,
    properties: {
      verification_code: {
        type: "string",
        description: "8-character verification code from the Supabase login page. Only needed in step 2.",
      },
      project_ref: {
        type: "string",
        description: "Supabase project reference ID. Only needed in step 3 (from the project list returned in step 2).",
      },
    },
  },
};

interface SetupState {
  sessionId: string;
  privateKey: string; // hex-encoded raw private key (32 bytes)
  publicKeyHex: string; // hex-encoded raw public key (65 bytes)
  tokenName: string;
}

function loadState(): SetupState | null {
  try {
    if (existsSync(STATE_PATH)) {
      return JSON.parse(readFileSync(STATE_PATH, "utf-8"));
    }
  } catch { /* ignore */ }
  return null;
}

function saveState(state: SetupState): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  writeFileSync(STATE_PATH, JSON.stringify(state), { mode: 0o600 });
}

function cleanupState(): void {
  try { unlinkSync(STATE_PATH); } catch { /* ignore */ }
}

function loadSupabaseToken(): string | null {
  try {
    if (existsSync(SUPABASE_TOKEN_PATH)) {
      const token = readFileSync(SUPABASE_TOKEN_PATH, "utf-8").trim();
      if (token) return token;
    }
  } catch { /* ignore */ }
  return null;
}

function saveSupabaseToken(token: string): void {
  const dir = join(homedir(), ".config", "supabase");
  mkdirSync(dir, { recursive: true });
  writeFileSync(SUPABASE_TOKEN_PATH, token, { mode: 0o600 });
}

async function fetchJson(url: string, headers?: Record<string, string>): Promise<unknown> {
  const res = await fetch(url, { headers });
  return res.json();
}

function openBrowser(url: string): void {
  try {
    const platform = process.platform;
    if (platform === "darwin") {
      execSync(`open "${url}"`, { stdio: "ignore" });
    } else if (platform === "linux") {
      execSync(`xdg-open "${url}"`, { stdio: "ignore" });
    } else if (platform === "win32") {
      execSync(`start "" "${url}"`, { stdio: "ignore" });
    }
  } catch { /* ignore - user can open URL manually */ }
}

export async function handleSetupGateflow(
  args: Record<string, unknown>
): Promise<{ content: Array<{ type: string; text: string }>; isError?: boolean }> {
  const verificationCode = args.verification_code as string | undefined;
  const projectRef = args.project_ref as string | undefined;

  // If config already exists, just report it
  if (existsSync(CONFIG_PATH) && !projectRef && !verificationCode) {
    return {
      content: [{
        type: "text",
        text: `GateFlow config already exists at ${CONFIG_PATH}.\n` +
          `To reconfigure, delete the file and run this tool again.\n` +
          `You can now deploy with: deploy_app(app_name="gateflow")`,
      }],
    };
  }

  // =========================================================================
  // STEP 3: Save config with project keys
  // =========================================================================
  if (projectRef) {
    // Need a valid Supabase token
    const token = loadSupabaseToken();
    if (!token) {
      return {
        isError: true,
        content: [{ type: "text", text: "No Supabase token found. Start from step 1 (call with no params)." }],
      };
    }

    // Fetch API keys
    const apiKeys = await fetchJson(
      `https://api.supabase.com/v1/projects/${projectRef}/api-keys?reveal=true`,
      { Authorization: `Bearer ${token}` }
    ) as Array<{ name: string; type?: string; api_key: string }>;

    if (!Array.isArray(apiKeys)) {
      return {
        isError: true,
        content: [{ type: "text", text: `Failed to fetch API keys for project ${projectRef}. Check if the project exists.` }],
      };
    }

    // Extract anon and service_role keys (support both old and new format)
    let anonKey = "";
    let serviceKey = "";
    for (const key of apiKeys) {
      if ((key.type === "publishable" && key.name === "default") || key.name === "anon") {
        anonKey = key.api_key;
      }
      if ((key.type === "secret" && key.name === "default") || key.name === "service_role") {
        serviceKey = key.api_key;
      }
    }

    if (!anonKey || !serviceKey) {
      return {
        isError: true,
        content: [{ type: "text", text: "Could not find anon/service_role keys for this project. Check Supabase Dashboard → Project Settings → API." }],
      };
    }

    // Save config
    mkdirSync(CONFIG_DIR, { recursive: true });
    const configContent = [
      `# GateFlow Deploy Configuration`,
      `# Generated by MCP setup_gateflow_config`,
      ``,
      `SUPABASE_URL="https://${projectRef}.supabase.co"`,
      `PROJECT_REF="${projectRef}"`,
      `SUPABASE_ANON_KEY="${anonKey}"`,
      `SUPABASE_SERVICE_KEY="${serviceKey}"`,
      ``,
      `# Domain (auto = Cytrus subdomain)`,
      `DOMAIN="-"`,
      `DOMAIN_TYPE="cytrus"`,
    ].join("\n") + "\n";

    writeFileSync(CONFIG_PATH, configContent, { mode: 0o600 });
    cleanupState();

    return {
      content: [{
        type: "text",
        text: `GateFlow configuration saved to ${CONFIG_PATH}\n\n` +
          `Project: ${projectRef}\n` +
          `Supabase URL: https://${projectRef}.supabase.co\n\n` +
          `You can now deploy with: deploy_app(app_name="gateflow", domain_type="cytrus", domain="auto")`,
      }],
    };
  }

  // =========================================================================
  // STEP 2: Exchange verification code for token + list projects
  // =========================================================================
  if (verificationCode) {
    const state = loadState();
    if (!state) {
      return {
        isError: true,
        content: [{ type: "text", text: "No pending login session. Start from step 1 (call with no params)." }],
      };
    }

    // Poll for token
    const pollUrl = `https://api.supabase.com/platform/cli/login/${state.sessionId}?device_code=${verificationCode}`;
    const tokenResponse = await fetchJson(pollUrl) as Record<string, string>;

    if (!tokenResponse.access_token) {
      cleanupState();
      return {
        isError: true,
        content: [{
          type: "text",
          text: `Failed to get token. The verification code may be incorrect or expired.\n` +
            `Start over by calling setup_gateflow_config() again.`,
        }],
      };
    }

    // Decrypt the token using ECDH
    let supabaseToken: string;
    try {
      const serverPubKey = Buffer.from(tokenResponse.public_key, "hex");
      const nonce = Buffer.from(tokenResponse.nonce, "hex");
      const encrypted = Buffer.from(tokenResponse.access_token, "hex");

      // Reconstruct ECDH from saved private key
      const ecdh = createECDH("prime256v1");
      ecdh.setPrivateKey(Buffer.from(state.privateKey, "hex"));

      const sharedSecret = ecdh.computeSecret(serverPubKey);

      // AES-256-GCM decrypt
      const tag = encrypted.subarray(-16);
      const ciphertext = encrypted.subarray(0, -16);
      const decipher = createDecipheriv("aes-256-gcm", sharedSecret, nonce);
      decipher.setAuthTag(tag);
      supabaseToken = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf-8");
    } catch {
      cleanupState();
      return {
        isError: true,
        content: [{
          type: "text",
          text: `Failed to decrypt token. This can happen if Cloudflare blocked the request.\n\n` +
            `Fallback: Ask the user to create a Personal Access Token manually:\n` +
            `1. Open: https://supabase.com/dashboard/account/tokens\n` +
            `2. Click "Generate new token"\n` +
            `3. Create the config file ~/.config/gateflow/deploy-config.env manually\n` +
            `   (see deploy_app tool for the required format)`,
        }],
      };
    }

    // Save token
    saveSupabaseToken(supabaseToken);
    cleanupState();

    // Fetch projects list
    const projects = await fetchJson(
      "https://api.supabase.com/v1/projects",
      { Authorization: `Bearer ${supabaseToken}` }
    ) as Array<{ id: string; name: string }>;

    if (!Array.isArray(projects) || projects.length === 0) {
      return {
        isError: true,
        content: [{
          type: "text",
          text: `Supabase login successful, but no projects found.\n` +
            `The user needs to create a Supabase project first at https://supabase.com/dashboard`,
        }],
      };
    }

    // If only one project, auto-select it
    if (projects.length === 1) {
      // Recursively call with project_ref
      return handleSetupGateflow({ project_ref: projects[0].id });
    }

    // Return project list for user to choose
    const projectList = projects
      .map((p, i) => `  ${i + 1}. ${p.name} (${p.id})`)
      .join("\n");

    return {
      content: [{
        type: "text",
        text: `Supabase login successful! Found ${projects.length} projects:\n\n` +
          `${projectList}\n\n` +
          `Ask the user which project to use for GateFlow, then call:\n` +
          `setup_gateflow_config(project_ref="<selected_project_id>")`,
      }],
    };
  }

  // =========================================================================
  // STEP 1: Start Supabase login flow
  // =========================================================================

  // Check if we already have a valid token
  const existingToken = loadSupabaseToken();
  if (existingToken) {
    // Verify token is still valid
    const testResponse = await fetchJson(
      "https://api.supabase.com/v1/projects",
      { Authorization: `Bearer ${existingToken}` }
    ) as Array<{ id: string; name: string }>;

    if (Array.isArray(testResponse)) {
      // Token is valid, skip login — go straight to project selection
      if (testResponse.length === 0) {
        return {
          isError: true,
          content: [{
            type: "text",
            text: `Supabase token is valid, but no projects found.\n` +
              `The user needs to create a Supabase project first at https://supabase.com/dashboard`,
          }],
        };
      }

      if (testResponse.length === 1) {
        return handleSetupGateflow({ project_ref: testResponse[0].id });
      }

      const projectList = testResponse
        .map((p, i) => `  ${i + 1}. ${p.name} (${p.id})`)
        .join("\n");

      return {
        content: [{
          type: "text",
          text: `Found existing Supabase token. ${testResponse.length} projects available:\n\n` +
            `${projectList}\n\n` +
            `Ask the user which project to use for GateFlow, then call:\n` +
            `setup_gateflow_config(project_ref="<selected_project_id>")`,
        }],
      };
    }
    // Token expired, continue with login flow
  }

  // Generate ECDH P-256 keypair
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();

  const privateKeyHex = ecdh.getPrivateKey("hex");
  const publicKeyHex = ecdh.getPublicKey("hex"); // 65 bytes: 04 + X + Y

  const sessionId = randomUUID();
  const tokenName = `mikrus_mcp_${Date.now()}`;

  // Save state for step 2
  saveState({
    sessionId,
    privateKey: privateKeyHex,
    publicKeyHex,
    tokenName,
  });

  // Build login URL
  const loginUrl = `https://supabase.com/dashboard/cli/login?session_id=${sessionId}&token_name=${tokenName}&public_key=${publicKeyHex}`;

  // Open browser
  openBrowser(loginUrl);

  return {
    content: [{
      type: "text",
      text: `Opening browser for Supabase login...\n\n` +
        `If the browser didn't open, tell the user to open this URL:\n${loginUrl}\n\n` +
        `After logging in, the user will see an 8-character verification code.\n` +
        `Ask them for the code, then call:\n` +
        `setup_gateflow_config(verification_code="<the_code>")`,
    }],
  };
}
