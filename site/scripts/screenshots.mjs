#!/usr/bin/env node
// Full-page screenshots of a running site at desktop (1440×900) and mobile (390×844)
// widths, plus a horizontal-overflow assertion on every page.
//
// Usage: node scripts/screenshots.mjs <baseURL | --serve[=distDir]> <outDir> [paths… | -]
//   e.g. node scripts/screenshots.mjs http://localhost:4321 .reports/task-2 / /styleguide/
//        node scripts/screenshots.mjs --serve .screenshots/final / /start /404
//        node scripts/all-pages.mjs dist | node scripts/screenshots.mjs --serve .reports/screenshots -
//
// `--serve` (default directory `dist`) serves the built site itself on a free port
// (scripts/serve-dist.mjs) for the duration of the run, so no preview server is needed,
// relied on or touched. A single path argument `-` reads the paths from stdin, one per
// line (the output of scripts/all-pages.mjs).
//
// Writes <outDir>/<slug>-desktop.png and <outDir>/<slug>-mobile.png, where <slug> is the
// path with "/" replaced by "-" (leading/trailing dashes trimmed) and the root is `home`.
// On each page it asserts `document.documentElement.scrollWidth <= window.innerWidth`;
// if any page overflows, every offender is listed and the exit code is 1.
// Default paths: "/". Requires the `playwright` devDependency and Chromium
// (`npx playwright install chromium`).

import { mkdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { serveDist } from './serve-dist.mjs';

const siteRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

const VIEWPORTS = {
  desktop: { width: 1440, height: 900 },
  mobile: { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 },
};

function usage() {
  console.error('usage: node scripts/screenshots.mjs <baseURL | --serve[=distDir]> <outDir> [paths… | -]');
  process.exit(2);
}

function readPaths(rest) {
  if (rest.length === 1 && rest[0] === '-') {
    return readFileSync(0, 'utf8')
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line !== '');
  }
  return rest.length > 0 ? rest : ['/'];
}

export function slugFor(path) {
  const trimmed = path.replace(/^\/+|\/+$/g, '');
  return trimmed === '' ? 'home' : trimmed.replace(/\//g, '-');
}

async function main() {
  const [target, outDir, ...rest] = process.argv.slice(2);
  if (!target || !outDir) usage();
  const paths = readPaths(rest);
  if (paths.length === 0) {
    console.error('screenshots: no paths given');
    process.exit(2);
  }
  const out = resolve(outDir);
  mkdirSync(out, { recursive: true });

  let server = null;
  let baseURL = target;
  if (target === '--serve' || target.startsWith('--serve=')) {
    const distDir = target === '--serve' ? 'dist' : target.slice('--serve='.length);
    server = await serveDist(resolve(siteRoot, distDir));
    baseURL = server.baseURL;
    console.log(`screenshots: serving ${resolve(siteRoot, distDir)} at ${baseURL}`);
  }

  const browser = await chromium.launch();
  const offenders = [];
  try {
    for (const [name, viewport] of Object.entries(VIEWPORTS)) {
      const { isMobile, hasTouch, deviceScaleFactor, ...size } = viewport;
      const context = await browser.newContext({
        viewport: size,
        isMobile,
        hasTouch,
        deviceScaleFactor: deviceScaleFactor ?? 1,
        colorScheme: 'dark',
      });
      const page = await context.newPage();
      for (const path of paths) {
        const url = new URL(path, baseURL).href;
        const response = await page.goto(url, { waitUntil: 'networkidle' });
        if (!response || !response.ok()) {
          console.error(`screenshots: ${url} responded ${response ? response.status() : 'with no response'}`);
          process.exitCode = 1;
        }
        await page.evaluate(() => document.fonts.ready);
        // A full-page capture does not scroll, so `loading="lazy"` images below the fold
        // would come out blank: walk the page once so they load, then return to the top.
        await page.evaluate(async () => {
          for (let y = 0; y < document.documentElement.scrollHeight; y += window.innerHeight) {
            window.scrollTo(0, y);
            await new Promise((r) => setTimeout(r, 50));
          }
          window.scrollTo(0, 0);
        });
        await page.waitForLoadState('networkidle');
        const file = join(out, `${slugFor(path)}-${name}.png`);
        await page.screenshot({ path: file, fullPage: true, animations: 'disabled' });
        // Overflow check. The site clips the root (`overflow-x: clip`), which can hide a
        // too-wide layout from scrollWidth, so measure once as-is and once with the root
        // clip lifted, and name the widest element when something is too wide.
        const m = await page.evaluate(() => {
          const root = document.documentElement;
          const asIs = root.scrollWidth;
          const prev = [root.style.overflowX, document.body.style.overflowX];
          root.style.overflowX = 'visible';
          document.body.style.overflowX = 'visible';
          const unclipped = root.scrollWidth;
          let widest = { right: 0, desc: '' };
          for (const el of document.body.querySelectorAll('*')) {
            const rects = el.getClientRects();
            if (!rects.length) continue;
            const r = rects[rects.length - 1];
            if (r.right > widest.right) {
              widest = {
                right: r.right,
                desc: el.tagName.toLowerCase() + (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).join('.') : ''),
              };
            }
          }
          [root.style.overflowX, document.body.style.overflowX] = prev;
          return { innerWidth: window.innerWidth, scrollWidth: Math.max(asIs, unclipped), widest };
        });
        if (m.scrollWidth > m.innerWidth) {
          offenders.push(
            `${path} @ ${name}: scrollWidth ${m.scrollWidth} > innerWidth ${m.innerWidth} (widest: ${m.widest.desc} right=${Math.round(m.widest.right)})`
          );
        }
        console.log(`${file}  (${size.width}×${size.height}, scrollWidth ${m.scrollWidth}/${m.innerWidth})`);
      }
      await context.close();
    }
  } finally {
    await browser.close();
    if (server) await server.close();
  }

  if (offenders.length > 0) {
    console.error(`\nHorizontal overflow on ${offenders.length} page(s):`);
    for (const o of offenders) console.error(`  ${o}`);
    process.exit(1);
  }
  console.log(`screenshots: ${paths.length} page(s) × ${Object.keys(VIEWPORTS).length} viewports, no horizontal overflow`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
