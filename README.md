# Brahma

Run a company of AI agents on your Mac. Each agent is a headless `claude` turn (your own Claude subscription),
scheduled by a single global orchestrator that respects your usage limits. Agents talk to each other and to you
through channels and DMs, backed by one SQLite database.

## Status

This is **Plan 1: the engine and the `brahma` CLI**. The Mac app comes in Plan 2.

## Build

Requires macOS 14+, Swift 6 and the `claude` CLI on your `PATH`, logged in.

```
swift build
swift test                                   # unit tests, no network
BRAHMA_LIVE=1 swift test --filter LiveSmokeTests   # real claude turns (haiku), uses subscription quota
```

The binary is `.build/debug/brahma` (or `swift run brahma ...`). Companies are addressed by name or slug,
case-insensitively.

## Commands

```
brahma company create <name> --goal <text>      prints id + workspace path
brahma company list
brahma company pause|resume <name>
brahma company mode <name> low|balanced|max     concurrency: 2 / 6 / hard cap
brahma company weight <name> <n>                share of slots when several companies run

brahma hire <company> <handle> --role <role> --model opus|sonnet|haiku
brahma say <company> (#channel|@handle) <text>  post as the owner, or DM an agent
brahma log <company> (#channel|@handle) [--limit 30]
brahma search <company> <query>

brahma status                                   agents, blockers, last turn, usage
brahma pause|wake|kill <company> <handle>

brahma run [--hard-cap 16] [--profile workspace|full]
```

`brahma run` is the orchestrator: keep it running in a terminal. It prints every activity event as
`HH:mm:ss [company] text`. Ctrl-C stops in-flight turns, records them as interrupted, returns the agents to
`ready` and exits 0. Only one `brahma run` per data home is allowed (a lock on `orchestrator.lock`).

- `pause` on a running agent lets its current turn finish, then it sleeps. `wake` clears the pause.
- `kill` is permanent. If the agent is mid-turn in a running orchestrator, that turn is allowed to finish and is
  recorded, but the agent stays killed.
- Usage is gated per company mode: no new turns start when five-hour utilisation reaches 80% (low), 90%
  (balanced) or 97% (max), when a request is rejected for usage, or once paid overage is in use. A usage
  warning alone (e.g. on the seven-day window) does not stop turns.

`brahma mcp` is internal: each agent turn launches it as that agent's company-tools MCP server.

## Data locations

| What | Where | Override |
| --- | --- | --- |
| Database (`brahma.sqlite`), MCP configs | `~/Library/Application Support/Brahma/` | `BRAHMA_HOME` |
| Company workspaces | `~/Brahma/<company-slug>/` | `BRAHMA_WORKSPACES` |

## Safety

Agents run with `--profile workspace` by default: a fixed tool allow-list (shell, file tools, company tools),
started in the company workspace. **This is a tool allow-list, NOT a sandbox.** The allow-list includes Bash, so
an agent can run any shell command as your user: it can read and write files anywhere you can, including the
brahma database (and so impersonate other agents or alter their state) and other companies' workspaces. Only
the Sandboxed profile (Plan 5) confines agents. Every turn ignores your personal Claude settings, plugins, MCP
servers and `CLAUDE.md` files (`--setting-sources ""`), and a `CLAUDE.md` in the workspace is not loaded either.

**`--profile full` gives agents your whole Mac** (all permission checks bypassed). Only use it for
companies and prompts you trust completely.
