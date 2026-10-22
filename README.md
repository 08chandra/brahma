# Brahma

Run a company of AI agents on your Mac. Each agent is a headless `claude` turn (your own Claude subscription),
scheduled by a single global orchestrator that respects your usage limits. Agents talk to each other and to you
through channels and DMs, backed by one SQLite database.

## Status

This is **Plan 2: Mac app shell** on top of the Plan 1 engine and `brahma` CLI.

## Build

Requires macOS 14+, Swift 6 and the `claude` CLI on your `PATH`, logged in.

```
swift build
swift test                                   # unit tests, no network
BRAHMA_LIVE=1 swift test --filter LiveSmokeTests   # real claude turns (haiku), uses subscription quota
```

The binary is `.build/debug/brahma` (or `swift run brahma ...`). Companies are addressed by name or slug,
case-insensitively.

## Mac app

A native SwiftUI app (dark ops-console look) over the same engine.

- Build with `scripts/make-app.sh`, then open `.build/Brahma.app` or copy it to `/Applications`.
- It uses the same data as the CLI (`BRAHMA_HOME`, `BRAHMA_WORKSPACES`).
- The engine runs inside the app unless `brahma run` holds the lock; then the app shows a banner and takes over
  automatically when the terminal engine stops.
- Closing the window keeps Brahma running in the menu bar (pause/resume companies, open, quit). Quit Brahma
  stops the agents (in-flight turns are interrupted and the agents return to ready); relaunching resumes.
- `BRAHMA_CLAUDE` overrides the `claude` path; otherwise `claude` is found on the PATH read from your login shell.

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

**Agent environment.** Every turn gets an allowlisted environment (`PATH, HOME, LANG, LC_*, TERM, USER, LOGNAME,
SHELL, DEVELOPER_DIR, TMPDIR`, minus anything named like a token, secret or key), plus `BRAHMA_AGENT_ID`; never
`BRAHMA_DEV`. `claude` itself also receives `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` when you set them
(keychain login needs neither), and an agent's Bash inherits those from the `claude` process until the 5-lite
shell prefix unsets them. `brahma mcp` refuses a foreign `--agent`, and owner-write commands refuse to run inside
an agent turn; as above, neither is tamper-proof until the sandbox lands.

**Engine git.** Every git command the engine runs forces off what a repository could make git run (hooks, fsmonitor,
gpg, credential helpers, askpass, ssh, editors, submodule recursion, external diff), reads attributes from the empty tree,
ignores replace refs and grafts, and is refused (with one owner alert) when the workspace's git config holds anything
beyond a short allowlist. Filters and diff/merge drivers are kept out by the engine's own `.git/info/attributes` plus that
config check, which an agent rewriting both files between the check and the command could still race: the 5-lite
sandbox must deny agent writes to `.git/config`, `config.worktree` and `.git/info/`.

`brahma doctor` checks the installed Claude Code CLI (version, required flags, a real haiku probe turn, and that
`--resume` keeps the role prompt). `brahma run` and the app require a passing probe, reused for 24 h per CLI version.

**Owner key and MCP turn tokens.** Owner-write CLI commands (including `doctor`) refuse to run unless
`<data home>/owner.key` (mode 0600) hashes to the SHA-256 held in the Keychain (service `dev.brahma.owner`, account =
the data-home path; on Linux a 0600 hash file under `~/.config/brahma`, which is weaker). No owner command creates
the key: the Mac app does at launch, or you run `brahma owner init` in Terminal (it needs an interactive terminal;
`--rotate` replaces a key and needs the current key to be valid; a lost or invalid key can only be replaced from the app after a user-presence check). The hash is keyed on the canonical (symlink-resolved) data home, and owner commands refuse a database that is a symlink or lies outside it. Each turn's `brahma mcp` only starts with a per-turn token (only its SHA-256 is stored)
that is valid while that turn is in progress, delivered in the 0600 per-turn MCP config. Both are a deterrent, not a
security boundary: until 5-lite's sandbox read-denies the data home and Keychain services to agents, an agent shell
can still read the key, the hash and the MCP configs, or fake a TTY with `script`.

For temp or demo data homes only, `BRAHMA_OWNER_KEY_STORE=file` keeps the owner-key hash in a 0600 file `<data home>/owner/keyhash` instead of the Keychain (a rebuilt dev binary re-prompts for the login password on every Keychain access); the CLI and app refuse it for the default data home and for any other value, and print a warning when it is used.
