// Tests for scripts/check-forbidden.mjs: the pattern groups, the allow-list and the
// api/ scoping, on text fragments. Run: npm test (node --test).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  PRIVATE_PATTERNS,
  PUBLIC_PATTERNS,
  emailPattern,
  emailsIn,
  loginNamePattern,
  patternsFor,
  scanText,
  stripAllowedTokens,
} from '../scripts/check-forbidden.mjs';

const names = (hits) => hits.map((h) => `${h.line}:${h.name}`);

test('private patterns: build-machine paths, .superpowers and the BRAHMA_OWNER_KEY token', () => {
  const text = [
    'fine',
    'see /Users/someone/x',
    'kept in .superpowers/',
    'BRAHMA_OWNER_KEY=abc',
    'home /var/folders/ab/T/brahma-x',
    'under /private/tmp/brahma-qs.123',
    'or /private/var/folders/ab/T',
  ].join('\n');
  assert.deepEqual(names(scanText(text, { patterns: PRIVATE_PATTERNS })), [
    '2:build-machine path (/Users/)',
    '3:.superpowers',
    '4:BRAHMA_OWNER_KEY',
    '5:build-machine path (/var/folders/)',
    '6:build-machine path (/private/tmp/)',
    '7:build-machine path (/var/folders/)',
    '7:build-machine path (/private/var/)',
  ]);
  // The plain repository paths a page may name are not machine paths.
  assert.deepEqual(scanText('/tmp/x, /var/log, Sources/BrahmaCore, ~/Library', { patterns: PRIVATE_PATTERNS }), []);
});

test('BRAHMA_OWNER_KEY_STORE (the documented env var) is a different token and passes', () => {
  assert.deepEqual(scanText('BRAHMA_OWNER_KEY_STORE=file keeps the hash in a file', { patterns: PRIVATE_PATTERNS }), []);
});

test('brand words are case-sensitive and empty hrefs fail', () => {
  const text = ['an anthropic model', 'by Anthropic', 'Palantir style', '<a href="">x</a>'].join('\n');
  assert.deepEqual(names(scanText(text, { patterns: PUBLIC_PATTERNS })), [
    '2:brand word: Anthropic',
    '3:brand word: Palantir',
    '4:empty href',
  ]);
});

test('allow-listed interop tokens are removed before the brand-word check, nothing wider', () => {
  assert.equal(stripAllowedTokens('set ANTHROPIC_API_KEY and CLAUDE_CONFIG_DIR'), 'set  and ');
  assert.deepEqual(scanText('<code>ANTHROPIC_API_KEY</code> <code>CLAUDE_CODE_OAUTH_TOKEN</code>', { patterns: PUBLIC_PATTERNS }), []);
  assert.deepEqual(names(scanText('ANTHROPIC_API_KEY from Anthropic', { patterns: PUBLIC_PATTERNS })), ['1:brand word: Anthropic']);
});

test('email addresses fail unless on the vendored allow-list; URL path segments are not addresses', () => {
  const allowed = new Set(['jan@example.org']);
  const pattern = emailPattern(allowed);
  assert.equal(pattern.test('contact me@example.com'), true);
  assert.equal(pattern.test('<jan@example.org>'), false);
  assert.equal(pattern.test('srcset="/screenshots/console@2x.png 2x"'), false);
  assert.equal(pattern.test('mailto:owner@example.net'), true);
  assert.deepEqual([...emailsIn('a <x@y.io>, b <x@y.io>, c <q@r.st>')], ['x@y.io', 'q@r.st']);
});

test('login name matches as a whole word, case-insensitively, and is never part of the hit name', () => {
  const pattern = loginNamePattern('someuser');
  assert.equal(pattern.name, 'login name (USER)');
  assert.equal(pattern.test('/home/SomeUser/x'), true);
  assert.equal(pattern.test('someuser'), true);
  assert.equal(pattern.test('someusers'), false);
  assert.equal(pattern.test('awesomeuser'), false);
  assert.equal(loginNamePattern(''), null);
  assert.equal(loginNamePattern(undefined), null);
});

test('api/ files get only the private patterns; everything else gets both', () => {
  const groups = { privatePatterns: PRIVATE_PATTERNS, publicPatterns: PUBLIC_PATTERNS };
  assert.deepEqual(patternsFor(['api', 'x', 'index.html'].join(sep), groups), PRIVATE_PATTERNS);
  assert.deepEqual(patternsFor(['apix', 'index.html'].join(sep), groups), [...PRIVATE_PATTERNS, ...PUBLIC_PATTERNS]);
  assert.deepEqual(patternsFor('index.html', groups), [...PRIVATE_PATTERNS, ...PUBLIC_PATTERNS]);
});

test('the command fails (exit 2) when USER is unset, and passes a clean directory when it is set', () => {
  const script = join(dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'check-forbidden.mjs');
  const dist = mkdtempSync(join(tmpdir(), 'check-forbidden-'));
  try {
    writeFileSync(join(dist, 'index.html'), '<html><body>clean</body></html>\n');
    const env = { ...process.env };
    delete env.USER;
    const unset = spawnSync(process.execPath, [script, dist], { env, encoding: 'utf8' });
    assert.equal(unset.status, 2);
    assert.match(unset.stderr, /USER is not set/);
    const set = spawnSync(process.execPath, [script, dist], { env: { ...env, USER: 'someuser' }, encoding: 'utf8' });
    assert.equal(set.status, 0, set.stdout + set.stderr);
    assert.match(set.stdout, /^0 forbidden strings \(1 files scanned\)$/m);
  } finally {
    rmSync(dist, { recursive: true, force: true });
  }
});
