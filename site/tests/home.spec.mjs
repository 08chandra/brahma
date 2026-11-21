// Browser tests for the Home page, the console hero and the designed 404.
// Plain node:test + Playwright Chromium; no test-runner package.
//
// Needs a built site served by `astro preview`. Run through `npm run test:ui`
// (scripts/test-ui.mjs starts the preview on port 4321, sets BASE_URL and stops it).
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';
import { site } from '../site.config.ts';

const heroData = JSON.parse(readFileSync(new URL('../src/data/hero-activity.json', import.meta.url), 'utf8'));

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:4321';
const url = (path) => new URL(path, BASE_URL).href;

let browser;
before(async () => {
  browser = await chromium.launch();
});
after(async () => {
  await browser?.close();
});

async function openPage(path, contextOptions = {}) {
  const context = await browser.newContext({ colorScheme: 'dark', ...contextOptions });
  const page = await context.newPage();
  const response = await page.goto(url(path), { waitUntil: 'domcontentloaded' });
  return { context, page, response };
}

// Lines of the hero feed a reader can see right now: inside the log window (not scrolled
// off the top or waiting below it), not hidden, not faded out.
function visibleHeroLines(page) {
  return page.evaluate(() => {
    const view = document.querySelector('[data-hero-state] [data-hero-viewport]').getBoundingClientRect();
    const lines = [...document.querySelectorAll('[data-hero-state] [data-hero-line]')];
    return lines.filter((el) => {
      const style = getComputedStyle(el);
      const box = el.getBoundingClientRect();
      const inside = box.top >= view.top - 1 && box.bottom <= view.bottom + 1;
      return inside && box.height > 0 && style.visibility !== 'hidden' && Number(style.opacity) > 0.5;
    }).length;
  });
}

test('home has no GitHub link while repoURL is empty', { skip: site.repoURL !== '' && 'repoURL is set' }, async () => {
  const { context, page } = await openPage('/');
  try {
    assert.equal(await page.locator('a[href=""]').count(), 0, 'no anchor with an empty href');
    assert.equal(await page.locator('a', { hasText: /github/i }).count(), 0, 'no anchor whose text mentions GitHub');
  } finally {
    await context.close();
  }
});

test('console hero honours reduced motion', async () => {
  const { context, page } = await openPage('/', { reducedMotion: 'reduce' });
  try {
    await page.waitForSelector('[data-hero-state="final"]', { timeout: 50 });
    await page.waitForTimeout(1000);
    assert.equal(await page.evaluate(() => window.__heroFrames), 0, 'no animation ticks under reduced motion');
    assert.equal(await page.getAttribute('[data-hero-state]', 'data-hero-state', { timeout: 2000 }), 'final');
  } finally {
    await context.close();
  }
});

test('console hero animates otherwise', async () => {
  const { context, page } = await openPage('/');
  try {
    await page.waitForTimeout(1500);
    const frames = await page.evaluate(() => window.__heroFrames);
    assert.ok(frames > 5, `expected more than 5 hero frames after 1.5 s, got ${frames}`);
    const lines = await visibleHeroLines(page);
    assert.ok(lines >= 6, `expected at least 6 visible hero lines, got ${lines}`);
  } finally {
    await context.close();
  }
});

test('console hero shows its final frame when JavaScript is off', async () => {
  const { context, page } = await openPage('/', { javaScriptEnabled: false });
  try {
    assert.equal(await page.getAttribute('[data-hero-state]', 'data-hero-state', { timeout: 2000 }), 'final');
    const total = await page.locator('[data-hero-state] [data-hero-line]').count();
    assert.equal(total, heroData.lines.length, 'the server renders every line');
    const shown = await visibleHeroLines(page);
    assert.ok(shown >= 6, `expected at least 6 lines in the window without JavaScript, got ${shown}`);
    const newestInWindow = await page.evaluate(() => {
      const view = document.querySelector('[data-hero-state] [data-hero-viewport]').getBoundingClientRect();
      const lines = document.querySelectorAll('[data-hero-state] [data-hero-line]');
      const box = lines[lines.length - 1].getBoundingClientRect();
      return box.top >= view.top - 1 && box.bottom <= view.bottom + 1;
    });
    assert.ok(newestInWindow, 'the window shows the newest line');
  } finally {
    await context.close();
  }
});

test('step commands have copy buttons that copy the command', async () => {
  const { context, page } = await openPage('/');
  try {
    await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE_URL });
    const buttons = page.locator('.step__copy');
    assert.equal(await buttons.count(), 4, 'one copy button per step');
    const first = buttons.first();
    assert.ok(await first.isVisible(), 'copy buttons are shown once the script runs');
    assert.match(await first.getAttribute('aria-label'), /^Copy command: /);
    await first.click();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), await first.getAttribute('data-copy'));
    const script = await page.evaluate(
      () => [...document.querySelectorAll('script:not([src])')].find((s) => s.textContent.includes('.step__copy')).textContent.trim().length,
    );
    assert.ok(script <= 520, `copy script is ${script} bytes`); // budget: a hand-written listener with a live region and a failure path, no library
  } finally {
    await context.close();
  }
});

test('copy buttons stay hidden when JavaScript is off', async () => {
  const { context, page } = await openPage('/', { javaScriptEnabled: false });
  try {
    assert.equal(await page.locator('.step__copy:visible').count(), 0);
  } finally {
    await context.close();
  }
});

test('404 renders the designed page', async () => {
  const { context, page, response } = await openPage('/does-not-exist');
  try {
    assert.equal(response.status(), 404);
    assert.match(await page.title(), /404/);
    assert.ok((await page.locator('main a[href="/"]').count()) > 0, 'links to the home page');
    assert.ok((await page.locator('main a[href="/start"], main a[href="/start/"]').count()) > 0, 'links to the quick start');
  } finally {
    await context.close();
  }
});
