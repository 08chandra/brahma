---
title: Work modes
description: "How each turn's intensity is chosen, compiled, bounded and counted: four modes, a rung ladder, and an engine that decides while agents can only ask."
sidebar:
  order: 6
---

## Context

The owner asked for agents to be able to use more intensive modes of the `claude` CLI when the work needs it or its priority warrants it. The design had to do that without letting an agent escalate itself, without new owner concepts, and without ever crossing into paid overage. It was finalised after three adversarial reviews: cost and pacing, safety and self-escalation, feasibility.

## Decision

- **Four intensity modes plus one modifier**, all compiled by the TurnProfile compiler: Quick, Standard, Deep and Ultra, with Plan-first as the modifier. Each mode is a fixed bundle: model, effort, sub-agent policy, workflow policy, turn and budget limits, wall clock and MCP quotas.
- **A rung ladder.** A rung is a (model, effort) pair, from the smallest model at low effort up to Ultra. Escalation moves one rung, effort first. The model stays fixed for an (agent, item) session after its first work turn, because an effort change keeps the prompt cache and a model change does not; the one exception, an explicit escalation to the strongest model, is recorded and costed as a cache break.
- **The engine decides; agents can only ask.** Mode selection is pure code with one reason string per step. An item's spec fields count toward intensity only when someone other than the lease holder set or confirmed them. An assignee's `request_mode` can raise its own item by a bounded amount.
- **Ultra is the CLI's workflow tool under Brahma's caps.** It runs only on the sandboxed profile, after its own probe gates pass, and Ultra the engine proposes after repeated failures always needs an owner `boost` ask whatever the autonomy preset.
- **Sub-agents are off** on the non-sandboxed workspace profile and come back per CLI version only when the sub-agent gate passes.
- **The no-overage rule covers every mode.** When the CLI reports that paid overage is allowed, every mode clamps to the low rungs with no sub-agents and no Ultra, and new admissions stop near the end of the usage window. A closed weekly pace really closes: admitted critical-path work runs at the lowest rungs only.
- **No new owner noun.** Work gets one item field, Intensity (Auto / Thorough / Ultra); the company's Low/Balanced/Max dial also bounds intensity; the Inbox gets a `boost` ask; Budget shows spend by mode.

## Consequences

- One point of truth: `ModePolicy.select` → a mode decision → the TurnProfile compiler, which emits argv, settings, the engine-set child environment and the MCP quota environment. Snapshot tests cover every mode.
- Allowlists, not denylists: an explicit model allowlist, an explicit list of the CLI environment variables the engine may set, and a pre-tool hook (`brahma hook pre-tool`) on the sub-agent and workflow tools. Anything else is refused.
- MCP quotas are counted inside the per-turn `brahma mcp` process, keyed to the turn token.
- `brahma doctor` gains a mode canary that verifies the CLI's mode behaviour without spending inference.

## Source

`2026-10-21-agent-modes-design.md`
