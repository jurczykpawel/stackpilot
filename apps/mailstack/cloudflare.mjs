// Idempotent Cloudflare resources for a Mailstack installation: find by name/domain, create only when missing.
const API = 'https://api.cloudflare.com/client/v4';

export function cloudflare({ token, account, fetch = globalThis.fetch }) {
  async function call(method, path, body, { missingOk = false } = {}) {
    const res = await fetch(API + path, { method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: body && JSON.stringify(body) });
    const text = await res.text();
    if (res.ok && !text) return null; // e.g. DELETE /workers/domains/<id>: 200 with an empty body (measured)
    let json; try { json = JSON.parse(text); } catch { json = { success: false, errors: [{ code: res.status, message: res.statusText }] }; }
    if (json.success) return json.result;
    if (missingOk && res.status === 404) return null;
    throw new Error(`Cloudflare ${method} ${path.split('?')[0]}: ${(json.errors ?? []).map(e => `${e.code} ${e.message}`).join('; ')}`);
  }
  const acc = path => `/accounts/${account}${path}`;
  const q = encodeURIComponent;

  // The D1 list matches ?name= as a substring (measured): `mailstack` also returns mailstack-staging, mailstack-panel...
  const findD1 = async name => (await call('GET', acc(`/d1/database?name=${q(name)}`))).find(d => d.name === name);
  async function ensureD1(name) {
    const found = await findD1(name);
    return (found ?? await call('POST', acc('/d1/database'), { name })).uuid;
  }

  async function zoneFor(host) {
    const labels = host.split('.');
    for (let i = 0; i < labels.length - 1; i++) {
      const [zone] = await call('GET', `/zones?name=${q(labels.slice(i).join('.'))}`);
      if (zone) return { id: zone.id, name: zone.name };
    }
    throw new Error(`No Cloudflare zone in this account contains ${host}`);
  }

  const teamDomain = async () => (await call('GET', acc('/access/organizations'))).auth_domain;

  // Client secrets are returned once: a token whose secret is not in the state is rotated, never duplicated.
  async function ensureServiceToken(name, stored) {
    const found = (await call('GET', acc('/access/service_tokens'))).find(t => t.name === name);
    if (found && stored?.id === found.client_id && stored.secret) return { tokenId: found.id, id: found.client_id, secret: stored.secret };
    const result = found ? await call('POST', acc(`/access/service_tokens/${found.id}/rotate`)) : await call('POST', acc('/access/service_tokens'), { name, duration: '8760h' });
    return { tokenId: result.id, id: result.client_id, secret: result.client_secret };
  }

  async function ensureAccessApp({ name, domain, email, serviceToken }) {
    const policy = email
      ? { name: 'Owner', decision: 'allow', include: [{ email: { email } }], precedence: 1 }
      : { name: 'Service token', decision: 'non_identity', include: [{ service_token: { token_id: serviceToken } }], precedence: 1 };
    const body = { type: 'self_hosted', name, domain, destinations: [{ type: 'public', uri: domain }], app_launcher_visible: false,
      session_duration: email ? '8h' : '24h', ...email ? {} : { service_auth_401_redirect: true }, policies: [policy] };
    const found = (await call('GET', acc('/access/apps'))).find(a => a.domain === domain);
    const app = found ? await call('PUT', acc(`/access/apps/${found.id}`), body) : await call('POST', acc('/access/apps'), body);
    return { id: app.id, aud: app.aud };
  }

  async function ensureTunnel(name, rules) {
    const [found] = await call('GET', acc(`/cfd_tunnel?name=${q(name)}&is_deleted=false`));
    const tunnel = found ?? await call('POST', acc('/cfd_tunnel'), { name, config_src: 'cloudflare' });
    await call('PUT', acc(`/cfd_tunnel/${tunnel.id}/configurations`), { config: { ingress: rules } });
    return { id: tunnel.id, token: await call('GET', acc(`/cfd_tunnel/${tunnel.id}/token`)) };
  }

  async function ensureCname(zone, host, target) {
    const [found] = await call('GET', `/zones/${zone}/dns_records?name=${q(host)}`);
    if (found?.type === 'CNAME' && found.content === target) return;
    if (found && !(found.type === 'CNAME' && found.content.endsWith('.cfargotunnel.com')))
      throw new Error(`${host} already has a DNS record that does not point at a tunnel; remove it first`);
    if (found) await call('DELETE', `/zones/${zone}/dns_records/${found.id}`);
    await call('POST', `/zones/${zone}/dns_records`, { type: 'CNAME', name: host, content: target, proxied: true, ttl: 1 });
  }

  async function remove({ workers = [], d1 = [], apps = [], tokens = [], tunnel, hosts = [] }) {
    for (const name of workers) {
      for (const domain of await call('GET', acc(`/workers/domains?service=${q(name)}`))) await call('DELETE', acc(`/workers/domains/${domain.id}`));
      await call('DELETE', acc(`/workers/scripts/${q(name)}?force=true`), undefined, { missingOk: true });
    }
    for (const name of d1) {
      const found = await findD1(name);
      if (found) await call('DELETE', acc(`/d1/database/${found.uuid}`));
    }
    const appList = apps.length ? await call('GET', acc('/access/apps')) : [];
    for (const domain of apps) for (const app of appList.filter(a => a.domain === domain)) await call('DELETE', acc(`/access/apps/${app.id}`));
    const tokenList = tokens.length ? await call('GET', acc('/access/service_tokens')) : [];
    for (const name of tokens) for (const t of tokenList.filter(t => t.name === name)) await call('DELETE', acc(`/access/service_tokens/${t.id}`));
    for (const host of hosts) {
      const zone = await zoneFor(host);
      for (const r of await call('GET', `/zones/${zone.id}/dns_records?name=${q(host)}`))
        if (r.type === 'CNAME' && r.content.endsWith('.cfargotunnel.com')) await call('DELETE', `/zones/${zone.id}/dns_records/${r.id}`);
    }
    if (tunnel) for (const t of await call('GET', acc(`/cfd_tunnel?name=${q(tunnel)}&is_deleted=false`))) {
      await call('DELETE', acc(`/cfd_tunnel/${t.id}/connections`));
      await call('DELETE', acc(`/cfd_tunnel/${t.id}`));
    }
  }

  return { ensureD1, zoneFor, teamDomain, ensureServiceToken, ensureAccessApp, ensureTunnel, ensureCname, remove };
}
