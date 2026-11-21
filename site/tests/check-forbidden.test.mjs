// Tests for scripts/check-forbidden.mjs: the pattern groups, the allow-list and the
// api/ scoping, on text fragments. Run: npm test (node --test).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sep } from 'node:path';
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

test('private patterns: build-machine path, .superpowers and the BRAHMA_OWNER_KEY token', () => {
  const text = ['fine', 'see /Users/someone/x', 'kept in .superpowers/', 'BRAHMA_OWNER_KEY=abc'].join('\n');
  assert.deepEqual(names(scanText(text, { patterns: PRIVATE_PATTERNS })), [
    '2:build-machine path (/Users/)',
    '3:.superpowers',
    '4:BRAHMA_OWNER_KEY',
  ]);
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
