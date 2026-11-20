#!/usr/bin/env node
// Optimises the seven site screenshots taken by scripts/site-screenshots.sh.
//
// Usage: node scripts/optimize-screenshots.mjs <inDir> <outDir>
//   e.g. node scripts/optimize-screenshots.mjs ../.superpowers/ui public/screenshots
//
// For each name writes <outDir>/<name>.png (resized to at most 1600 px wide, PNG palette) and
// <outDir>/<name>@2x.png (original size, optimised). Fails if an input is missing, empty or not
// the expected 2560x1600, or if an output exceeds MAX_KB (the oversized files are deleted first).
// Prints each output path and its size in KB.
//
// Banner splice. The app shows its dev/demo startup notice ("BRAHMA_OWNER_KEY_STORE=file stores the
// hash in ...") whenever the file-backed stores are in use, which every snapshot home is. The notice
// sits in the detail pane under the toolbar; in the 2560x1600 snapshot (the 1280x800 window at 2x) its
// background is rows 140-221 and its bottom hairline rows 222-223, from x = 548 (right of the sidebar's
// border) to the right edge. The sidebar shares those rows (its selected row, the company rail), so only
// the pane is spliced: rows [140, 224) are dropped for x >= 548, the pane content below moves up 84 rows,
// and the vacated 84 rows at the pane's bottom are filled with the window background bg0 #0E1217 (which
// the pane already ends in, so the margin just continues). Title bar, toolbar, sidebar and the image
// dimensions are unchanged. Every input is probed first and the run fails if the banner is not exactly
// there. Set BRAHMA_SITE_SHOTS_KEEP_BANNER=1 to skip the splice (e.g. once the app has a presentation
// mode that hides the notice).

import { existsSync, mkdirSync, statSync, unlinkSync } from 'node:fs';
import { join, resolve } from 'node:path';
import sharp from 'sharp';

const NAMES = ['console', 'inbox', 'backlog', 'board', 'map', 'handbook', 'resources'];
const MAX_WIDTH = 1600;
const MAX_KB = 400;
const PNG = { palette: true, compressionLevel: 9, effort: 10 };

const SRC = { width: 2560, height: 1600 };
// Rows [top, bottom) are removed for x >= left; `rgb` is the banner background, probed at column `probeX`.
const BANNER = { top: 140, bottom: 224, left: 548, rgb: [49, 39, 31], probeX: 1200 };
const BG0 = { r: 14, g: 18, b: 23, alpha: 1 };
const KEEP_BANNER = process.env.BRAHMA_SITE_SHOTS_KEEP_BANNER === '1';

const [inDir, outDir] = process.argv.slice(2);
if (!inDir || !outDir) {
  console.error('usage: node scripts/optimize-screenshots.mjs <inDir> <outDir>');
  process.exit(2);
}

function fail(message) {
  console.error(`optimize-screenshots: ${message}`);
  process.exit(1);
}

// The input must be the snapshot size and, unless the splice is skipped, carry the banner at the expected rows.
async function checkInput(src) {
  const meta = await sharp(src).metadata();
  if (meta.width !== SRC.width || meta.height !== SRC.height) {
    fail(`${src} is ${meta.width}x${meta.height}, expected ${SRC.width}x${SRC.height}`);
  }
  if (KEEP_BANNER) return;
  const column = await sharp(src)
    .extract({ left: BANNER.probeX, top: BANNER.top, width: 1, height: BANNER.bottom - BANNER.top + 1 })
    .removeAlpha().raw().toBuffer();
  const rgbAt = (row) => [...column.subarray(row * 3, row * 3 + 3)];
  const isBanner = (row) => rgbAt(row).every((v, i) => v === BANNER.rgb[i]);
  const lastBg = BANNER.bottom - BANNER.top - 3; // row 221: the last background row above the hairline
  if (!isBanner(0) || !isBanner(lastBg) || isBanner(BANNER.bottom - BANNER.top)) {
    fail(`${src}: the dev/demo banner is not at rows ${BANNER.top}-${BANNER.bottom - 1} (x >= ${BANNER.left}); ` +
      `update BANNER in this script or set BRAHMA_SITE_SHOTS_KEEP_BANNER=1`);
  }
}

// The source with the banner rows spliced out of the detail pane (see the header).
async function spliceBanner(src) {
  const paneWidth = SRC.width - BANNER.left;
  const removed = BANNER.bottom - BANNER.top;
  const pane = await sharp(src)
    .extract({ left: BANNER.left, top: BANNER.bottom, width: paneWidth, height: SRC.height - BANNER.bottom })
    .png().toBuffer();
  return sharp(src).composite([
    { input: pane, left: BANNER.left, top: BANNER.top },
    { input: { create: { width: paneWidth, height: removed, channels: 4, background: BG0 } },
      left: BANNER.left, top: SRC.height - removed },
  ]).png().toBuffer();
}

mkdirSync(outDir, { recursive: true });
const oversized = [];

for (const name of NAMES) {
  const src = resolve(inDir, `${name}.png`);
  if (!existsSync(src) || statSync(src).size === 0) fail(`missing or empty input: ${src}`);
  await checkInput(src);
  const source = KEEP_BANNER ? src : await spliceBanner(src);
  const outputs = [
    { path: join(outDir, `${name}.png`), pipeline: sharp(source).resize({ width: MAX_WIDTH, withoutEnlargement: true }) },
    { path: join(outDir, `${name}@2x.png`), pipeline: sharp(source) },
  ];
  for (const { path, pipeline } of outputs) {
    await pipeline.png(PNG).toFile(path);
    const kb = statSync(path).size / 1024;
    const over = kb > MAX_KB;
    if (over) oversized.push(path);
    console.log(`${path}  ${kb.toFixed(0)} KB${over ? `  OVER ${MAX_KB} KB` : ''}`);
  }
}

if (oversized.length > 0) {
  for (const path of oversized) unlinkSync(path);
  fail(`${oversized.length} output(s) exceeded ${MAX_KB} KB and were deleted: ${oversized.join(', ')}`);
}
