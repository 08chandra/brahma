// Tests for scripts/check-generated.mjs and scripts/all-pages.mjs on a synthetic dist/.
// Run: npm test (node --test).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { MIN_CLI_FILES, OG_CARDS, SCREENSHOTS, requirements } from '../scripts/check-generated.mjs';
import { allPages } from '../scripts/all-pages.mjs';

function touch(dist, rel) {
  const file = join(dist, ...rel.split('/'));
  mkdirSync(join(file, '..'), { recursive: true });
  writeFileSync(file, '');
}

function completeDist() {
  const dist = mkdtempSync(join(tmpdir(), 'gen-check-'));
  touch(dist, 'index.html');
  for (let i = 0; i < MIN_CLI_FILES; i++) touch(dist, `docs/cli/cmd${i}/index.html`);
  touch(dist, 'api/index.html');
  touch(dist, 'api/brahmacore/documentation/brahmacore/index.html');
  for (const name of SCREENSHOTS) {
    touch(dist, `screenshots/${name}.png`);
    touch(dist, `screenshots/${name}@2x.png`);
  }
  for (const name of OG_CARDS) touch(dist, `og/${name}.png`);
  return dist;
}

test('a complete dist satisfies every requirement', () => {
  const dist = completeDist();
  try {
    const reqs = requirements(dist);
    assert.equal(reqs.length, 1 + 2 + SCREENSHOTS.length * 2 + OG_CARDS.length);
    assert.deepEqual(reqs.filter((r) => !r.ok), []);
  } finally {
    rmSync(dist, { recursive: true, force: true });
  }
});

test('missing pieces are named individually and the CLI count is reported', () => {
  const dist = completeDist();
  try {
    rmSync(join(dist, 'screenshots', 'map@2x.png'));
    rmSync(join(dist, 'og', 'api.png'));
    rmSync(join(dist, 'docs', 'cli', 'cmd0'), { recursive: true });
    rmSync(join(dist, 'api', 'index.html'));
    const missing = requirements(dist).filter((r) => !r.ok).map((r) => r.label);
    assert.deepEqual(missing, [
      `docs/cli/: ${MIN_CLI_FILES - 1} files (need >= ${MIN_CLI_FILES})`,
      'api/index.html',
      'screenshots/map@2x.png',
      'og/api.png',
    ]);
  } finally {
    rmSync(dist, { recursive: true, force: true });
  }
});

test('the seven screenshots and five OG cards are the brief’s lists', () => {
  assert.deepEqual(SCREENSHOTS, ['backlog', 'board', 'console', 'handbook', 'inbox', 'map', 'resources']);
  assert.deepEqual(OG_CARDS, ['home', 'start', 'docs', 'internals', 'api']);
});

test('all-pages lists every index.html route except api/, sorted, root as "/"', () => {
  const dist = completeDist();
  try {
    touch(dist, 'start/index.html');
    touch(dist, 'docs/concepts/companies/index.html');
    touch(dist, '404.html');
    touch(dist, 'apiary/index.html');
    const routes = allPages(dist);
    assert.equal(routes[0], '/');
    assert.ok(routes.includes('/start/'));
    assert.ok(routes.includes('/docs/concepts/companies/'));
    assert.ok(routes.includes('/apiary/'));
    assert.ok(routes.includes('/docs/cli/cmd0/'));
    assert.equal(routes.some((r) => r.startsWith('/api/')), false);
    assert.equal(routes.includes('/404/'), false);
    assert.deepEqual(routes, [...routes].sort());
  } finally {
    rmSync(dist, { recursive: true, force: true });
  }
});
