#!/usr/bin/env node
// ./local/deploy.sh mailstack --plan=<file> [--update | --status | --uninstall --yes] [--invite]
// Runs on the owner's computer: keys (core CLI), Cloudflare resources, Workers (core release, Pro panel Worker) and the
// server stack (install.sh). Keys and resource ids stay in ~/.config/stackpilot/mailstack/<instance>/ (0700/0600).
import { execFileSync } from 'node:child_process';
import { Resolver } from 'node:dns/promises';
import { request } from 'node:https';
import { createHash, randomBytes } from 'node:crypto';
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cloudflare } from './cloudflare.mjs';
import { apiConfig, apiEnv, ingress, panelWorkerEnv, publicLookup, readPlan, releaseEnv, resolveSecret, serverFiles, services } from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const random = () => randomBytes(32).toString('base64url');
const ring = kid => JSON.stringify([{ kid, key: random() }]);

function realRun(cmd, args, { cwd, env = {}, input, capture } = {}) {
  return execFileSync(cmd, args, { cwd, env: { ...process.env, ...env }, encoding: 'utf8', maxBuffer: 1 << 26,
    input: input ? readFileSync(input) : undefined, stdio: [input ? 'pipe' : 'inherit', capture ? 'pipe' : 'inherit', 'inherit'] }) ?? '';
}

/** GET through Cloudflare's public resolvers (publicLookup); returns { ok, status, json }. */
function publicFetch(url) {
  const resolver = new Resolver();
  resolver.setServers(['1.1.1.1', '1.0.0.1']);
  return new Promise((resolve, reject) => {
    const req = request(url, { lookup: publicLookup(resolver), timeout: 15000, headers: { 'cache-control': 'no-store' } }, res => {
      let body = '';
      res.setEncoding('utf8').on('data', chunk => { body += chunk; }).on('end', () =>
        resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, status: res.statusCode, json: async () => JSON.parse(body) }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout'))).on('error', reject).end();
  });
}

export async function main(argv, deps = {}) {
  const { home = homedir(), env = process.env, run = realRun, log = console.log, sleep = ms => new Promise(r => setTimeout(r, ms)) } = deps;
  const flag = name => argv.includes(`--${name}`);
  const planFile = argv.find(a => a.startsWith('--plan='))?.slice(7);
  if (!planFile) throw new Error('Use: deploy.sh mailstack --plan=<install plan JSON> [--update | --status | --uninstall --yes] [--invite]');
  const plan = readPlan(JSON.parse(readFileSync(planFile, 'utf8')));
  const state = join(home, '.config/stackpilot/mailstack', plan.instance), file = name => join(state, name);
  const read = name => existsSync(file(name)) ? JSON.parse(readFileSync(file(name), 'utf8')) : undefined;
  const save = (name, value) => { writeFileSync(file(name), JSON.stringify(value, null, 2), { mode: 0o600 }); chmodSync(file(name), 0o600); };
  const worker = plan.profile !== 'c', i = plan.instance, list = services(plan.profile).join(' ');
  if (flag('uninstall') && !flag('yes')) throw new Error(`Uninstall removes ${i} with all its data; rerun with --yes`);
  if (flag('update') && !read('generated.json')) throw new Error(`No installation state in ${state}; install first`);

  const io = { env, readFile: path => readFileSync(path, 'utf8'), run: (cmd, args) => run(cmd, args, { capture: true }) };
  const secret = ref => resolveSecret(ref, io);
  const group = async refs => Object.fromEntries(await Promise.all(Object.entries(refs ?? {}).map(async ([k, ref]) => [k, await secret(ref)])));
  const cfToken = await secret(plan.secrets.cloudflare);
  const cf = (deps.cloudflare ?? cloudflare)({ token: cfToken, account: plan.accountId });
  const zt = plan.secrets.cloudflareZeroTrust ? (deps.cloudflare ?? cloudflare)({ token: await secret(plan.secrets.cloudflareZeroTrust), account: plan.accountId }) : cf;
  const cfEnv = { CLOUDFLARE_API_TOKEN: cfToken, CLOUDFLARE_ACCOUNT_ID: plan.accountId };
  const ssh = (command, input) => run('ssh', [plan.ssh, command], { input });
  const serverScript = vars => `sudo env STACK_DIR='${plan.stackDir}' ${vars} bash -s`;
  const wrangler = `${plan.core}/node_modules/.bin/wrangler`;
  const panelEnv = ids => ({ ...panelWorkerEnv(plan, ids), ...cfEnv, PATH: `${plan.core}/node_modules/.bin:${process.env.PATH}` });
  // Secret files exist only for the one command that reads them.
  // /health with store ok and, for Workers, the commits of both checkouts (the Node image reports commit dev).
  const waitHealth = async expected => {
    const url = `https://${plan.hosts.api}/health`, fetchImpl = deps.fetch ?? publicFetch;
    let seen = 'no answer';
    for (let attempt = 0; ; attempt++) {
      const res = await fetchImpl(url).catch(error => { seen = error.message; });
      const body = res?.ok ? await res.json().catch(() => ({})) : {};
      if (res) seen = res.ok ? JSON.stringify({ store: body.store, commit: body.commit, proCommit: body.proCommit }) : `HTTP ${res.status}`;
      if (body.store === 'ok' && Object.entries(expected).every(([key, value]) => body[key] === value)) return;
      if (attempt >= 40) throw new Error(`${url} health is not ready or not this version (last: ${seen}); check the Tunnel, the api container or the Worker`);
      await sleep(3000);
    }
  };
  const head = dir => run('git', ['-C', dir, 'rev-parse', 'HEAD'], { capture: true }).trim();
  const withSecrets = (values, fn) => {
    const path = file('.secrets.json');
    writeFileSync(path, JSON.stringify(values), { mode: 0o600 });
    try { return fn(path); } finally { rmSync(path, { force: true }); }
  };

  if (flag('uninstall')) {
    ssh(serverScript('MAILSTACK_ACTION=uninstall'), join(HERE, 'install.sh'));
    const hosts = ingress(plan).flatMap(r => r.hostname ? [r.hostname] : []);
    await cf.remove({ workers: { a: [i, plan.workerPanel], b: [i], c: [] }[plan.profile], d1: { a: [i, plan.workerPanel], b: [i], c: [] }[plan.profile], hosts });
    await zt.remove({ apps: [plan.hosts.panel, ...worker ? [plan.hosts.internal, plan.hosts.egress] : []], tokens: worker ? [`${i}-panel`, `${i}-egress`] : [], tunnel: i });
    log(`Removed ${i}. The content keys and generated secrets stay in ${state}; delete that directory only when no backup needs them.`);
    return;
  }
  if (flag('status')) {
    const health = await (deps.fetch ?? publicFetch)(`https://${plan.hosts.api}/health`);
    log(`API ${plan.hosts.api}: ${health.status} ${JSON.stringify(await health.json().catch(() => null))}`);
    ssh(serverScript('MAILSTACK_ACTION=status'), join(HERE, 'install.sh'));
    return;
  }

  mkdirSync(state, { recursive: true, mode: 0o700 });
  chmodSync(state, 0o700);
  const user = { api: await group(plan.secrets.api), backup: await group(plan.secrets.backup), panel: await group(plan.secrets.panel) };
  let generated = read('generated.json');
  if (!generated) {
    // The core CLI prints keys only after verifying an offline copy of the private keyring (prompt on a terminal).
    const keyring = file('content-private.json'), verify = existsSync(keyring) ? ['--backup-verified', plan.keyBackup] : [];
    let printed;
    try { printed = run('node', ['scripts/keys.mjs', 'init', keyring, ...verify], { cwd: plan.core, capture: true }); }
    catch { throw new Error(`Copy ${keyring} to offline storage at ${plan.keyBackup} (keyBackup), then rerun; no keys were deployed`); }
    const keys = Object.fromEntries(printed.split('\n').map(l => /^([A-Z_]+)='(.+)'$/.exec(l)).filter(Boolean).map(m => [m[1], m[2]]));
    for (const k of ['CONTENT_PUBLIC_KEYS', 'INDEX_KEYS', 'TRANSIT_KEYS']) if (!keys[k]) throw new Error(`Key generation printed no ${k}`);
    generated = { ...keys, API_KEY: randomBytes(32).toString('hex'), ALTCHA_HMAC_KEY: randomBytes(32).toString('hex'), PANEL_ASSERTION_KEYS: ring('panel-1'),
      PRO_WEBHOOK_KEYS: ring('webhook-1'), EGRESS_KEYS: ring('egress-1'), PANEL_TOKEN: `msk_panel_${random()}`, TOMBSTONE_REGISTRY_ID: randomBytes(16).toString('hex') };
    save('generated.json', generated);
  }
  const ids = read('ids.json') ?? {};
  // The register id is saved before B2 is written, so a retry after a lost response reuses it.
  if (!ids.register) {
    run('node', ['scripts/backup/init-register.mjs'], { cwd: plan.core, env: { B2_ENDPOINT: plan.backup.endpoint, B2_BUCKET: plan.backup.bucket,
      B2_KEY_ID: user.api.B2_KEY_ID, B2_APP_KEY: user.api.B2_APP_KEY, BACKUP_AGE_RECIPIENT: plan.backup.ageRecipient,
      TOMBSTONE_REGISTRY_ID: generated.TOMBSTONE_REGISTRY_ID, ...plan.backup.tombstonePrefix ? { TOMBSTONE_PREFIX: plan.backup.tombstonePrefix } : {} } });
    save('ids.json', { ...ids, register: true });
    ids.register = true;
  }

  if (worker) {
    ids.egressZone = (await cf.zoneFor(plan.hosts.egress)).name;
    ids.egressToken = await zt.ensureServiceToken(`${i}-egress`, ids.egressToken);
    if (plan.profile === 'b') ids.panelToken = await zt.ensureServiceToken(`${i}-panel`, ids.panelToken);
    save('ids.json', ids);
  }
  await zt.ensureAccessApp({ name: `${i} panel`, domain: plan.hosts.panel, email: plan.ownerEmail });
  if (plan.profile === 'b') {
    ids.teamDomain = plan.accessTeamDomain ?? await zt.teamDomain(); // the lookup needs Access: Organizations Read
    ids.internalAud = (await zt.ensureAccessApp({ name: `${i} internal API`, domain: plan.hosts.internal, serviceToken: ids.panelToken.tokenId })).aud;
  }
  if (worker) await zt.ensureAccessApp({ name: `${i} egress`, domain: plan.hosts.egress, serviceToken: ids.egressToken.tokenId });
  const tunnel = await zt.ensureTunnel(i, ingress(plan));
  ids.tunnelToken = tunnel.token;
  for (const rule of ingress(plan).filter(r => r.hostname)) await cf.ensureCname((await cf.zoneFor(rule.hostname)).id, rule.hostname, `${tunnel.id}.cfargotunnel.com`);
  if (worker) ids.d1 = await cf.ensureD1(i);
  if (plan.profile === 'a') ids.panelD1 = await cf.ensureD1(plan.workerPanel);
  save('ids.json', ids);

  const owner = JSON.parse(readFileSync(plan.config, 'utf8'));
  if (worker) {
    save('api.json', apiConfig(owner, plan, generated));
    withSecrets(apiEnv(plan, generated, user, ids), path => run(wrangler, ['secret', 'bulk', path, '--name', i], { cwd: plan.core, env: cfEnv }));
    run('npm', ['run', 'release'], { cwd: plan.core, env: { ...releaseEnv(plan, ids, file('api.json')), ...cfEnv } });
    await waitHealth({ commit: head(plan.core), proCommit: head(plan.pro) });
  }
  if (plan.profile === 'a') {
    run('npm', ['run', 'build:panel-worker'], { cwd: plan.pro, env: panelEnv(ids) });
    run(wrangler, ['d1', 'migrations', 'apply', 'PANEL_DB', '--remote', '--config', 'wrangler.panel.toml'], { cwd: plan.pro, env: panelEnv(ids) });
    withSecrets({ PANEL_API_TOKEN: generated.PANEL_TOKEN, PANEL_ASSERTION_KEYS: generated.PANEL_ASSERTION_KEYS, MAILSTACK_LICENSE: user.api.MAILSTACK_LICENSE,
      PANEL_NTFY_URL: user.panel.PANEL_NTFY_URL }, path => run(wrangler, ['deploy', '--config', 'wrangler.panel.toml', '--secrets-file', path], { cwd: plan.pro, env: panelEnv(ids) }));
  }

  const staging = mkdtempSync(join(tmpdir(), 'mailstack-'));
  try {
    chmodSync(staging, 0o700);
    const bundle = join(staging, 'stack');
    for (const [name, { content, mode }] of Object.entries(serverFiles(plan, { owner, generated, user, ids }))) {
      mkdirSync(dirname(join(bundle, name)), { recursive: true, mode: 0o700 });
      writeFileSync(join(bundle, name), content, { mode });
    }
    copyFileSync(join(plan.pro, 'compose.yml'), join(bundle, 'compose.yml'));
    copyFileSync(join(plan.pro, 'scripts/egress-firewall.sh'), join(bundle, 'egress-firewall.sh'));
    run('node', [join(plan.pro, 'scripts/container-context.mjs'), plan.core, join(bundle, 'context')]);
    const context = createHash('sha256');
    for (const name of readdirSync(join(bundle, 'context'), { recursive: true }).sort()) {
      const path = join(bundle, 'context', name);
      if (statSync(path).isFile()) context.update(`${name}\0`).update(readFileSync(path)).update('\0');
    }
    writeFileSync(join(bundle, 'context.sha256'), context.digest('hex') + '\n');
    run('tar', ['-C', bundle, '-czf', join(staging, 'stack.tgz'), '.']);
    ssh(`sudo mkdir -p '${plan.stackDir}' && sudo rm -rf '${plan.stackDir}/context' && sudo tar -C '${plan.stackDir}' -xzf -`, join(staging, 'stack.tgz'));
    ssh(serverScript(`MAILSTACK_SERVICES='${list}'`), join(HERE, 'install.sh'));
  } finally { rmSync(staging, { recursive: true, force: true }); }

  if (!worker) {
    await waitHealth({});
  }
  if (!ids.invited || flag('invite')) {
    const invite = plan.profile === 'a'
      ? run('node', ['scripts/panel-worker.mjs', 'invite', '--role', 'admin'], { cwd: plan.pro, env: panelEnv(ids), capture: true })
      : run('ssh', [plan.ssh, `cd '${plan.stackDir}' && sudo docker compose -p ${i} exec -T panel node dist/panel.mjs invite --role admin`], { capture: true });
    log(`First admin invitation (single use, 15 minutes): ${invite.trim()}`);
    save('ids.json', { ...ids, invited: true });
  }
  log(`Mailstack ${i} (profile ${plan.profile}): https://${plan.hosts.api}/health, panel https://${plan.hosts.panel} behind Access. State: ${state}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2)).catch(error => { console.error(`mailstack: ${error.message}`); process.exitCode = 1; });
