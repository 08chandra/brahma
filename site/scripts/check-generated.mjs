#!/usr/bin/env node
// Fails the build when the generators' output is missing from the built site.
//
// Usage: node scripts/check-generated.mjs <distDir>
//
// Requires, under <distDir>:
//   - at least 50 files under docs/cli/           (scripts/site-cli-docs.sh → CLI reference)
//   - api/index.html and
//     api/brahmacore/documentation/brahmacore/index.html
//                                                  (scripts/site-api-docs.sh → DocC reference)
//   - screenshots/<name>.png and <name>@2x.png for the seven app screenshots
//     backlog board console handbook inbox map resources
//                                                  (scripts/site-screenshots.sh)
//   - og/<name>.png for the five Open Graph cards home start docs internals api
//                                                  (scripts/gen-og.mjs — CARDS; keep in step)
//
// Prints one line per requirement (`ok` or `MISSING`), then `N missing`; exit 1 if N > 0.
// Zero dependencies: node:fs and node:path only.

import { existsSync, readdirSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const MIN_CLI_FILES = 50;
export const SCREENSHOTS = ['backlog', 'board', 'console', 'handbook', 'inbox', 'map', 'resources'];
export const OG_CARDS = ['home', 'start', 'docs', 'internals', 'api'];
export const API_PAGES = ['api/index.html', 'api/brahmacore/documentation/brahmacore/index.html'];

function countFiles(dir) {
  if (!existsSync(dir) || !statSync(dir).isDirectory()) return 0;
  let n = 0;
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    n += statSync(full).isDirectory() ? countFiles(full) : 1;
  }
  return n;
}

// Returns [{ label, ok }] for every requirement, in report order.
export function requirements(dist) {
  const out = [];
  const cliFiles = countFiles(join(dist, 'docs', 'cli'));
  out.push({ label: `docs/cli/: ${cliFiles} files (need >= ${MIN_CLI_FILES})`, ok: cliFiles >= MIN_CLI_FILES });
  for (const rel of API_PAGES) out.push({ label: rel, ok: existsSync(join(dist, rel)) });
  for (const name of SCREENSHOTS) {
    for (const file of [`${name}.png`, `${name}@2x.png`]) {
      out.push({ label: `screenshots/${file}`, ok: existsSync(join(dist, 'screenshots', file)) });
    }
  }
  for (const name of OG_CARDS) out.push({ label: `og/${name}.png`, ok: existsSync(join(dist, 'og', `${name}.png`)) });
  return out;
}

function usage() {
  console.error('usage: node scripts/check-generated.mjs <distDir>');
  process.exit(2);
}

function main() {
  const distArg = process.argv[2];
  if (!distArg) usage();
  const dist = resolve(distArg);
  if (!existsSync(dist) || !statSync(dist).isDirectory()) {
    console.error(`check-generated: ${distArg} is not a directory`);
    process.exit(2);
  }
  let missing = 0;
  for (const { label, ok } of requirements(dist)) {
    console.log(`${ok ? 'ok     ' : 'MISSING'} ${label}`);
    if (!ok) missing++;
  }
  console.log(`${missing} missing`);
  process.exit(missing > 0 ? 1 : 0);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
