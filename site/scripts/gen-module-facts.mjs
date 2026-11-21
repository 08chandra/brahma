#!/usr/bin/env node
// Module facts for the public site: turns the swiftc symbol graphs written by
// scripts/site-api-docs.sh into src/generated/modules.json, which
// src/components/ModuleFacts.astro renders as a "Public API" panel.
//
// Usage: node scripts/gen-module-facts.mjs <symbolGraphDir> <outFile> [<apiDir>]
//   e.g. node site/scripts/gen-module-facts.mjs .build/symbol-graphs site/src/generated/modules.json site/public/api
// With <apiDir> (the DocC output root), every type path is checked against the generated
// pages and the run fails if one is missing.
//
// Output shape:
//   { "<Module>": { "symbols": n,
//                   "byArea": { "<Area>": { "symbols": n, "files": [..], "types": [{ name, kind, path }] } } } }
// Only Brahma's own modules are read (MODULES); dependency graphs in the same directory are
// ignored, and so is a module whose graphs hold no symbols (scripts/site-api-docs.sh does not
// document it either). A module's main graph (<Module>.symbols.json) and its extension graphs
// (<Module>@<Other>.symbols.json) are merged. Areas: for BrahmaCore, the first directory under
// Sources/BrahmaCore/ (files directly in it map to "Orchestrator"); every other module is one
// area named for the module. `types` are the module's top-level types, linked to their DocC page.
//
// Privacy: symbol graphs carry absolute `file://` locations and doc comments. Only the
// repo-relative part of a location (everything after `/Sources/`) and symbol names/kinds are
// copied; a location outside `/Sources/<Module>/` is dropped, never copied.
//
// Zero dependencies: node:fs and node:path only.

import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const MODULES = [
  'BrahmaCore',
  'BrahmaAppModel',
  'BrahmaApp',
  'BrahmaMapKit',
  'BrahmaKeychain',
  'CSandboxCheck',
  'brahma',
];
const AREA_MODULE = 'BrahmaCore';
const TOP_LEVEL_AREA = 'Orchestrator';
const API_BASE = '/api';
const TYPE_KINDS = new Set(['struct', 'class', 'enum', 'protocol', 'actor', 'typealias']);

/**
 * The repo-relative path of a symbol location (`BrahmaCore/Work/Foo.swift`), or null when the
 * URI is not inside `/Sources/<module>/`.
 */
export function repoRelative(uri, module) {
  if (typeof uri !== 'string') return null;
  let path = uri.replace(/^file:\/\//, '');
  try {
    path = decodeURIComponent(path);
  } catch {
    return null;
  }
  const marker = `/Sources/${module}/`;
  const at = path.indexOf(marker);
  if (at === -1) return null;
  const rel = path.slice(at + '/Sources/'.length);
  if (rel.split('/').some((part) => part === '' || part === '.' || part === '..')) return null;
  return rel;
}

function areaOf(module, rel) {
  if (module !== AREA_MODULE) return module;
  const parts = rel.split('/'); // [BrahmaCore, <Area>?, ..., file]
  return parts.length > 2 ? parts[1] : TOP_LEVEL_AREA;
}

/** DocC's static-hosting URL for a top-level symbol of `module`. */
export function docPath(module, pathComponents) {
  const mod = module.toLowerCase();
  const slug = pathComponents.map((c) => encodeURIComponent(c.toLowerCase())).join('/');
  return `${API_BASE}/${mod}/documentation/${mod}/${slug}/`;
}

function graphFiles(graphDir, module) {
  return readdirSync(graphDir)
    .filter((name) => name === `${module}.symbols.json` || (name.startsWith(`${module}@`) && name.endsWith('.symbols.json')))
    .sort();
}

function moduleFacts(graphDir, module, files) {
  const seen = new Set();
  const areas = new Map();
  const area = (name) => {
    if (!areas.has(name)) areas.set(name, { symbols: 0, files: new Set(), types: [] });
    return areas.get(name);
  };
  for (const file of files) {
    const graph = JSON.parse(readFileSync(join(graphDir, file), 'utf8'));
    const isMain = file === `${module}.symbols.json`;
    for (const sym of graph.symbols ?? []) {
      const id = sym.identifier?.precise;
      if (!id || seen.has(id)) continue;
      seen.add(id);
      const rel = repoRelative(sym.location?.uri, module);
      if (!rel) continue;
      const a = area(areaOf(module, rel));
      a.symbols++;
      a.files.add(rel);
      const kind = String(sym.kind?.identifier ?? '').replace(/^swift\./, '');
      const path = sym.pathComponents ?? [];
      if (isMain && TYPE_KINDS.has(kind) && path.length === 1) {
        a.types.push({ name: path[0], kind, path: docPath(module, path) });
      }
    }
  }
  const byArea = {};
  for (const name of [...areas.keys()].sort()) {
    const a = areas.get(name);
    byArea[name] = {
      symbols: a.symbols,
      files: [...a.files].sort(),
      types: a.types.sort((x, y) => x.name.localeCompare(y.name)),
    };
  }
  return { symbols: seen.size, byArea };
}

/** Reads the Brahma module graphs in `graphDir`, writes `outFile`, returns the facts. */
export function buildFacts(graphDir, outFile) {
  const facts = {};
  for (const module of MODULES) {
    const files = graphFiles(graphDir, module);
    if (files.length === 0) continue;
    const mod = moduleFacts(graphDir, module, files);
    if (mod.symbols > 0) facts[module] = mod;
  }
  const text = `${JSON.stringify(facts, null, 2)}\n`;
  if (text.includes('/Users/') || text.includes('file:')) {
    throw new Error('gen-module-facts: refusing to write an absolute path');
  }
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, text);
  return facts;
}

/** Type paths in `facts` with no generated page under `apiDir` (the dir served at /api). */
export function missingPages(facts, apiDir) {
  const missing = [];
  for (const mod of Object.values(facts)) {
    for (const area of Object.values(mod.byArea)) {
      for (const t of area.types) {
        const rel = decodeURIComponent(t.path.slice(API_BASE.length));
        if (!existsSync(join(apiDir, ...rel.split('/').filter(Boolean), 'index.html'))) missing.push(t.path);
      }
    }
  }
  return missing;
}

function main() {
  const [graphDir, outFile, apiDir] = process.argv.slice(2);
  if (!graphDir || !outFile) {
    console.error('usage: node scripts/gen-module-facts.mjs <symbolGraphDir> <outFile> [<apiDir>]');
    process.exit(2);
  }
  const facts = buildFacts(resolve(graphDir), resolve(outFile));
  for (const [name, mod] of Object.entries(facts)) {
    const types = Object.values(mod.byArea).reduce((n, a) => n + a.types.length, 0);
    console.log(`module facts: ${name}: ${mod.symbols} symbols, ${Object.keys(mod.byArea).length} areas, ${types} types`);
  }
  if (apiDir) {
    const missing = missingPages(facts, resolve(apiDir));
    for (const p of missing) console.error(`gen-module-facts: no DocC page for ${p}`);
    if (missing.length > 0) process.exit(1);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
