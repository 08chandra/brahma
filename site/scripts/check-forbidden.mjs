#!/usr/bin/env node
// Fails the build when the built site carries private content or forbidden branding.
//
// Usage: node scripts/check-forbidden.mjs <distDir>
//
// Scans every text file under <distDir> (.html .js .mjs .css .json .xml .txt .svg
// .webmanifest). Two groups of patterns:
//
//   private  — checked everywhere, including the generated API reference (dist/api/**):
//              build-machine paths (`/Users/`, `/var/folders/`, `/private/var/`,
//              `/private/tmp/`), `.superpowers`, the `BRAHMA_OWNER_KEY` token, email
//              addresses, and the login name of the user running the check
//              (`process.env.USER`, compared only — never printed; the check refuses to
//              run, exit 2, when USER is unset, so the name can never slip through).
//   public   — checked outside dist/api/** (DocC pages carry source doc comments verbatim;
//              the Task 6 review rules on those): the brand words `Palantir` and
//              `Anthropic` (case-sensitive, as written) and empty links (`href=""`).
//
// Every hit prints as `path:line: <pattern name>`; the matched text is never printed, so
// the report itself cannot leak what it found. The last line is `N forbidden strings`
// and the exit code is 1 if N > 0.
//
// Allow-list (controller rulings, Task 13). Each entry is an exact token, nothing wider:
//   - `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CONFIG_DIR`: factual
//     interop identifiers (environment variables the `claude` CLI reads), quoted in code
//     spans. Removed from a line before the brand-word patterns run.
//   - Email addresses that occur verbatim in Pagefind's vendored search UI
//     (node_modules/@pagefind/default-ui): translator credits shipped inside Starlight's
//     search bundle, third-party package content rather than site content. Only those
//     exact addresses pass; any other address fails, wherever it is.
//
// Zero dependencies: node:fs and node:path only.

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const TEXT_EXTENSIONS = new Set(['.html', '.htm', '.js', '.mjs', '.css', '.json', '.xml', '.txt', '.svg', '.webmanifest']);
const API_DIR = 'api';

// An address: local part, "@", one or more labels, a letters-only top-level label. A match
// directly after "/" is a URL path segment, not an address (`/screenshots/console@2x.png`).
const EMAIL = /(^|[^/A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})/g;

// Exact tokens removed before the brand-word patterns run (see the file comment).
const BRAND_ALLOWED_TOKENS = [
  'ANTHROPIC_API_KEY', // env var the `claude` CLI reads; interop identifier (controller ruling)
  'CLAUDE_CODE_OAUTH_TOKEN', // env var the `claude` CLI reads; interop identifier (controller ruling)
  'CLAUDE_CONFIG_DIR', // env var the `claude` CLI reads; interop identifier (controller ruling)
];

// Vendored Pagefind UI, the only sanctioned source of email addresses (see the file comment).
const PAGEFIND_UI_FILES = [
  'node_modules/@pagefind/default-ui/npm_dist/mjs/ui-core.mjs',
  'node_modules/@pagefind/default-ui/npm_dist/cjs/ui-core.cjs',
];

export const PRIVATE_PATTERNS = [
  { name: 'build-machine path (/Users/)', test: (line) => line.includes('/Users/') },
  // macOS temp dirs: $TMPDIR (/var/folders/<per-user id>/…) and the /private/… targets
  // of the /var and /tmp symlinks, which generators running in a temp data home print.
  { name: 'build-machine path (/var/folders/)', test: (line) => line.includes('/var/folders/') },
  { name: 'build-machine path (/private/var/)', test: (line) => line.includes('/private/var/') },
  { name: 'build-machine path (/private/tmp/)', test: (line) => line.includes('/private/tmp/') },
  { name: '.superpowers', test: (line) => line.includes('.superpowers') },
  // Whole token: `\b` treats "_" as a word character, so the documented environment
  // variable BRAHMA_OWNER_KEY_STORE (PlatformOwnerKeyStore.environmentVariable) is a
  // different token and does not match.
  { name: 'BRAHMA_OWNER_KEY', test: (line) => /\bBRAHMA_OWNER_KEY\b/.test(line) },
];

export const PUBLIC_PATTERNS = [
  { name: 'brand word: Palantir', test: (line) => line.includes('Palantir') },
  { name: 'brand word: Anthropic', test: (line) => stripAllowedTokens(line).includes('Anthropic') },
  { name: 'empty href', test: (line) => line.includes('href=""') },
];

export function stripAllowedTokens(line) {
  let out = line;
  for (const token of BRAND_ALLOWED_TOKENS) out = out.split(token).join('');
  return out;
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function loginNamePattern(user) {
  if (!user || user.trim() === '') return null;
  const re = new RegExp(`(^|[^A-Za-z0-9])${escapeRegExp(user)}(?![A-Za-z0-9])`, 'i');
  return { name: 'login name (USER)', test: (line) => re.test(line) };
}

export function emailPattern(allowedAddresses) {
  return {
    name: 'email address',
    test: (line) => {
      for (const match of line.matchAll(EMAIL)) {
        if (!allowedAddresses.has(match[2])) return true;
      }
      return false;
    },
  };
}

export function emailsIn(text) {
  const out = new Set();
  for (const match of text.matchAll(EMAIL)) out.add(match[2]);
  return out;
}

function loadPagefindAddresses(siteRoot) {
  const out = new Set();
  for (const rel of PAGEFIND_UI_FILES) {
    const file = join(siteRoot, rel);
    if (!existsSync(file)) continue;
    for (const address of emailsIn(readFileSync(file, 'utf8'))) out.add(address);
  }
  return out;
}

function* textFiles(dir) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      yield* textFiles(full);
    } else if (TEXT_EXTENSIONS.has(extname(name).toLowerCase())) {
      yield full;
    }
  }
}

// Scans one file's text. Returns [{ line, name }] for every (line, pattern) pair that hits.
export function scanText(text, { patterns }) {
  const hits = [];
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    for (const pattern of patterns) {
      if (pattern.test(lines[i])) hits.push({ line: i + 1, name: pattern.name });
    }
  }
  return hits;
}

export function patternsFor(relPath, { privatePatterns, publicPatterns }) {
  const inApi = relPath === API_DIR || relPath.startsWith(API_DIR + sep);
  return inApi ? privatePatterns : [...privatePatterns, ...publicPatterns];
}

function usage() {
  console.error('usage: node scripts/check-forbidden.mjs <distDir>');
  process.exit(2);
}

function main() {
  const distArg = process.argv[2];
  if (!distArg) usage();
  const dist = resolve(distArg);
  if (!existsSync(dist) || !statSync(dist).isDirectory()) {
    console.error(`check-forbidden: ${distArg} is not a directory`);
    process.exit(2);
  }
  const siteRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

  const privatePatterns = [...PRIVATE_PATTERNS, emailPattern(loadPagefindAddresses(siteRoot))];
  const login = loginNamePattern(process.env.USER);
  if (!login) {
    console.error('check-forbidden: USER is not set; the login-name check cannot run (set USER to the login name)');
    process.exit(2);
  }
  privatePatterns.push(login);

  let files = 0;
  let hits = 0;
  for (const file of textFiles(dist)) {
    files++;
    const rel = relative(dist, file);
    const patterns = patternsFor(rel, { privatePatterns, publicPatterns: PUBLIC_PATTERNS });
    for (const hit of scanText(readFileSync(file, 'utf8'), { patterns })) {
      console.log(`${rel.split(sep).join('/')}:${hit.line}: ${hit.name}`);
      hits++;
    }
  }
  console.log(`${hits} forbidden strings (${files} files scanned)`);
  process.exit(hits > 0 ? 1 : 0);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
