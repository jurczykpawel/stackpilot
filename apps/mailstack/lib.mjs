// Mailstack install plan: validation and the files, environments and Tunnel routes each profile needs. No I/O here.
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HOST = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$/;
const NODE_EXTENSION = '/workspace/mailstack-pro/dist/extension.mjs';
const LICENSE_FIELDS = ['product', 'host', 'seller', 'jwksUrl', 'revocationUrl'];
const REPO = fileURLToPath(new URL('../..', import.meta.url));

const fail = message => { throw new Error(`Install plan: ${message}`); };
const need = (ok, message) => ok || fail(message);
const isRef = value => typeof value === 'string' && /^(env|file|bw|keystore):.+/.test(value);

export function readPlan(input) {
  const p = { sesRegion: 'eu-west-1', sesConfigurationSet: '', ...input, hosts: { ...input.hosts }, backup: { ...input.backup } };
  need(['a', 'b', 'c'].includes(p.profile), 'profile must be a, b or c');
  need(/^[a-z0-9][a-z0-9-]{0,50}$/.test(p.instance ?? ''), 'instance must be 1-51 lowercase letters, digits or hyphens');
  need(/^[A-Za-z0-9._@-]+$/.test(p.ssh ?? ''), 'ssh must name an SSH alias');
  need(/^[0-9a-f]{32}$/.test(p.accountId ?? ''), 'accountId must be the 32-character Cloudflare account id');
  need(/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(p.ownerEmail ?? ''), 'ownerEmail must be the address Access admits to the panel');
  if (p.externalEgress !== undefined) {
    need(p.profile === 'b' && p.externalEgress && typeof p.externalEgress === 'object', 'externalEgress is supported only in profile b');
    need(typeof p.externalEgress.url === 'string' && /^https:\/\/[^/]+$/.test(p.externalEgress.url) && HOST.test(p.externalEgress.url.slice(8)) && !['api', 'panel', 'internal'].some(k => p.externalEgress.url === `https://${p.hosts[k]}`), 'externalEgress.url must be an https origin with a lowercase hostname');
    for (const key of ['keys', 'accessClientId', 'accessClientSecret']) need(isRef(p.externalEgress[key]), `externalEgress.${key} must reference a secret`);
  }
  for (const host of ['api', 'panel', ...p.profile === 'c' ? [] : ['internal', ...p.externalEgress ? [] : ['egress']]])
    need(HOST.test(p.hosts[host] ?? ''), `hosts.${host} must be a lowercase hostname`);
  for (const path of ['core', 'pro', 'config', 'keyBackup']) need(p[path]?.startsWith('/'), `${path} must be an absolute path`);
  need(/^https:\/\/[^/]+$/.test(p.backup.endpoint ?? ''), 'backup.endpoint must be the https S3 endpoint of the bucket');
  need(!!p.backup.bucket, 'backup.bucket is required');
  need(/^age1[0-9a-z]{58}$/.test(p.backup.ageRecipient ?? ''), 'backup.ageRecipient must be the public age key (age1...)');
  need(/^[a-z]{2}(-[a-z]+)+-\d$/.test(p.sesRegion), 'sesRegion must be an AWS region');
  need(p.accessTeamDomain === undefined || /^[a-z0-9-]+\.cloudflareaccess\.com$/.test(p.accessTeamDomain), 'accessTeamDomain must be <team>.cloudflareaccess.com');
  for (const field of LICENSE_FIELDS) need(typeof p.license?.[field] === 'string' && p.license[field], `license.${field} is required`);
  const s = p.secrets ?? {};
  need(isRef(s.cloudflare), 'secrets.cloudflare must reference the Cloudflare API token');
  need(s.cloudflareZeroTrust === undefined || isRef(s.cloudflareZeroTrust), 'secrets.cloudflareZeroTrust must reference a token for Access and Tunnel');
  const required = { api: ['MAILSTACK_LICENSE', 'B2_KEY_ID', 'B2_APP_KEY'], backup: ['B2_KEY_ID', 'B2_APP_KEY', ...p.profile === 'c' ? [] : ['CLOUDFLARE_API_TOKEN']], panel: ['PANEL_NTFY_URL'] };
  for (const [group, names] of Object.entries(required)) {
    for (const name of names) need(isRef(s[group]?.[name]), `secrets.${group}.${name} is required`);
    for (const [name, ref] of Object.entries(s[group] ?? {})) need(/^[A-Z][A-Z0-9_]*$/.test(name) && isRef(ref), `secrets.${group}.${name} must be env:, file:, bw: or keystore:`);
  }
  return { ...p, stackDir: p.stackDir ?? `/opt/stacks/${p.instance}`, workerPanel: `${p.instance}-panel` };
}

export async function resolveSecret(ref, { env = process.env, readFile, run, repo = REPO }) {
  const [, kind, name] = /^(env|file|bw|keystore):(.+)$/.exec(ref ?? '') ?? [];
  if (!kind) throw new Error('Secret references must start with env:, file:, bw: or keystore:');
  const value = kind === 'env' ? env[name] : kind === 'file' ? await readFile(name)
    : kind === 'bw' ? await run('bw', ['get', 'password', name]) : await run(`${repo}local/keys.sh`, ['get', name]);
  const trimmed = (value ?? '').trim();
  if (!trimmed) throw new Error(`Secret ${kind}:${name} is empty`);
  return trimmed;
}

export const services = (profile, external = false) => ({ a: ['cloudflared', 'egress', 'backup'], b: ['panel', 'cloudflared', 'egress', 'backup'], c: ['api', 'panel', 'cloudflared', 'backup'] })[profile].filter(s => !external || s !== 'egress');

export function ingress(p) {
  const panel = { hostname: p.hosts.panel, service: 'https://panel:8090', originRequest: { originServerName: p.hosts.panel, noTLSVerify: true } };
  const egress = { hostname: p.hosts.egress, service: 'http://egress:8080' };
  const rules = { a: [egress], b: [panel, egress], c: [{ hostname: p.hosts.api, service: 'http://api:8080' }, panel] }[p.profile];
  return [...rules.filter(r => !p.externalEgress || r !== egress), { service: 'http_status:404' }];
}

const sha256 = value => createHash('sha256').update(value).digest('hex');

export function apiConfig(owner, p, generated, licenseKey) {
  const node = p.profile === 'c';
  const current = (owner.extensions ?? []).find(e => e.module === 'mailstack-pro' || e.module === NODE_EXTENSION);
  const options = { ...p.license, ...node ? { license: licenseKey, cachePath: '/data/license-cache.json' } : {}, webhooks: current?.options?.webhooks ?? { endpoints: [] } };
  const panel = { id: 'panel', tokenSha256: sha256(generated.PANEL_TOKEN), scopes: ['panel', 'webhooks:write'], brands: '*', templates: '*' };
  return {
    ...owner,
    clients: [...(owner.clients ?? []).filter(c => c.id !== 'panel'), panel],
    extensions: [...(owner.extensions ?? []).filter(e => e !== current), { module: node ? NODE_EXTENSION : 'mailstack-pro', options }],
  };
}

const GENERATED_API = ['API_KEY', 'ALTCHA_HMAC_KEY', 'CONTENT_PUBLIC_KEYS', 'INDEX_KEYS', 'TRANSIT_KEYS', 'PANEL_ASSERTION_KEYS', 'PRO_WEBHOOK_KEYS', 'TOMBSTONE_REGISTRY_ID'];

export function apiEnv(p, generated, user, ids) {
  const env = Object.fromEntries(GENERATED_API.map(k => [k, generated[k]]));
  Object.assign(env, { BACKUP_AGE_RECIPIENT: p.backup.ageRecipient, B2_ENDPOINT: p.backup.endpoint, B2_BUCKET: p.backup.bucket },
    p.backup.tombstonePrefix ? { TOMBSTONE_PREFIX: p.backup.tombstonePrefix } : {}, user.api);
  if (p.profile === 'c') {
    delete env.MAILSTACK_LICENSE;
    return { ...env, NODE_ENV: 'production', TRUSTED_PROXY: 'cloudflare', SES_REGION: p.sesRegion, ...p.sesConfigurationSet ? { SES_CONFIGURATION_SET: p.sesConfigurationSet } : {} };
  }
  return { ...env, EGRESS_KEYS: p.externalEgress ? user.egress.keys : generated.EGRESS_KEYS,
    EGRESS_ACCESS_CLIENT_ID: p.externalEgress ? user.egress.accessClientId : ids.egressToken.id,
    EGRESS_ACCESS_CLIENT_SECRET: p.externalEgress ? user.egress.accessClientSecret : ids.egressToken.secret };
}

export function releaseEnv(p, ids, configPath) {
  const b = p.profile === 'b';
  return {
    MAILSTACK_CONFIG: configPath, MAILSTACK_PRO_PATH: p.pro, MAILSTACK_WORKER_NAME: p.instance, MAILSTACK_D1_ID: ids.d1, MAILSTACK_D1_PREVIEW_ID: '',
    MAILSTACK_ROUTE: p.hosts.api, SES_REGION: p.sesRegion, SES_CONFIGURATION_SET: p.sesConfigurationSet, MAILSTACK_EGRESS_URL: p.externalEgress?.url ?? `https://${p.hosts.egress}`,
    MAILSTACK_INTERNAL_ROUTE: b ? p.hosts.internal : '', MAILSTACK_ACCESS_TEAM_DOMAIN: b ? ids.teamDomain : '', MAILSTACK_ACCESS_AUD: b ? ids.internalAud : '',
    // The installer checks /health itself through public DNS (see publicLookup), so the release skips its check.
    MAILSTACK_PANEL_AUDIENCE: b ? '' : p.hosts.internal, MAILSTACK_HEALTH_URL: '',
  };
}

export const panelWorkerEnv = (p, ids) => ({
  PANEL_WORKER_NAME: p.workerPanel, PANEL_WORKER_ROUTE: p.hosts.panel, PANEL_API_AUDIENCE: p.hosts.internal,
  PANEL_D1_ID: ids.panelD1, PANEL_API_WORKER: p.instance, PANEL_LICENSE_OPTIONS: JSON.stringify(p.license),
});

// Compose env files take single-quoted values literally; a quote or line break could not be represented.
function envFile(vars) {
  return Object.entries(vars).map(([k, v]) => {
    if (/['\n\r]/.test(v)) throw new Error(`${k} contains a quote or line break`);
    return /^[A-Za-z0-9_./:@,+-]*$/.test(v) ? `${k}=${v}` : `${k}='${v}'`;
  }).join('\n') + '\n';
}

export function serverFiles(p, { owner, generated, user, ids }) {
  const secret = content => ({ content, mode: 0o600 });
  const worker = p.profile !== 'c', panel = p.profile !== 'a';
  // Compose and the firewall name the egress bridges after this value; installations on one host must not share them.
  const compose = { COMPOSE_PROFILES: 'production', BUILD_CONTEXT: `${p.stackDir}/context`, PANEL_NTFY_URL: user.panel.PANEL_NTFY_URL,
    EGRESS_BRIDGE: `ms${sha256(p.instance).slice(0, 6)}` };
  if (panel) Object.assign(compose, { PANEL_ORIGIN: `https://${p.hosts.panel}`, API_AUDIENCE: worker ? p.hosts.internal : p.hosts.api,
    PANEL_API_ORIGIN: worker ? `https://${p.hosts.internal}` : 'http://api:8081' },
    worker ? { PANEL_API_ACCESS_ID_FILE: '/run/panel/access-id', PANEL_API_ACCESS_SECRET_FILE: '/run/panel/access-secret' } : {});
  if (worker && !p.externalEgress) compose.EGRESS_DENY_ZONES = ids.egressZone;
  const backup = { BACKUP_SOURCE: worker ? 'd1' : 'sqlite', B2_ENDPOINT: p.backup.endpoint, B2_BUCKET: p.backup.bucket,
    B2_KEY_ID: user.backup.B2_KEY_ID, B2_APP_KEY: user.backup.B2_APP_KEY, BACKUP_AGE_RECIPIENT: p.backup.ageRecipient };
  if (worker) Object.assign(backup, { BACKUP_D1_ID: p.profile === 'a' ? `${ids.d1},${ids.panelD1}` : ids.d1,
    CLOUDFLARE_ACCOUNT_ID: p.accountId, CLOUDFLARE_API_TOKEN: user.backup.CLOUDFLARE_API_TOKEN });
  const files = { '.env': secret(envFile(compose)), 'backup.env': secret(envFile(backup)), 'secrets/tunnel/token': secret(ids.tunnelToken) };
  if (worker && !p.externalEgress) files['secrets/egress/keys'] = secret(generated.EGRESS_KEYS);
  if (panel) Object.assign(files, {
    'secrets/panel/token': secret(generated.PANEL_TOKEN), 'secrets/panel/assertion': secret(generated.PANEL_ASSERTION_KEYS),
    'secrets/panel/license.json': secret(JSON.stringify({ ...p.license, license: user.api.MAILSTACK_LICENSE, cachePath: '/data/license-cache.json' })),
  });
  if (p.profile === 'b') Object.assign(files, { 'secrets/panel/access-id': secret(ids.panelToken.id), 'secrets/panel/access-secret': secret(ids.panelToken.secret) });
  if (p.profile === 'c') Object.assign(files, {
    'api.env': secret(envFile(apiEnv(p, generated, user, ids))),
    'config/api.json': secret(JSON.stringify(apiConfig(owner, p, generated, user.api.MAILSTACK_LICENSE), null, 2)),
  });
  return files;
}

/** dns.lookup replacement asking the given resolver (public DNS). The first query for a new custom domain can reach the
 * local resolver before the record exists; its negative answer is then cached for the zone's SOA minimum (30 min on
 * Cloudflare), which made a fresh install fail its health check although the Worker was serving. */
export const publicLookup = resolver => (host, options, callback) => {
  resolver.resolve4(host).then(addresses => options?.all
    ? callback(null, addresses.map(address => ({ address, family: 4 })))
    : callback(null, addresses[0], 4), callback);
};
