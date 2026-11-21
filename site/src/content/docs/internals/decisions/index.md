---
title: Decisions
description: Why Brahma is built the way it is, one page per design spec.
sidebar:
  order: 3
---

Each page distils one design spec from `docs/superpowers/specs/` into four parts: the **context** the decision was made in, the **decision** itself, its **consequences** for the code, and the **source** spec. The specs are long and record every review round; these pages keep only what someone changing Brahma needs to know. Where a page and the code disagree, the code wins and the page is wrong.

| Page | Decides |
| --- | --- |
| [One orchestrator, headless turns](/internals/decisions/one-orchestrator-headless-turns/) | An agent is a database record; one scheduler runs short `claude` turns; agents act only through company tools. |
| [Brahma v2](/internals/decisions/brahma-v2/) | The authoritative design: five owner nouns, the database as the bus, sessions and prompt caching, portability. |
| [Work modes](/internals/decisions/agent-modes/) | How a turn's intensity is chosen, compiled and bounded; the engine decides, agents can only ask. |
| [Universal preview and granular communication](/internals/decisions/collab-preview/) | One typed reference for all work, a Show bar that costs nothing until asked, sharing that never widens access. |
| [Extensions](/internals/decisions/extensions/) | One installable thing, the trust boundary that decides where each part runs, one install pipeline. |
| [Requirements traceability](/internals/decisions/traceability/) | Every requirement has an id, a spec section, a plan and a status. |
| [Visual design](/internals/decisions/visual-design/) | The ops-console look: dark, dense, hairlines, mono data, colour only for meaning. |
| [Improvements from research](/internals/decisions/research-improvements/) | Coordinate through work items, not chat; the engine owns verification. |
