import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

interface ServerConfig {
  sshAlias: string;
  hostname?: string;
  user?: string;
  lastChecked?: string;
}

interface Config {
  servers: Record<string, ServerConfig>;
  defaultServer: string;
}

const CONFIG_DIR = join(homedir(), ".config", "mikrus");
const CONFIG_FILE = join(CONFIG_DIR, "mcp-server.json");

function defaultConfig(): Config {
  return {
    servers: {},
    defaultServer: "mikrus",
  };
}

export function loadConfig(): Config {
  if (!existsSync(CONFIG_FILE)) {
    return defaultConfig();
  }
  try {
    const raw = readFileSync(CONFIG_FILE, "utf-8");
    return { ...defaultConfig(), ...JSON.parse(raw) };
  } catch {
    return defaultConfig();
  }
}

export function saveConfig(config: Config): void {
  mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2) + "\n", { mode: 0o600 });
}

export function getDefaultAlias(): string {
  const config = loadConfig();
  const server = config.servers[config.defaultServer];
  return server?.sshAlias ?? config.defaultServer;
}

export function setServer(
  name: string,
  info: Partial<ServerConfig> & { sshAlias: string },
  setDefault = true
): void {
  const config = loadConfig();
  config.servers[name] = {
    ...config.servers[name],
    ...info,
    lastChecked: new Date().toISOString(),
  };
  if (setDefault) {
    config.defaultServer = name;
  }
  saveConfig(config);
}
