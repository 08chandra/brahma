// Tests for scripts/gen-module-facts.mjs against a hand-trimmed symbol-graph fixture
// (tests/fixtures/symbol-graphs): BrahmaCore with a struct + method in Work/, a class in a
// top-level file and an extension graph (a member in Util/ plus one synthesized symbol with
// no location); BrahmaKeychain with one enum; BrahmaApp with an empty graph; and a
// dependency graph (ArgumentParser) that must be ignored. Fixture paths use a fake `/Users/example/repo` checkout so the
// no-absolute-path rule is exercised.
//
// Run: npm test (node --test).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildFacts, repoRelative } from '../scripts/gen-module-facts.mjs';

const GRAPHS = fileURLToPath(new URL('./fixtures/symbol-graphs', import.meta.url));

function run() {
  const dir = mkdtempSync(join(tmpdir(), 'module-facts-'));
  const outFile = join(dir, 'generated', 'modules.json');
  const returned = buildFacts(GRAPHS, outFile);
  const text = readFileSync(outFile, 'utf8');
  return { returned, text, facts: JSON.parse(text), cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test('BrahmaCore Work area lists the repo-relative file and the type with its /api path', () => {
  const r = run();
  try {
    const work = r.facts.BrahmaCore.byArea.Work;
    assert.deepEqual(work.files, ['BrahmaCore/Work/Foo.swift']);
    assert.deepEqual(work.types, [
      { name: 'Foo', kind: 'struct', path: '/api/brahmacore/documentation/brahmacore/foo/' },
    ]);
  } finally {
    r.cleanup();
  }
});

test('top-level BrahmaCore files map to area Orchestrator', () => {
  const r = run();
  try {
    const orch = r.facts.BrahmaCore.byArea.Orchestrator;
    assert.deepEqual(orch.files, ['BrahmaCore/Orchestrator.swift']);
    assert.deepEqual(orch.types, [
      { name: 'Orchestrator', kind: 'class', path: '/api/brahmacore/documentation/brahmacore/orchestrator/' },
    ]);
  } finally {
    r.cleanup();
  }
});

test('extension graphs are merged: Util area kept, extension members are not types', () => {
  const r = run();
  try {
    const util = r.facts.BrahmaCore.byArea.Util;
    assert.deepEqual(util.files, ['BrahmaCore/Util/String+Shell.swift']);
    assert.deepEqual(util.types, []);
    assert.deepEqual(Object.keys(r.facts.BrahmaCore.byArea).sort(), ['Orchestrator', 'Util', 'Work']);
  } finally {
    r.cleanup();
  }
});

test('other modules have one area named for the module', () => {
  const r = run();
  try {
    assert.deepEqual(r.facts.BrahmaKeychain, {
      symbols: 1,
      byArea: {
        BrahmaKeychain: {
          symbols: 1,
          files: ['BrahmaKeychain/KeyStore.swift'],
          types: [
            { name: 'KeyStore', kind: 'enum', path: '/api/brahmakeychain/documentation/brahmakeychain/keystore/' },
          ],
        },
      },
    });
  } finally {
    r.cleanup();
  }
});

test('module count includes unlocated (synthesized) symbols; area counts only located ones', () => {
  const r = run();
  try {
    const core = r.facts.BrahmaCore;
    assert.equal(core.symbols, 5);
    assert.equal(core.byArea.Work.symbols, 2);
    assert.equal(core.byArea.Orchestrator.symbols, 1);
    assert.equal(core.byArea.Util.symbols, 1);
  } finally {
    r.cleanup();
  }
});

test('a module whose graphs hold no symbols is left out', () => {
  const r = run();
  try {
    assert.ok(!('BrahmaApp' in r.facts));
  } finally {
    r.cleanup();
  }
});

test('dependency graphs are ignored; only Brahma modules appear', () => {
  const r = run();
  try {
    assert.deepEqual(Object.keys(r.facts).sort(), ['BrahmaCore', 'BrahmaKeychain']);
    assert.ok(!r.text.includes('ArgumentParser'));
  } finally {
    r.cleanup();
  }
});

test('no absolute path, file URL or doc comment reaches the JSON', () => {
  const r = run();
  try {
    assert.ok(!r.text.includes('/Users/'), 'no /Users/ path');
    assert.ok(!r.text.includes('file:'), 'no file: URL');
    assert.ok(!r.text.includes('example/repo'), 'no checkout prefix');
    assert.ok(!r.text.includes('A unit of work'), 'no doc comment text');
  } finally {
    r.cleanup();
  }
});

test('buildFacts returns what it wrote', () => {
  const r = run();
  try {
    assert.deepEqual(r.returned, r.facts);
  } finally {
    r.cleanup();
  }
});

test('repoRelative strips everything through /Sources/ and rejects other paths', () => {
  assert.equal(
    repoRelative('file:///Users/example/repo/Sources/BrahmaCore/Work/Foo.swift', 'BrahmaCore'),
    'BrahmaCore/Work/Foo.swift',
  );
  assert.equal(
    repoRelative('file:///Users/example/my%20repo/Sources/BrahmaCore/Orchestrator+Merge.swift', 'BrahmaCore'),
    'BrahmaCore/Orchestrator+Merge.swift',
  );
  assert.equal(repoRelative('file:///Users/example/repo/Other/BrahmaCore/X.swift', 'BrahmaCore'), null);
  assert.equal(repoRelative('file:///Users/example/repo/Sources/BrahmaApp/X.swift', 'BrahmaCore'), null);
  assert.equal(repoRelative(undefined, 'BrahmaCore'), null);
});
