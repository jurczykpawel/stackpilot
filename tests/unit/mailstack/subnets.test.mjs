import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

const script = new URL('../../../apps/mailstack/network-subnets.py', import.meta.url).pathname;
const select = (occupied, saved = {}) => JSON.parse(execFileSync('python3', ['-B', '-c', `
import importlib.util,json,sys
spec=importlib.util.spec_from_file_location('subnets',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.select_subnets(**json.loads(sys.stdin.read()))))
`, script], { input: JSON.stringify({ occupied, saved }), encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }));

test('chooses two private /24 networks outside occupied Docker pools and host routes', () => {
  const occupied = Array.from({ length: 15 }, (_, n) => `172.${17 + n}.0.0/16`);
  occupied.push('10.253.0.0/23', '10.253.2.128/25', '0.0.0.0/0');
  assert.deepEqual(select(occupied), { INTERNAL_SUBNET: '10.253.3.0/24', EGRESS_SUBNET: '10.253.4.0/24' });
});
test('keeps saved subnets and allocates around them', () => {
  assert.deepEqual(select([], { EGRESS_SUBNET: '10.253.0.0/24' }), { INTERNAL_SUBNET: '10.253.1.0/24', EGRESS_SUBNET: '10.253.0.0/24' });
  const saved = { INTERNAL_SUBNET: '172.20.0.0/16', EGRESS_SUBNET: '172.31.250.0/24' };
  assert.deepEqual(select(['10.253.0.0/16'], saved), saved);
});
test('refuses overlap, invalid saved values and an exhausted pool', () => {
  for (const saved of [{ INTERNAL_SUBNET: '10.253.0.1/24' }, { EGRESS_SUBNET: '8.8.8.0/24' },
    { INTERNAL_SUBNET: '10.0.0.0/8', EGRESS_SUBNET: '10.253.0.0/24' }, { EGRESS_SUBNET: '10.253.0.0/24' }]) {
    assert.throws(() => select(['10.253.0.0/16'], saved));
  }
  assert.throws(() => select(['10.0.0.0/8']));
});

test('server inventory preserves live settings and rejects unavailable inventory', () => {
  execFileSync('python3', ['-B', '-c', `
import importlib.util,json,tempfile,pathlib,subprocess,sys
spec=importlib.util.spec_from_file_location('subnets',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as directory:
    stack=pathlib.Path(directory); env=stack/'.env'
    env.write_text('OTHER=unchanged\\n')
    networks=[{'Id':'abc123def456789', 'Labels':{'com.docker.compose.project':'demo','com.docker.compose.network':'internal'},'IPAM':{'Config':[{'Subnet':'172.30.0.0/16'}]}}]
    routes=[{'dst':'default'},{'dst':'172.30.0.0/16','dev':'br-abc123def456'}, {'dst':'10.253.0.0/24','dev':'eth0'}]
    def run(*args):
        if args[:3] == ('docker','network','ls'): return 'abc'
        return json.dumps(networks if args[0]=='docker' else routes)
    m.run=run; m.configure(stack,'demo')
    assert m.read_settings(env)=={'INTERNAL_SUBNET':'172.30.0.0/16','EGRESS_SUBNET':'10.253.1.0/24'}
    assert env.read_text().startswith('OTHER=unchanged\\n')
    env.write_text('OTHER=new\\n'); m.configure(stack,'demo')
    assert m.read_settings(env)['EGRESS_SUBNET']=='10.253.1.0/24'
    assert env.stat().st_mode & 0o077 == 0
    assert (stack/'.network-subnets').stat().st_mode & 0o077 == 0
    env.write_text(env.read_text()+'INTERNAL_SUBNET=10.253.9.0/24\\n')
    try: m.configure(stack,'demo'); raise AssertionError('expected changed live network refusal')
    except ValueError: pass
    env.write_text('OTHER=new\\nINTERNAL_SUBNET=172.30.0.0/16\\nEGRESS_SUBNET=10.253.1.0/24\\n')
    before=env.read_bytes()
    routes.append({'dst':'10.253.1.0/24','dev':'br-abc123def456'})
    try: m.configure(stack,'demo'); raise AssertionError('expected additional bridge route refusal')
    except ValueError: pass
    routes.pop()
    routes.append({'dst':'10.253.1.7/32','dev':'eth0'})
    try: m.configure(stack,'demo'); raise AssertionError('expected conflict')
    except ValueError: pass
    assert env.read_bytes()==before
    def fail(*args): raise subprocess.CalledProcessError(1,args)
    m.run=fail
    try: m.configure(stack,'demo'); raise AssertionError('expected inventory failure')
    except subprocess.CalledProcessError: pass
    assert env.read_bytes()==before
`, script], { stdio: 'pipe' });
});
