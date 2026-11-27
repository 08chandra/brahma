#!/usr/bin/env node
// Serves a built site directory over plain HTTP on a free localhost port.
//
// The screenshot and Lighthouse scripts use this instead of `astro preview` so they
// never depend on, collide with or stop a preview server that something else started:
// the server runs inside the calling process and is closed by the caller, not by pid.
//
// Usage: node scripts/serve-dist.mjs [distDir]      (prints the URL; Ctrl-C stops it)
//   or:  import { serveDist } from './serve-dist.mjs';
//        const server = await serveDist('dist'); … await server.close();
//
// Routing mirrors static hosting: `/x/` → x/index.html; `/x` → x/index.html, else x.html
// (so `/404` → 404.html); anything else → 404.html with status 404 (plain text when there
// is no 404.html). Text responses are gzip-compressed when the client accepts it, like the
// production host, so Lighthouse measures what visitors get.

import { createServer } from 'node:http';
import { createReadStream, existsSync, statSync, readFileSync } from 'node:fs';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.wasm': 'application/wasm',
  '.webmanifest': 'application/manifest+json',
};
const COMPRESSIBLE = new Set(['.html', '.css', '.js', '.mjs', '.json', '.xml', '.txt', '.svg', '.webmanifest']);

function isFile(path) {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

// Maps a request path to a file under `root`, or null. Never escapes `root`.
export function resolveFile(root, urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath);
  } catch {
    return null;
  }
  const rel = normalize(decoded).replace(/^(\.\.(\/|\\|$))+/, '');
  const base = resolve(root, '.' + sep + rel);
  if (base !== root && !base.startsWith(root + sep)) return null;
  if (decoded.endsWith('/')) {
    const index = join(base, 'index.html');
    return isFile(index) ? index : null;
  }
  if (isFile(base)) return base;
  if (isFile(join(base, 'index.html'))) return join(base, 'index.html');
  if (isFile(`${base}.html`)) return `${base}.html`;
  return null;
}

export async function serveDist(distDir, port = 0) {
  const root = resolve(distDir);
  if (!existsSync(join(root, 'index.html'))) {
    throw new Error(`serve-dist: ${distDir} has no index.html; run \`npm run build\` first`);
  }
  const notFound = join(root, '404.html');

  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    let file = resolveFile(root, url.pathname);
    let status = 200;
    if (!file) {
      status = 404;
      if (!isFile(notFound)) {
        res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
        res.end('not found');
        return;
      }
      file = notFound;
    }
    const ext = extname(file).toLowerCase();
    const headers = { 'content-type': MIME[ext] ?? 'application/octet-stream', 'cache-control': 'no-store' };
    const gzip = COMPRESSIBLE.has(ext) && /\bgzip\b/.test(req.headers['accept-encoding'] ?? '');
    if (gzip) {
      const body = gzipSync(readFileSync(file));
      headers['content-encoding'] = 'gzip';
      headers['content-length'] = body.length;
      res.writeHead(status, headers);
      res.end(req.method === 'HEAD' ? undefined : body);
      return;
    }
    headers['content-length'] = statSync(file).size;
    res.writeHead(status, headers);
    if (req.method === 'HEAD') {
      res.end();
      return;
    }
    createReadStream(file).pipe(res);
  });

  await new Promise((ok, fail) => {
    server.once('error', fail);
    server.listen(port, '127.0.0.1', ok);
  });
  const address = server.address();
  return {
    port: address.port,
    baseURL: `http://127.0.0.1:${address.port}`,
    close: () =>
      new Promise((ok) => {
        server.closeAllConnections?.();
        server.close(() => ok());
      }),
  };
}

async function main() {
  const dir = process.argv[2] ?? 'dist';
  const server = await serveDist(dir);
  console.log(`serve-dist: ${resolve(dir)} at ${server.baseURL}/ (Ctrl-C to stop)`);
  const stop = async () => {
    await server.close();
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
