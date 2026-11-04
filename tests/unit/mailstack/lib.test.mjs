import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readPlan, apiConfig, apiEnv, releaseEnv, ingress, serverFiles, services, panelWorkerEnv, resolveSecret } from '../../../apps/mailstack/lib.mjs';

const base = {
  instance: 'mailstack-test', ssh: 'vps', accountId: 'a'.repeat(32), ownerEmail: 'owner@example.com',
  hosts: { api: 'mail.example.com', panel: 'panel.example.com', internal: 'internal.example.com', egress: 'egress.example.net' },
  core: '/src/mailstack', pro: '/src/mailstack-pro', config: '/cfg/mailstack.json', keyBackup: '/offline/content.json',
  license: { product: 'mailstack-pro', host: 'mail.example.com', seller: 's', jwksUrl: 'https://l.example/jwks', revocationUrl: 'https://l.example/crl' },
  backup: { endpoint: 'https://s3.example.com', bucket: 'b', ageRecipient: 'age1' + 'q'.repeat(58) },
  secrets: { cloudflare: 'env:CF', api: { SES_ACCESS_KEY_ID: 'env:X', MAILSTACK_LICENSE: 'env:L', B2_KEY_ID: 'env:K', B2_APP_KEY: 'env:A' }, backup: { B2_KEY_ID: 'env:K2', B2_APP_KEY: 'env:A2', CLOUDFLARE_API_TOKEN: 'env:D1' }, panel: { PANEL_NTFY_URL: 'env:N' } },
};
const plan = (profile, extra = {}) => readPlan({ ...base, profile, ...extra });
const generated = {
  API_KEY: 'k', ALTCHA_HMAC_KEY: 'h', CONTENT_PUBLIC_KEYS: '{"keys":[]}', INDEX_KEYS: '[]', TRANSIT_KEYS: '{"keys":[]}',
  PANEL_ASSERTION_KEYS: '[{"kid":"panel-1","key":"x"}]', PRO_WEBHOOK_KEYS: '[{"kid":"webhook-1","key":"y"}]', EGRESS_KEYS: '[{"kid":"egress-1","key":"z"}]',
  PANEL_TOKEN: 'msk_panel_abc', TOMBSTONE_REGISTRY_ID: 'r'.repeat(32),
};
const ids = { d1: 'd1-api', panelD1: 'd1-panel', teamDomain: 'team.cloudflareaccess.com', internalAud: 'aud', egressZone: 'example.net',
  tunnelToken: 'tt', egressToken: { id: 'eid', secret: 'esec' }, panelToken: { id: 'pid', secret: 'psec' } };
const user = { api: { SES_ACCESS_KEY_ID: 'ses', MAILSTACK_LICENSE: 'lic', B2_KEY_ID: 'k', B2_APP_KEY: 'a' }, backup: { B2_KEY_ID: 'k2', B2_APP_KEY: 'a2', CLOUDFLARE_API_TOKEN: 'd1t' }, panel: { PANEL_NTFY_URL: 'https://ntfy.example/t' } };

test('readPlan rejects unknown profiles, bad names and missing hosts with readable messages', () => {
  assert.throws(() => plan('d'), /profile must be a, b or c/);
  assert.throws(() => plan('c', { instance: 'Mail Stack' }), /instance/);
  assert.throws(() => plan('b', { hosts: { ...base.hosts, egress: undefined } }), /hosts.egress/);
  assert.throws(() => plan('a', { hosts: { ...base.hosts, internal: undefined } }), /hosts.internal/);
  assert.throws(() => plan('c', { hosts: { ...base.hosts, panel: 'https://panel.example.com' } }), /hosts.panel/);
  assert.throws(() => plan('c', { core: 'relative/path' }), /core/);
  assert.throws(() => plan('c', { backup: { ...base.backup, ageRecipient: 'secret' } }), /ageRecipient/);
  assert.throws(() => plan('a', { secrets: { ...base.secrets, backup: { B2_KEY_ID: 'env:K2', B2_APP_KEY: 'env:A2' } } }), /CLOUDFLARE_API_TOKEN/);
  assert.throws(() => plan('c', { secrets: { ...base.secrets, panel: {} } }), /PANEL_NTFY_URL/);
  assert.equal(plan('c', { hosts: { api: 'mail.example.com', panel: 'panel.example.com' } }).profile, 'c');
});

test('apiConfig adds the panel client and the Pro extension for the runtime and keeps owner webhooks', () => {
  const owner = { version: 1, brands: { acme: {} }, clients: [{ id: 'panel', tokenSha256: 'old' }, { id: 'shop' }],
    extensions: [{ module: 'mailstack-pro', options: { webhooks: { endpoints: [{ id: 'e1' }] } } }] };
  const worker = apiConfig(owner, plan('a'), generated);
  assert.deepEqual(worker.clients.map(c => c.id), ['shop', 'panel']);
  const panel = worker.clients.find(c => c.id === 'panel');
  assert.deepEqual(panel.scopes, ['panel', 'webhooks:write']);
  assert.match(panel.tokenSha256, /^[0-9a-f]{64}$/);
  assert.notEqual(panel.tokenSha256, 'old');
  assert.deepEqual(worker.extensions, [{ module: 'mailstack-pro', options: { ...base.license, webhooks: { endpoints: [{ id: 'e1' }] } } }]);
  const node = apiConfig(owner, plan('c'), generated, 'lic');
  assert.deepEqual(node.extensions, [{ module: '/workspace/mailstack-pro/dist/extension.mjs',
    options: { ...base.license, license: 'lic', cachePath: '/data/license-cache.json', webhooks: { endpoints: [{ id: 'e1' }] } } }]);
  assert.equal(owner.clients.length, 2, 'owner config is not mutated');
});

test('services, ingress and Access follow the profile', () => {
  assert.deepEqual(services('a'), ['cloudflared', 'egress', 'backup']);
  assert.deepEqual(services('b'), ['panel', 'cloudflared', 'egress', 'backup']);
  assert.deepEqual(services('c'), ['api', 'panel', 'cloudflared', 'backup']);
  const panelRule = { hostname: 'panel.example.com', service: 'https://panel:8090', originRequest: { originServerName: 'panel.example.com', noTLSVerify: true } };
  assert.deepEqual(ingress(plan('c')), [{ hostname: 'mail.example.com', service: 'http://api:8080' }, panelRule, { service: 'http_status:404' }]);
  assert.deepEqual(ingress(plan('b')), [panelRule, { hostname: 'egress.example.net', service: 'http://egress:8080' }, { service: 'http_status:404' }]);
  assert.deepEqual(ingress(plan('a')), [{ hostname: 'egress.example.net', service: 'http://egress:8080' }, { service: 'http_status:404' }]);
});

test('apiEnv: Worker secrets carry egress credentials, Node env carries runtime settings, never the private content key', () => {
  const worker = apiEnv(plan('b'), generated, user, ids);
  for (const k of ['API_KEY', 'CONTENT_PUBLIC_KEYS', 'TRANSIT_KEYS', 'PANEL_ASSERTION_KEYS', 'PRO_WEBHOOK_KEYS', 'EGRESS_KEYS', 'TOMBSTONE_REGISTRY_ID', 'BACKUP_AGE_RECIPIENT', 'B2_BUCKET', 'SES_ACCESS_KEY_ID', 'MAILSTACK_LICENSE'])
    assert.ok(worker[k], k);
  assert.equal(worker.EGRESS_ACCESS_CLIENT_ID, 'eid');
  assert.equal(worker.EGRESS_ACCESS_CLIENT_SECRET, 'esec');
  assert.equal(worker.PANEL_TOKEN, undefined);
  assert.equal(worker.TRUSTED_PROXY, undefined);
  const node = apiEnv(plan('c'), generated, user, ids);
  assert.equal(node.TRUSTED_PROXY, 'cloudflare');
  assert.equal(node.SES_REGION, 'eu-west-1');
  assert.equal(node.EGRESS_KEYS, undefined);
  assert.equal(node.MAILSTACK_LICENSE, undefined, 'Node reads the license from its config');
  for (const env of [worker, node]) assert.ok(!JSON.stringify(env).includes('"d"'), 'no private JWK member');
});

test('releaseEnv sets every routing variable explicitly so a stray .env cannot change the profile', () => {
  const b = releaseEnv(plan('b'), ids, '/state/api.json');
  assert.deepEqual({ ...b }, {
    MAILSTACK_CONFIG: '/state/api.json', MAILSTACK_PRO_PATH: '/src/mailstack-pro', MAILSTACK_WORKER_NAME: 'mailstack-test', MAILSTACK_D1_ID: 'd1-api',
    MAILSTACK_D1_PREVIEW_ID: '', MAILSTACK_ROUTE: 'mail.example.com', SES_REGION: 'eu-west-1', SES_CONFIGURATION_SET: '', MAILSTACK_EGRESS_URL: 'https://egress.example.net',
    MAILSTACK_INTERNAL_ROUTE: 'internal.example.com', MAILSTACK_ACCESS_TEAM_DOMAIN: 'team.cloudflareaccess.com', MAILSTACK_ACCESS_AUD: 'aud',
    MAILSTACK_PANEL_AUDIENCE: '', MAILSTACK_HEALTH_URL: 'https://mail.example.com/health',
  });
  const a = releaseEnv(plan('a'), ids, '/state/api.json');
  assert.equal(a.MAILSTACK_INTERNAL_ROUTE, '');
  assert.equal(a.MAILSTACK_ACCESS_AUD, '');
  assert.equal(a.MAILSTACK_PANEL_AUDIENCE, 'internal.example.com');
});

test('panelWorkerEnv binds the panel Worker to this API Worker and its own D1', () => {
  assert.deepEqual(panelWorkerEnv(plan('a'), ids), {
    PANEL_WORKER_NAME: 'mailstack-test-panel', PANEL_WORKER_ROUTE: 'panel.example.com', PANEL_API_AUDIENCE: 'internal.example.com',
    PANEL_D1_ID: 'd1-panel', PANEL_API_WORKER: 'mailstack-test', PANEL_LICENSE_OPTIONS: JSON.stringify(base.license),
  });
});

test('serverFiles writes only what each profile runs, all secrets 0600, no private content key', () => {
  const owner = { version: 1, brands: {} };
  const files = p => serverFiles(plan(p), { owner, generated, user, ids });
  const c = files('c'), b = files('b'), a = files('a');
  assert.deepEqual(Object.keys(a).sort(), ['.env', 'backup.env', 'secrets/egress/keys', 'secrets/tunnel/token']);
  assert.deepEqual(Object.keys(b).sort(), ['.env', 'backup.env', 'secrets/egress/keys', 'secrets/panel/access-id', 'secrets/panel/access-secret',
    'secrets/panel/assertion', 'secrets/panel/license.json', 'secrets/panel/token', 'secrets/tunnel/token']);
  assert.deepEqual(Object.keys(c).sort(), ['.env', 'api.env', 'backup.env', 'config/api.json', 'secrets/panel/assertion', 'secrets/panel/license.json',
    'secrets/panel/token', 'secrets/tunnel/token']);
  for (const set of [a, b, c]) for (const [name, file] of Object.entries(set)) {
    assert.equal(file.mode, 0o600, name);
    assert.ok(!file.content.includes('"d":'), name);
  }
  assert.match(a['backup.env'].content, /^BACKUP_SOURCE=d1$/m);
  assert.match(a['backup.env'].content, /^BACKUP_D1_ID=d1-api,d1-panel$/m);
  assert.match(b['backup.env'].content, /^BACKUP_D1_ID=d1-api$/m);
  assert.match(c['backup.env'].content, /^BACKUP_SOURCE=sqlite$/m);
  assert.doesNotMatch(c['backup.env'].content, /CLOUDFLARE_API_TOKEN/);
  assert.match(b['.env'].content, /^PANEL_API_ORIGIN=https:\/\/internal\.example\.com$/m);
  assert.match(b['.env'].content, /^API_AUDIENCE=internal\.example\.com$/m);
  assert.match(b['.env'].content, /^EGRESS_DENY_ZONES=example\.net$/m);
  assert.match(c['.env'].content, /^PANEL_API_ORIGIN=http:\/\/api:8081$/m);
  assert.match(c['.env'].content, /^COMPOSE_PROFILES=production$/m);
  const bridge = files => /^EGRESS_BRIDGE=(.*)$/m.exec(files['.env'].content)?.[1];
  assert.match(bridge(c), /^ms[0-9a-f]{6}$/, 'own bridge names, at most 15 characters with -t');
  assert.equal(bridge(c), bridge(a), 'stable for an instance');
  assert.notEqual(bridge(c), bridge(serverFiles(readPlan({ ...base, profile: 'c', instance: 'other' }), { owner, generated, user, ids })));
  assert.match(c['.env'].content, /^PANEL_NTFY_URL=https:\/\/ntfy\.example\/t$/m);
  assert.equal(JSON.parse(c['secrets/panel/license.json'].content).license, 'lic');
  assert.equal(b['secrets/panel/token'].content, 'msk_panel_abc');
  assert.match(c['api.env'].content, /^CONTENT_PUBLIC_KEYS='\{"keys":\[\]\}'$/m);
  assert.throws(() => serverFiles(plan('c'), { owner, generated, user: { ...user, api: { ...user.api, SES_SECRET_ACCESS_KEY: "it's" } }, ids }), /SES_SECRET_ACCESS_KEY/);
});

test('resolveSecret reads env, file, keystore and Vaultwarden references without echoing values', async () => {
  const calls = [];
  const io = { env: { CF: 'from-env' }, readFile: path => (calls.push(path), 'from-file\n'), run: (cmd, args) => (calls.push([cmd, ...args].join(' ')), 'from-cmd\n') };
  assert.equal(await resolveSecret('env:CF', io), 'from-env');
  assert.equal(await resolveSecret('file:/s/x', io), 'from-file');
  assert.equal(await resolveSecret('bw:Item name', io), 'from-cmd');
  assert.equal(await resolveSecret('keystore:cloudflare_api_token', io), 'from-cmd');
  assert.deepEqual(calls.slice(0, 2), ['/s/x', 'bw get password Item name']);
  assert.match(calls[2], /local\/keys\.sh get cloudflare_api_token$/);
  await assert.rejects(resolveSecret('env:MISSING', io), /MISSING is empty/);
  await assert.rejects(resolveSecret('plain-value', io), /env:, file:, bw: or keystore:/);
});
