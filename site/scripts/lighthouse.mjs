#!/usr/bin/env node
// Runs Lighthouse on the built site and fails below the award bar.
//
// Usage: node scripts/lighthouse.mjs [distDir]        (default: dist; run `npm run build` first)
//
// Serves <distDir> itself (scripts/serve-dist.mjs — never `astro preview`, so a preview
// running elsewhere is neither relied on nor touched) and runs the pinned `lighthouse`
// CLI once per page and preset (mobile = Lighthouse's default emulation, desktop =
// `--preset=desktop`) on the pages below, with Playwright's Chromium: `CHROME_PATH` is
// set from `chromium.executablePath()` unless the caller already set it.
//
// Fails (exit 1) if any of performance, accessibility, best-practices or seo scores
// below 95 (0–100) on any run, or if cumulative layout shift (CLS) is above 0.
//
// Lighthouse numbers on a laptop carry noise: the first run after a cold Chromium start has
// been seen to report a long "Unattributable" main-thread task on an otherwise idle page.
// So one warm-up run of the first page is made and discarded, and a run that misses the
// bar is repeated once; the repeat is what counts, and the summary records both. A page
// that misses twice fails the gate.
//
// Writes to .reports/lighthouse/: <slug>-<preset>.json (the full Lighthouse result of the
// counted run) and summary.md (the table below plus, for every failing run, the audits
// that cost points).

import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { serveDist } from './serve-dist.mjs';
import { slugFor } from './screenshots.mjs';

export const PAGES = ['/', '/start', '/docs/concepts/companies/', '/docs/cli/', '/internals/architecture/'];
export const PRESETS = ['mobile', 'desktop'];
export const CATEGORIES = ['performance', 'accessibility', 'best-practices', 'seo'];
export const MIN_SCORE = 95;
export const MAX_CLS = 0;
const RUN_TIMEOUT_MS = 240_000;

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

function runLighthouse(url, preset, outFile, env) {
  const bin = join(root, 'node_modules', '.bin', 'lighthouse');
  const args = [
    url,
    '--output=json',
    `--output-path=${outFile}`,
    `--only-categories=${CATEGORIES.join(',')}`,
    '--chrome-flags=--headless=new --no-first-run --no-default-browser-check',
    '--quiet',
  ];
  if (preset === 'desktop') args.push('--preset=desktop');
  return new Promise((ok, fail) => {
    const child = spawn(bin, args, { cwd: root, env, stdio: ['ignore', 'inherit', 'inherit'] });
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      fail(new Error(`lighthouse ${preset} ${url} did not finish within ${RUN_TIMEOUT_MS / 1000}s`));
    }, RUN_TIMEOUT_MS);
    child.on('error', (error) => {
      clearTimeout(timer);
      fail(error);
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      if (code === 0) ok();
      else fail(new Error(`lighthouse ${preset} ${url} exited ${code}`));
    });
  });
}

// Reduces one Lighthouse JSON result to the numbers the gate judges.
export function summarize(result) {
  const scores = {};
  for (const id of CATEGORIES) {
    const score = result.categories?.[id]?.score;
    scores[id] = typeof score === 'number' ? Math.round(score * 100) : null;
  }
  const cls = result.audits?.['cumulative-layout-shift']?.numericValue ?? null;
  return { scores, cls };
}

// Names what misses the bar: ["performance 91 < 95", "CLS 0.012 > 0"].
export function failures({ scores, cls }) {
  const out = [];
  for (const id of CATEGORIES) {
    if (scores[id] === null || scores[id] < MIN_SCORE) out.push(`${id} ${scores[id] ?? 'n/a'} < ${MIN_SCORE}`);
  }
  if (cls === null || cls > MAX_CLS) out.push(`CLS ${cls === null ? 'n/a' : cls} > ${MAX_CLS}`);
  return out;
}

// Audits in the given categories that scored below 1 (or are informative with items), by id.
export function costlyAudits(result, categoryIds) {
  const out = [];
  for (const id of categoryIds) {
    for (const ref of result.categories?.[id]?.auditRefs ?? []) {
      const audit = result.audits?.[ref.id];
      if (!audit) continue;
      if (audit.scoreDisplayMode === 'binary' || audit.scoreDisplayMode === 'numeric' || audit.scoreDisplayMode === 'metricSavings') {
        if (audit.score !== null && audit.score < 1) {
          out.push(`${id}: ${ref.id} (score ${audit.score}${audit.displayValue ? `, ${audit.displayValue}` : ''})`);
        }
      }
    }
  }
  return out;
}

export function table(rows) {
  const lines = ['| Page | Preset | Performance | Accessibility | Best practices | SEO | CLS |', '| --- | --- | ---: | ---: | ---: | ---: | ---: |'];
  for (const row of rows) {
    const s = row.scores;
    lines.push(`| \`${row.page}\` | ${row.preset} | ${s.performance ?? 'n/a'} | ${s.accessibility ?? 'n/a'} | ${s['best-practices'] ?? 'n/a'} | ${s.seo ?? 'n/a'} | ${row.cls ?? 'n/a'} |`);
  }
  return lines.join('\n');
}

async function main() {
  const distDir = resolve(root, process.argv[2] ?? 'dist');
  const reports = join(root, '.reports', 'lighthouse');
  mkdirSync(reports, { recursive: true });

  const env = { ...process.env };
  if (!env.CHROME_PATH) env.CHROME_PATH = chromium.executablePath();

  const server = await serveDist(distDir);
  console.log(`lighthouse: serving ${distDir} at ${server.baseURL}`);
  const rows = [];
  const failing = [];
  const retried = [];
  const measure = async (page, preset, outFile) => {
    await runLighthouse(new URL(page, server.baseURL).href, preset, outFile, env);
    const result = JSON.parse(readFileSync(outFile, 'utf8'));
    if (result.runtimeError) throw new Error(`lighthouse ${preset} ${page}: ${result.runtimeError.message}`);
    return result;
  };
  const describe = ({ scores: s, cls }) => `perf ${s.performance} a11y ${s.accessibility} bp ${s['best-practices']} seo ${s.seo} cls ${cls}`;
  try {
    console.log(`lighthouse: warm-up ${PRESETS[0]} ${PAGES[0]} (discarded)`);
    await measure(PAGES[0], PRESETS[0], join(reports, 'warm-up.json'));
    for (const page of PAGES) {
      for (const preset of PRESETS) {
        const outFile = join(reports, `${slugFor(page)}-${preset}.json`);
        console.log(`lighthouse: ${preset} ${page}`);
        let result = await measure(page, preset, outFile);
        let summary = summarize(result);
        let misses = failures(summary);
        console.log(`  ${describe(summary)}${misses.length ? `  MISS ${misses.join('; ')}` : ''}`);
        if (misses.length) {
          const first = summary;
          console.log(`lighthouse: ${preset} ${page} (repeat)`);
          result = await measure(page, preset, outFile);
          summary = summarize(result);
          misses = failures(summary);
          console.log(`  ${describe(summary)}${misses.length ? `  FAIL ${misses.join('; ')}` : ''}`);
          retried.push({ page, preset, first, second: summary });
        }
        rows.push({ page, preset, ...summary });
        if (misses.length) {
          const s = summary.scores;
          const failedCategories = CATEGORIES.filter((id) => s[id] === null || s[id] < MIN_SCORE);
          if (summary.cls === null || summary.cls > MAX_CLS) failedCategories.push('performance');
          failing.push({ page, preset, misses, audits: costlyAudits(result, [...new Set(failedCategories)]) });
        }
      }
    }
  } finally {
    await server.close();
  }

  const lines = [
    '# Lighthouse',
    '',
    `Lighthouse ${JSON.parse(readFileSync(join(root, 'node_modules', 'lighthouse', 'package.json'), 'utf8')).version}, ` +
      `${new Date().toISOString()}. Bar: every category >= ${MIN_SCORE}, CLS <= ${MAX_CLS}.`,
    '',
    table(rows),
    '',
  ];
  if (retried.length) {
    lines.push('## Repeated runs', '', 'These runs missed the bar once and were repeated; the table shows the repeat.', '');
    for (const r of retried) lines.push(`- \`${r.page}\` ${r.preset}: first ${describe(r.first)}; repeat ${describe(r.second)}`);
    lines.push('');
  }
  if (failing.length) {
    lines.push('## Below the bar', '');
    for (const f of failing) {
      lines.push(`- \`${f.page}\` ${f.preset}: ${f.misses.join('; ')}`);
      for (const audit of f.audits) lines.push(`  - ${audit}`);
    }
    lines.push('');
  } else {
    lines.push('All runs meet the bar.', '');
  }
  writeFileSync(join(reports, 'summary.md'), lines.join('\n'));
  console.log(`\n${table(rows)}\n`);
  console.log(`lighthouse: wrote ${join(reports, 'summary.md')}`);
  if (failing.length) {
    console.error(`lighthouse: ${failing.length} of ${rows.length} runs below the bar:`);
    for (const f of failing) {
      console.error(`  ${f.page} ${f.preset}: ${f.misses.join('; ')}`);
      for (const audit of f.audits) console.error(`    ${audit}`);
    }
    process.exit(1);
  }
  console.log(`lighthouse: ${rows.length}/${rows.length} runs meet the bar`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.message ?? error);
    process.exit(1);
  });
}
