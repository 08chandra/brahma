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
brahma company create <name> --goal <text> --from-repo <folder|https-url>   start from an existing repo
brahma company trust-import <name> [--yes]      show, then (--yes) lift, an imported repo's taint (owner only, engine stopped)
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

Phone alerts go through the service you pick. With ntfy.sh, anyone who knows the topic name can read it: pick a long
random topic or run your own server. Brahma sends counts, not content, unless you choose titles.

```
brahma prefs set push ntfy <topic> [--server <https url>] [--token-stdin]
brahma prefs set push pushover                  app token, then user key, one per line on standard input
brahma prefs set push off
brahma prefs set push-detail counts|titles
brahma push test                                send one test alert
```

The service credentials are kept in the secrets vault (Keychain), never in the database, and agents never receive them.
An ntfy token is only sent to the server it was set for: changing the server or the service deletes it.
Urgent alerts go at once; the rest wait out quiet hours and arrive as at most one alert every 5 minutes, 30 per day.

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
sub-agents (Task/Agent/Workflow) never run on Workspace or Full companies. On Sandboxed companies they stay off until
their probe gates pass for the installed CLI build: L-2, V-3 and V-5, plus V-2 or V-8 (`brahma mode gates`; see
[Safety](#safety)). The plan tier is a setting (`brahma settings plan`, default max5x).

**Engine git safety.** Engine git ignores repository filters, drivers, hooks and replace objects, and allowlists
repository config. A workspace whose repo config sets any key outside that short allowlist is refused, with an owner
alert; that includes `remote.*` (clones), LFS filters, `core.autocrlf`, aliases and submodules. Merges run in an engine-owned repo under the data home and land only the verified SHA.
Uncommitted changes found on `main` are quarantined under `refs/brahma/quarantine/*` and merges wait for you:
approving Brahma's ask (or `brahma main accept <company> <ref>`) merges exactly the recorded commit; rejecting it
leaves `main` as it is and keeps the ref. "main changed outside Brahma" needs `brahma main accept <company>`. Git state
planted in the workspace repo that would hold merges (stale lock files, `shallow`, `info/grafts`, deleted history
objects) is repaired and reported to you.

**Owner key.** `brahma owner init` (in an interactive terminal) or the Mac app creates it. On Sandboxed
companies the sandbox enforces it, because agents cannot read the data home or the Keychain; on Workspace and Full
companies it is still only a deterrent. `BRAHMA_OWNER_KEY_STORE=file` is only for temp or demo homes.

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
brahma canary edit                                          write the sandbox canary's probe lines ($EDITOR, default vi)
brahma canary run                                           run the sandbox canary now; records a pass
```

### Workspace profile limits

Workspace profile only: an agent's Bash is not sandboxed. The engine refuses owner commands from inside a turn, but a determined process can escape that check; use Sandboxed (the default).

**Checks and merges.** Each item's check runs with `/bin/sh` in an engine-made checkout under the data home. A
Workspace company's checks are sandboxed like a Sandboxed company's (see [Safety](#safety)); only Full-profile checks run
unconfined as your user. Verification, merges and owner approvals are engine-owned for every agent tool, but under the
workspace profile an agent's shell can still edit the database or the git repository directly, or run the brahma CLI.
Brahma refuses owner commands when `BRAHMA_AGENT_ID` is set and strips `BRAHMA_DEV` from agent turns, but an agent can
unset variables. So on Workspace and Full companies, verification and approvals are not tamper-proof; on Sandboxed
companies agents cannot read or write the data home (which holds the database) or git's config, hooks and `main` ref.

A nested `claude` launched from an agent's Bash can load your settings (`fastMode`, `enableWorkflows`) and Keychain
auth. Brahma sets environment defusers, but an agent can unset them, which is why sub-agents and Ultra run only on
Sandboxed companies, and only once their probe gates pass. Also open on Workspace and Full companies, and closed by the
Sandboxed profile's write and read denies: the race between the git-config scan and the command that follows it, agent
worktrees under `.brahma/wt`, and the database and MCP configs staying readable by agent shells.

**Large repositories.** Each landing into `main` fetches the history it needs into a fresh engine-owned repository, so on a
very large repository a merge costs a full-history fetch. This is acceptable for the workspaces Brahma creates; the 4a merge
queue is where it gets reworked.

## Data locations

| What | Where | Override |
| --- | --- | --- |
| Database (`brahma.sqlite`), MCP configs | `~/Library/Application Support/Brahma/` | `BRAHMA_HOME` |
| Company workspaces | `~/Brahma/<company-slug>/` | `BRAHMA_WORKSPACES` |

## Safety

**Profiles.** Every agent turn runs under its company's profile, set with
`brahma company profile <company> sandboxed|workspace|full [--role <id>]` (`--role` sets it for one role's agents).
`brahma run --profile` is only a ceiling: it can narrow a company's profile, never widen it.

- **Sandboxed** (the default) confines each turn with macOS Seatbelt to its own places in the company workspace.
- **Workspace** is a tool allow-list (shell, file tools, company tools) started in the workspace. **It is NOT a sandbox.**
  The agent's Bash runs as your user and can read and write anything you can, including the Brahma database (and so
  impersonate other agents or alter their state) and other companies' workspaces.
- **Full gives agents your whole Mac** (every permission check bypassed). Only use it for companies and prompts you trust
  completely.

Switching a company back to Sandboxed does not rule out a process an earlier Workspace or Full turn left running; check
`ps` for strays. Every turn ignores your personal Claude settings, plugins, MCP servers and `CLAUDE.md` files
(`--setting-sources ""`), and a `CLAUDE.md` in the workspace is not loaded either.

**What Sandboxed blocks.** A sandboxed turn cannot:

- read your home folder, apart from the toolchain's read-only places and paths you grant;
- read Brahma's data home (the database, MCP configs, owner key, backups);
- read credentials and private app data, even under a granted path: `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.gnupg`,
  `~/.netrc`, `~/.docker`, `~/.kube`, `~/.claude`, `~/.gitconfig`, shell histories, the Keychains, cookies, Mail, Messages,
  Safari, browser and other app profiles (Chrome, Firefox, Arc, Claude, Slack, 1Password, VS Code, ...);
- read or write other companies' workspaces;
- read `/Volumes`;
- read or delete your backup targets and the WAL replica folder;
- write outside its own places in the workspace: the item turn's worktree, or the agent's lab, plus its home (with its
  own cache inside) and its notes file. `.brahma/cache` and the other engine-owned parts of `.brahma`, and git's
  config, hooks, `info/` and `main` ref, are write-denied;
- reach hosts outside its allowlist: Bash's network is limited by Claude Code's own sandbox network allowlist
  (`sandbox.network.allowedDomains`), set from the company's Bash list plus the agent's granted domains. Turns do not go
  through Brahma's egress proxy. WebFetch has its own list. Anthropic's domains are never allowed. Listening on loopback
  is off unless you turn it on;
- use helper programs that act outside the sandbox: the Keychain, the pasteboard, screen capture, `open` (LaunchServices),
  `osascript` (Apple events), accessibility, privacy (TCC) services, preference writes (cfprefsd) and disk mounting
  (DiskArbitration and `mount_*`).

**Engine-run checks** run under Brahma's own Seatbelt policy, not a turn's. A check writes only its own checkout under
the data home. It reads the company's workspace except the private parts of `.brahma` (agents' homes, labs and notes,
extension review pages, `ext try` copies, trash and plans), and it cannot read Claude's temp folders. Its network goes
only through Brahma's egress proxy: HTTPS (port 443) to the company's Bash allowlist (grants are not included), and only
at public addresses (loopback, private ranges and cloud metadata are refused). `brahma run --profile` narrows checks
as it narrows turns: a check runs unconfined as your user only when its company's profile, and the profile of the
item holder's role when there is one, are still Full after that ceiling. The egress proxy is used only by commands Brahma itself runs under
Seatbelt (checks, and the owner-side runner the doctor, the sandbox canary and the `ext` commands use).

**Network allowlist.** The default Bash list is the package registries (npm, Yarn, PyPI, crates.io, Go, RubyGems, Maven,
GitHub); WebFetch also gets a few docs sites (Apple, Swift, MDN, Node, Python, docs.rs, pkg.go.dev).

```
brahma network <company>                          the effective lists (defaults marked)
brahma network <company> add|rm <domain> [--web]  a Bash egress domain (--web: a WebFetch domain)
brahma network <company> local on|off             whether agents may listen on loopback
brahma network <company> toolchain add|rm <path>  an extra read-only toolchain path
```

**Sandbox checks.** `brahma doctor` reports `sandbox-backend`, `sandbox-canary-local`, `sandbox-canary` and
`sandbox-helpers`. Before a sandboxed turn starts, its CLI build, turn shape and your canary probe file must have passed
the sandbox canary; until then the agent waits and you get a sandbox-check alert naming the reason (missing file, no
probes, probe line N failed, a leak). Workspace and Full companies run.

The canary is a self-test whose probes are yours: `brahma canary edit` opens `<data home>/canary/probes.txt` (created
with header comments only, also by the engine when it is missing; a regular file you own, mode 0600, never a link), one
shell command per line, each expected to be DENIED. Probes refer to `$CANARY_HOME_FILE`, `$CANARY_DATA_FILE`,
`$CANARY_OUTSIDE_DIR` and `$OTHER_AGENT_LAB`, places where Brahma plants a dummy `BRAHMA-CANARY-<uuid>` token for the run
(passed as environment variables, never spliced into the command). Every probe runs twice. First model-free, through a
throwaway agent's shell prefix inside Brahma's own Seatbelt profile, the one around checks and previews (10 s each,
after a positive control that must succeed): this vouches for that sandbox, not for the agent turn's. Then in one small
haiku turn built like a real sandboxed turn of the shape being verified (the real compiled settings, both hooks; budget-
and time-capped), judged only from its raw stream: each probe's tool result must be an error or a non-zero exit; a probe
the model did not run, a command not found (exit 127), or a probe stopped by one of Claude Code's permission rules (it
never reached the sandbox) fails as unverified; no stream line may contain the token (raw, encoded, its bare UUID or
base64); the Read of the home token must be a permission denial; and the session may have no tool, plugin, skill or
MCP server beyond the expected ones. Only this second run vouches for the agent turn's sandbox. The planted places must
not change during either run. A line ending in `# helper` is warn-only (`sandbox-helpers`). The file's SHA-256 is part
of the canary key, so any edit needs a new pass: `brahma canary run` runs both layers for the turn shape of each
running sandboxed company, prints each line's verdict, exit status and redacted output, and records the passes (with
the file's SHA prefix and probe count); the engine also runs it when a sandboxed agent waits, backing off after
failures, and never pays for a turn whose shape it cannot build.

Writing probes: the permission rules deny `launchctl`, `security`, `osascript`, `open`, `crontab`, `at`, `sudo`,
`screencapture` and `claude` by name, so write such probes in a form the rules do not match (an absolute path such as
`/bin/launchctl`, or `sh -c '...'`), or the canary fails them as not run. A probe must test something the sandbox is
meant to stop: `osascript -e 'get name of ...'` of the Finder, for one, is answered locally by LaunchServices and is not
an escape test (real Apple events are gated by macOS Automation consent).

**Grants and presets.** An agent that needs more asks with `request_access` (a Bash domain, a WebFetch domain or a
directory to read). You decide; a grant takes effect from the agent's next turn.

```
brahma access <company>                              open access requests, and recently refused ones
brahma access approve <company> A-<n> --scope once|item|agent|role|company --duration turn|sprint|always
brahma approve <company> A-<n> --reject              reject one
brahma grants <company> [--all]                      the grant ledger
brahma grants revoke <company> G-<n>                 gone from the next turn
brahma presets <company> [enable|disable <preset>]   both off by default
```

`readonly-web-engineers` lets engineers, QA, DevOps, security and architects read well-known docs sites (exact hosts);
`auto-low-risk` approves low-risk web reads for the sprint under the `auto` autonomy preset. Neither ever approves a
medium or high risk or a reserved matter.

**The taint rule.** Once a session has read outside content, it is tainted until the agent's next fresh session. Outside
content is a WebFetch or WebSearch result, another MCP server's output, a Bash command that reaches the network or runs
fetched code (`curl`, `ssh`, `npm`, `pip`, `git fetch`, `/dev/tcp`, ...), or a third-party or not-installed skill or
sub-agent. A tainted session keeps talking, reading and ordinary item work (messages, channels, items, leases,
`submit_for_review`, hand-offs). Every other company tool is refused: proposing or deciding asks, reviews and audits,
sprint planning, asking for access or secrets, `use_secret`, mode requests, re-adopting branches and proposing extensions.
It also cannot start sub-agents or workflows. What it writes reaches readers marked as coming from a session that read
outside content, and its items lose auto-approval. Fan-out turns count as tainted from launch until the installed CLI
passes the V-1 hook gate. Text that claims to come from the owner is flagged and never changes an ask; only you, as the
owner, approve anything.

Deciding which shell commands reach the network is done by a command classifier, and **the classifier is advisory**: it
errs towards tainting, but it is not the wall. On the Sandboxed profile the network allowlist is the real wall: a command
the classifier misses still reaches only the allowlisted hosts.

**Lab marks.** Each agent has a lab, a scratch repository it builds extensions in. Once a tainted session has worked in a
lab, the lab carries a sticky mark: every extension proposed from it goes to you and mounts as third-party. A tainted turn
on the Workspace or Full profile marks every lab in its company (a company mark, which new hires also inherit), and on Full
it also leaves a machine-wide mark, since it could write any company's labs. Only you clear marks, after checking what
is in the labs:

```
brahma lab clear-taint <company> <handle>   one agent's lab
brahma lab clear-taint <company>            the company mark and every agent's lab mark in it
brahma lab clear-taint --machine-wide       the mark a Full-profile session left
```

A clear is refused while a tainted session or turn is still in scope, and commits made before the clear stay recorded as
tainted.

**Agent-built extensions.** An agent proposes an extension from its own lab with `propose_extension` (lint-clean, as
committed). Brahma decides its provenance from the lab commits that introduced its content. A clean one goes to the
company's internal reviewer and then to you. One whose provenance is tainted or unrecorded, or that comes from a marked lab,
goes straight to you and no teammate reads it. Nothing is mounted on any turn before you approve it. To try a folder
yourself, `brahma ext try <folder> --company <company> --role <role> --prompt <text>` runs one throwaway Quick turn on the
Sandboxed profile with the folder mounted; it files no ask, and everything it made is removed.

**Ultra mode is gated.** Ultra (an approved run of Claude's workflow engine on the Sandboxed profile, under a budget cap,
a wall clock and an agent-count kill) stays off until every one of its probe gates passes for the installed CLI build.
Sub-agents on the Sandboxed profile have gates of their own. `brahma mode gates` lists every gate per shape (`--run` runs
the missing live ones, on haiku); `brahma mode ultra-status <company>` says why Ultra cannot run for a company; `brahma
settings ultra-share <company> <0-50>` sets the share of the company's weekly share Ultra may use (0 turns it off).

**Emergency stop.** `brahma stop [--note <why>]`, or STOP EVERYTHING in the app's top bar, holds every company at once.
The running engine cancels every turn (Ultra included), check, merge, git task and sandbox canary, and starts nothing new
until `brahma resume` (or Resume in the app); a restore also comes back stopped. The command itself signals the process
group of every turn the database records as running and of every check and merge child the engine recorded (SIGTERM, then
SIGKILL), so a wedged engine cannot keep agents running. Probe-gate, canary and `ext try` processes are not in that
record, so `brahma stop` with no engine running does not signal them; a probe gate already running when you press stop
finishes that gate. `brahma mode gates --run` and `brahma ext try` refuse to start while stopped.

**Agent environment.** Every turn gets an allowlisted environment (`PATH, HOME, LANG, LC_*, TERM, USER, LOGNAME,
SHELL, DEVELOPER_DIR, TMPDIR`, minus anything named like a token, secret or key), plus `BRAHMA_AGENT_ID`; never
`BRAHMA_DEV`. `claude` itself also receives `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` when you set them
(keychain login needs neither). On the Sandboxed profile the agent's shell prefix unsets those and every other variable
named like a token, secret or key before each Bash command; on Workspace and Full an agent's Bash can inherit them. `brahma mcp` refuses a foreign `--agent`, and owner-write commands refuse to run inside an agent turn;
on the Workspace and Full profiles neither is tamper-proof.

**Engine git.** Every git command the engine runs forces off what a repository could make git run (hooks, fsmonitor,
gpg, credential helpers, askpass, ssh, editors, submodule recursion, external diff), reads attributes from the empty tree,
ignores replace refs and grafts, and is refused (with one owner alert) when the workspace's git config holds anything
beyond a short allowlist. On the Sandboxed profile agents cannot write `.git/config`, `config.worktree` or `.git/info/`.
When the engine commits an agent's work it leaves out, and reports, any symbolic link whose target has a `..` part or
points outside the checkout: repositories that use such links need them rewritten.

`brahma doctor` checks the installed Claude Code CLI (version, required flags, a real haiku probe turn, and that
`--resume` keeps the role prompt). `brahma run` and the app require a passing probe, reused for 24 h per CLI version.

**Owner key and MCP turn tokens.** Owner-write CLI commands (including `doctor`) refuse to run unless
`<data home>/owner.key` (mode 0600) hashes to the SHA-256 held in the Keychain (service `dev.brahma.owner`, account =
the data-home path; on Linux a 0600 hash file under `~/.config/brahma`, which is weaker). No owner command creates
the key: the Mac app does at launch, or you run `brahma owner init` in Terminal (it needs an interactive terminal;
`--rotate` replaces a key and needs the current key to be valid; a lost or invalid key can only be replaced from the app after a user-presence check). The hash is keyed on the canonical (symlink-resolved) data home, and owner commands refuse a database that is a symlink or lies outside it. Each turn's `brahma mcp` only starts with a per-turn token (only its SHA-256 is stored)
that is valid while that turn is in progress, delivered in the 0600 per-turn MCP config. Both are a deterrent, not a
security boundary on their own: the Sandboxed profile denies agents the data home and the Keychain, but on the Workspace
and Full profiles an agent shell can still read the key, the hash and the MCP configs, or fake a TTY with `script`.

For temp or demo data homes only, `BRAHMA_OWNER_KEY_STORE=file` keeps the owner-key hash in a 0600 file `<data home>/owner/keyhash` instead of the Keychain (a rebuilt dev binary re-prompts for the login password on every Keychain access); the CLI and app refuse it for the default data home and for any other value, and print a warning when it is used.

**Secrets.** `brahma secret set <company> NAME [--test]` stores the value in the Keychain (service `dev.brahma.secrets`); the database holds only names and flags. Each item trusts only the running Brahma binary and its sibling (the app and its bundled `brahma`), so other programs, `/usr/bin/security` included, get the system prompt instead of the value. Residual risk: Keychain asks once per item per binary build to allow access (a rebuilt or re-signed binary is a new application to macOS, and only the binaries trusted by the build that last wrote an item can read it). Background reads (the engine, `brahma mcp`, other CLI commands, app launch) never show a prompt: a read that needs your permission fails, is retried with backoff (5 s doubling to 5 min) and pauses agents, and Brahma posts one notice; run `brahma secret load` (or press Load secrets in the app) to allow access. Values are redacted from everything the engine stores; until every secret has loaded, the engine starts no turns, checks or merges, `brahma mcp` refuses tool calls ("secrets are not loaded yet; try again shortly") and text writes fail instead of storing unredacted text. Read-only CLI commands never read secrets. A test key (`--test`) needs a name containing `KEY`, `TOKEN` or `SECRET` that is not a variable that changes how programs run (`GIT_*`, `SSH_*`, `DYLD_*`, `LD_*`, `NODE_*`, `PYTHON*`, `*PATH`, `*_OPTIONS`, ...). For temp or demo data homes only, `BRAHMA_SECRET_STORE=file` keeps values in a 0600 file `<data home>/secrets/vault.json` (`memory` is for in-process tests and the CLI and app refuse it); like the owner-key switch it is refused for the default data home and for any other value.

A test key (`--test`) can be put in an agent's environment, and its checks', for an item it holds (`use_secret`), from its
next turn until it releases the item or the item is done. Every other secret is engine-held: no agent is ever given it.

**Residual risks.**

- Claude Code keeps its own unredacted copy of each session transcript in ~/.claude/projects; Brahma's captured copy is redacted.
- Workspace profile Bash is not sandboxed.
- Resource scopes and lab privacy are enforced only by Brahma's tools on the Workspace and Full profiles; an agent's shell can read them.
- Extensions run inside the agent's sandbox. Brahma refuses hooks, MCP servers, LSP servers, monitors, plugin settings and install scripts in any extension.
- The git pre-commit hook is advisory; the engine's submit- and merge-time scans are the real check.
- Agent turns can write files in your user temp folder, because xcrun needs its cache file there.
- Keychain asks once per app build to allow access.
- **The sandbox canary checks only what your probe lines ask.** Sandboxed companies stay blocked until you write them (`brahma canary edit`) and they pass; the canary is as thorough as the probes.
  Ultra's V-9 gate is pending for the same reason.
- **Other Seatbelt mount routes** beyond the known DiskArbitration and `mount_*` routes (both denied and tested) have not
  been exhaustively reviewed. This is a human-review item.
- **Checks can't attach or mount disk images.**
- **Workspace-profile Bash can clear or forge taint flags,** by removing or writing the flag files or editing the
  database. The Sandboxed profile blocks this.
- **A marked work item still merges after a normal reviewer approval.** Its taint mark clears only when the item is done.
- **The command classifier is advisory.** Ordinary local commands such as `git stash`, `cd x && git status`, or variables
  in commands taint a session.
- A lab mark covers the whole agent, not one session. There is no command yet that lists lab marks.
- On the Workspace and Full profiles, an untainted agent writing into another agent's lab is not detected, and the folders
  of extension reviews and `ext try` stay readable to agents.
- Checks cannot read your SwiftPM cache, so a check that has to resolve packages through it fails.
- **Dev homes built from earlier pre-release lane builds must be recreated,** because of in-place migration changes.
- **Live tests have not been run.**

## Live: preview, deploy and human tasks

Plan L takes a company from a goal to a URL you can open. The path is the same in every software company: the brief, a
walking skeleton (a static site whose `npm run build` writes `dist/`), a preview the engine keeps running from `main`, a smoke
check that keeps `main` green, then a deploy you approve. Agents never deploy; they propose, and the engine does exactly what
you approved, once.

**The path to live.** The CTO, architect and DevOps role cards carry the recipe: start a walking skeleton on an item branch
while the brief is reviewed; call `set_preview_command`, `set_smoke_check` and `set_deploy_config`; when `main` is green, call
`propose_deploy`. Anything only a human can do (an account, a domain, keys, posting) becomes a human task in your Inbox
(`request_human_task`).

**Previews.** A preview is a web server the engine builds from `main` in a fresh sandboxed export and keeps running on a
loopback port (`127.0.0.1`, ports 47100–47999, at most 8 per company), restarted when `main` moves. Agents and you write the
command with `{port}` where the engine's port goes (`PORT={port} npm start`, `http://127.0.0.1:{port}/`). Every merge gives a
fresh export: a preview never runs from an agent's working tree, and its process group is killed on restart. The app shows
previews in a pane that loads only the loopback origin; the engine logs each preview under the data home.

**Hosting.** You pick the provider and project (`brahma hosting set`, or Company › Settings › HOSTING). Cloudflare Pages is
the default: its free plan serves static sites with no commercial-use restriction, a scoped API token is enough, and `wrangler`
prints the deployment URL the engine checks. Vercel is the alternative (its free Hobby plan is for non-commercial use; deploys
need the team or account ID). Both CLIs are pinned to exact versions and installed by the engine, token-free, into a folder
agent code cannot write. Hosting tokens arrive through the `hosting-account` human task and go to your Keychain. Agents never
receive the hosting token.

**The deploy ask.** `propose_deploy` records a release (`R-<n>`, a version unique in the company, the exact `main` commit) and
puts one ask in your Inbox showing the provider and project, the commit, the release notes, the build command and output
folder, the smoke results on `main`, and the exact deploy and rollback commands the engine will run. Approving it is the only
way a deploy starts; `brahma approve` and the app do it, no tool can. The engine then, in order and each step recorded before
the next: checks the commit is still on the engine-accepted `main` and runs the smoke check at it; re-renders the plan and
refuses if anything differs from what you approved; records `refs/brahma/main-backup` and `refs/brahma/releases/<version>`;
builds in a clean `.git`-free export of the commit (sandboxed, no secrets, 30 minutes at most); stages only the output folder
(at most 500 MB, 20 000 files); installs the provider CLI if missing; runs the deploy steps (15 minutes each) with the token
only in their environment; smoke-checks the live URL (6 attempts, 10 s apart, for CDN propagation); and marks the release
`deployed` or `failed` (a P1 bug is filed and you are told). The redacted deploy and build logs land in
`<workspace>/.brahma/releases/R-<n>/`, which agents can read and never write.

**The smoke check on `main`.** `set_smoke_check` sets the command the engine runs, sandboxed in a clean export, on every new
`main` and before every deploy (10 minutes by default, 60 at most). While it fails `main` is red: the engine files a bug and
deploys are blocked. A deploy needs a passing smoke run at the exact commit being deployed; `brahma release smoke` runs it on
demand.

Preview and build commands are written by agents and run in Plan 5-lite's sandbox, in fresh engine exports of main that contain no .git, in their own process group, with no secrets. Deploy and rollback commands are composed by the engine from your hosting settings, shown to you exactly in the deploy request, and run once after you approve, from a clean folder holding only the built files, using a provider CLI the engine installed where agent code cannot write, with the hosting token taken from your Keychain. Agents never receive the hosting token.

**Releases, rollback and recovery.** Work › Releases lists every release with its status, commit, URL and smoke result; the
PATH TO LIVE strip shows `main`'s health and the milestones (`GOAL 0:00 · PRD +0:52 · … · LIVE +3:10`) with what each stretch
cost and how often you were needed. Only the live release (the newest deployed or failed one, with nothing in flight) can be
rolled back: `brahma release rollback <co> R-<n>` or the Roll Back button runs the rollback commands recorded before that
deploy, exactly as shown, then smoke-checks the site. A rollback never touches `main`, is never retried by the engine, and
you can also roll back from the provider dashboard. If the engine stops mid-release (Ctrl-C, the app quitting, the emergency
stop), the release records where it was (`interrupted` while deploying, else `failed`) and nothing runs again on restart.

**Human tasks.** Agents, and the engine, ask you for things only a person can do. The templates are engine-written, with
their links, steps and paste-back fields: `hosting-account` (the provider token into your Keychain, plus the account ID),
`domain` (buy or connect a domain, with the DNS records to add), `stripe-test-keys` (test-mode keys only; a live key is
refused) and `launch-post` (the text to post, with links that open the post pre-filled on X, LinkedIn and Hacker News, and a
field for the posted URL). An agent's own custom task can only ask for https links and URL fields; whatever you type in a
non-secret field is shown to the agent that asked, so the form says so. Secret values go to the Keychain and are recorded only
as "saved". Do a task with `brahma task done <co> A-<n> --field name=value [--secret NAME]` (secrets read from standard input)
or in the Inbox; decline it with `brahma task decline`. A work item an agent blocked on the task resumes when you answer.

**The demo.** `brahma company create <name> --demo live [--goal …]` creates the goal-to-URL demo: a four-agent org (`ceo`,
`cto`, `eng-1`, `devops-1`; autonomy `important`), hosting on the default provider with the project named after the company,
the `hosting-account` task already in your Inbox, and the owner's kickoff in #general. Do the hosting task, then approve the
brief and the deploy when they arrive. The default goal is a one-page waitlist site. `brahma dev release-scenario` (with
`BRAHMA_DEV=1`) populates a dev home's Releases and Inbox against a loopback dev host; it never contacts a provider.

**Start from an existing repo.** `brahma company create <name> --goal … --from-repo <folder|https-url>` (or EXISTING REPO
in the app's New company sheet) clones an existing repository into the new company's workspace. The source is a local folder
holding a git repository, or an `https://` URL. Nothing else: ssh, `git@…`, `git://`, `http://` and hand-typed `file://` are
refused, and so is a URL with credentials or a query (put credentials in a human task, not in the URL; for a private repo,
clone it yourself and pass the folder). The engine fetches it itself, never an agent turn, through its hardened git: an
empty template (no hooks), one fetch by URL and refspec (no remote is ever configured, so the original is never pushed to
and is never changed), fsck on every object, no tags, no submodules, no LFS smudge, no filters, hooks or fsmonitor, TLS
verified, a redirect followed only to https, no credential helper, prompt or `~/.netrc` (the fetch runs with an empty
home), git's output capped (a server that floods it is cut off), and a 600 s limit per step. A folder is fetched from its
own `.git`, which must be a plain repository git resolves to itself (not a linked worktree's `.git` file). Its git config
is checked first: one that names a program (a hook path, fsmonitor command, filter, pager, include, credential helper and
the like), a partial clone or promisor remote, or an unknown repository format refuses the import; import a fresh
`git clone` of it instead. A repo that tracks anything under `.brahma`, `.brahma-tmp` or a `.git` (in any case), or a
symbolic link that is absolute, has a `..` part, passes through another link or points into those names, is refused. History: from a folder, the current
branch's full history comes over and becomes `main`; from https only the tip comes over (`--depth 1`), as one root commit
whose message names the upstream commit. Before the company exists the import is refused, and nothing is kept, when the
repo is over 2 GB (working tree plus `.git`, also enforced while the fetch runs) or 100 000 files, or uses Git LFS. The
repo's `.claude/`, `.mcp.json`, `CLAUDE.md` and `AGENTS.md` stay plain files that no turn loads. Everything imported is
scanned for secrets; findings (names and files, never values) become one Inbox question, and the import goes ahead. The
CTO (or the CEO) gets a ready spike to survey the repo and propose its check, preview and deploy config. Everything
imported is outside content: until you trust it, every turn of the company (work, plan, review, audit) is tainted at
launch (`import: <host>`, `import: local` for a folder), so decisions, owner requests, sprint plans, preview, smoke and
deploy config, deploy proposals and review verdicts are off. `brahma company trust-import <co>` shows the source, the
imported commit and the secret scan's result; with `--yes` (the engine stopped, after reading the repo or the survey) it
lifts the mark and ends every tainted session. Agents' labs stay marked until `brahma lab clear-taint <co>`. Every new
import is tainted again, even of a repo you trusted before.

```
brahma preview <co>                                            previews: name, kind, status, url, commit
brahma preview set <co> <name> --run <cmd> --url <url> [--build <cmd>] [--smoke "GET / 200"]
brahma preview remove|restart <co> <name>
brahma hosting show <co>
brahma hosting set <co> [--provider cloudflare-pages|vercel] [--project <name>] [--account-id <id>] [--production-url <https url>]
brahma release <co>                                            releases, newest first, then main's smoke result
brahma release show <co> R-<n>                                 the exact deploy and rollback commands, smoke results, output
brahma release rollback <co> R-<n>                             roll the live release back (owner only)
brahma release smoke <co>                                      run the smoke check on main now (owner only)
brahma task <co> | task show <co> A-<n>                        pending human tasks; one task's steps, links (with hosts) and fields
brahma task done <co> A-<n> --field name=value [--secret NAME] mark it done (secrets from standard input)
brahma task decline <co> A-<n> --note <text>
brahma milestones <co>                                         the path-to-live scorecard
```

## Backups

Backups live under `<data home>/backups/` and are made by the engine (the app, or `brahma run`) while it runs:

| What | When | Kept |
| --- | --- | --- |
| Database snapshot (`VACUUM INTO`, integrity-checked) | every hour | 48 |
| Repository bundle per company (`git bundle --all`, verified; skipped when no ref moved) | daily at 03:30 | 14 per company |
| Data-home snapshot (hard-linked against the previous one) | daily at 04:00 | 30 |
| Copy to every off-machine target | daily at 04:30 | |
| Database snapshot before a migration | when a migration runs | 10 |
| Manual database snapshot (`brahma backup now`) | when you ask | 20 |
| Database snapshot before a restore | when you restore | 5 |

A snapshot that fails its check is deleted and nothing is pruned. A failed backup posts a "Backup failed" notice.

**What is included.** The data-home snapshot holds everything under the data home (archives, transcripts, role cards,
company files) except `run/`, `backups/`, `tmp/`, `cache/`, `owner/` and `secrets/`, SQLite `-wal`, `-shm` and `-journal`
files, `*.lock` files and the live `brahma.sqlite` (which has its own snapshots). SQLite files in it are integrity-checked
copies. Links are never followed. Secrets and the owner key are never backed up. Workspaces are backed up only as their
git history (the bundles): uncommitted files in a workspace are not, and neither are agent labs (separate repositories
under `.brahma/labs`) or other `.brahma` state outside the workspace's git history.

**Restore.** Quit the app and `brahma run` first.

```
brahma restore --list                  the database snapshots, newest first (also: brahma backup list)
brahma restore --latest                the newest snapshot that passes its integrity check
brahma restore --at <ISO-8601 time>    the newest snapshot at or before that time
brahma restore <snapshot file>
  --with-files                         also put the data home's files back, from the newest data-home snapshot at or
                                       before the database snapshot (it may be up to a day older)
  --dry-run                            check the snapshot and show what would happen; change nothing
```

The current database is kept next to it as `brahma.sqlite.pre-restore-<time>`, and with `--with-files` whatever the files
replaced is kept in `<data home>/.pre-restore-<time>`.

A restore comes back stopped: nothing runs until `brahma resume`. Before the swap it reads the current database and
writes into the restored one what must not roll back:

- grant revocations and used-up uses, and a revocation of every grant that had already ended in the current database
  (revoked, used up, expired on company-active time, or its sprint ended);
- every taint mark: agent sessions, items, lab and company marks, the machine-wide mark, and lab commits recorded tainted.

It also always sets the machine-wide lab mark, so no lab commit made after the snapshot is recorded clean; clear it with
`brahma lab clear-taint --machine-wide` once you have checked the labs.

For each security-relevant company setting, the restore keeps the stricter of the current and the snapshot's value:
autonomy, the company and role profiles, toolchain read paths, network and web domains (only entries both allow are
kept), local listening, auto-merge, and the pause. Owner-wide, auto-merge stays off if it is off now, and the
auto-merge folder list is the narrower of the two. Where auto-merge is kept off, auto-approvals in the snapshot that
have not landed go back to a normal review, as when you switch it off. Other rows are not carried, only reported:
companies and agents removed after the snapshot come back, and so do disabled or removed extensions, access presets
and removed secret entries (their values are not restored). The restore lists each setting it kept stricter and each
row it brought back. The list is printed by the CLI, put in the stop note and raised as an engine alert in every
company. Review it before you resume. If the current database cannot be read, every grant is
revoked, every agent session and open item is marked, and the list says that what was rolled back is unknown. Ultra
approvals used after the snapshot become usable again, and messages, hand-offs and events made after it are gone.

Git repositories are never touched: after you resume, Brahma re-adopts each company's `main` as the snapshot recorded
it. Commits made after the snapshot are kept, but Brahma alerts you and holds that company until you review `main` and
accept it (`brahma main accept`).

**Export.** `brahma export <company> --to <new directory> [--no-workspace]` writes a self-contained copy of one company:
its database rows, its repository as a bundle (left out with `--no-workspace`), its files, transcripts, archive and roles.
Machine-specific records (turn tokens, restore records, the stop, the canary) are left out.

**Off-machine targets.** `rclone` and `litestream` are not bundled; without them those features read "unavailable".

```
brahma backup target add folder <path>   mirror the backups to <path>/<hostname>/ (an external drive, a NAS mount)
brahma backup target add rclone <remote> upload through an rclone remote, which must be of type crypt
brahma backup targets                    list them
brahma backup target rm <n>
brahma backup now [--targets]            a database snapshot now, then (with --targets) a copy to every target
```

A folder must exist, be writable and lie outside the data home and every workspace; it is checked again on every copy.
A drive that is not connected is skipped, with one notice a day. Sandboxed turns and
sandboxed checks can neither read nor delete a folder target or the WAL replica folder. On the Workspace profile
Claude's file tools are denied them too, but the agent's Bash is not sandboxed and can reach them; Full-profile turns
and checks can reach them.

**WAL shipping (optional).** `brahma backup wal enable <replica>` ships the database's write-ahead log with Litestream to a
folder (with a folder target's checks) or a URL Litestream understands (`s3://bucket/path`); `brahma backup wal disable`
stops it. Both take effect when the engine next starts. Credentials go in the engine's environment (`AWS_*`,
`LITESTREAM_*`, `SSH_AUTH_SOCK`), never in the URL. With it on, `brahma restore --at` first has Litestream rebuild that
moment (checked before it is used) and falls back to the newest snapshot if that fails. `brahma doctor` reports
`wal-shipping` and `backup-targets`.

**In the app.** Settings › Backups shows the last hourly snapshot, the last data-home snapshot and the last target copy,
lists the targets (add and remove), has the WAL switch (disabled with "Install litestream to enable" when Litestream is
missing) and Back up now.

Include ~/Library/Application Support/Brahma and ~/Brahma in Time Machine; Brahma's own backups live inside the first.
