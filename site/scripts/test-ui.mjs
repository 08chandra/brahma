#!/usr/bin/env node
// Runs the browser tests (tests/*.spec.mjs) against the built site.
//
// Usage: npm run test:ui        (after `npm run build`)
//
// Starts `astro preview` on port 4321 (in the foreground, with --ignore-lock so a
// background preview of this project elsewhere neither blocks it nor is touched), waits until it answers, runs
// `node --test tests/*.spec.mjs` with BASE_URL set, then stops the preview it
// started. Exits with the test run's exit code. If something already listens on
// 4321 the run fails rather than testing a server it did not start.
import { spawn } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { createConnection } from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PORT = 4321;
const BASE_URL = `http://localhost:${PORT}`;
const root = join(dirname(fileURLToPath(import.meta.url)), '..');

function portInUse(port) {
  return new Promise((resolve) => {
    const socket = createConnection({ port, host: 'localhost' });
    socket.once('connect', () => {
      socket.destroy();
      resolve(true);
    });
    socket.once('error', () => resolve(false));
  });
}

async function waitForServer(deadline) {
  while (Date.now() < deadline) {
    try {
      const res = await fetch(BASE_URL);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`preview did not answer on ${BASE_URL} within the timeout`);
}

async function main() {
  if (!existsSync(join(root, 'dist', 'index.html'))) {
    console.error('test:ui: dist/ is missing; run `npm run build` first');
    process.exit(2);
  }
  if (await portInUse(PORT)) {
    console.error(`test:ui: port ${PORT} is already in use; stop that server first`);
    process.exit(2);
  }

  const astro = join(root, 'node_modules', '.bin', 'astro');
  const preview = spawn(astro, ['preview', '--port', String(PORT), '--ignore-lock'], {
    cwd: root,
    stdio: ['ignore', 'ignore', 'inherit'],
  });
  const stop = () => {
    if (preview.exitCode === null) preview.kill('SIGTERM');
  };
  process.on('exit', stop);
  process.on('SIGINT', () => process.exit(130));

  let code = 1;
  try {
    await waitForServer(Date.now() + 30_000);
    const specs = readdirSync(join(root, 'tests'))
      .filter((name) => name.endsWith('.spec.mjs'))
      .map((name) => join('tests', name));
    code = await new Promise((resolve) => {
      const run = spawn(process.execPath, ['--test', ...specs], {
        cwd: root,
        stdio: 'inherit',
        env: { ...process.env, BASE_URL },
      });
      run.on('exit', (status) => resolve(status ?? 1));
    });
  } catch (error) {
    console.error(`test:ui: ${error.message}`);
  } finally {
    stop();
  }
  process.exit(code);
}

main();
