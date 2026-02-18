#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import {
  setupServerTool,
  handleSetupServer,
} from "./tools/configure-server.js";
import { listAppsTool, handleListApps } from "./tools/list-apps.js";
import { deployAppTool, handleDeployApp } from "./tools/deploy-app.js";
import {
  deployCustomAppTool,
  handleDeployCustomApp,
} from "./tools/deploy-custom-app.js";
import {
  deploySiteTool,
  handleDeploySite,
} from "./tools/deploy-site.js";
import {
  serverStatusTool,
  handleServerStatus,
} from "./tools/server-status.js";
import {
  setupDomainTool,
  handleSetupDomain,
} from "./tools/configure-domain.js";
import {
  setupBackupTool,
  handleSetupBackup,
} from "./tools/setup-backup.js";
import {
  setupGateflowTool,
  handleSetupGateflow,
} from "./tools/setup-gateflow.js";
import { updateToolboxIfCloned } from "./lib/repo.js";

// Auto-update toolbox scripts if running from ~/.mikrus-toolbox clone
updateToolboxIfCloned();

const server = new Server(
  { name: "mikrus-toolbox", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    setupServerTool,
    listAppsTool,
    deployAppTool,
    deployCustomAppTool,
    deploySiteTool,
    serverStatusTool,
    setupDomainTool,
    setupBackupTool,
    setupGateflowTool,
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "setup_server":
      return handleSetupServer(args ?? {});
    case "list_apps":
      return handleListApps(args ?? {});
    case "deploy_app":
      return handleDeployApp(args ?? {});
    case "deploy_custom_app":
      return handleDeployCustomApp(args ?? {});
    case "deploy_site":
      return handleDeploySite(args ?? {});
    case "server_status":
      return handleServerStatus(args ?? {});
    case "setup_domain":
      return handleSetupDomain(args ?? {});
    case "setup_backup":
      return handleSetupBackup(args ?? {});
    case "setup_gateflow_config":
      return handleSetupGateflow(args ?? {});
    default:
      return {
        content: [{ type: "text", text: `Unknown tool: ${name}` }],
        isError: true,
      };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  process.stderr.write(`MCP server error: ${err}\n`);
  process.exit(1);
});
