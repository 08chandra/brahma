---
title: Improvements from research
description: "What a survey of multi-agent systems and failure studies changed in the design: coordinate through work items, not chat, and let the engine own verification."
sidebar:
  order: 11
---

## Context

Before the engine was built, the team surveyed published multi-agent coding systems and studies of why such systems fail. The one big lesson: every system that worked at scale coordinates through structured artifacts — work items, files, git — not chat. Chat-heavy systems fail by context loss down the line, conflicting implicit decisions, fake "done" and token blow-ups. The strongest single predictor of failure is missing or fake verification. The owner approved the proposal as part of the design.

## Decision

Keep the chat-like UI, because it is how the owner watches and steers, but make work items the agents' real coordination substrate. Ranked changes:

- **Truth and verification.** Every work item carries an executable check; the engine runs it in the sandbox and records pass or fail, and an item moves to Done only on an engine-recorded pass. Agents may only flip status fields; acceptance criteria and checks belong to the item's author and reviewer. Reviews are done by an agent that sees only the diff and the item, never the author's chat. Hard gates are engine hooks, not prompts, and an approval relayed by an agent never counts as the owner's.
- **Parallel work without collisions.** One writing agent per item and the paths it touches, with leases that expire and a reaper. A worktree per engineer and a merge queue in plain code that rebases, runs the checks, bisects and merges. Architect-owned interface contracts for parallel teams.
- **Context that survives short turns.** Every hand-off is a file: goal, acceptance check, decisions and rationale, open questions, file references; messages carry a reference. Each turn starts with orientation: the role card re-injected from file, the current item, the progress file, recent git log. Tiered memory with a librarian that consolidates notes, and an experience store of short lessons.
- **Cost and liveness.** Effort tiers and budgets per item; token cost read from the CLI's own records, not self-reported. A watchdog in plain code for stalls, loops and over-long runs. A planner / worker / judge loop per sprint with few layers. A worker may hand a hard sub-problem to a stronger model for one turn. Team-size caps and per-agent post rate limits.
- **Pairing and debugging.** Driver and navigator as a per-item option: one writer, one read-only reviewer of each diff as it lands. Competing-hypotheses templates for debugging and architecture.
- **Anti-reward-hacking.** A diff that deletes, skips or weakens a test or check is detected by the engine and needs the reviewer's explicit approval; agents never see or control the engine's verification records.
- **Self-improvement safety.** Any engine that proposes changes to itself works against an immutable evaluator, held-out scenarios, a separate read-only auditor, no self-granted resources, one change at a time with cooldown, and a draining hot-swap.
- **Observability.** Trace-shaped records, one span per turn and per tool call; an owner daily digest, anomaly alarms and a global kill switch.

## Consequences

- The work system (checks, leases, worktrees, review, merge, budgets, watchdog) is engine code, not prompt text, and most of it is pure functions that tests can pin.
- Agents are biased toward many small independent items and a few strong reviewers rather than wide conversations; implementation of one item stays serial while research, exploration and independent reviews run in parallel.
- The number of concepts the owner must learn is kept small, which later became the five-noun budget.

## Source

`2026-10-20-improvements-from-research.md`
