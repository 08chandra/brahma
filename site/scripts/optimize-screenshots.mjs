#!/usr/bin/env node
// Optimises the seven site screenshots taken by scripts/site-screenshots.sh.
//
// Usage: node scripts/optimize-screenshots.mjs <inDir> <outDir>
//   e.g. node scripts/optimize-screenshots.mjs ../.superpowers/ui public/screenshots
//
// For each name writes <outDir>/<name>.png (resized to at most 1600 px wide, PNG palette) and
// <outDir>/<name>@2x.png (original size, optimised). Fails if an input is missing or an output
// exceeds MAX_KB. Prints each output path and its size in KB.

import { existsSync, mkdirSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import sharp from 'sharp';

const NAMES = ['console', 'inbox', 'backlog', 'board', 'map', 'handbook', 'resources'];
const MAX_WIDTH = 1600;
const MAX_KB = 400;
const PNG = { palette: true, compressionLevel: 9, effort: 10 };

const [inDir, outDir] = process.argv.slice(2);
if (!inDir || !outDir) {
  console.error('usage: node scripts/optimize-screenshots.mjs <inDir> <outDir>');
  process.exit(2);
}

mkdirSync(outDir, { recursive: true });
let failed = false;

for (const name of NAMES) {
  const src = resolve(inDir, `${name}.png`);
  if (!existsSync(src) || statSync(src).size === 0) {
    console.error(`optimize-screenshots: missing or empty input: ${src}`);
    process.exit(1);
  }
  const outputs = [
    { path: join(outDir, `${name}.png`), pipeline: sharp(src).resize({ width: MAX_WIDTH, withoutEnlargement: true }) },
    { path: join(outDir, `${name}@2x.png`), pipeline: sharp(src) },
  ];
  for (const { path, pipeline } of outputs) {
    await pipeline.png(PNG).toFile(path);
    const kb = statSync(path).size / 1024;
    const over = kb > MAX_KB;
    if (over) failed = true;
    console.log(`${path}  ${kb.toFixed(0)} KB${over ? `  OVER ${MAX_KB} KB` : ''}`);
  }
}

if (failed) {
  console.error(`optimize-screenshots: an output exceeds ${MAX_KB} KB`);
  process.exit(1);
}
