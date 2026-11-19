#!/usr/bin/env node
// Checks that every root-relative href/src in a built site resolves to a file.
//
// Usage: node scripts/check-links.mjs <distDir>
//
// Walks every .html under <distDir>, collects href="..." and src="..." values
// that start with "/", strips any "#fragment" and "?query", and resolves each
// to <dist>/<path>, <dist>/<path>/index.html or <dist>/<path>.html. Each
// missing target is printed as `BROKEN <page> -> <href>`; the final line is
// `N broken links` and the exit code is 1 if N > 0.
//
// One deliberate exception: links into the API reference (`/api/...`) are
// generated output (DocC, produced by scripts/site-api-docs.sh) and are not
// committed. When <dist>/api/index.html is absent the generator did not run,
// so those links are reported once as `SKIP /api/ (generator output absent)`
// and are not counted as broken. When it is present they are checked strictly.
//
// Zero dependencies: node:fs and node:path only.

import { readdirSync, statSync, readFileSync, existsSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';

const API_PREFIX = '/api/';
const ATTR_PATTERN = /\b(?:href|src)\s*=\s*"([^"]*)"/g;

function usage() {
  console.error('usage: node scripts/check-links.mjs <distDir>');
  process.exit(2);
}

function* htmlFiles(dir) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      yield* htmlFiles(full);
    } else if (name.endsWith('.html')) {
      yield full;
    }
  }
}

function targetPath(href) {
  let path = href;
  const hash = path.indexOf('#');
  if (hash !== -1) path = path.slice(0, hash);
  const query = path.indexOf('?');
  if (query !== -1) path = path.slice(0, query);
  return path;
}

function resolves(dist, path) {
  const decoded = decodeURIComponent(path);
  const base = join(dist, ...decoded.split('/').filter(Boolean));
  if (decoded.endsWith('/')) {
    return existsSync(join(base, 'index.html'));
  }
  return (
    existsSync(base) ||
    existsSync(join(base, 'index.html')) ||
    existsSync(`${base}.html`)
  );
}

function main() {
  const distArg = process.argv[2];
  if (!distArg) usage();
  const dist = resolve(distArg);
  if (!existsSync(dist) || !statSync(dist).isDirectory()) {
    console.error(`check-links: ${distArg} is not a directory`);
    process.exit(2);
  }

  const apiPresent = existsSync(join(dist, 'api', 'index.html'));
  let apiSkipped = false;
  let broken = 0;

  for (const file of htmlFiles(dist)) {
    const page = '/' + relative(dist, file).split(sep).join('/');
    const html = readFileSync(file, 'utf8');
    const seen = new Set();
    for (const match of html.matchAll(ATTR_PATTERN)) {
      const href = match[1];
      if (!href.startsWith('/') || href.startsWith('//')) continue;
      if (seen.has(href)) continue;
      seen.add(href);

      const path = targetPath(href);
      if (path === '' || path === '/') {
        if (!existsSync(join(dist, 'index.html'))) {
          console.log(`BROKEN ${page} -> ${href}`);
          broken++;
        }
        continue;
      }
      if (!apiPresent && (path === API_PREFIX || path.startsWith(API_PREFIX) || path === '/api')) {
        apiSkipped = true;
        continue;
      }
      if (!resolves(dist, path)) {
        console.log(`BROKEN ${page} -> ${href}`);
        broken++;
      }
    }
  }

  if (apiSkipped) console.log('SKIP /api/ (generator output absent)');
  console.log(`${broken} broken links`);
  process.exit(broken > 0 ? 1 : 0);
}

main();
