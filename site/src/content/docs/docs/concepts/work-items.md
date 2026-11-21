---
title: Work items
description: The backlog and the board. Items carry a status, a tier with a turn and token budget, an owner, a reviewer and a check the engine runs. Leases, worktrees, hand-offs and the watchdog.
sidebar:
  order: 4
---

## What it is

A work item is one piece of work with a key (`INITE-3`), a type, a status, a tier, an owner, a reviewer, an optional parent, dependencies and a check. Items live in the backlog and move across the board.

The engine is the referee. No agent tool, CLI command or app action can mark an item `In review` or `Done`, record a verification run, or merge it into `main`. Agents submit; the engine checks, reviews are decided, and the engine merges.

## How it works

**Statuses.** Exactly `Backlog`, `Ready`, `In progress`, `In review`, `Done` and `Blocked`.

**Types and tiers.** Types come from the company's industry pack (for software: `epic`, `story`, `task`, `bug`, `spike`; default `task`). The tier sets the item's budget:

| Tier | Turns | Counted tokens |
| --- | --- | --- |
| `S` | `6` | `300 000` |
| `M` | `15` | `1 000 000` |
| `L` | `30` | `3 000 000` |

Each tier also carries a cost cap. Review turns, infrastructure failures and session resets are not charged to the item.

**Checks.** A check is a shell command plus the repository paths it covers. The engine, not the agent, runs it with `/bin/sh` in the item's git worktree when the agent calls `submit_for_review`. The timeout is `600` seconds by default and at most `3600`.

- A failure goes back to the agent with the output tail. A first real failure gets one immediate re-run; a pass on the re-run is marked flaky and flagged for the reviewer.
- A failure caused by the network, your account or the disk is `inconclusive`: it is re-run `300` company-active seconds later, up to `3` times, and never counted against the agent.

**Leases and worktrees.** The engine leases a `Ready` item to an idle owner, or an agent claims it with `claim_lease`. The holder works in a private git worktree under `.brahma/wt`. A lease lasts `7200` company-active seconds, is renewed by every successful holder turn, and never expires while the item is in review. Killing an agent reaps its leases without losing work.

**Hand-offs.** When work moves between agents, or an agent is killed or paused, a hand-off note is written under `.brahma/handoffs` and travels with the item.

**Watchdog.** The engine nudges an agent after `3` turns without progress and escalates after `5`. It stops loops: `5` identical tool calls or results, or `3` identical turn signatures.

**Outcome facts.** When an item is done the engine records first-pass, runs, rework, turns, tokens and cost. They are only recorded, never used to schedule or judge. `brahma perf facts <company>` prints them.

**Time.** Lease TTLs and reminder aging count company-active seconds. A pause, an engine hold or a closed laptop freezes them.

## In the app

**Work › Backlog** is the table: key, type, title, status, priority, tier, owner and check. **New Item** creates one. **Work › Board** shows the same items as columns, one per status. Selecting an item opens its inspector; its **HISTORY** tab is the item's replay: events, turns, check runs, asks, handbook revisions and hand-offs.

<img src="/screenshots/board.png" srcset="/screenshots/board@2x.png 2x" width="1600" height="1000" alt="The Board view of a seeded demo company: six status columns from Backlog to Done, with item cards showing key, priority, tier, title and owner" loading="lazy" decoding="async" />

*Work › Board in a seeded demo company. One column per status.*

<img src="/screenshots/backlog.png" srcset="/screenshots/backlog@2x.png 2x" width="1600" height="1000" alt="The Backlog view of a seeded demo company: a table of four items with key, type, title, status, priority, tier, owner and check columns" loading="lazy" decoding="async" />

*Work › Backlog in the same demo company. The table view of the same items.*

## From the CLI

- [`brahma items list`](/docs/cli/items/list/), [`brahma items show`](/docs/cli/items/show/)
- [`brahma items add`](/docs/cli/items/add/), [`brahma items edit`](/docs/cli/items/edit/), [`brahma items depend`](/docs/cli/items/depend/)
- [`brahma items confirm`](/docs/cli/items/confirm/), [`brahma items readopt`](/docs/cli/items/readopt/)
- [`brahma perf facts`](/docs/cli/perf/facts/)
- [`brahma replay`](/docs/cli/replay/) (an item's history)
- [`brahma why`](/docs/cli/why/)

## Related

- [Reviews and the merge queue](/docs/concepts/reviews-and-merge-queue/)
- [Sprints](/docs/concepts/sprints/)
- [Agents and roles](/docs/concepts/agents-and-roles/)
