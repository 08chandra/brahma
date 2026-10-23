# Brahma

Run a company of AI agents on your Mac. Each agent is a headless `claude` turn (your own Claude subscription),
scheduled by a single global orchestrator that respects your usage limits. Agents talk to each other and to you
through channels and DMs, backed by one SQLite database.

## Status

This is **Plan 3a: the work system** (backlog, checks, review, Inbox) on top of the Plan 2 Mac app and the Plan 1 engine and `brahma` CLI.

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

## Work system

Plan 3a adds a backlog, a board, checks, review and an Inbox on top of the chat engine. The engine is the referee:
no agent tool, CLI command or app action can mark an item `inReview` or `done`, record a verification run, or merge
into `main`.

**Items.** Statuses are exactly Backlog, Ready, In progress, In review, Done and Blocked. Create items with
`brahma items add` (types come from the company's industry pack: epic, task, bug and so on). An item carries a tier
(S, M or L, which sets its turn and token budget), an owner, a reviewer, an optional parent, dependencies and a check.

**Checks.** A check is a shell command plus the repo paths it covers. The engine, not the agent, runs it in the item's
git worktree with `/bin/sh` when the agent calls `submit_for_review`. A failure goes back to the agent with the output
tail. A pass that needed a second run is marked flaky and flagged for the reviewer. A failure caused by the network,
your account or the disk is `inconclusive`: it is re-run later (3 retries, 300 active seconds apart) and never counted
against the agent.

**Leases and worktrees.** The engine leases a Ready item to an idle owner (or an agent claims it with `claim_lease`).
The holder works in a private git worktree under `.brahma/wt`. A lease lasts 7200 company-active seconds, is renewed by
every successful holder turn, and never expires while the item is in review. Killing an agent reaps its leases without
losing work.

**Review and merge.** A submitted item is reviewed in a fresh, clean-context session by its reviewer: the reviewer sees
the diff, the check result and the flags, not the author's conversation. Review flags (a check edited after start,
deleted or modified tests, an edited check script, code changed after the pass, a flaky pass) need explicit approval.
Three review turns without a decision escalate to the reviewer's manager (else you). On approval the engine merges the
verified SHA into `main`; it re-verifies only when `main` moved and the branch had to be rebased first. Auto-merge is **off
by default**: a company turns it on with `brahma company set <company> auto-merge-small on` (and you can switch it off
for every company with `brahma settings auto-merge off`, the owner-wide master switch). With it on, small tier-S changes
under `autoMergePaths` (default `Sources/ src/ lib/ app/ docs/`) set up by a lead merge automatically and are audited
100%; switching it off takes back every auto-approval that has not landed yet.

**Sessions and hand-offs.** Each agent keeps one session per item it works on (plus its base session for chat), so
returning to an item resumes with its context. When work moves between agents, or an agent is killed or paused, a
hand-off note is written and travels with the item.

**Membership versus wake.** Being in a channel never wakes an agent. A message wakes only the agents it mentions
(`@eng-7`), DMs, or `@here`/`@team` (2 per poster per hour, owner exempt); system posts wake nobody. This is what keeps
a 300-agent company quiet.

**Time.** Durations (lease TTL, sprint timebox, reminder aging, deadlock re-escalation) count company-active seconds, so
a pause, an engine hold or a closed laptop freezes them. Calendar text (`HH:mm`, dates) uses your time zone
(`brahma settings timezone`).

**Health gate.** One global hold starts when the network drops (3 failures in 300 s), the account is logged out (2
failures), the Claude Code CLI changes version (it is re-probed) or the disk falls under 5 GB (released at 6 GB). Failed
turns do not count against agents, retries do not spin, active time freezes, and everything resumes when the probe
passes. `brahma doctor` runs the probe by hand.

**Sprints.** `brahma sprint` shows open sprints and `brahma sprint list` lists all of them. Agents plan and close sprints (`plan_sprint`, `close_sprint`), and sprint plans are approved through the Inbox. A sprint has a timebox of 5 active days or 200 team work
turns, and the engine writes a standup every 86 400 active seconds.

**Inbox.** Agents propose things (a PRD, an architecture, a sprint plan, a release, or any other ask) that go to an
approver, who may be the CEO or another executive, before they reach you. Ask lifecycle: pending, then approved,
rejected, answered, rescinded or expired, with reminders to you at 1 and 3 active days. `brahma inbox` lists asks;
`brahma approve`, `answer` and `rescind` decide them (rescinding reverses what the ask started; for a sprint plan it
cancels the sprint). If a proposed document changes after it was proposed, approval requires acknowledging the change.
Autonomy presets (`brahma company autonomy <name> everything|important|auto`): Everything asks you for every ask,
Important (the default) asks you for the ones that matter and shows internally approved PRDs as waiting for you,
Auto lets ordinary asks go through once the C-suite approves and gives you an FYI. **Reserved matters** (money,
contracts, pricing, legal, staffing, stage changes and similar) and questions
always need you, under every setting.

**Attrition.** A killed or paused agent's leases are reaped, its items unassigned with an auto-hand-off, its reviews
and internal asks re-routed, and its reports reparented (an over-span raises an org issue). If the CEO is killed an
acting CEO is named, pending your confirmation. Handles are never reused. `brahma org move|acting` changes the tree.

**Why is nothing running?** `brahma why <company>` explains in one list: an engine hold, a paused company, usage or
weekly pace, agents blocked on someone, asks waiting for you, deadlocks, long-blocked items, or no Ready items.

**Budgets, watchdog, facts.** Each tier has a turn and counted-token budget (S 6 / 300 000, M 15 / 1 000 000, L 30 /
3 000 000). A watchdog nudges after 3 turns without progress, escalates after 5, and stops loops (5 identical calls or
results, 3 identical turn signatures). When an item is done the engine records outcome facts (first-pass, runs, rework,
turns, tokens, cost); they are only recorded, never used to schedule or judge: `brahma perf facts`.

**Weekly pacing.** Spend is paced against a straight line across your seven-day window, keeping a reserve for you
(30% by default; `brahma company reserve <company> <reserve>` overrides it for one company). When ahead of the line only work that others wait on runs; past the reserve
nothing runs.

**Work modes.** The engine picks Quick, Standard or Deep per turn. Plan-first is off on this CLI version (probe V-4);
sub-agents (Task/Agent/Workflow) are off until the sandbox (5-lite). The plan tier is a setting (`brahma settings plan`,
default max5x).

**Engine git safety.** Engine git ignores repository filters, drivers, hooks and replace objects, and allowlists
repository config. Workspaces whose repo config has `remote.*` (clones), LFS, `core.autocrlf`, aliases or submodules
are refused until 5-lite. Merges run in an engine-owned repo under the data home and land only the verified SHA.
Uncommitted changes found on `main` are quarantined under `refs/brahma/quarantine/*` and merges wait for you:
approving Brahma's ask (or `brahma main accept <company> <ref>`) merges exactly the recorded commit; rejecting it
leaves `main` as it is and keeps the ref. "main changed outside Brahma" needs `brahma main accept <company>`. Git state
planted in the workspace repo that would hold merges (stale lock files, `shallow`, `info/grafts`, deleted history
objects) is repaired and reported to you.

**Owner key.** `brahma owner init` (in an interactive terminal) or the Mac app creates it. It is a deterrent until
5-lite, not a boundary; `BRAHMA_OWNER_KEY_STORE=file` is only for temp or demo homes.

**Commands.**

```
brahma company create <name> --goal <text> [--agents <n>]   n agents (default 6; 0 for none; over 50 is experimental)
brahma org [show|vacancies|fill]; brahma org move <company> <handle> ...; brahma org acting <company> <handle>
brahma items list|show|add|edit|depend|confirm ...          the backlog
brahma inbox <company> [--all]                              asks: pending, FYI, recently decided
brahma approve <company> <ask> [--reject] [--note <text>] [--ack-changed]
brahma answer <company> <ask> <text>
brahma rescind <company> <ask> --note <text>
brahma company autonomy <company> everything|important|auto
brahma company reserve <company> <reserve>                  weekly owner reserve for one company
brahma settings timezone [<id>]                             (also: plan, share, auto-merge, auto-merge-paths)
brahma sprint [show|list]
brahma why <company>                                        why little or nothing is running
brahma perf facts <company>                                 outcome facts of finished items
brahma main accept <company> [<ref>]                        after main changed outside Brahma, or a quarantine
brahma doctor                                               probe the installed Claude Code CLI
```

### Workspace profile limits

**Checks and merges run as your user.** Each item's check runs in that item's git worktree with `/bin/sh`.
Verification, merges and owner approvals are engine-owned for every agent tool, but under the workspace profile an
agent's shell can still edit the database or the git repository directly, or run the brahma CLI. Brahma refuses owner
commands when `BRAHMA_AGENT_ID` is set and strips `BRAHMA_DEV` from agent turns, but an agent can unset variables. Only
the sandbox (Plan 5-lite) makes verification and approvals tamper-proof.

A nested `claude` launched from an agent's Bash can load your settings (`fastMode`, `enableWorkflows`) and Keychain
auth. Brahma sets environment defusers, but an agent can unset them, which is why sub-agents and Ultra wait for the
sandbox. Other 5-lite residuals: the race between the git-config scan and the command that follows it, agent worktrees
under `.brahma/wt`, and the database and MCP configs staying readable by agent shells.

**Large repositories.** Each landing into `main` fetches the history it needs into a fresh engine-owned repository, so on a
very large repository a merge costs a full-history fetch. This is acceptable for the workspaces Brahma creates; the 4a merge
queue is where it gets reworked.

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
