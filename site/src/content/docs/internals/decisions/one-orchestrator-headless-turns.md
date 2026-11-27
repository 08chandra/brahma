---
title: One orchestrator, headless turns
description: "The first design: an agent is a database record, one global scheduler runs short headless claude turns, and agents act on the company only through tools."
sidebar:
  order: 4
---

## Context

The owner wanted a native Mac app in which one person creates a company of AI agents, hands it a goal, and watches it organise itself, plan sprints and build the product locally, stepping in at any level like a board member. Every agent had to be a real `claude` CLI session so agents really write, run and test code, billed to the owner's subscription rather than a per-token API.

Two facts shaped the design. A live `claude` process costs hundreds of megabytes of memory, so on one Mac tens of agents can execute at the same instant, not hundreds. And subscription usage limits are a second ceiling that the system must hit gracefully. The owner also named anti-goals: agents chattering in circles, a secret anywhere in chat or the database, money spent without owner action, a UI that lags at hundreds of agents, lost state on crash, a Mac made unusable.

## Decision

- **An agent is not a process.** It is a database record: role, prompt, memory, session id, inbox, state. When scheduled, the orchestrator launches one short turn (`claude -p`, resuming the agent's session) with a compact inbox digest as the prompt. The turn streams events to the activity feed and the map, then exits. Sleeping and blocked agents cost zero memory and zero usage. This is what lets hundreds of agents exist.
- **One scheduler** in the orchestrator owns every transition into running. Usage modes Low, Balanced and Max set a company's ceiling; a machine safety cap derived from free memory, an owner hard cap and the usage limits bound the total across all companies. Priority: critical path first, then role weight, sprint priority, wait time. Companies share slots by weighted round-robin.
- **Agents act only through company tools**, an MCP server the engine provides: messaging, work items, decisions, owner requests, secrets by name, org actions, preview. Final stdout is a turn summary, not a message. A `use_secret` tool never returns a value into the transcript; the engine injects it into the next turn's process.
- **Sandbox by default.** Three permission profiles: Sandboxed (OS-sandboxed tool execution, writes only inside the company workspace, a network allow-list), Workspace (tool allow-list, Bash unrestricted) and Full (`bypassPermissions`, with a persistent warning). A profile change applies from each agent's next turn.
- **No paid overage.** If the CLI reports paid extra usage, treat it exactly like a usage limit. When a turn hits a limit, agents not yet running go blocked and the scheduler backs off until the reset.
- **Persistence** in SQLite with WAL and FTS5: companies, agents, channels, messages, work items, sprints, decisions, requests (never secret values), turn logs. Every state transition is persisted before it takes effect; an agent recorded as running whose process is gone goes back to ready on launch.

## Consequences

- The engine needs three things first: a store, a turn runner that drives one `claude -p` turn end to end with the company tools, and the scheduler. The build order in the spec starts there.
- Because every agent action is a tool call into the engine, authorisation can be enforced in one place, server-side, instead of by hiding tools in prompts.
- Short turns make prompt caching and session resumption an efficiency question for the engine rather than for the agent; later specs tighten both.
- The three profiles and the "sandbox by default" rule are the root of the later sandbox, canary and taint work.

## Source

`2026-10-20-agent-company-design.md`
