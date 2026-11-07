import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

KEYS = {'internal': 'INTERNAL_SUBNET', 'egress-out': 'EGRESS_SUBNET'}
PRIVATE = [ipaddress.ip_network(cidr) for cidr in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]


def select_subnets(occupied, saved, egress=True):
    used = [ipaddress.ip_network(cidr, strict=False) for cidr in occupied]
    used = [net for net in used if net.version == 4 and net.prefixlen]
    chosen = {}
    for key in KEYS.values():
        if key not in saved:
            continue
        net = ipaddress.ip_network(saved[key])
        if net.version != 4 or not any(net.subnet_of(pool) for pool in PRIVATE):
            raise ValueError(f'{key} must be a private IPv4 subnet')
        blocked = used if egress or key != 'EGRESS_SUBNET' else [ipaddress.ip_network(v) for v in chosen.values()]
        if any(net.overlaps(other) for other in blocked):
            raise ValueError(f'{key} overlaps another network or host route')
        chosen[key] = str(net)
        used.append(net)
    for key in KEYS.values():
        if key not in chosen:
            net = next((n for n in ipaddress.ip_network('10.253.0.0/16').subnets(new_prefix=24)
                        if not any(n.overlaps(other) for other in used)), None)
            if net is None:
                raise ValueError('No free /24 in 10.253.0.0/16; configure two available private subnets')
            chosen[key] = str(net)
            used.append(net)
    return {key: chosen[key] for key in KEYS.values()}


def read_settings(path):
    lines = path.read_text().splitlines() if path.exists() else []
    return {k: v.strip("'\"") for line in lines if '=' in line
            for k, v in [line.split('=', 1)] if k in KEYS.values()}


def run(*args):
    return subprocess.check_output(args, text=True)


def configure(stack, project, egress=True):
    env = stack / '.env'
    saved = {**read_settings(stack / '.network-subnets'), **read_settings(env)}
    ids = run('docker', 'network', 'ls', '-q').split()
    networks = json.loads(run('docker', 'network', 'inspect', *ids)) if ids else []
    occupied, devices = [], {}
    for network in networks:
        labels = network.get('Labels') or {}
        key = KEYS.get(labels.get('com.docker.compose.network')) if labels.get('com.docker.compose.project') == project else None
        subnets = [c['Subnet'] for c in network['IPAM'].get('Config') or [] if c.get('Subnet') and ':' not in c['Subnet']]
        if key and subnets:
            egress = egress or key == 'EGRESS_SUBNET'
            if key in saved and saved[key] != subnets[0]:
                raise ValueError(f'{key} differs from the running network; migrate it explicitly first')
            saved[key] = subnets[0]
            bridge = (network.get('Options') or {}).get('com.docker.network.bridge.name') or 'br-' + network['Id'][:12]
            devices[bridge] = ipaddress.ip_network(subnets[0])
        else:
            occupied.extend(subnets)
    routes = json.loads(run('ip', '-j', '-4', 'route', 'show', 'table', 'all'))
    occupied.extend(r['dst'] for r in routes if r.get('dst', 'default') != 'default' and not
                    (r.get('dev') in devices and ipaddress.ip_network(r['dst'], strict=False).subnet_of(devices[r['dev']])))
    selected = select_subnets(occupied, saved, egress)
    settings = ''.join(f'{key}={value}\n' for key, value in selected.items())
    lines = [line for line in env.read_text().splitlines() if line.split('=', 1)[0] not in KEYS.values()]
    for path, content in [(stack / '.network-subnets', settings), (env, '\n'.join(lines) + '\n' + settings)]:
        fd, temporary = tempfile.mkstemp(dir=stack)
        with os.fdopen(fd, 'w') as out:
            out.write(content)
        os.replace(temporary, path)


if __name__ == '__main__':
    try:
        configure(Path(sys.argv[1]), sys.argv[2], 'egress' in sys.argv[3].split())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'Mailstack networks: {error}')
