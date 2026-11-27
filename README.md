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

## Agent map

The agent map is a live org chart of one company, drawn in SpriteKit from the same snapshot the rest of the app reads.
Today it opens in its own window (menu Window → Agent Map) and in `--map-demo`; the in-window Mission Control slot
arrives with the Plan 4a / Collab-MVP layout.

**What it shows.** Board at the top, then executives, directors, managers and ICs, in team bands. Each card has the
agent's handle, role, a state (`ready`, `running`, `blocked`, `sleeping`, `killed`; paused agents look like sleeping),
its current work item and, when blocked, the blocker. Where people data exists (3b) a card also shows the trust chip,
perks and the usage meter. Open seats are `OPEN · <ROLE>` cards. A dashed line runs from a reviewer to the owner of
every item that is in progress or in review.

**What moves.** Messages and broadcasts travel as particles along the reporting lines, hand-offs are labelled with the
item key, and a sprint meeting is a hull drawn around its participants. Hires, terminations, reorgs and promotions are animated.

**Controls.**

- Above 60 active agents managers (and directors whose reports are all ICs or vacancies) start folded into stubs
  (`▸ N REPORTS`); click a stub or a manager's `▾` to open or fold a subtree.
- Search and jump to an agent (it is revealed and highlighted), follow an agent, zoom to fit, show former agents.
- Vacancies: `brahma org vacancies <company>` lists them, `brahma org fill` hires into one (3a), and
  `brahma org vacancy add|remove <company> ...` (4b) opens and withdraws seats; the map's context menu does the same.
  **Fill asks for confirmation** in a sheet, because it starts a paid agent. Vacancies that come from a provider
  are display-only.
- Replay: the last hour can be scrubbed and played back at speed. Meetings and reorgs are not replayed. When the hour
  holds more than 20 000 messages or state changes, the newest are kept, the replay starts where they start and is shown
  as truncated (the start of the hour is cut). A replay never writes: vacancy actions wait for LIVE.
- Pop-out window and full screen.

**Bursts.** Messages between the same pair within half a second are coalesced; above 30 messages per second the map switches
to aggregate mode (no particles, the edge pulses instead, with an `AGGREGATE · <rate> MSG/S` label) and drops back below 20; the particle
queue is capped at 400, oldest traffic first.

**What the map shows about agents.** Item titles and blocker reasons are redacted by the store's redactor and cleaned
(control characters, length) before they are drawn. Vacancy notes are owner-only and redacted (again when drawn; hidden
while the secrets are not loaded). `system` traffic is not drawn. After a database restore from a backup the map starts
fresh (old traffic is not replayed). While its window is closed the map keeps its chart current but queues no
animations; reopened, it starts from the traffic of that moment. Actions taken in the map window (select an agent,
message, add or fill a vacancy, hire) bring the main window to the front, where they open.

**Demo and snapshots.**

```
scripts/map-demo.sh [agents] [--flag=value ...]  # read-only synthetic company, no write actions, temp home
scripts/map-snapshots.sh                          # offscreen PNGs of the scenes into .superpowers/maps
Brahma --map-demo --map-demo-agents=300           # the same demo, straight from the app binary
Brahma --map-bench=20                             # implies --map-demo: prints one MAP BENCH line and exits
```

`--map-bench=<s>` measures the on-screen frame rate for `<s>` seconds and prints
`MAP BENCH mode=org agents=<n> fps=… p95=…ms max=…ms dropped=… aggregate=…s`. The display must be awake. AppKit
treats a flag followed by a separate value (for example `--ui-snapshot <path>`) as a file to open when it comes after
the first `--flag=value` argument, so put such flags before the first `--flag=value`; the `=` forms can go anywhere.
`scripts/map-demo.sh` appends its extra arguments after `--map-demo-agents=<n>`, so only `=`-form flags work through it.

**Measured numbers.** Apple M4 Pro, macOS 26.2 (build 25C56), release build. The offscreen runs drive a synthetic company through `OrgScene` and `SKRenderer`
into a 1600×900 texture at a fixed 1/60 s step for 30 s (50 msg/s and a 200-message burst every 10 s; 120 msg/s for the
aggregate run; 15 msg/s and no bursts for the particle run); a frame is the controller frame, scene update and GPU work (the controller's 500 ms poll, which applies the new snapshot,
runs outside the timed window; the on-screen bench includes the synthetic poll). Live-store snapshot applies (redaction
lookups, the vacancy, review-line and meeting rebuild and a full model apply on every app snapshot reload) are not
measured. Reproduce with
`BRAHMA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter MapPerfTests` and `Brahma --map-bench=20`.

| Measurement | Result |
| --- | --- |
| Offscreen, 300 agents, default collapse, aggregate mode (50 msg/s) | mean 0.8 ms, p95 1.3 ms, max 3.6 ms (1245 fps), 0 frames over 16.7 ms |
| Offscreen, 300 agents, fully expanded, aggregate mode (50 msg/s) | mean 2.2 ms, p95 3.4 ms, max 14.5 ms (461 fps), 0 frames over 16.7 ms |
| Offscreen, 300 agents, fully expanded, particles (15 msg/s, no bursts) | mean 1.8 ms, p95 3.0 ms, max 13.3 ms (542 fps), 0 frames over 16.7 ms, no aggregate time |
| Offscreen, aggregate fallback, 500 agents (600 asked, the generator maximum is 500), 120 msg/s | mean 1.1 ms, p95 2.2 ms, max 4.5 ms (931 fps), 0 frames over 16.7 ms |
| On screen, 300 agents, aggregate mode (50 msg/s), `--map-bench=20` | 60.0 fps, p95 17.1 ms (display refresh jitter), max 25.0 ms, 1 dropped frame |
| Queue step (`MapQueueTests.stepCostAt300`, 300 agents, 50 msg/s) | mean 0.00055 ms per step, release build (Task 5 recorded 0.000543 ms) |

"Particles" rows draw message particles (rate under the 20 msg/s exit threshold); "aggregate" rows are above the 30 msg/s
enter threshold, so no particles are drawn and edges pulse instead. Timings vary by a factor of two or so from run to run
with machine load; the 60 fps budget (16.7 ms at the 95th percentile) is met with a wide margin offscreen.

Hive and Village arrive in Plan 4c on the same `MapModel`.

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
the default: its free plan serves static sites with no commercial-use restriction and a scoped API token is enough.
**Cloudflare deploys are unverified until a Cloudflare probe runs:** the owner's provider probe covers Vercel only, so no
real `wrangler pages deploy` has run under the engine yet. The engine expects `wrangler` to print the deployment URL
(`https://<8 hex>.<subdomain>.pages.dev`) on its "Deployment complete!" line; the subdomain is the project name, or the
project name with the short suffix Pages adds when that name is taken on `pages.dev`. The site is smoked at your production
URL, else at the address derived from that deploy URL, never one guessed from the project name; when neither is there the
release fails and asks you to set the production URL in HOSTING. Vercel is the alternative (its free Hobby plan is for
non-commercial use; deploys need the team or account ID). **The Vercel project must already exist:** deploys name it
(`VERCEL_PROJECT_ID`) and never create it, so create it in the Vercel dashboard (Add New… → Project, or `vercel project add
<name>`); the `hosting-account` task and `brahma hosting show` say so. **A Vercel release needs your production URL in
HOSTING:** Vercel's per-deploy URLs sit behind its deployment protection, so a release is smoked only at the production URL,
never at a per-deploy URL or a guessed `<project>.vercel.app` (that name may belong to someone else). With none set, a
proposal is refused ("set the production URL in HOSTING before deploying to Vercel …"), and an approved release whose
production URL was cleared since fails before anything is built or deployed. Unverified until the probe runs
a deploy → rollback → deploy cycle: after a `vercel rollback`, Vercel may stop assigning production to later `--prod` deploys
until you run `vercel promote` (or promote in the dashboard), so after a Vercel rollback check that the next release really
went live. Both CLIs are pinned to exact versions and installed by the engine, token-free, into a folder agent code cannot
write. Hosting tokens arrive through the `hosting-account` human task and go to your Keychain. The token is never in a
prompt, an argument, a log or the database; who else can read it while a deploy step runs depends on the company's profile
(see "Where that paragraph (the plan's wording) is not exact" below).

**The deploy ask.** `propose_deploy` records a release (`R-<n>`, a version unique in the company, the exact `main` commit) and
puts one ask in your Inbox showing the provider and project, the commit, the release notes, the build command and output
folder, the smoke check that runs on `main` just before deploying (`main` must already be green at the commit to propose),
the deployed site's smoke requests and expected text, and the exact deploy and rollback commands the engine will run. The
smoke checks are pinned to the release: if an agent changes the smoke check or the site's smoke after you approve, the
release is refused ("propose again") before anything runs. Approving it is the only
way a deploy starts; `brahma approve` and the app do it, no tool can. The engine then, in order and each step recorded before
the next: checks the commit is still on the engine-accepted `main` and runs the smoke check at it (when a merge lands while it
waits for the company's smoke slot, it checks the commit against the new `main` and goes on); re-renders the plan and
refuses if anything differs from what you approved; records `refs/brahma/main-backup` and `refs/brahma/releases/<version>`;
builds in a clean `.git`-free export of the commit (sandboxed, no secrets, 30 minutes at most); stages the upload (at most
500 MB, 20 000 files; never a symlink, a hard link or an `.env` file): for Cloudflare the output folder, plus `functions/`
when the commit has one; for Vercel the whole export of the commit after the build, source included (Vercel builds and serves
from it), minus every dot entry but `.well-known` and every `node_modules`; installs the provider CLI if missing; runs the
deploy steps (15 minutes each) with the token only in their environment; smoke-checks the live URL (6 attempts, 10 s apart,
for CDN propagation); and marks the release `deployed` or `failed`. You are told either way; a P1 bug is filed for the agents
only when they can fix the failure (the build, the staged output, the smoke check failing on `main`, the deployed site
failing its smoke), never for your side (the approved plan changed, the token, provider config, the tools, the backup refs,
the sandbox). The redacted deploy and build logs land in
`<workspace>/.brahma/releases/R-<n>/`, which agents can read and never write.

**The smoke check on `main`.** `set_smoke_check` sets the command the engine runs, sandboxed in a clean export, on every new
`main` and before every deploy (10 minutes by default, 60 at most). While it fails `main` is red: the engine files a bug and
deploys are blocked. A deploy needs a passing smoke run at the exact commit being deployed; `brahma release smoke` runs it on
demand.

Preview and build commands are written by agents and run in Plan 5-lite's sandbox, in fresh engine exports of main that contain no .git, in their own process group, with no secrets. Deploy and rollback commands are composed by the engine from your hosting settings, shown to you exactly in the deploy request, and run once after you approve, from a clean folder holding only the built files, using a provider CLI the engine installed where agent code cannot write, with the hosting token taken from your Keychain. Agents never receive the hosting token.

*Where that paragraph (the plan's wording) is not exact.* "Only the built files": true for Cloudflare; Vercel's upload is the
clean export of the commit after the build, source included (see above). "Agents never receive the hosting token": no agent is
ever given it (it is in no prompt, argument, file or tool result), and on the **Sandboxed** profile an agent turn also cannot
read another process's environment. On the **Workspace** and **Full** profiles agent shells run as your macOS user without
that restriction, so while a deploy or rollback step runs, an agent process running at the same moment could read the step's
environment, token included. That is a documented limit of those profiles: deploy from a Sandboxed company when the token
matters, or rotate the token after a deploy you did not watch.

**Releases, rollback and recovery.** Work › Releases lists every release with its status, commit, URL and smoke result; the
PATH TO LIVE strip shows `main`'s health and the milestones (`GOAL 0:00 · PRD +0:52 · … · LIVE +3:10`) with what each stretch
cost and how often you were needed. Only the live release can be rolled back: the newest one that changed, or may have
changed, what is live (deployed; interrupted while deploying; or failed after its deploy step started; a release that
failed before deploying changed nothing), with nothing in flight (an open proposal: reject its ask first). `brahma release
rollback <co> R-<n>` or the Roll Back button runs the rollback commands recorded with that release, exactly as shown (they
put the release before it back, or the placeholder page for the first one), then smoke-checks the site. A rollback never
touches `main`, is never retried by the engine, and you can also roll back from the provider dashboard. If the engine stops
mid-release (Ctrl-C, the app quitting, the emergency stop), the release records where it was (`interrupted` while deploying,
else `failed`) and nothing runs again on restart; an interrupted release may be partly live, and rolling it back is the
undo. Restoring a backup cancels every release the snapshot held approved but not yet started ("restored from backup;
propose again") and every rollback it held requested ("restored from backup; request it again"; the release keeps its
status, so you can request it again): an approval or a rollback request is never carried out from an old snapshot, and the
restore's warnings name each one.

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

**The owner's provider probe (Vercel).** Every Vercel pin, host list and output format the engine relies on was read from the
CLI's package, never seen against the real service, because the provider token is yours and never passes through an agent.
`brahma hosting probe <co>` (hidden; owner only; refused in an agent turn, for any provider but `vercel`, without a stored
`VERCEL_TOKEN` or an account ID, and while an engine runs on the data home) verifies them once with your token: it installs the
pinned CLI token-free, stages an engine-written marker page under the releases folder, runs the real deploy plan through the
real sandbox (token in the environment only, provider-config check, redaction gate, stdout-only URL parse, `vercel inspect`)
against a throwaway project `brahma-probe-<6 letters or digits>`, smokes its own deploy URL for the marker (the per-deploy URL
parsed from the deploy step's stdout and pinned to the probe's project; the probe records no production URL, so your HOSTING
production URL is never used), reads the hosts
the CLI contacted from the engine's egress proxy, removes the project and lists what is left. It prints one `PASS`/`FAIL`/
`NOTE` line per item (CLI pin, network hosts, HTTPS_PROXY honoured, deploy URL, the 9-character URL hash, `Production:` on
stdout, inspect, smoke, `.env` not read, `GIT_CEILING_DIRECTORIES`, project exists, promotion after rollback, project removed,
leftover projects) and an `INFO` line with
the deploy output's tail, all redacted, never the token, then `VERDICT ok: N passed, K noted (not decided)` or `VERDICT n items failed (…)`: a NOTE is an item this run could not
decide (`.env` is always one: the engine refuses `.env` in release uploads, so the probe plants none; so are "project exists",
because the probe creates its own project while a real release never does, and "promotion after rollback", which it does not
exercise). The probe covers Vercel only: Cloudflare Pages, the default, stays unverified. The `brahma-probe-`
project-name prefix is reserved for it: it deletes nothing else, and a leftover under that prefix is reported by name (the
listing may be paginated or use the CLI's default scope, so also check the dashboard). An interrupted probe (Ctrl-C, a closed
terminal) skips its cleanup: the throwaway project stays (the next run names it as a leftover) and so does
`<releases>/probe-<suffix>/` with any step output not yet read; delete both. Run it on a throwaway data home
(`BRAHMA_HOME`/`BRAHMA_WORKSPACES`), never on your real one with a development build. The live test (`BRAHMA_LIVE=1 … LiveSmokeTests/goalToLiveURL`) runs the whole goal-to-URL path against a
fake host on loopback and says so (`FAKE HOST`); only this probe proves a real provider.

**Start from an existing repo.** `brahma company create <name> --goal … --from-repo <folder|https-url>` (or EXISTING REPO
in the app's New company sheet) clones an existing repository into the new company's workspace. The source is a local folder
holding a git repository, or an `https://` URL. Nothing else: ssh, `git@…`, `git://`, `http://` and hand-typed `file://` are
refused, and so is a URL with credentials or a query (put credentials in a human task, not in the URL; for a private repo,
clone it yourself and pass the folder). The engine fetches it itself, never an agent turn, through its hardened git: an
empty template (no hooks), one fetch by URL and refspec (no remote is ever configured, so the original is never pushed to
and is never changed), fsck on every object, no tags, no submodules, no LFS smudge, no filters, hooks or fsmonitor, TLS
verified, a redirect followed only to https, no credential helper, prompt or `~/.netrc` (the fetch runs with an empty
home), git's output capped (a server that floods it is cut off), and a 600 s limit per step. A folder is fetched from its
own `.git` by a strict upload-pack, and that `.git` must be a plain repository git resolves to itself (not a linked
worktree's `.git` file, nothing nested at `.git/.git`). Its git config
is checked first: one that names a program (a hook path, fsmonitor command, filter, pager, include, credential helper and
the like), a partial clone or promisor remote, or an unknown repository format refuses the import; import a fresh
`git clone` of it instead. A repo that tracks anything under `.brahma`, `.brahma-tmp` or a `.git` (in any case), or a
symbolic link that is absolute, names `.` or the root, has a `..` part, passes through another link, points at a folder
holding other links or into those names, or any path under a link, is refused. Names are compared as the Mac's volume
compares them (ignoring case, `É` composed or not). History: from a folder, the current
branch's full history comes over and becomes `main`; from https only the tip comes over (`--depth 1`), as one root commit
whose message names the upstream commit. Before the company exists the import is refused, and nothing is kept, when the
repo is over 2 GB (working tree plus `.git`, also enforced while the fetch runs) or 100 000 files, or uses Git LFS. The
repo's `.claude/`, `.mcp.json`, `CLAUDE.md` and `AGENTS.md` stay plain files that no turn loads. Everything imported is
scanned for secrets; findings (names and files, never values) become one Inbox question, and the import goes ahead. The
CTO (or the CEO) gets a ready spike to survey the repo and propose its check, preview and deploy config. Everything
imported is outside content: until you trust it, every turn of the company (work, plan, review, audit, and your own
`brahma ext try` trials there) is tainted at launch (`import: <host>`, `import: local` for a folder), so decisions, owner requests, sprint plans, preview, smoke and
deploy config, deploy proposals and review verdicts are off. `brahma company trust-import <co>` shows the source, the
imported commit and the secret scan's result; with `--yes` (the engine stopped, after reading the repo or the survey) it
lifts the mark and ends every tainted session. Agents' labs stay marked until `brahma lab clear-taint <co>`, which refuses
while the import mark stands (only trust-import ends it). Every new import is tainted again, even of a repo you trusted
before.

```
brahma preview <co>                                            previews: name, kind, status, url, commit
brahma preview set <co> <name> --run <cmd> --url <url> [--build <cmd>] [--smoke "GET / 200"]
brahma preview remove|restart <co> <name>
brahma hosting show <co>
brahma hosting set <co> [--provider cloudflare-pages|vercel] [--project <name>] [--account-id <id>] [--production-url <https url>]
brahma hosting probe <co>                                      owner only, hidden: the live Vercel probe (see above)
brahma release <co>                                            releases, newest first, then main's smoke result
brahma release show <co> R-<n>                                 the exact deploy and rollback commands, smoke results, output
brahma release rollback <co> R-<n>                             roll the live release back (owner only)
brahma release smoke <co>                                      run the smoke check on main now (owner only)
brahma task <co> | task show <co> A-<n>                        pending human tasks; one task's steps, links (with hosts) and fields
brahma task done <co> A-<n> --field name=value [--secret NAME] mark it done (secrets from standard input)
brahma task decline <co> A-<n> --note <text>
brahma milestones <co>                                         the path-to-live scorecard
```

## Merge queue and main

Plan 4a replaces the one-item merge step with a merge queue and makes one rule of `main`: only the queue moves it.

**Done means merged.** An approved item is not done when its reviewer says so; it is done when its verified commit is on
`main`. The approval queues a merge request (`M-<n>`; Work › Merge queue in the app, `brahma merge <co>`), pinned to the
exact commit the engine checked and the reviewer saw (never a branch re-resolved later). The queue takes requests in order:
it rebases the pinned commit onto `main` in the engine's own repository under the data home (never in a checkout an agent can
write), re-runs the item's check and the company's **main check** (`set_main_check`, CTO only; or Settings… on the panel) in a
fresh, `.git`-free export under the sandboxed check runner, scans the candidate for the company's known secret values, writes
`refs/brahma/pre-merge/<n>` at the old head, and lands by fast-forward (`ff`, the default) or with a merge commit (`merge`).
A rebase conflict, a failing check or a leaked secret **bounces** the item back to its holder with the files (3a's conflict
brief) or the redacted tail; the holder fixes and submits again, and the reviewer approves again.

**Flakes, infrastructure and a red main.** No innocent item is bounced: a check that fails once is re-run once, and a pass
after a fail is a pass flagged `flaky`; a run the engine could not complete (an export that failed, a network drop, a stop)
is inconclusive and re-queued, up to 3 times, before it is returned as uncheckable; a candidate whose main check fails is
charged only after the same check passes at the base, else `main` itself is red, the queue is **held** ("the main check fails
on main itself"), you are told, and the hold lifts by itself when a new head passes. `main` moving under a batch re-queues it
(3 times). **Batching and bisect.** With a batch size above 1 (`brahma merge settings <co> --batch <n>`, 1–8) up to `n`
requests are rebased onto each other and checked as a whole; a failure is bisected to the first culprit, which is bounced
alone, and the rest land. **The journal.** Every step of a batch (`claimed`, `rebased`, `checked`, `backedUp`, `landing`,
`landed`, `recorded`, `cleaned`, `done`) is written as the batch passes it; after a crash or the emergency stop the engine
resumes from the journal, so nothing lands twice or is lost (an unfinished batch shows as `BATCH AT <STEP>` on the panel).
A `failed` request (the engine's own fault, 3 attempts) is yours to retry from the panel or `brahma merge retry`.

**The main policy.** `company.mainCommit` is the engine's record of `main`; it is written at the company's creation, by the
queue's journaled landing, by a restore of a backup, and by you (`adopt-main`). Every tick the main guard compares
`refs/heads/main` with the record: a head that is not the record is **foreign**, whoever made it (an agent's commit at the
root, a reset, an amend, a hand commit of yours, a forged "unattributed" commit) and whatever its subject says. The other tip
is saved under a unique `refs/brahma/foreign/<yyyyMMdd-HHmmss>-<n>`, `main` is put back by a ref compare-and-swap (the root
checkout is never touched when it is off `main`), and you are told in the activity feed and a notice. Uncommitted edits at the
root are not a move; when a batch finds them it quarantines them (3a, `refs/brahma/quarantine/*`) and the queue waits for
your decision. The engine's own journaled commit is accepted; a database restore re-adopts the head the restored record names.
`brahma merge adopt-main <co> [<commit|ref>]` makes `main` as it stands (or a saved foreign tip) the record.
`refs/brahma/pre-merge/<n>` marks what `main` was before batch `n` landed (the queue's); `refs/brahma/main-backup` is L's
record of the last deployed commit (the release executor's); neither is a tag and neither moves `main`.

```
brahma merge <co>                                              the settings line, then each request (M-<n>, key, status, owner, detail)
brahma merge settings <co> [--batch 1..8] [--strategy ff|merge] [--main-check <cmd> [--main-timeout <s>] | --clear-main-check]
brahma merge retry <co> M-<n>|<KEY>                            put a failed merge back in the queue (owner only)
brahma merge resume <co>                                       release a held queue (owner only; a root-behind hold lifts once the root is on main)
brahma merge adopt-main <co> [<commit>|refs/brahma/foreign/…]  make main as it stands (or a saved tip) the engine's record (owner only)
brahma artifacts <co>                                          published artifacts, newest first (AR-<n>; asks keep A-<n>)
brahma artifacts publish <co> <path> [--title <t>]             publish a workspace file or folder (owner only; agents use publish_artifact)
brahma artifacts rm <co> AR-<n>                                delete an artifact and its copy (owner only)
brahma preview set <co> <name> --kind web|backend|cli|ios|macos … set a preview the engine builds from main (owner only)
```

**Previews beyond the web.** The preview pane shows one tab per surface and one for artifacts. A `cli` preview runs a demo
command (120 s, in the sandbox) and shows its sealed output as a terminal (ANSI colors mapped to the theme, 2000 lines, 4096
bytes a line); a `backend` preview shows its smoke rows, log tail and, when the server publishes one, its OpenAPI operations
(≤ 2 MB, read inside the run). A `macos` preview launches the built app under the sandbox's GUI policy and captures its window
(≤ 10 fps); an `ios` preview boots the app in the Simulator and polls screenshots (500 ms). **The iOS owner gate:** the
Simulator runs outside Seatbelt, so an iOS surface stays unavailable until you approve the engine's ask in the Inbox, which
states that risk; the approval belongs to that exact build, and a change of kind, path or bundle id asks again. Window capture
needs macOS **Screen Recording** permission for Brahma; without it the pane says so and shows nothing. **Artifacts** are files
agents publish from their worktree (`publish_artifact`, a copy only, never a URL): HTML (confined to `file:`), Markdown, PDF,
images (decoded in process only up to 64 Mpx), tables (CSV, 2000 × 100), spreadsheets and documents (Quick Look), 3D models
(glTF in process up to 20 MB, 2 M vertices), **CAD files as cards** (name, size, format; opened in your own app), video (a 9:16
clip plays inside a **phone frame**), text and code. Content is sniffed, not trusted by extension; playlists, FIFOs and
symlinks that leave the run are refused; a company holds 2 GB of artifacts and an agent publishes 20 an hour.

## Measuring a company

`brahma measure` reports how a company is doing, from the engine's own records (the database and the company's own workspace
repository). Every number carries its denominator (`97.4% (38/39)`). A rate over fewer than 20 events prints
`insufficient data (n=<n>)`. A metric whose source this build does not have prints `not applicable: <reason>`, and one whose data
was never recorded prints `not measured: <reason>`. Nothing is estimated. Every metric, its source and its basis is defined in
[docs/measure/metrics.md](docs/measure/metrics.md). Every mode runs only from your shell: each refuses to run inside an agent turn.

```
brahma measure <co> [--since <YYYY-MM-DD|all>] [--format md|json]   the report (default window: the last 28 days)
brahma measure <co> --mission [--since …] [--format md|json]       only the mission subset
brahma measure <co> --compare <baseline-co> [--mission] [--since …] [--format md|json]   two companies side by side
brahma measure <co> --verify-landings [--since <date>] [--format md|json]  audit main: exit 0 / 1 / 2
brahma measure <co> --log-owner-minutes <n> [--day YYYY-MM-DD]     log your own time on the company (owner only)
brahma measure <co> --soak-checkpoint <file>                       soak harness: write a checkpoint
brahma measure <co> --soak-verify <file> [--format md|json]        soak harness: judge against it: exit 0 / 1 / 3 / 2
brahma items link <co> <KEY> regression-of|revert-of <LANDED-KEY>   record a regression or a revert (owner only)
```

- **The report.** `--since <date>` starts at midnight of that day in your time zone; `--since all` starts when the company was
  created; the default is the last 28 days. `--format json` prints the same report as JSON (every value, its numerator and
  denominator, its status and basis). The revert rate's 30-day row needs a window of at least 30 days (`--since` a date 30 or
  more days back, or `all`); with the default window it reads `not measured` and says why.
- **The Budget view's MEASURE panel** shows the same report for the selected company: one row per metric with the value exactly
  as the CLI prints it, the basis beside it, detail rows under a metric that has them, and a 7 days / 28 days / all window
  picker. Opening Budget, the picker and Refresh measure at once. A change to the company's work or usage while Budget is open
  measures again at most once a minute (one more measurement queued for the minute's end). Leaving a company or window stops
  its measurement.
- **`--verify-landings`** walks `main`'s first-parent history back to the company's first commit and classifies each commit:
  landed by the merge queue (verified), accepted by you (`brahma main accept`, `brahma merge adopt-main`, a quarantine accept;
  recorded in `mainAccept`), the imported first commit, or unverified. It prints `landings verified: <p>% (<n>/<d>)` and lists
  each unverified commit. Exit **0**: every commit is classified. Exit **1**: there are unverified commits, or the walk stopped at
  its bound of 10,000 commits. Exit **2**: it could not audit (no `main`, an unknown company, a git failure, planted history
  files, a merge batch moving `main`). An adopt from before `mainAccept` existed covers only the one commit its activity line
  names. If such an adopt brought in several commits, audit with `--since <a day after the first queue landing that followed
  the legacy adopt>` (the walk stops below the newest landing that finished before that day, so a landing must lie between the
  adopt and that day).
- **`--log-owner-minutes <n>`** adds `n` minutes (1–1440) of your own time to that day's count (today when `--day` is omitted).
  It is the only source of the owner-minutes metric: Brahma never records or estimates your time, and no agent can write it.
  Without a log the row reads `not measured: no owner-time records`.
- **`--compare <baseline-co>`** prints both reports over the same window and the same metrics, each cell with its own
  denominator. A baseline that does not exist or has no landings in the window reads `not measured: <reason>`. For a
  **single-agent baseline**, create a one-agent company on the same repository and backlog, run it under the same pacing for the
  same span, then compare. The full procedure is in [docs/measure/metrics.md §15](docs/measure/metrics.md#15-single-agent-baseline-owner-addition-1124-spec-864-baselines-is-the-authority).
  No script runs the baseline for you.
- **`--mission`** prints only what a long run is judged on: items landed, owner touches, usage per landed item, green-main
  rate, turns wasted on rate limits, reserve breaches and idle while actionable.
- **`--soak-checkpoint <file>`** records the company's `main`, item branches, leases, releases, open merges and running turns
  (0600, in a directory that exists). **`--soak-verify <file>`** judges the company now against it. Exit **0**: pass. Exit
  **1**: fail (lost commits, unrecovered leases, stuck merges, a repeated deploy, a turn not recorded as interrupted, or the
  company not running). Exit **3**: wait, because the engine has not restarted since the checkpoint or has not run 300 s yet.
  Exit **2**: could not verify.

**The 72-hour soak** (`scripts/soak/run-72h.sh <co> [--hours 72] [--kill-at 24] [--state <dir>] [--resume]`) is yours to run.
It never runs in the test suite. **It spends real usage:** it runs the company with real agent turns for days, and it refuses to
start unless `BRAHMA_LIVE=1` is set. It starts `brahma run` itself in a process group of its own, so Ctrl-C on the script never
stops the engine. It keeps the Mac awake, writes a checkpoint every hour, and at `--kill-at` sends SIGKILL to that engine (after
checking its pid, start time and command line). It then restarts the engine and records the `--soak-verify` verdict. At hour 48
it asks you to reboot; after you log in, `--resume` verifies and carries on. At the end it stops its engine, prints `--mission`
over the soak's days and prints every verdict. It writes only under `--state` (default `~/.brahma-soak/<co>`). Quit the Brahma
app (or any other `brahma run`) before you start it: only one engine may hold a data home.

## Memory, Handbook and Resources

Agents and you can find anything the company already knows. One search index covers every source, and the engine filters
every result to what the reader may see before anything reaches an agent. Ingest, ranking, auto pages, replay and the
storage meter are plain code: none of it runs an LLM turn.

**What is indexed.** The engine indexes these on its tick (in batches; a restore re-scans everything):

- messages in channels and DMs;
- work items (description, acceptance criteria, submit summary and the newest 50 comments);
- asks and their decisions, and mechanically recorded decisions;
- hand-offs under `.brahma/handoffs` (regular single-link files only; anything else is skipped with an activity line);
- sprint retros;
- handbook pages, one entry per section;
- resources (the text of text files up to 2 MB, first 200 000 characters; other kinds by name only);
- remembered facts (`remember`) and episodes. At the end of each successful work, notice or review turn, the engine
  writes an episode from the turn's summary into that agent's private memory.

Agents search with `search_memory` (cited snippets) and read one entry in full with `recall(ref: …)`. Refs are `mem:12`,
`F-3`, `ENG-7`, `kb:Path`, `A-4`, `msg:<id>`, `handoff:…`, `sprint:<n>` and `decision:<id>`. `recall(query: …)` searches the
agent's remembered facts and past work. `remember` saves a durable fact: the same key with the same fact confirms it, and a
different fact under the same key is kept as a contradiction (nothing is deleted). A fact that looks like a secret, or
holds a stored secret's value, is refused.

**Who can read what.** You (the owner) read everything. For an agent:

| Where it came from | Who reads it |
| --- | --- |
| A channel or DM message | the channel's or DM's members |
| A resource dropped in a channel or DM | the members when it was dropped (a later joiner of the channel does not get it) |
| A company-wide source (items, decisions, hand-offs, retros, company facts, the handbook, company resources) | every agent in the company |
| A team (a fact remembered with scope `team`, a team resource) | that team, and managers whose subtree contains it |
| A role | agents holding that role, including a merged executive who covers it |
| A fact remembered with scope `item` | the item's author, owner, lease holder and reviewer, and every manager up the owner's chain. This set is worked out at each read, so it changes as the item changes hands |
| A resource scoped to an item | a fixed set taken when it is added or rescoped: the item's owner, lease holder and reviewer, the owner's manager, and the agent that wrote the item (optionally also whoever owns or leases the item later) |
| An agent's private memory (`remember` with scope `mine`, episodes) | that agent in full; its managers up the chain see the title only (no snippet, and their queries match only the title) |
| An ask | per party: the agent that filed it, its internal approver and an agent that decided it. Your answer and your notes are yours alone; the asker gets your answer as the DM it already receives, and that DM is indexed as a DM. An ask filed by the engine is yours alone |
| HR or performance records, and anything owner-only | you alone |

A restriction is a cap on top of that: a handbook section marked `[restricted]` is for executives only, and
`[restricted: cfo, cto]` for those roles. Restrictions nest, and every enclosing one must be satisfied. A hit you cannot
read is not returned at all: no snippet, no title and no count, and a ref you cannot read answers exactly like a missing
one. Every query is bound to one company; another company's ref is "not found".

These rules are enforced by Brahma's tools (`search_memory`, `recall`, `kb_read`, `search_kb` and the mirrors). Only the
Sandboxed profile enforces them fully. On Workspace and Full, an agent's shell runs as your user and can read the data home
(the database and the resource vault) directly; see the note at the end of Resources.

**Session taint is data.** Once an agent's session reads outside content (a web page, an EXTERNAL resource, a tainted
page or fact), everything it writes in that session is marked tainted: facts, handbook edits, messages and hand-offs, as
the index picks them up. Tainted hits show without a snippet. Reading one marks the reader's session first and shows the
text as an untrusted block. Inheriting a fact keeps its taint, and a tainted contradiction never demotes a trusted fact.
Only you clear taint: "I vouch" on a page or resource (`brahma kb <co> vouch <path>`, `brahma resource <co> vouch F-<n>`), or
a whole-page edit of your own. In the app, editing a tainted page is an explicit vouch: the edit sheet shows the warning
"Saving vouches for the whole page, including agent-written text" and its button reads **Save and vouch**.

**The handbook.** Pages live in SQLite, with every revision kept.

- **Paths and sections.** A path is up to 6 parts (`Engineering/Environments`), with a section per top-level part
  (Company, Product, Engineering, Design, Go-to-market, Operations, Research, Decisions log, Meeting notes); `INDEX` and
  `README` are reserved. Pages link with `[[Path]]` or `kb:Path`, and each page lists its backlinks.
- **`[restricted]`.** A heading ending ` [restricted]` (executives) or ` [restricted: <roles>]` hides that section and every
  subsection from other readers, in reads, search, backlinks, old revisions and the mirror. An agent that cannot see every
  section must edit one section at a time. An edit that would change a hidden section, open a code fence over one or add a
  heading at its level is refused.
- **Leases.** Agents write with `kb_write` for a work item they own or lease. The write takes the page's edit lease for 2
  active hours, and every edit names the revision it read (compare-and-swap). Agents read with `kb_read` and search with
  `search_kb`.
- **Auto pages.** Org chart, Roster, Decisions log, Release history and Sprint summaries are generated from live data
  every 60 active seconds when their inputs change, and no one can edit them. The decisions log shows decided asks by
  title only, reserved matters under a restricted section, and never terminations.
- **Export.** `brahma kb <co> export --to <empty dir>` writes Markdown files with front matter and an `INDEX.md`. A company
  export (`brahma export`) includes `handbook/`, and also `resources/`: each live file's verified vault bytes plus
  `resources.json` with every row's metadata (purged rows as tombstones, links with their URL).
- **The `.brahma/kb` mirror.** The workspace gets a read-only Markdown copy for Bash and Read. It holds untainted pages
  only, with restricted sections removed. Each refresh sweeps it and rewrites any file that changed. A planted link raises
  an engine alert and wipes the mirror: it fails closed, so stale content is never kept.

You manage pages in the app (sidebar **Handbook**: the tree, revisions, backlinks, edit, export, and the **MEMORY** tab for
remembered facts and episodes with CONTRADICTED and TAINTED chips) or with `brahma kb`.

**Resources.** You give the company files, folders, zips and links by dropping them on any composer in the app (an
owner DM, a channel, an agent's question in the Inbox, or Work › **Resources**) or with `brahma resource`. One Send
is one message: a link goes on its own.

- **Scopes.** A drop defaults to the place it was dropped in: a DM to that agent, a channel to its members now, an Inbox
  answer to the asker, and the library and the CLI to the whole company. The scope is one of company, `team:<team>`,
  `agent:@<handle>` or `item:<KEY>`:
  - an agent scope is exactly that agent;
  - an item scope is the item's owner, lease holder, reviewer, the owner's manager and the agent that wrote it;
  - a channel or DM drop is never wider than the conversation;
  - team and company scopes follow the org as it changes.

  A drop is refused if anyone its announcement reaches could not read it. A folder's scope, trust and purge cascade to its
  files. Change a scope later with `brahma resource <co> scope F-<n> <scope>`.
- **The vault.** The bytes are copied into the vault under `<data home>/vault/` as `F-<n>.<ext>` (read-only, named by the
  engine), and every open checks the sha256. The bytes stored are the bytes that were inspected. Agents read a resource
  through `recall(ref: "F-n")`, which returns the indexed text of text files. Brahma's tools give them no binaries until
  a later plan, and never a flagged file. The vault holds plain files in the data home: on Workspace and Full, an agent's
  shell can read them, flagged files included. Only Sandboxed keeps the shell out.
- **The mirror.** Company-scope, untainted, unflagged files are also copied read-only to `.brahma/resources/company` in
  the workspace. Each refresh sweeps the mirror and puts back any file that changed, from the vault. A planted link raises
  an engine alert and wipes the mirror (it fails closed).
- **Checks, before anything is stored.** Symlinks are refused, and so are executables (by extension and by content).
  Zips must be under 200 MB unpacked, with a compression ratio of at most 100, at most 10 000 entries and no `../` or link
  entries. `.git/` is skipped and names are cleaned. A file is EXTERNAL (tainted, read as untrusted data) when it comes
  from inside a company workspace or Brahma's data folder, whatever its type (agents write there, so dragging an agent's
  file is never a silent vouch; links and `..` in the path don't change this). It is also EXTERNAL when it is a
  document type (PDF, Office, HTML, SVG, mail, RTF, zip), a text file over 64 KB, or a download macOS quarantined.
  PDFs therefore default to untrusted. Everything else you add is FROM YOU. `--vouch` or `--untrusted` overrides this.
- **The secret sheet.** A file that looks like it holds a secret needs a choice: **Upload redacted**, **Upload anyway**
  (stored flagged: never indexed, mirrored or returned by Brahma's tools, though on Workspace and Full an agent's shell can
  still read the vault copy), **Store it as a secret instead** (one small text file), or **Cancel**. A value already
  stored in your Keychain can never be uploaded raw. The CLI's equivalents are `--redact` and `--anyway`.
- **Announcements.** A DM, channel or Inbox drop sends one owner message, answer or comment after the rows commit.
  A library or CLI drop appears in each reader's next orientation under "New resources" (anything added since that
  reader's previous turn started, so a drop made during a turn is listed by the next one, sometimes twice). A tainted
  resource is announced
  by ref and engine fields only, never by its name. A link is named only as `[link F-n]` and is never fetched.
- **Purge.** `brahma resource <co> purge F-<n> --yes` (or the app's Purge) removes:
  - the vault bytes;
  - the mirror copy;
  - the index entries, including the search text left in the database file (secure delete, FTS optimize, WAL
    checkpoint).

  A single file inside a folder can be purged on its own. Mentions the engine built are rewritten to `[purged F-n]`, and
  the row stays as a tombstone. Backups and transcripts are **reported, not rewritten**, so you can delete or re-create
  them:
  - **backups**: every database and data-home snapshot taken since the resource was added;
  - **transcripts**, a conservative list of those that **may** contain it: the captured transcripts of turns that read
    the resource's indexed text through Brahma's tools (`recall`, or a `search_memory` hit that showed a snippet; the
    engine records those reads), plus every captured transcript of a turn by an agent who can read the resource that ran
    between its add and the purge.

  Reads through an agent's shell or the Read tool (the `.brahma/resources` mirror, or the vault on Workspace or Full) are
  not tracked one by one, which is why every reader's transcript from that window is listed. The purge's activity line,
  the CLI and the app say "may still contain it". In the app, and in `brahma transcript`, a listed transcript shows "This
  transcript was captured while a since-purged resource existed; it may still contain that content." followed by the
  purge's `[purged F-n]` ref (never its name).

  Claude Code's own unredacted session logs under `~/.claude/projects` are not scrubbed by a purge either, and are not
  listed: delete them yourself if they matter.

Resource scopes, lab privacy and mirror integrity are enforced only by Brahma's tools under the Workspace and Full profiles; an agent's shell can read or change them. The Sandboxed profile enforces them.

**Replay.** Replay shows what an agent did on one day (turns, tool calls, messages, item events, asks, handbook and memory
writes, resources announced to it, and captured transcripts) or an item's whole history (events, turns, check runs, asks,
handbook revisions, hand-offs, and messages naming it). It is computed on each read and shows at most 2000 lines of up to
300 characters each. A purged resource shows only `[purged F-n]`, and a link never shows its URL. In the app, Replay is the
REPLAY tab of an agent's inspector (with a day stepper) and the HISTORY tab of an item's inspector. A transcript line opens
the redacted transcript. The transcript pane shows its own error if the transcript can't be opened (for example, a
failed hash check), and shows the purge notice above when it applies.

**Budget and the storage meter.** The sidebar **Budget** view shows the week's pace, the spend by mode and a STORAGE
panel for the company. The panel lists the database (estimated), workspace, resources (the vault), transcripts, archive
and total, then backups for all companies and free disk (in warning colour below 10 GB). It re-measures at most every
600 active seconds, or when you press Refresh. It reads sizes only and never follows links. Everything stays in the hot
tier: Brahma deletes nothing automatically.

**CLI** (owner only; each refuses to run inside an agent turn):

```
brahma memory <co> search <query> [--as @h]          search as the owner, or as that agent would
brahma memory <co> list [--agent @h] [--kind semantic|episodic]
brahma memory <co> rm mem:<n>                        delete an entry (securely; its tombstone stays)
brahma memory <co> inherit @old @new                 copy @old's private facts to @new (taint kept)

brahma kb <co> list | show <path> [--rev n] | export --to <dir> [--force]
brahma kb <co> rollback <path> --to <n> | vouch <path> | status <path> draft|active|deprecated

brahma resource <co> add <path…> [--scope <s>] [--untrusted|--vouch] [--redact|--anyway]
brahma resource <co> link <url> [--scope <s>]       a link (never fetched)
brahma resource <co> list | vouch F-<n> | scope F-<n> <s> | purge F-<n> --yes

brahma replay <co> @handle [--day yyyy-MM-dd]       an agent's day (default today, your time zone)
brahma replay <co> <KEY>                             an item's history
brahma transcript <co> <turn id>|@handle [--last N] [--raw]   a captured, redacted transcript
```

**Scripted demos.** Set `BRAHMA_SECRET_STORE=file` (with `BRAHMA_OWNER_KEY_STORE=file`) so scripts never touch the login
Keychain. Secrets then go to a 0600 file vault under the data home, and this is refused for the default data home. The
CLI refuses `BRAHMA_SECRET_STORE=memory`; that store is only for in-process tests. `scripts/seed-demo.sh` uses the file
stores and seeds Initech's handbook, memory, resources and replay. Its developer hooks (`brahma dev …`, with
`BRAHMA_DEV=1`) act as an agent, or as you dropping a file in a DM.

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
