#!/usr/bin/env node
// Generates the Open Graph images: public/og/{home,start,docs,internals,api}.png, 1200 × 630.
//
// Usage: npm run og            (output is gitignored; scripts/site-build.sh runs it before the build)
//
// Renders src/og/template.html?kicker=…&title=… in Playwright Chromium. The page is served
// from a local stand-in origin through request interception: the template, the site's
// tokens.css and the three woff2 faces from node_modules. Nothing touches the network.
// SiteHead points og:image at /og/<section>.png.
import { mkdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const ORIGIN = 'http://og.localhost';

export const CARDS = [
  { name: 'home', kicker: 'Mac app · brahma CLI', title: 'Run a company of AI agents on your Mac.' },
  { name: 'start', kicker: 'Quick start', title: 'From nothing to a running company.' },
  { name: 'docs', kicker: 'Using Brahma', title: 'Concepts, guides and the full CLI reference.' },
  { name: 'internals', kicker: 'Inside Brahma', title: 'How the engine, sandbox and app fit together.' },
  { name: 'api', kicker: 'API reference', title: 'Every public Swift symbol, generated with DocC.' },
];

const FILES = {
  '/template.html': ['src/og/template.html', 'text/html'],
  '/tokens.css': ['src/styles/tokens.css', 'text/css'],
  '/fonts/display.woff2': ['node_modules/@fontsource/instrument-serif/files/instrument-serif-latin-400-normal.woff2', 'font/woff2'],
  '/fonts/sans.woff2': ['node_modules/@fontsource-variable/inter/files/inter-latin-wght-normal.woff2', 'font/woff2'],
  '/fonts/mono.woff2': [
    'node_modules/@fontsource-variable/jetbrains-mono/files/jetbrains-mono-latin-wght-normal.woff2',
    'font/woff2',
  ],
};

async function main() {
  const out = join(root, 'public', 'og');
  mkdirSync(out, { recursive: true });
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
    await context.route('**/*', (route) => {
      const url = new URL(route.request().url());
      const file = url.origin === ORIGIN ? FILES[url.pathname] : undefined;
      if (!file) return route.abort();
      return route.fulfill({ status: 200, contentType: file[1], body: readFileSync(join(root, file[0])) });
    });
    const page = await context.newPage();
    for (const card of CARDS) {
      const query = new URLSearchParams({ kicker: card.kicker, title: card.title });
      await page.goto(`${ORIGIN}/template.html?${query}`, { waitUntil: 'load' });
      await page.evaluate(() => document.fonts.ready);
      const missing = await page.evaluate(() =>
        ['Instrument Serif', 'Inter Variable', 'JetBrains Mono Variable'].filter((f) => !document.fonts.check(`16px "${f}"`)),
      );
      if (missing.length) throw new Error(`og: fonts did not load: ${missing.join(', ')}`);
      const file = join(out, `${card.name}.png`);
      await page.screenshot({ path: file, clip: { x: 0, y: 0, width: 1200, height: 630 } });
      console.log(`og: ${file}`);
    }
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
