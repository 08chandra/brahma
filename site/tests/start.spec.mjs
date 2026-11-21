// Browser tests for the quick start (/start): the install tabs, hash links, mobile width,
// empty links and the single-source rule (the page shows the quickstart files verbatim).
// Plain node:test + Playwright Chromium. Run through `npm run test:ui` (scripts/test-ui.mjs
// starts the preview on port 4321, sets BASE_URL and stops it).
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { chromium } from 'playwright';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:4321';
const url = (path) => new URL(path, BASE_URL).href;
const quickstart = (name) => readFileSync(new URL(`../src/content/quickstart/${name}`, import.meta.url), 'utf8');

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
  await page.goto(url(path), { waitUntil: 'domcontentloaded' });
  return { context, page };
}

const selected = (page) => page.getAttribute('[role="tab"][aria-selected="true"]', 'data-tab');
const visiblePanels = (page) =>
  page.$$eval('[data-panel]', (panels) => panels.filter((p) => !p.hidden && p.offsetHeight > 0).map((p) => p.id));

test('install tabs switch with a click and with ArrowRight', async () => {
  const { context, page } = await openPage('/start/');
  try {
    assert.equal(await page.getAttribute('[data-itabs] > div', 'role'), 'tablist');
    assert.equal(await selected(page), 'source', 'Build from source is selected by default');
    assert.deepEqual(await visiblePanels(page), ['source']);

    await page.click('[role="tab"][data-tab="installer"]');
    assert.equal(await selected(page), 'installer');
    assert.deepEqual(await visiblePanels(page), ['installer']);
    assert.match(new URL(page.url()).hash, /^#installer$/);

    await page.focus('[role="tab"][data-tab="installer"]');
    await page.keyboard.press('ArrowRight');
    assert.equal(await selected(page), 'source');
    assert.deepEqual(await visiblePanels(page), ['source']);
    assert.equal(await page.evaluate(() => document.activeElement.dataset.tab), 'source', 'focus follows the selection');
    await page.keyboard.press('ArrowRight');
    assert.equal(await selected(page), 'installer', 'ArrowRight wraps around');
    assert.deepEqual(
      await page.$$eval('[role="tab"]', (tabs) => tabs.map((t) => t.tabIndex)),
      [0, -1],
      'roving tabindex: only the selected tab is in the tab order',
    );
  } finally {
    await context.close();
  }
});

test('the #source and #installer hashes select their tab', async () => {
  for (const id of ['source', 'installer']) {
    const { context, page } = await openPage(`/start/#${id}`);
    try {
      assert.equal(await selected(page), id);
      assert.deepEqual(await visiblePanels(page), [id]);
    } finally {
      await context.close();
    }
  }
  const { context, page } = await openPage('/start/#installer');
  try {
    await page.click('#installer a[href="#source"]');
    await page.waitForFunction(() => document.querySelector('[role="tab"][data-tab="source"]').ariaSelected === 'true', null, {
      timeout: 2000,
    });
    assert.deepEqual(await visiblePanels(page), ['source'], 'the Installer panel links to the source tab');
  } finally {
    await context.close();
  }
});

test('without JavaScript both install panels show, stacked, and the tab strip stays hidden', async () => {
  const { context, page } = await openPage('/start/', { javaScriptEnabled: false });
  try {
    assert.deepEqual(await visiblePanels(page), ['installer', 'source']);
    assert.equal(await page.locator('[role="tablist"]').isVisible(), false);
  } finally {
    await context.close();
  }
});

test('no horizontal overflow at 390 px', async () => {
  const { context, page } = await openPage('/start/', {
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true,
  });
  try {
    await page.waitForLoadState('load');
    const { scrollWidth, innerWidth } = await page.evaluate(() => ({
      scrollWidth: document.documentElement.scrollWidth,
      innerWidth: window.innerWidth,
    }));
    assert.ok(scrollWidth <= innerWidth, `scrollWidth ${scrollWidth} > innerWidth ${innerWidth}`);
  } finally {
    await context.close();
  }
});

test('no empty links', async () => {
  const { context, page } = await openPage('/start/');
  try {
    assert.equal(await page.locator('a[href=""]').count(), 0);
  } finally {
    await context.close();
  }
});

test('the shell blocks are the quickstart files, verbatim', async () => {
  const { context, page } = await openPage('/start/');
  try {
    // Expressive Code keeps the source text for its copy button in data-code (lines joined by U+007F).
    const blocks = await page.$$eval('.expressive-code figure', (figures) =>
      figures.map((f) => ({
        title: f.querySelector('.title')?.textContent.trim() ?? '',
        code: f.querySelector('.copy button')?.dataset.code.replaceAll('\u007f', '\n') ?? '',
      })),
    );
    for (const name of ['build.sh', 'connect.sh', 'first-company.sh', 'run.sh', 'watch.sh']) {
      const block = blocks.find((b) => b.title === name);
      assert.ok(block, `a block titled ${name}`);
      assert.equal(block.code, quickstart(name).replace(/\n$/, ''), `${name} is shown as it is on disk`);
    }
  } finally {
    await context.close();
  }
});
