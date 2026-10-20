# Agent Company

Run a company of AI agents on your Mac. Each agent is a headless `claude` turn (your own Claude subscription),
scheduled by a single global orchestrator that respects your usage limits. Agents talk to each other and to you
through channels and DMs, backed by one SQLite database.

## Status

This is **Plan 1: the engine and the `agentco` CLI**. The Mac app comes in Plan 2.

## Build

Requires macOS 14+, Swift 6 and the `claude` CLI on your `PATH`, logged in.

```
swift build
swift test                                   # unit tests, no network
AGENTCO_LIVE=1 swift test --filter LiveSmokeTests   # real claude turns (haiku), uses subscription quota
```

The binary is `.build/debug/agentco` (or `swift run agentco ...`). Companies are addressed by name or slug,
case-insensitively.

## Commands

```
agentco company create <name> --goal <text>      prints id + workspace path
agentco company list
agentco company pause|resume <name>
agentco company mode <name> low|balanced|max     concurrency: 2 / 6 / hard cap
agentco company weight <name> <n>                share of slots when several companies run

agentco hire <company> <handle> --role <role> --model opus|sonnet|haiku
agentco say <company> (#channel|@handle) <text>  post as the owner, or DM an agent
agentco log <company> (#channel|@handle) [--limit 30]
agentco search <company> <query>

agentco status                                   agents, blockers, last turn, usage
agentco pause|wake|kill <company> <handle>

agentco run [--hard-cap 16] [--profile workspace|full]
```

`agentco run` is the orchestrator: keep it running in a terminal. It prints every activity event as
`HH:mm:ss [company] text`. Ctrl-C stops in-flight turns, records them as interrupted, returns the agents to
`ready` and exits 0. Only one `agentco run` per data home is allowed (a lock on `orchestrator.lock`).

- `pause` on a running agent lets its current turn finish, then it sleeps. `wake` clears the pause.
- `kill` is permanent. If the agent is mid-turn in a running orchestrator, that turn is allowed to finish and is
  recorded, but the agent stays killed.
- Usage is gated per company mode: no new turns start when five-hour utilisation reaches 80% (low), 90%
  (balanced) or 97% (max), or when the account would go into paid overage.

`agentco mcp` is internal: each agent turn launches it as that agent's company-tools MCP server.

## Data locations

| What | Where | Override |
| --- | --- | --- |
| Database (`agentco.sqlite`), MCP configs | `~/Library/Application Support/AgentCompany/` | `AGENTCO_HOME` |
| Company workspaces | `~/AgentCompany/<company-slug>/` | `AGENTCO_WORKSPACES` |

## Safety

Agents run with `--profile workspace` by default: a fixed tool allowlist (shell, file tools, company tools),
working in the company workspace, with normal permission checks. Every turn ignores your personal Claude
settings, plugins and MCP servers.

**`--profile full` gives agents your whole Mac** (all permission checks bypassed). Only use it for
companies and prompts you trust completely.
