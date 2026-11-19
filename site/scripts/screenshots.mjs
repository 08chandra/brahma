#!/usr/bin/env node
// Full-page screenshots of a running site at desktop (1440×900) and mobile (390×844)
// widths, plus a horizontal-overflow assertion on every page.
//
// Usage: node scripts/screenshots.mjs <baseURL> <outDir> [paths…]
//   e.g. node scripts/screenshots.mjs http://localhost:4321 .reports/task-2 / /styleguide/
//
// Writes <outDir>/<slug>-desktop.png and <outDir>/<slug>-mobile.png, where <slug> is the
// path with "/" replaced by "-" (leading/trailing dashes trimmed) and the root is `home`.
// On each page it asserts `document.documentElement.scrollWidth <= window.innerWidth`;
// if any page overflows, every offender is listed and the exit code is 1.
// Default paths: "/". Requires the `playwright` devDependency and Chromium
// (`npx playwright install chromium`).

import { mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { chromium } from 'playwright';

const VIEWPORTS = {
  desktop: { width: 1440, height: 900 },
  mobile: { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 },
};

function usage() {
  console.error('usage: node scripts/screenshots.mjs <baseURL> <outDir> [paths…]');
  process.exit(2);
}

export function slugFor(path) {
  const trimmed = path.replace(/^\/+|\/+$/g, '');
  return trimmed === '' ? 'home' : trimmed.replace(/\//g, '-');
}

async function main() {
  const [baseURL, outDir, ...rest] = process.argv.slice(2);
  if (!baseURL || !outDir) usage();
  const paths = rest.length > 0 ? rest : ['/'];
  const out = resolve(outDir);
  mkdirSync(out, { recursive: true });

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
  }

  if (offenders.length > 0) {
    console.error('\nHorizontal overflow on:');
    for (const o of offenders) console.error(`  ${o}`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
