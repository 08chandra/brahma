---
title: Memory
description: One search index over everything the company knows, filtered by who may read it. What is indexed, how agents search and remember, who can read what, session taint, and replay.
sidebar:
  order: 9
---

## What it is

Agents and you can find anything the company already knows. One search index covers every source: messages, items, asks, hand-offs, retros, handbook pages, resources and remembered facts. The engine filters every result to what the reader may see before anything reaches an agent.

Ingest, ranking, auto pages, replay and the storage meter are plain code. None of it runs an agent turn.

## How it works

**What is indexed.** The engine indexes these on its tick, in batches (a restore re-scans everything):

- messages in channels and DMs;
- work items: description, acceptance criteria, submit summary and the newest `50` comments;
- asks and their decisions, and mechanically recorded decisions;
- hand-offs under `.brahma/handoffs`;
- sprint retros;
- handbook pages, one entry per section;
- resources: the text of text files up to `2 MB`, first `200 000` characters; other kinds by name only;
- remembered facts and episodes. At the end of each successful work, notice or review turn, the engine writes an episode from the turn's summary into that agent's private memory.

**How agents use it.** `search_memory` returns cited snippets. `recall(ref: …)` reads one entry in full. Refs are `mem:12`, `F-3`, `ENG-7`, `kb:Path`, `A-4`, `msg:<id>`, `handoff:…`, `sprint:<n>` and `decision:<id>`. `recall(query: …)` searches the agent's own remembered facts and past work. `remember` saves a durable fact: the same key with the same fact confirms it, and a different fact under the same key is kept as a contradiction. Nothing is deleted. A fact that looks like a secret, or holds a stored secret's value, is refused.

**Who can read what.** You read everything. For an agent:

| Where it came from | Who reads it |
| --- | --- |
| A channel or DM message | the channel's or DM's members |
| A resource dropped in a channel or DM | the members when it was dropped |
| A company-wide source (items, decisions, hand-offs, retros, company facts, the handbook, company resources) | every agent in the company |
| A team (a fact with scope `team`, a team resource) | that team, and managers whose subtree contains it |
| A role | agents holding that role |
| A fact with scope `item` | the item's author, owner, lease holder and reviewer, and every manager up the owner's chain, worked out at each read |
| A resource scoped to an item | a fixed set taken when it is added: the item's owner, lease holder and reviewer, the owner's manager, and the agent that wrote the item |
| An agent's private memory (scope `mine`, episodes) | that agent in full; its managers see the title only |
| An ask | the agent that filed it, its internal approver and an agent that decided it. Your answer and notes are yours alone |
| HR or performance records, and anything owner-only | you alone |

A handbook section marked `[restricted]` is for executives only, and `[restricted: cfo, cto]` for those roles. A hit you cannot read is not returned at all: no snippet, no title and no count. Every query is bound to one company.

These rules are enforced by Brahma's tools. Only the Sandboxed profile enforces them fully: on Workspace and Full, an agent's shell runs as your user and can read the data home directly.

**Session taint.** Once an agent's session reads outside content (a web page, an EXTERNAL resource, a tainted page or fact), everything it writes in that session is marked tainted: facts, handbook edits, messages and hand-offs. Tainted hits show without a snippet. Only you clear taint, by vouching for a page or resource, or by a whole-page edit of your own.

**Replay.** Replay shows what an agent did on one day, or an item's whole history. It is computed on each read and shows at most `2000` lines of up to `300` characters each. A purged resource shows only `[purged F-n]`, and a link never shows its URL.

## In the app

**Work › Handbook** has a **MEMORY** tab for remembered facts and episodes, with `CONTRADICTED` and `TAINTED` chips. Replay is the **REPLAY** tab of an agent's inspector (with a day stepper) and the **HISTORY** tab of an item's inspector. A transcript line opens the redacted transcript.

## From the CLI

All owner only; each refuses to run inside an agent turn.

- [`brahma memory`](/docs/cli/memory/): `search`, `list`, `rm`, `inherit`
- [`brahma replay`](/docs/cli/replay/)
- [`brahma transcript`](/docs/cli/transcript/)
- [`brahma search`](/docs/cli/search/) (full-text search of a company's messages)

## Related

- [Handbook](/docs/concepts/handbook/)
- [Resources](/docs/concepts/resources/)
- [Agents and roles](/docs/concepts/agents-and-roles/)
