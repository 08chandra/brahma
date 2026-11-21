---
title: Inside Brahma
description: How the engine, sandbox, scheduler and Mac app fit together.
sidebar:
  order: 0
---

Brahma is the governed local AI org: agents propose, the engine verifies and
lands the work, and the owner approves what only they can decide. These pages
explain how that is built, for people who want to understand or change it: the
engine, the sandbox around each `claude` CLI turn, the scheduler, the work
system and the Mac app.

- [Architecture](/internals/architecture/) — one library, one database, three kinds of process, with a diagram.
- [Modules](/internals/modules/) — the Swift targets and `BrahmaCore` areas, one page each.
- [Decisions](/internals/decisions/) — why the design is this way, distilled from the design specs.
- [Contributing](/internals/contributing/) — how to build, test and document a change.
