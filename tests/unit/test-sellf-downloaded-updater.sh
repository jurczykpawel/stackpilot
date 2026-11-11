#!/usr/bin/env bash
# Verify Stackpilot hands its already-verified extraction to the release runner.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
node <<'NODE'
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const source = fs.readFileSync(path.join(process.env.REPO_ROOT, 'apps/sellf/update.sh'), 'utf8');
const block = source.slice(source.indexOf('# ----- SELLF DOWNLOADED UPDATER START -----'), source.indexOf('# ----- SELLF DOWNLOADED UPDATER END -----'));
for (const exit of [0, 9]) test(`downloaded runner owns the update and propagates exit ${exit}`, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'stackpilot-stage2-'));
  try {
    const extract = path.join(dir, 'extracted');
    fs.mkdirSync(path.join(extract, 'scripts'), { recursive: true });
    fs.mkdirSync(path.join(dir, 'release'));
    fs.mkdirSync(path.join(dir, 'bin'));
    fs.writeFileSync(path.join(extract, 'scripts/upgrade.sh'), `#!/bin/bash\n# sellf-upgrade-stage2:1\nprintf '%s\\n' "$@" > "$FIXTURE/captured"\nexit ${exit}\n`);
    // Test paths only; no host /run or real PM2 is touched.
    for (const [name, body] of Object.entries({id: 'echo 1000', cat: 'echo 11111111-1111-4111-8111-111111111111', pm2: 'exit 0', flock: 'exit 0'})) {
      fs.writeFileSync(path.join(dir, 'bin', name), '#!/bin/bash\n' + body + '\n', { mode: 0o755 });
    }
    const script = `set -euo pipefail\nRESTART_ONLY=false\nNEW_VERSION=2026.11.0\nPM2_NAME=sellf-fixture\nMSG_SELLF_UPDATE_LOCKED=locked\n${block}`;
    let status = 0;
    try { execFileSync('bash', ['-c', script], { env: { ...process.env, FIXTURE: dir, PATH: path.join(dir, 'bin') + ':' + process.env.PATH, INSTALL_DIR: path.join(dir, 'instance'), TEMP_DIR: extract, RELEASE_DIR: path.join(dir, 'release') } }); }
    catch (error) { status = error.status; }
    assert.equal(status, exit);
    const args = fs.readFileSync(path.join(dir, 'captured'), 'utf8').trim().split('\n');
    assert.equal(args[1], path.join(dir, 'instance/admin-panel'));
    assert.equal(args[2], '--apply-verified');
    assert.equal(args[4], 'v2026.11.0');
    assert.equal(args[6], 'sellf-fixture');
    assert.match(args[7], /sellf-upgrade-11111111.*\.json$/);
    assert.equal(fs.existsSync(args[3]), false, 'private extraction cleaned');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
NODE
