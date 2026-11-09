#!/bin/bash
# Sellf updater passes dotenv values intact to PM2.
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
node <<'NODE'
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
test('update starts PM2 with intact JSON, PEM and quoted values', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sellf-update-env-'));
  try {
    const policy = JSON.stringify([{ templateId: 'storefront-a', pem: 'public\nkey\n' }]);
    fs.writeFileSync(path.join(dir, '.env.local'), `SELLF_TEMPLATE_LICENSE_POLICIES=${policy}\nQUOTED='a b = c'\nLITERAL=$(echo changed)\nPORT=4444\n`);
    fs.writeFileSync(path.join(dir, 'pm2'), '#!/bin/sh\nif [ "$1" = start ]; then node -e \'require("fs").writeFileSync("captured.json", JSON.stringify(process.env))\'; fi\n', {mode: 0o755});
    const script = fs.readFileSync(path.join(process.env.REPO_ROOT, 'apps/sellf/update.sh'), 'utf8');
    const start = script.slice(script.indexOf('unset HOSTNAME'), script.indexOf('pm2 save'));
    execFileSync('bash', ['-ec', start], {cwd: dir, env: {...process.env, PATH: `${dir}:${process.env.PATH}`, PM2_NAME: 'sellf-test'}});
    const env = JSON.parse(fs.readFileSync(path.join(dir, 'captured.json')));
    assert.equal(env.SELLF_TEMPLATE_LICENSE_POLICIES, policy);
    assert.equal(env.QUOTED, 'a b = c');
    assert.equal(env.LITERAL, '$(echo changed)');
    assert.equal(env.PORT, '4444');
    assert.equal(env.HOSTNAME, '::');
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});
NODE
