---
title: Brahma v2
description: "The authoritative design: five owner nouns, the database as the message bus, one engine per data home, sessions and prompt caching, a portable core."
sidebar:
  order: 5
---

## Context

After the first engine and the Mac app were built, the design was rewritten as one authoritative document that folded in the research findings, the review rounds and the owner's later decisions. The yardstick it sets: the owner states a goal and the company researches, builds, launches, markets and operates the result, with the owner approving only what matters; the first proof point is goal → live URL → first launch post.

## Decision

- **Five owner nouns.** The owner operates exactly Company, People, Work, Inbox and Budget. Leases, review turns, hand-offs, tiers, trust and health holds are engine internals, visible read-only under Insights, never something the owner must operate. Every later spec is checked against this budget.
- **The database is the bus.** One SQLite database (GRDB, WAL, FTS5) holds every company. The MCP server is the same `brahma` binary in `mcp` mode and writes straight into it; there is no socket. Every process reads and writes the same file.
- **One engine per data home.** An `OrchestratorLock` file. The app embeds the orchestrator only while it holds the lock; otherwise it is a live client that writes owner actions to the database and retries. `brahma run` is the same engine in a terminal, under the same lock.
- **Turns, sessions, caching.** The prompt goes on stdin, never argv. A fresh `claude` session per work item, resumed only while warm; review and audit turns are always fresh. The role card and company rules are passed as a byte-stable system prompt on every turn so the cacheable prefix never changes. If nothing is actionable, the turn is skipped and the agent sleeps.
- **Model by turn kind**, not by role: product and architecture decisions and large work on the strongest model, reviews and most work on the middle one, notice-only turns on the smallest. No role defaults to the strongest model.
- **Argv comes only from the TurnProfile compiler**, snapshot-tested, which also emits the per-turn settings file, child environment and shell prefix. Every turn is isolated from the owner's own `claude` setup (`--setting-sources ""`, `--strict-mcp-config`, the company's MCP config). The child environment is an allowlist. `brahma doctor` verifies the installed CLI with real probe turns and scheduling refuses on a mismatch.
- **Portability.** `BrahmaCore` stays free of AppKit, SwiftUI, Observation and the other Mac-only frameworks; Keychain, notifications, Seatbelt and the like sit behind protocols with fail-closed stubs elsewhere.
- **Usage.** Weekly pacing with an owner reserve so Brahma never consumes the owner's own share; per-mode concurrency caps from the plan tier; never paid overage.
- **Sandbox by default** stays the rule, with Workspace and Full as the non-sandboxed alternatives, and a profile change is a reserved matter.

## Consequences

- Every component has a named home: store and models in `BrahmaCore/Store` and `Model`, scheduling in `Scheduler`, turns in `Turns`, the work system in `Work`, `Verify` and `Git`, the app model and map in their own targets, the CLI in `Sources/brahma`. The [architecture](/internals/architecture/) page is this table drawn.
- Slow work (git, probes, worktree removal, merges) never runs inside the orchestrator's tick; the next tick reads the results.
- The concept budget is why later features (modes, previews, extensions) arrive as fields, cards and settings on the existing nouns rather than as new screens.

## Source

`2026-10-21-brahma-design-v2.md`
