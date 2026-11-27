#!/usr/bin/env node
// Lists every page route of a built site, one per line, for the screenshot sweep.
//
// Usage: node scripts/all-pages.mjs <distDir>
//   e.g. node scripts/all-pages.mjs dist | node scripts/screenshots.mjs --serve .reports/screenshots -
//
// A route is the directory of each <distDir>/**/index.html, as `/dir/` (the root is `/`),
// sorted. The generated API reference (api/**) is excluded: DocC pages are not ours to
// restyle and number in the thousands. Zero dependencies.

import { existsSync, readdirSync, statSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export function allPages(dist) {
  const routes = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const full = join(dir, name);
      if (statSync(full).isDirectory()) {
        if (dir === dist && name === 'api') continue;
        walk(full);
      } else if (name === 'index.html') {
        const rel = relative(dist, dir).split(sep).filter(Boolean).join('/');
        routes.push(rel === '' ? '/' : `/${rel}/`);
      }
    }
  };
  walk(dist);
  return routes.sort();
}

function main() {
  const distArg = process.argv[2];
  if (!distArg) {
    console.error('usage: node scripts/all-pages.mjs <distDir>');
    process.exit(2);
  }
  const dist = resolve(distArg);
  if (!existsSync(dist) || !statSync(dist).isDirectory()) {
    console.error(`all-pages: ${distArg} is not a directory`);
    process.exit(2);
  }
  for (const route of allPages(dist)) console.log(route);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
