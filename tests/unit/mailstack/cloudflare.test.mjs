import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cloudflare } from '../../../apps/mailstack/cloudflare.mjs';

// In-memory Cloudflare API: just the endpoints the installer uses, with the documented response envelope.
function fakeApi() {
  const db = { d1: [], zones: [{ id: 'z1', name: 'example.com' }, { id: 'z2', name: 'example.net' }], tokens: [], apps: [], tunnels: [], dns: [], configs: {}, scripts: ['mailstack-test'], domains: [{ id: 'wd1', service: 'mailstack-test' }] };
  const calls = [];
  let n = 0;
  const ok = result => new Response(JSON.stringify({ success: true, errors: [], result }), { status: 200 });
  const fetch = async (url, init = {}) => {
    const { pathname, searchParams } = new URL(url), method = init.method ?? 'GET', body = init.body ? JSON.parse(init.body) : undefined;
    calls.push(`${method} ${pathname.replace('/client/v4/accounts/acc', '')}`);
    assert.equal(init.headers.authorization, 'Bearer tok');
    const p = pathname.replace('/client/v4', '');
    let m;
    // Like the live API (measured 2026-11-04): ?name= matches a substring, newest first.
    if (p === '/accounts/acc/d1/database') return method === 'GET' ? ok(db.d1.filter(d => d.name.includes(searchParams.get('name'))).reverse())
      : ok(db.d1[db.d1.push({ uuid: `d1-${++n}`, name: body.name }) - 1]);
    if ((m = p.match(/^\/accounts\/acc\/d1\/database\/(.+)$/))) { db.d1 = db.d1.filter(d => d.uuid !== m[1]); return ok(null); }
    if (p === '/zones') return ok(db.zones.filter(z => z.name === searchParams.get('name')));
    if (p === '/accounts/acc/access/organizations') return ok({ auth_domain: 'team.cloudflareaccess.com' });
    if (p === '/accounts/acc/access/service_tokens') return method === 'GET' ? ok(db.tokens)
      : ok({ ...db.tokens[db.tokens.push({ id: `t${++n}`, name: body.name, client_id: `cid${n}` }) - 1], client_secret: `sec${n}` });
    if ((m = p.match(/^\/accounts\/acc\/access\/service_tokens\/(.+?)(\/rotate)?$/))) {
      if (m[2]) return ok({ ...db.tokens.find(t => t.id === m[1]), client_secret: `rot${++n}` });
      db.tokens = db.tokens.filter(t => t.id !== m[1]); return ok(null);
    }
    if (p === '/accounts/acc/access/apps') return method === 'GET' ? ok(db.apps)
      : ok(db.apps[db.apps.push({ ...body, id: `app${++n}`, aud: `aud${n}` }) - 1]);
    if ((m = p.match(/^\/accounts\/acc\/access\/apps\/(.+)$/))) {
      if (method === 'DELETE') { db.apps = db.apps.filter(a => a.id !== m[1]); return ok(null); }
      const i = db.apps.findIndex(a => a.id === m[1]); db.apps[i] = { ...db.apps[i], ...body }; return ok(db.apps[i]);
    }
    if (p === '/accounts/acc/cfd_tunnel') return method === 'GET' ? ok(db.tunnels.filter(t => t.name === searchParams.get('name')))
      : ok(db.tunnels[db.tunnels.push({ id: `tun${++n}`, name: body.name, config_src: body.config_src }) - 1]);
    if ((m = p.match(/^\/accounts\/acc\/cfd_tunnel\/(.+?)\/(token|configurations|connections)$/))) {
      if (m[2] === 'token') return ok(`token-${m[1]}`);
      if (m[2] === 'configurations') { db.configs[m[1]] = body.config; return ok(body); }
      return ok(null);
    }
    if ((m = p.match(/^\/accounts\/acc\/cfd_tunnel\/(.+)$/))) { db.tunnels = db.tunnels.filter(t => t.id !== m[1]); return ok(null); }
    if ((m = p.match(/^\/zones\/(z\d)\/dns_records$/))) return method === 'GET' ? ok(db.dns.filter(r => r.zone === m[1] && r.name === searchParams.get('name')))
      : ok(db.dns[db.dns.push({ ...body, id: `r${++n}`, zone: m[1] }) - 1]);
    if ((m = p.match(/^\/zones\/z\d\/dns_records\/(.+)$/))) { db.dns = db.dns.filter(r => r.id !== m[1]); return ok(null); }
    if (p === '/accounts/acc/workers/domains') return ok(db.domains.filter(d => d.service === searchParams.get('service')));
    if ((m = p.match(/^\/accounts\/acc\/workers\/domains\/(.+)$/))) { db.domains = db.domains.filter(d => d.id !== m[1]); return ok(null); }
    if ((m = p.match(/^\/accounts\/acc\/workers\/scripts\/(.+)$/))) {
      if (!db.scripts.includes(m[1])) return new Response(JSON.stringify({ success: false, errors: [{ code: 10007, message: 'not found' }] }), { status: 404 });
      db.scripts = db.scripts.filter(s => s !== m[1]); return ok(null);
    }
    return new Response(JSON.stringify({ success: false, errors: [{ code: 1, message: `unexpected ${method} ${p}` }] }), { status: 400 });
  };
  return { db, calls, cf: cloudflare({ token: 'tok', account: 'acc', fetch }) };
}

test('N: D1 lookup takes the exact name, not a longer name containing it', async () => {
  const { db, cf } = fakeApi();
  const api = await cf.ensureD1('mailstack-test'), panel = await cf.ensureD1('mailstack-test-panel');
  assert.notEqual(api, panel, 'the panel database is created, not the API one reused');
  db.d1.push({ uuid: 'other', name: 'mailstack-test-preview' });
  assert.equal(await cf.ensureD1('mailstack-test'), api, 'rerun finds the API database');
  assert.equal(await cf.ensureD1('mailstack-test-panel'), panel);
  await cf.remove({ workers: [], d1: ['mailstack-test'], apps: [], tokens: [], hosts: [] });
  assert.deepEqual(db.d1.map(d => d.name).sort(), ['mailstack-test-panel', 'mailstack-test-preview'], 'uninstall removes only the exact database');
});

test('ensure functions create once and find on the second run', async () => {
  const { db, calls, cf } = fakeApi();
  const run = async (state = {}) => {
    const d1 = await cf.ensureD1('mailstack-test');
    const zone = await cf.zoneFor('egress.example.net');
    const token = await cf.ensureServiceToken('mailstack-test-egress', state.egress);
    const app = await cf.ensureAccessApp({ name: 'mailstack-test egress', domain: 'egress.example.net', serviceToken: token.tokenId });
    const tunnel = await cf.ensureTunnel('mailstack-test', [{ hostname: 'egress.example.net', service: 'http://egress:8080' }, { service: 'http_status:404' }]);
    await cf.ensureCname(zone.id, 'egress.example.net', `${tunnel.id}.cfargotunnel.com`);
    return { d1, zone, token, app, tunnel };
  };
  const first = await run();
  assert.equal(first.zone.name, 'example.net');
  assert.match(first.token.secret, /^sec/);
  assert.equal(first.tunnel.token, `token-${first.tunnel.id}`);
  assert.equal(db.apps[0].service_auth_401_redirect, true);
  assert.deepEqual(db.apps[0].policies.map(p => [p.decision, Object.keys(p.include[0])[0]]), [['non_identity', 'service_token']]);
  assert.equal(db.dns[0].proxied, true);
  const posts = calls.filter(c => c.startsWith('POST')).length;
  const second = await run({ egress: { id: first.token.id, secret: first.token.secret } });
  assert.equal(calls.filter(c => c.startsWith('POST')).length, posts, 'no second creation');
  assert.deepEqual([second.d1, second.tunnel.id, second.app.aud, second.token.secret], [first.d1, first.tunnel.id, first.app.aud, first.token.secret]);
  assert.equal(db.d1.length + db.tunnels.length + db.apps.length + db.tokens.length + db.dns.length, 5);
});

test('a lost token secret is rotated instead of creating a duplicate; identity apps admit only the owner', async () => {
  const { db, cf } = fakeApi();
  const first = await cf.ensureServiceToken('t');
  const again = await cf.ensureServiceToken('t');
  assert.equal(db.tokens.length, 1);
  assert.match(again.secret, /^rot/);
  assert.notEqual(again.secret, first.secret);
  await cf.ensureAccessApp({ name: 'panel', domain: 'panel.example.com', email: 'owner@example.com' });
  assert.deepEqual(db.apps[0].policies[0].include, [{ email: { email: 'owner@example.com' } }]);
  assert.equal(db.apps[0].session_duration, '8h');
  assert.equal(await cf.teamDomain(), 'team.cloudflareaccess.com');
});

test('ensureCname refuses to replace a record that does not point at a tunnel', async () => {
  const { db, cf } = fakeApi();
  db.dns.push({ id: 'r0', zone: 'z1', name: 'panel.example.com', type: 'A', content: '192.0.2.1' });
  await assert.rejects(cf.ensureCname('z1', 'panel.example.com', 'x.cfargotunnel.com'), /panel\.example\.com already has a DNS record/);
  assert.equal(db.dns.length, 1);
  await assert.rejects(cf.zoneFor('host.unknown.org'), /No Cloudflare zone/);
});

test('remove deletes everything it is given and tolerates already missing resources', async () => {
  const { db, cf } = fakeApi();
  const d1 = await cf.ensureD1('mailstack-test');
  const token = await cf.ensureServiceToken('tk');
  const app = await cf.ensureAccessApp({ name: 'x', domain: 'egress.example.net', serviceToken: token.tokenId });
  const tunnel = await cf.ensureTunnel('mailstack-test', [{ service: 'http_status:404' }]);
  await cf.ensureCname('z2', 'egress.example.net', `${tunnel.id}.cfargotunnel.com`);
  const spec = { workers: ['mailstack-test', 'mailstack-test-panel'], d1: ['mailstack-test', 'missing-db'], apps: ['egress.example.net'], tokens: ['tk'], tunnel: 'mailstack-test', hosts: ['egress.example.net'] };
  await cf.remove(spec);
  assert.deepEqual([db.d1, db.apps, db.tokens, db.tunnels, db.dns, db.scripts, db.domains].map(x => x.length), [0, 0, 0, 0, 0, 0, 0]);
  await cf.remove(spec);
  assert.ok(d1 && app);
});

test('API errors surface the Cloudflare message, never the token', async () => {
  const cf = cloudflare({ token: 'tok', account: 'acc', fetch: async () => new Response(JSON.stringify({ success: false, errors: [{ code: 9109, message: 'Unauthorized' }] }), { status: 403 }) });
  await assert.rejects(cf.ensureD1('x'), e => /9109 Unauthorized/.test(e.message) && !e.message.includes('tok'));
});
