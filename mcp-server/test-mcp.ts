/**
 * Comprehensive MCP server test suite.
 * Tests everything that can run locally without SSH.
 *
 * Run: npx tsx test-deploy-site.ts
 */

import { mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { detectProject } from "./src/lib/project-detect.js";
import { handleDeploySite } from "./src/tools/deploy-site.js";
import { parseAppMetadata, listAllApps } from "./src/lib/app-metadata.js";
import { handleListApps } from "./src/tools/list-apps.js";
import { handleDeployCustomApp } from "./src/tools/deploy-custom-app.js";
import { resolveRepoRoot, getAppsDir, getDeployShPath } from "./src/lib/repo.js";
import { handleSetupServer } from "./src/tools/configure-server.js";
import { handleSetupDomain } from "./src/tools/configure-domain.js";

const TEST_ROOT = join(tmpdir(), "mikrus-mcp-test-" + Date.now());
let passed = 0;
let failed = 0;

function setup() {
  mkdirSync(TEST_ROOT, { recursive: true });
}

function teardown() {
  rmSync(TEST_ROOT, { recursive: true, force: true });
}

function makeDir(name: string, files: Record<string, string>): string {
  const dir = join(TEST_ROOT, name);
  mkdirSync(dir, { recursive: true });
  for (const [filename, content] of Object.entries(files)) {
    const filePath = join(dir, filename);
    const parent = filePath.substring(0, filePath.lastIndexOf("/"));
    mkdirSync(parent, { recursive: true });
    writeFileSync(filePath, content);
  }
  return dir;
}

function assert(condition: boolean, testName: string, detail?: string) {
  if (condition) {
    console.log(`  \u2705 ${testName}`);
    passed++;
  } else {
    console.log(`  \u274c ${testName}${detail ? ` \u2014 ${detail}` : ""}`);
    failed++;
  }
}

function assertEq(actual: unknown, expected: unknown, testName: string) {
  assert(
    actual === expected,
    testName,
    `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
  );
}

// ══════════════════════════════════════════════════════
// 1. detectProject() — project type detection
// ══════════════════════════════════════════════════════

function testDetectStatic() {
  console.log("\n\ud83d\udcc1 Static HTML project");
  const dir = makeDir("static-site", {
    "index.html": "<h1>Hello</h1>",
    "style.css": "body { color: red; }",
  });
  const r = detectProject(dir);
  assertEq(r.type, "static", "type = static");
  assertEq(r.strategy, "static", "strategy = static");
  assert(r.files.includes("index.html"), "files includes index.html");
  assertEq(r.port, null, "port = null");
  assertEq(r.buildRequired, false, "no build required");
  assert(r.totalFiles >= 2, `totalFiles >= 2 (got ${r.totalFiles})`);
  assert(r.summary.includes("Static site"), "summary mentions static");
}

function testDetectStaticNoIndex() {
  console.log("\n\ud83d\udcc1 Static HTML project (no index.html, but has .html files)");
  const dir = makeDir("static-no-index", {
    "about.html": "<h1>About</h1>",
    "contact.html": "<h1>Contact</h1>",
  });
  const r = detectProject(dir);
  assertEq(r.type, "static", "type = static");
  assertEq(r.strategy, "static", "strategy = static");
}

function testDetectDockerCompose() {
  console.log("\n\ud83d\udc33 Docker Compose project");
  const dir = makeDir("compose-project", {
    "docker-compose.yaml": `services:
  web:
    image: nginx
    ports:
      - "8080:80"
`,
    "Dockerfile": "FROM node:20",
  });
  const r = detectProject(dir);
  assertEq(r.type, "docker-compose", "type = docker-compose");
  assertEq(r.strategy, "docker", "strategy = docker");
  assertEq(r.port, 8080, "detected port from compose = 8080");
  assert(r.files.includes("docker-compose.yaml"), "files includes compose");
  assert(r.files.includes("Dockerfile"), "files includes Dockerfile");
}

function testDetectComposeYml() {
  console.log("\n\ud83d\udc33 Docker Compose project (compose.yml)");
  const dir = makeDir("compose-yml", {
    "compose.yml": `services:
  app:
    build: .
    ports:
      - "3000:3000"
`,
  });
  const r = detectProject(dir);
  assertEq(r.type, "docker-compose", "type = docker-compose");
  assertEq(r.port, 3000, "port = 3000");
}

function testDetectDockerfile() {
  console.log("\n\ud83d\udc0b Dockerfile project (no compose)");
  const dir = makeDir("dockerfile-only", {
    Dockerfile: `FROM python:3.12\nCOPY . .\nCMD ["python", "app.py"]`,
  });
  const r = detectProject(dir);
  assertEq(r.type, "dockerfile", "type = dockerfile");
  assertEq(r.strategy, "docker", "strategy = docker");
  assertEq(r.port, 3000, "default port = 3000");
}

function testDetectNextjs() {
  console.log("\n\u26a1 Next.js project (no build)");
  const dir = makeDir("nextjs-app", {
    "package.json": JSON.stringify({
      name: "my-next-app",
      dependencies: { next: "14.0.0", react: "18.0.0" },
      scripts: { dev: "next dev", build: "next build", start: "next start" },
    }),
    "next.config.js": "module.exports = { output: 'standalone' }",
  });
  const r = detectProject(dir);
  assertEq(r.type, "nextjs", "type = nextjs");
  assertEq(r.strategy, "docker", "strategy = docker");
  assertEq(r.port, 3000, "port = 3000");
  assert(r.buildRequired === true, "build required (no .next/standalone)");
  assert(r.buildHint !== null, "has build hint");
}

function testDetectNextjsWithBuild() {
  console.log("\n\u26a1 Next.js project (with standalone build)");
  const dir = makeDir("nextjs-built", {
    "package.json": JSON.stringify({
      name: "my-next-app",
      dependencies: { next: "14.0.0" },
      scripts: { start: "next start" },
    }),
    "next.config.mjs": "export default { output: 'standalone' }",
    ".next/standalone/server.js": "// built",
  });
  const r = detectProject(dir);
  assertEq(r.type, "nextjs", "type = nextjs");
  assert(r.buildRequired === false, "build NOT required (standalone exists)");
}

function testDetectNode() {
  console.log("\n\ud83d\udce6 Node.js project");
  const dir = makeDir("node-app", {
    "package.json": JSON.stringify({
      name: "my-api",
      scripts: { start: "node server.js" },
    }),
    "server.js": "require('http').createServer().listen(3000)",
    ".env.example": "PORT=4000\nDB_URL=...",
  });
  const r = detectProject(dir);
  assertEq(r.type, "node", "type = node");
  assertEq(r.strategy, "node", "strategy = node");
  assertEq(r.port, 4000, "port from .env.example = 4000");
  assertEq(r.startCommand, "node server.js", "startCommand from package.json");
}

function testDetectNodeDefaultPort() {
  console.log("\n\ud83d\udce6 Node.js project (no .env.example -> default port)");
  const dir = makeDir("node-default-port", {
    "package.json": JSON.stringify({
      name: "my-api",
      scripts: { start: "npm run serve" },
    }),
  });
  const r = detectProject(dir);
  assertEq(r.type, "node", "type = node");
  assertEq(r.port, 3000, "default port = 3000");
}

function testDetectPython() {
  console.log("\n\ud83d\udc0d Python project (requirements.txt)");
  const dir = makeDir("python-app", {
    "requirements.txt": "fastapi\nuvicorn",
    "main.py": "from fastapi import FastAPI\napp = FastAPI()",
  });
  const r = detectProject(dir);
  assertEq(r.type, "python", "type = python");
  assertEq(r.strategy, "docker", "strategy = docker");
  assertEq(r.port, 8000, "default port = 8000");
  assert(r.warnings.length > 0, "has warning about uvicorn default CMD");
}

function testDetectPythonPyproject() {
  console.log("\n\ud83d\udc0d Python project (pyproject.toml)");
  const dir = makeDir("python-pyproject", {
    "pyproject.toml": "[project]\nname = 'my-app'",
  });
  const r = detectProject(dir);
  assertEq(r.type, "python", "type = python");
  assert(r.files.includes("pyproject.toml"), "files includes pyproject.toml");
}

function testDetectUnknown() {
  console.log("\n\u2753 Unknown project");
  const dir = makeDir("unknown-project", {
    "README.md": "# This is a project",
    "data.csv": "a,b,c",
  });
  const r = detectProject(dir);
  assertEq(r.type, "unknown", "type = unknown");
  assert(r.warnings.length > 0, "has warning");
}

function testDetectInvalidPath() {
  console.log("\n\ud83d\udca5 Invalid path");
  const r = detectProject("/tmp/nonexistent-path-" + Date.now());
  assertEq(r.type, "unknown", "type = unknown");
  assert(r.warnings.length > 0, "has warning about invalid path");
}

function testDetectPriority() {
  console.log("\n\ud83c\udfc6 Priority: docker-compose > Dockerfile > Node.js");
  const dir = makeDir("priority-test", {
    "docker-compose.yaml": `services:\n  app:\n    build: .\n    ports:\n      - "5000:5000"`,
    "package.json": JSON.stringify({
      scripts: { start: "node index.js" },
    }),
    Dockerfile: "FROM node:20",
  });
  const r = detectProject(dir);
  assertEq(r.type, "docker-compose", "docker-compose wins over node");
}

function testDetectPkgJsonNoStart() {
  console.log("\n\ud83d\udce6 package.json without start script -> warnings");
  const dir = makeDir("node-no-start", {
    "package.json": JSON.stringify({ name: "lib", scripts: { test: "jest" } }),
  });
  const r = detectProject(dir);
  assertEq(r.type, "unknown", "type = unknown (no start script, no html)");
  assert(
    r.warnings.some((w) => w.includes("start")),
    "warning mentions missing start script"
  );
}

function testFileSizeCounting() {
  console.log("\n\ud83d\udcca File size counting (excludes node_modules, .git)");
  const dir = makeDir("size-test", {
    "index.html": "<h1>Hello World</h1>",
    "node_modules/express/index.js": "// should be excluded",
    ".git/HEAD": "ref: refs/heads/main",
    "assets/image.png": "fake-image-data-that-is-larger",
  });
  const r = detectProject(dir);
  assertEq(r.totalFiles, 2, "totalFiles = 2 (excludes node_modules, .git)");
}

function testEmptyDirectory() {
  console.log("\n\ud83d\udcc2 Empty directory");
  const dir = makeDir("empty-dir", {});
  const r = detectProject(dir);
  assertEq(r.type, "unknown", "type = unknown");
  assertEq(r.totalFiles, 0, "totalFiles = 0");
}

// ══════════════════════════════════════════════════════
// 2. handleDeploySite() — tool handler validation
// ══════════════════════════════════════════════════════

async function testHandlerAnalyzeOnly() {
  console.log("\n\ud83d\udd0d handleDeploySite -- analyze_only mode");
  const dir = makeDir("handler-static", {
    "index.html": "<h1>Test</h1>",
    "app.js": "console.log('hi')",
  });
  const result = await handleDeploySite({
    project_path: dir,
    analyze_only: true,
  });
  assert(!result.isError, "no error");
  const text = result.content[0].text;
  assert(text.includes("Project Analysis"), "has 'Project Analysis'");
  assert(text.includes("static"), "mentions static type");
  assert(text.includes("confirmed=true"), "mentions confirmed=true next step");
}

async function testHandlerAnalyzeNode() {
  console.log("\n\ud83d\udd0d handleDeploySite -- analyze_only Node.js");
  const dir = makeDir("handler-node", {
    "package.json": JSON.stringify({
      name: "my-api",
      scripts: { start: "node index.js" },
    }),
    "index.js": "require('http').createServer().listen(3000)",
  });
  const result = await handleDeploySite({
    project_path: dir,
    analyze_only: true,
  });
  assert(!result.isError, "no error");
  const text = result.content[0].text;
  assert(text.includes("node"), "mentions node type");
  assert(text.includes("PM2"), "mentions PM2");
  assert(text.includes("node index.js"), "shows start command");
}

async function testHandlerInvalidPath() {
  console.log("\n\ud83d\udca5 handleDeploySite -- invalid path");
  const result = await handleDeploySite({
    project_path: "/tmp/nonexistent-" + Date.now(),
  });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("does not exist"),
    "error message mentions path"
  );
}

async function testHandlerNotConfirmed() {
  console.log("\n\ud83d\udd12 handleDeploySite -- deploy without confirmation");
  const dir = makeDir("handler-no-confirm", {
    "index.html": "<h1>Test</h1>",
  });
  const result = await handleDeploySite({ project_path: dir });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("not confirmed"),
    "error message about confirmation"
  );
}

async function testHandlerBuildRequired() {
  console.log("\n\ud83c\udfd7\ufe0f handleDeploySite -- build required blocks deploy");
  const dir = makeDir("handler-nextjs-no-build", {
    "package.json": JSON.stringify({
      name: "next-app",
      dependencies: { next: "14.0.0" },
      scripts: { start: "next start", build: "next build" },
    }),
    "next.config.js": "module.exports = {}",
  });
  const result = await handleDeploySite({
    project_path: dir,
    confirmed: true,
  });
  assert(result.isError === true, "returns error (build required)");
  assert(
    result.content[0].text.includes("building first") ||
      result.content[0].text.includes("Build"),
    "error mentions build"
  );
}

async function testHandlerInvalidName() {
  console.log("\n\ud83d\udeab handleDeploySite -- invalid name");
  const dir = makeDir("handler-bad-name", {
    "index.html": "<h1>Hi</h1>",
  });
  const result = await handleDeploySite({
    project_path: dir,
    name: "---",
    analyze_only: true,
  });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("Invalid site name"),
    "error mentions invalid name"
  );
}

async function testHandlerNameSanitization() {
  console.log("\n\ud83d\udd24 handleDeploySite -- name sanitization");
  const dir = makeDir("My Cool Site!", {
    "index.html": "<h1>Hi</h1>",
  });
  const result = await handleDeploySite({
    project_path: dir,
    analyze_only: true,
  });
  assert(!result.isError, "no error");
  assert(
    result.content[0].text.includes("my-cool-site"),
    "name sanitized to my-cool-site"
  );
}

async function testHandlerCustomName() {
  console.log("\n\ud83c\udff7\ufe0f handleDeploySite -- custom name");
  const dir = makeDir("handler-custom-name", {
    "index.html": "<h1>Hi</h1>",
  });
  const result = await handleDeploySite({
    project_path: dir,
    name: "my-blog",
    analyze_only: true,
  });
  assert(!result.isError, "no error");
  assert(
    result.content[0].text.includes("my-blog"),
    "uses custom name my-blog"
  );
}

// ══════════════════════════════════════════════════════
// 3. repo.ts — resolveRepoRoot, getAppsDir, getDeployShPath
// ══════════════════════════════════════════════════════

function testRepoRoot() {
  console.log("\n\ud83d\udcc2 resolveRepoRoot()");
  const root = resolveRepoRoot();
  assert(root.length > 0, "root is non-empty");
  assert(root.includes("mikrus-toolbox"), `root includes 'mikrus-toolbox' (got ${root})`);
}

function testAppsDir() {
  console.log("\n\ud83d\udcc2 getAppsDir()");
  const appsDir = getAppsDir();
  assert(appsDir.endsWith("/apps"), "ends with /apps");
}

function testDeployShPath() {
  console.log("\n\ud83d\udcc2 getDeployShPath()");
  const deployPath = getDeployShPath();
  assert(deployPath.includes("local/deploy.sh"), "includes local/deploy.sh");
}

// ══════════════════════════════════════════════════════
// 4. app-metadata.ts — parseAppMetadata on real apps
// ══════════════════════════════════════════════════════

function testMetadataUptimeKuma() {
  console.log("\n\ud83d\udcca parseAppMetadata -- uptime-kuma");
  const appsDir = getAppsDir();
  const meta = parseAppMetadata(join(appsDir, "uptime-kuma"));
  assert(meta !== null, "metadata not null");
  if (!meta) return;
  assertEq(meta.name, "uptime-kuma", "name = uptime-kuma");
  assertEq(meta.defaultPort, 3001, "port = 3001");
  assertEq(meta.requiresDb, false, "no DB required");
  assert(meta.imageSizeMb !== null && meta.imageSizeMb > 0, `imageSizeMb > 0 (got ${meta.imageSizeMb})`);
  assert(meta.description.length > 10, `has description (got: ${meta.description})`);
}

function testMetadataN8n() {
  console.log("\n\ud83d\udcca parseAppMetadata -- n8n");
  const appsDir = getAppsDir();
  const meta = parseAppMetadata(join(appsDir, "n8n"));
  assert(meta !== null, "metadata not null");
  if (!meta) return;
  assertEq(meta.name, "n8n", "name = n8n");
  assertEq(meta.defaultPort, 5678, "port = 5678");
  assertEq(meta.requiresDb, true, "requires DB");
  assertEq(meta.dbType, "postgres", "dbType = postgres");
  assert(meta.imageSizeMb === 800, `imageSizeMb = 800 (got ${meta.imageSizeMb})`);
  assert(
    meta.specialNotes.some((n) => n.includes("pgcrypto") || n.includes("WYMAG")),
    "special notes mention pgcrypto or WYMAG"
  );
}

function testMetadataWordpress() {
  console.log("\n\ud83d\udcca parseAppMetadata -- wordpress");
  const appsDir = getAppsDir();
  const meta = parseAppMetadata(join(appsDir, "wordpress"));
  assert(meta !== null, "metadata not null");
  if (!meta) return;
  assertEq(meta.name, "wordpress", "name = wordpress");
  assertEq(meta.requiresDb, true, "requires DB");
  assertEq(meta.dbType, "mysql", "dbType = mysql");
}

function testMetadataStirlingPdf() {
  console.log("\n\ud83d\udcca parseAppMetadata -- stirling-pdf (no DB)");
  const appsDir = getAppsDir();
  const meta = parseAppMetadata(join(appsDir, "stirling-pdf"));
  assert(meta !== null, "metadata not null");
  if (!meta) return;
  assertEq(meta.requiresDb, false, "no DB required");
}

function testMetadataNonExistent() {
  console.log("\n\ud83d\udcca parseAppMetadata -- non-existent app");
  const meta = parseAppMetadata("/tmp/fake-app-" + Date.now());
  assertEq(meta, null, "returns null for missing app");
}

function testListAllApps() {
  console.log("\n\ud83d\udcca listAllApps()");
  const apps = listAllApps();
  assert(apps.length >= 10, `at least 10 apps (got ${apps.length})`);
  assert(
    apps.some((a) => a.name === "uptime-kuma"),
    "includes uptime-kuma"
  );
  assert(
    apps.some((a) => a.name === "n8n"),
    "includes n8n"
  );
  assert(
    apps.some((a) => a.name === "wordpress"),
    "includes wordpress"
  );
  // Every app must have a name
  assert(
    apps.every((a) => a.name.length > 0),
    "all apps have a name"
  );
}

// ══════════════════════════════════════════════════════
// 5. handleListApps() — tool handler
// ══════════════════════════════════════════════════════

async function testListAppsAll() {
  console.log("\n\ud83d\udcdd handleListApps -- all");
  const result = await handleListApps({});
  const text = result.content[0].text;
  assert(text.includes("Available Apps"), "has title");
  assert(text.includes("uptime-kuma"), "includes uptime-kuma");
  assert(text.includes("deploy_app"), "mentions deploy_app");
}

async function testListAppsNoDb() {
  console.log("\n\ud83d\udcdd handleListApps -- no-db filter");
  const result = await handleListApps({ category: "no-db" });
  const text = result.content[0].text;
  assert(text.includes("No Database Required"), "has 'No Database Required' section");
  assert(!text.includes("Requires PostgreSQL"), "no PostgreSQL section");
  assert(!text.includes("Requires MySQL"), "no MySQL section");
}

async function testListAppsPostgres() {
  console.log("\n\ud83d\udcdd handleListApps -- postgres filter");
  const result = await handleListApps({ category: "postgres" });
  const text = result.content[0].text;
  assert(text.includes("PostgreSQL"), "has PostgreSQL section");
  assert(text.includes("n8n"), "includes n8n");
}

async function testListAppsMysql() {
  console.log("\n\ud83d\udcdd handleListApps -- mysql filter");
  const result = await handleListApps({ category: "mysql" });
  const text = result.content[0].text;
  assert(text.includes("MySQL"), "has MySQL section");
  assert(text.includes("wordpress"), "includes wordpress");
}

async function testListAppsLightweight() {
  console.log("\n\ud83d\udcdd handleListApps -- lightweight filter");
  const result = await handleListApps({ category: "lightweight" });
  const text = result.content[0].text;
  assert(text.includes("Available Apps"), "has title");
  // All listed apps should have IMAGE_SIZE_MB <= 200
  assert(!text.includes("No apps found"), "found some lightweight apps");
}

// ══════════════════════════════════════════════════════
// 6. handleDeployCustomApp() — validation only
// ══════════════════════════════════════════════════════

async function testCustomAppNotConfirmed() {
  console.log("\n\ud83d\udce6 handleDeployCustomApp -- not confirmed");
  const result = await handleDeployCustomApp({
    name: "my-app",
    compose: "services:\n  app:\n    image: nginx",
    confirmed: false,
  });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("not confirmed"),
    "error about confirmation"
  );
}

async function testCustomAppInvalidName() {
  console.log("\n\ud83d\udce6 handleDeployCustomApp -- invalid name");
  const result = await handleDeployCustomApp({
    name: "---invalid",
    compose: "services:\n  app:\n    image: nginx",
    confirmed: true,
  });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("Invalid stack name"),
    "error about invalid name"
  );
}

async function testCustomAppInvalidCompose() {
  console.log("\n\ud83d\udce6 handleDeployCustomApp -- invalid compose (no services)");
  const result = await handleDeployCustomApp({
    name: "my-app",
    compose: "version: '3'\nnothing_here: true",
    confirmed: true,
  });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("services"),
    "error about missing services"
  );
}

// ══════════════════════════════════════════════════════
// 7. handleSetupServer() — validation only
// ══════════════════════════════════════════════════════

async function testSetupServerNoArgs() {
  console.log("\n\ud83d\udd27 handleSetupServer -- no args");
  const result = await handleSetupServer({});
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("host") && result.content[0].text.includes("ssh_alias"),
    "error mentions required args"
  );
}

async function testSetupServerHostNoPort() {
  console.log("\n\ud83d\udd27 handleSetupServer -- host without port");
  const result = await handleSetupServer({ host: "srv20.mikr.us" });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("port"),
    "error mentions port"
  );
}

// ══════════════════════════════════════════════════════
// 7b. handleSetupDomain() — validation only
// ══════════════════════════════════════════════════════

async function testSetupDomainNoPort() {
  console.log("\n\ud83c\udf0d handleSetupDomain -- no port");
  const result = await handleSetupDomain({});
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("port"),
    "error mentions port"
  );
}

async function testSetupDomainInvalidPort() {
  console.log("\n\ud83c\udf0d handleSetupDomain -- invalid port");
  const result = await handleSetupDomain({ port: 99999 });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("port"),
    "error mentions port"
  );
}

async function testSetupDomainInvalidDomain() {
  console.log("\n\ud83c\udf0d handleSetupDomain -- invalid domain");
  const result = await handleSetupDomain({ port: 3001, domain: "invalid.com" });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("byst.re"),
    "error mentions supported TLDs"
  );
}

async function testSetupDomainInvalidAlias() {
  console.log("\n\ud83c\udf0d handleSetupDomain -- invalid alias");
  const result = await handleSetupDomain({ port: 3001, ssh_alias: "--inject" });
  assert(result.isError === true, "returns error");
  assert(
    result.content[0].text.includes("Invalid SSH alias"),
    "error mentions invalid alias"
  );
}

// ══════════════════════════════════════════════════════
// 8. index.ts — tool registration integrity
// ══════════════════════════════════════════════════════

function testToolRegistrationIntegrity() {
  console.log("\n\ud83d\udd17 Tool registration integrity (index.ts)");
  const indexContent = readFileSync(
    join(resolveRepoRoot(), "mcp-server", "src", "index.ts"),
    "utf-8"
  );

  // Extract tool names from tools array (XXXTool references)
  const toolArrayMatch = indexContent.match(/tools:\s*\[([\s\S]*?)\]/);
  assert(toolArrayMatch !== null, "found tools array in index.ts");

  // Extract case names from switch
  const caseNames = [...indexContent.matchAll(/case\s+"([^"]+)":/g)].map(
    (m) => m[1]
  );

  // Known tools
  const expectedTools = [
    "setup_server",
    "list_apps",
    "deploy_app",
    "deploy_custom_app",
    "deploy_site",
    "server_status",
    "setup_domain",
    "setup_backup",
    "setup_gateflow_config",
  ];

  for (const tool of expectedTools) {
    assert(
      caseNames.includes(tool),
      `switch has case "${tool}"`
    );
  }

  // Every case should have a corresponding tool import
  assert(
    caseNames.length === expectedTools.length,
    `switch has exactly ${expectedTools.length} cases (got ${caseNames.length})`
  );

  // Check for default error case
  assert(
    indexContent.includes("Unknown tool"),
    "has default 'Unknown tool' case"
  );
}

// ══════════════════════════════════════════════════════
// 9. Tool definitions — inputSchema validation
// ══════════════════════════════════════════════════════

function testToolDefinitions() {
  console.log("\n\ud83d\udccb Tool definitions — inputSchema");
  // Import all tool definitions
  // We can't easily import them without re-importing, so validate via index.ts content

  const indexContent = readFileSync(
    join(resolveRepoRoot(), "mcp-server", "src", "index.ts"),
    "utf-8"
  );

  // Ensure all 6 tools are imported
  const imports = [
    "setupServerTool",
    "listAppsTool",
    "deployAppTool",
    "deployCustomAppTool",
    "deploySiteTool",
    "serverStatusTool",
    "setupDomainTool",
    "setupBackupTool",
  ];

  for (const imp of imports) {
    assert(indexContent.includes(imp), `imports ${imp}`);
  }
}

// ══════════════════════════════════════════════════════
// 10. deploy-app.ts — validation (app existence, DB)
// ══════════════════════════════════════════════════════

// We can't test handleDeployApp directly (it calls deploy.sh),
// but we can test the metadata-based validation logic indirectly
function testDeployAppValidation() {
  console.log("\n\ud83d\ude80 deploy_app — validation logic");
  const appsDir = getAppsDir();

  // n8n needs DB — metadata check
  const n8nMeta = parseAppMetadata(join(appsDir, "n8n"));
  assert(n8nMeta !== null, "n8n metadata exists");
  assert(n8nMeta!.requiresDb === true, "n8n requires DB");
  assert(
    n8nMeta!.specialNotes.some((n) => n.includes("pgcrypto") || n.includes("WYMAG")),
    "n8n has pgcrypto note"
  );

  // uptime-kuma does NOT need DB
  const kumaMeta = parseAppMetadata(join(appsDir, "uptime-kuma"));
  assert(kumaMeta !== null, "uptime-kuma metadata exists");
  assert(kumaMeta!.requiresDb === false, "uptime-kuma does NOT require DB");
}

// ══════════════════════════════════════════════════════
// 11. Cross-cutting: all apps have valid metadata
// ══════════════════════════════════════════════════════

function testAllAppsMetadata() {
  console.log("\n\ud83c\udf10 All apps — metadata sanity check");
  const apps = listAllApps();
  let allHavePort = true;
  let portIssues: string[] = [];

  for (const app of apps) {
    // Every app must have a non-empty name
    assert(app.name.length > 0, `${app.name}: has name`);

    // Check port is reasonable if present
    if (app.defaultPort !== null) {
      if (app.defaultPort < 1 || app.defaultPort > 65535) {
        portIssues.push(`${app.name}: port ${app.defaultPort} out of range`);
      }
    }

    // DB type consistency
    if (app.requiresDb) {
      assert(
        app.dbType !== null,
        `${app.name}: has dbType when requiresDb=true`
      );
    }
  }

  if (portIssues.length > 0) {
    assert(false, `port range issues: ${portIssues.join(", ")}`);
  } else {
    assert(true, "all ports in valid range");
  }
}

// ══════════════════════════════════════════════════════
// Run all tests
// ══════════════════════════════════════════════════════

async function main() {
  console.log("=".repeat(50));
  console.log("  mikrus-toolbox MCP — full test suite");
  console.log("=".repeat(50));

  setup();

  try {
    // 1. detectProject
    testDetectStatic();
    testDetectStaticNoIndex();
    testDetectDockerCompose();
    testDetectComposeYml();
    testDetectDockerfile();
    testDetectNextjs();
    testDetectNextjsWithBuild();
    testDetectNode();
    testDetectNodeDefaultPort();
    testDetectPython();
    testDetectPythonPyproject();
    testDetectUnknown();
    testDetectInvalidPath();
    testDetectPriority();
    testDetectPkgJsonNoStart();
    testFileSizeCounting();
    testEmptyDirectory();

    // 2. handleDeploySite
    await testHandlerAnalyzeOnly();
    await testHandlerAnalyzeNode();
    await testHandlerInvalidPath();
    await testHandlerNotConfirmed();
    await testHandlerBuildRequired();
    await testHandlerInvalidName();
    await testHandlerNameSanitization();
    await testHandlerCustomName();

    // 3. repo.ts
    testRepoRoot();
    testAppsDir();
    testDeployShPath();

    // 4. app-metadata.ts
    testMetadataUptimeKuma();
    testMetadataN8n();
    testMetadataWordpress();
    testMetadataStirlingPdf();
    testMetadataNonExistent();
    testListAllApps();

    // 5. handleListApps
    await testListAppsAll();
    await testListAppsNoDb();
    await testListAppsPostgres();
    await testListAppsMysql();
    await testListAppsLightweight();

    // 6. handleDeployCustomApp validation
    await testCustomAppNotConfirmed();
    await testCustomAppInvalidName();
    await testCustomAppInvalidCompose();

    // 7. handleSetupServer validation
    await testSetupServerNoArgs();
    await testSetupServerHostNoPort();

    // 7b. handleSetupDomain validation
    await testSetupDomainNoPort();
    await testSetupDomainInvalidPort();
    await testSetupDomainInvalidDomain();
    await testSetupDomainInvalidAlias();

    // 8. index.ts integrity
    testToolRegistrationIntegrity();

    // 9. Tool definitions
    testToolDefinitions();

    // 10. deploy_app validation
    testDeployAppValidation();

    // 11. All apps sanity
    testAllAppsMetadata();
  } finally {
    teardown();
  }

  console.log("\n" + "=".repeat(50));
  console.log(`  Results: ${passed} passed, ${failed} failed`);
  console.log("=".repeat(50));

  if (failed > 0) process.exit(1);
}

main();
