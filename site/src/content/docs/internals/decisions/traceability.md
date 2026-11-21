---
title: Requirements traceability
description: "Every requirement has an id, the v2 spec section it comes from, the plan and task that build it, and a status."
sidebar:
  order: 9
---

## Context

The v2 spec grew to cover many domains, and the implementation plans were written one at a time. Without a table joining the two, a requirement could sit in the spec with no plan carrying it, or a plan could drift from what the spec said.

## Decision

- **Every requirement gets a row.** An id (`R-001` onward), the requirement in one line, the v2 section it comes from, the plan and task that build it, and a status.
- **Five statuses plus one alarm:** `built`, `building` (in a worktree), `planned` (a written plan, not started), `to-write` (a plan in the build order, not yet written), `deferred` (deferred by the owner), and `UNPLANNED` (no plan in the order carries it).
- **A chief review drives UNPLANNED to zero.** Each unhomed requirement is given a plan and task; some are moved between plans; a few are explicitly deferred to a later plan or to an operations plan after the dogfood week. One requirement, verifying the subscription terms before scaling or distributing, is an owner checklist rather than code and is recorded as such.
- **The table is kept in step with the master roadmap**, which fixes the plan order and the contracts between plans; task references use the plan's own numbering (`3a T7`, `5L T10`).

## Consequences

- At the time of the review the table held 295 requirements and no `UNPLANNED` row. Deferred rows are listed by name, so a deferral is a visible decision rather than a silent omission.
- A reviewer of a plan can check it against the rows that name it, and a reviewer of a spec change can see which plans the change touches.
- The pages under [Decisions](/internals/decisions/) summarise the specs; the traceability table is the place to look for *whether* and *where* a given requirement is built.

## Source

`2026-10-21-traceability.md`
