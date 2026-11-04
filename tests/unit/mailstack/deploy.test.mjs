import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, writeFileSync, readdirSync, statSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { main } from '../../../apps/mailstack/deploy.mjs';

function world(profile) {
  const dir = mkdtempSync(join(tmpdir(), 'ms-deploy-')), log = [];
  const config = join(dir, 'owner.json'), pro = join(dir, 'pro');
  mkdirSync(join(pro, 'scripts'), { recursive: true });
  writeFileSync(join(pro, 'compose.yml'), 'services: {}\n');
  writeFileSync(join(pro, 'scripts/egress-firewall.sh'), '#!/bin/sh\n');
  writeFileSync(config, JSON.stringify({ version: 1, brands: { acme: {} } }));
  const plan = join(dir, 'plan.json');
  writeFileSync(plan, JSON.stringify({
    instance: 'mailstack-test', profile, ssh: 'vps', accountId: 'a'.repeat(32), ownerEmail: 'owner@example.com',
    hosts: { api: 'mail.example.com', panel: 'panel.example.com', internal: 'internal.example.com', egress: 'egress.example.net' },
    core: '/src/core', pro, config, keyBackup: '/offline/keys.json',
    license: { product: 'p', host: 'mail.example.com', seller: 's', jwksUrl: 'https://l/j', revocationUrl: 'https://l/r' },
    backup: { endpoint: 'https://s3.example.com', bucket: 'b', ageRecipient: 'age1' + 'q'.repeat(58) },
    secrets: { cloudflare: 'env:CF', api: { MAILSTACK_LICENSE: 'env:L', B2_KEY_ID: 'env:K', B2_APP_KEY: 'env:A' },
      backup: { B2_KEY_ID: 'env:K', B2_APP_KEY: 'env:A', CLOUDFLARE_API_TOKEN: 'env:CF' }, panel: { PANEL_NTFY_URL: 'env:N' } },
  }));
  const files = {};
  const deps = {
    home: join(dir, 'home'), env: { CF: 'cf-token', L: 'lic', K: 'k', A: 'a', N: 'https://ntfy.example/t' },
    log: () => {},
    run(cmd, args, { cwd, env = {}, input } = {}) {
      const line = [cmd, ...args].join(' ');
      log.push({ line, cwd, env, input });
      if (line.includes('keys.mjs init')) return 'CONTENT_PUBLIC_KEYS={"keys":[]}\nINDEX_KEYS=[{"kid":"i","key":"x"}]\nTRANSIT_KEYS={"keys":[{"kid":"t","d":"secret"}]}\n';
      if (line.includes('wrangler secret bulk') || line.includes('--secrets-file')) {
        const file = args[args.findIndex(a => a === 'bulk' || a === '--secrets-file') + 1];
        files[args.includes('bulk') ? 'bulk' : 'deploy'] = { mode: statSync(file).mode & 0o777, json: JSON.parse(readFileSync(file, 'utf8')) };
      }
      if (line.includes('invite')) return 'https://panel.example.com/?invite=abc\n';
      return '';
    },
    cloudflare: () => ({
      zoneFor: async host => (log.push({ line: `zone ${host}` }), { id: 'z', name: host.split('.').slice(-2).join('.') }),
      teamDomain: async () => 'team.cloudflareaccess.com',
      ensureServiceToken: async (name, stored) => (log.push({ line: `token ${name} ${stored ? 'stored' : 'new'}` }), { tokenId: 'tid', id: `${name}-id`, secret: `${name}-secret` }),
      ensureAccessApp: async app => (log.push({ line: `access ${app.domain} ${app.email ? 'email' : 'token'}` }), { id: 'app', aud: 'aud' }),
      ensureTunnel: async (name, rules) => (log.push({ line: `tunnel ${rules.map(r => r.hostname ?? r.service).join(',')}` }), { id: 'tun', token: 'tunnel-token' }),
      ensureCname: async (zone, host) => log.push({ line: `cname ${host}` }),
      ensureD1: async name => (log.push({ line: `d1 ${name}` }), `${name}-id`),
      remove: async spec => log.push({ line: 'remove', spec }),
    }),
    fetch: async url => (log.push({ line: `fetch ${url}` }), new Response('{"ok":true,"store":"ok"}', { status: 200 })),
  };
  return { plan, deps, log, files, dir };
}
const lines = log => log.map(e => e.line);
const index = (log, text) => lines(log).findIndex(l => l.includes(text));

test('profile a: secrets before release, release before the panel Worker, server runs only cloudflared, egress and backup', async () => {
  const w = world('a');
  await main(['--plan=' + w.plan], w.deps);
  const order = ['keys.mjs init', 'init-register.mjs', 'd1 mailstack-test', 'wrangler secret bulk', 'npm run release', 'build:panel-worker',
    'd1 migrations apply PANEL_DB', 'wrangler deploy --config wrangler.panel.toml', 'MAILSTACK_SERVICES=\'cloudflared egress backup\'', 'panel-worker.mjs invite'];
  const at = order.map(t => index(w.log, t));
  assert.ok(at.every(i => i >= 0), `missing step: ${order[at.indexOf(-1)]}`);
  assert.deepEqual([...at].sort((x, y) => x - y), at, 'steps in order');
  const release = w.log.find(e => e.line === 'npm run release');
  assert.equal(release.cwd, '/src/core');
  assert.equal(w.log.find(e => e.line === 'npm run build:panel-worker').cwd, join(w.dir, 'pro'));
  assert.equal(release.env.MAILSTACK_PANEL_AUDIENCE, 'internal.example.com');
  assert.equal(release.env.CLOUDFLARE_API_TOKEN, 'cf-token');
  assert.ok(lines(w.log).includes('tunnel egress.example.net,http_status:404'));
  assert.ok(!lines(w.log).some(l => l.startsWith('access internal')), 'no internal host in profile a');
  const bulk = w.files.bulk;
  assert.equal(bulk.mode, 0o600);
  assert.equal(bulk.json.EGRESS_ACCESS_CLIENT_SECRET, 'mailstack-test-egress-secret');
  assert.ok(!('PANEL_TOKEN' in bulk.json));
  const panelSecrets = w.files.deploy;
  assert.equal(panelSecrets.mode, 0o600);
  assert.deepEqual(Object.keys(panelSecrets.json).sort(), ['MAILSTACK_LICENSE', 'PANEL_API_TOKEN', 'PANEL_ASSERTION_KEYS', 'PANEL_NTFY_URL']);
  const state = join(w.deps.home, '.config/stackpilot/mailstack/mailstack-test');
  assert.equal(statSync(state).mode & 0o777, 0o700);
  for (const f of readdirSync(state)) assert.equal(statSync(join(state, f)).mode & 0o777, 0o600, f);
  assert.deepEqual(readdirSync(state).sort(), ['api.json', 'generated.json', 'ids.json']);
});

test('a second run reuses keys, register and tokens and creates no new invitation', async () => {
  const w = world('a');
  await main(['--plan=' + w.plan], w.deps);
  const first = JSON.parse(readFileSync(join(w.deps.home, '.config/stackpilot/mailstack/mailstack-test/generated.json'), 'utf8'));
  w.log.length = 0;
  await main(['--plan=' + w.plan, '--update'], w.deps);
  for (const step of ['keys.mjs init', 'init-register.mjs', 'invite']) assert.equal(index(w.log, step), -1, step);
  assert.ok(lines(w.log).includes('token mailstack-test-egress stored'));
  assert.deepEqual(JSON.parse(readFileSync(join(w.deps.home, '.config/stackpilot/mailstack/mailstack-test/generated.json'), 'utf8')), first);
});

test('--update without an existing installation refuses before any change', async () => {
  const w = world('c');
  await assert.rejects(main(['--plan=' + w.plan, '--update'], w.deps), /No installation state/);
  assert.equal(w.log.length, 0);
});

test('profile c: no Worker, API and panel through the Tunnel, health checked on the public host', async () => {
  const w = world('c');
  await main(['--plan=' + w.plan], w.deps);
  for (const absent of ['npm run release', 'wrangler', 'd1 mailstack']) assert.equal(index(w.log, absent), -1, absent);
  assert.ok(lines(w.log).includes('tunnel mail.example.com,panel.example.com,http_status:404'));
  assert.ok(index(w.log, "MAILSTACK_SERVICES='api panel cloudflared backup'") >= 0);
  assert.ok(index(w.log, 'fetch https://mail.example.com/health') > index(w.log, 'MAILSTACK_SERVICES'));
  const upload = w.log.find(e => e.line.startsWith('ssh vps') && e.input);
  assert.ok(upload, 'files streamed over ssh');
  assert.ok(index(w.log, 'container-context.mjs /src/core') >= 0);
  assert.ok(index(w.log, 'compose -p mailstack-test exec -T panel node dist/panel.mjs invite --role admin') >= 0);
});

test('profile b: panel reaches the internal host through Access with its own service token', async () => {
  const w = world('b');
  await main(['--plan=' + w.plan], w.deps);
  for (const step of ['access internal.example.com token', 'access egress.example.net token', 'access panel.example.com email', 'token mailstack-test-panel new'])
    assert.ok(lines(w.log).includes(step), step);
  assert.equal(w.log.find(e => e.line === 'npm run release').env.MAILSTACK_INTERNAL_ROUTE, 'internal.example.com');
  assert.ok(index(w.log, "MAILSTACK_SERVICES='panel cloudflared egress backup'") >= 0);
});

test('uninstall needs --yes, then removes Cloudflare resources and the server stack', async () => {
  const w = world('a');
  await main(['--plan=' + w.plan], w.deps);
  w.log.length = 0;
  await assert.rejects(main(['--plan=' + w.plan, '--uninstall'], w.deps), /--yes/);
  assert.equal(w.log.length, 0);
  await main(['--plan=' + w.plan, '--uninstall', '--yes'], w.deps);
  const removal = w.log.find(e => e.line === 'remove').spec;
  assert.deepEqual(removal, { workers: ['mailstack-test', 'mailstack-test-panel'], d1: ['mailstack-test', 'mailstack-test-panel'],
    apps: ['panel.example.com', 'internal.example.com', 'egress.example.net'], tokens: ['mailstack-test-panel', 'mailstack-test-egress'],
    tunnel: 'mailstack-test', hosts: ['egress.example.net'] });
  assert.ok(index(w.log, 'MAILSTACK_ACTION=uninstall') >= 0);
  assert.ok(index(w.log, 'MAILSTACK_ACTION=uninstall') < index(w.log, 'remove'), 'server stops before its tunnel disappears');
  assert.ok(existsSync(join(w.deps.home, '.config/stackpilot/mailstack/mailstack-test/generated.json')), 'local keys stay with the owner');
});

test('without a verified offline copy no key is deployed; the rerun verifies the copy named in the plan', async () => {
  const w = world('c');
  const run = w.deps.run;
  w.deps.run = (cmd, args, opts) => {
    if (args.includes('init') && !args.includes('--backup-verified')) {
      writeFileSync(args[2], '{}', { mode: 0o600 });
      throw new Error('exit 1');
    }
    return run(cmd, args, opts);
  };
  await assert.rejects(main(['--plan=' + w.plan], w.deps), /Copy .*content-private\.json to offline storage .*\/offline\/keys\.json/);
  assert.equal(index(w.log, 'init-register'), -1);
  await main(['--plan=' + w.plan], w.deps);
  assert.ok(lines(w.log).some(l => l.includes('keys.mjs init') && l.endsWith('--backup-verified /offline/keys.json')));
});

test('a failed register initialization is retried with the same register id and keys', async () => {
  const w = world('c');
  const run = w.deps.run;
  let fail = true;
  w.deps.run = (cmd, args, opts) => {
    if (args.includes('scripts/backup/init-register.mjs') && fail) { fail = false; w.log.push({ line: 'init-register failed', env: opts.env }); throw new Error('B2 deadline'); }
    return run(cmd, args, opts);
  };
  await assert.rejects(main(['--plan=' + w.plan], w.deps), /init-register|B2 deadline/);
  await main(['--plan=' + w.plan], w.deps);
  const attempts = w.log.filter(e => e.line.includes('init-register')).map(e => e.env.TOMBSTONE_REGISTRY_ID);
  assert.equal(attempts.length, 2);
  assert.equal(attempts[0], attempts[1]);
  assert.equal(lines(w.log).filter(l => l.includes('keys.mjs init')).length, 1);
  w.log.length = 0;
  await main(['--plan=' + w.plan], w.deps);
  assert.equal(index(w.log, 'init-register'), -1);
});
