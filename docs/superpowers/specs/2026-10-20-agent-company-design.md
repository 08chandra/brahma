# Brahma — Design

Date: 2026-10-20
Status: draft, awaiting owner approval

> **Name [owner, 2026-10-20]:** the product is **Brahma**. Code identifiers
> follow: CLI `brahma`, library `BrahmaCore`, app `Brahma.app`, data in
> `~/Library/Application Support/Brahma/` and `~/Brahma/<company>/`, env vars
> `BRAHMA_HOME` / `BRAHMA_WORKSPACES`. Earlier text that says
> "Agent Company"/`agentco` refers to the same thing.

## 1. What this is, and why

A native macOS app where the owner (one person) creates a "company" of AI
agents, hands it one big goal — "take this idea to a production-ready
product" — and the company organizes itself into a hierarchy (C-suite,
architects, managers, engineers, designers, QA…), breaks the goal into a
backlog, runs sprints, and actually builds the product on the owner's Mac.

The owner is usually hands-off, like a board member, but can tap in at any
level: post in any channel, DM the CEO, or DM a single worker.

It feels like Slack for a company of agents, but its main screen is
**mission control**: watch the product being built live and watch the agents
talk to each other live.

Every agent is a real **Claude Code** session (the `claude` CLI), so agents
really write, run, and test code, and usage comes out of the owner's Claude
subscription, not a per-token API bill.

## 2. Goals

1. Create a company of N agents (N from ~5 up to several hundred) with an
   auto-generated, editable org chart.
2. Give the company a goal; it produces a backlog of work items, plans
   sprints, executes them, and ships a working product in a local git repo.
3. Mission-control UI: live product preview + live agent communication map +
   activity feed, with Slack-style channels and DMs in a sidebar.
4. Owner sign-off at decision gates, unless **Auto mode** is on.
5. Usage modes (Low / Balanced / Max) and a thread-style scheduler so the
   company stays within subscription limits, or goes all-out when asked.
6. Hundreds of agents can exist at once; as many as the machine and
   subscription allow run simultaneously. Idle agents cost nothing.
7. Owner can drop files, folders, and links in for the agents at company,
   channel, or single-agent scope.
8. Agents can ask the owner for API keys, sign-ins/permissions, or money,
   and the owner gets notified by macOS notification, iMessage text, and
   email.
9. All chat history, work items, decisions, and agent memory are saved
   locally on the Mac and searchable.

## 3. Non-goals (v1)

- Running agents on other machines or in the cloud.
- Other agent harnesses (Codex, opencode, Gemini). Claude Code only.
- A mobile app or web UI. (Notifications reach the phone via iMessage/email.)
- Agents deploying to paid production hosting on their own. They may prepare
  deployment; going live is an owner-approved request.
- Multi-user / teams of humans sharing one company.
- Agents operating accounts the owner didn't connect, or scraping/automating
  platforms outside their official APIs.

## 4. Anti-goals (failure even if it "works")

- Agents chattering in circles, burning usage with no work-item progress.
- A secret (API key, password) ever appearing in chat history, logs, the
  database, or a git commit.
- Any money being spent, or any card/payment detail reaching an agent,
  without explicit owner action.
- The UI lagging or the map becoming unreadable at hundreds of agents.
- Losing chat history or company state on crash/quit.
- The Mac becoming unusable (RAM/CPU exhausted) because too many sessions
  were launched.

## 5. Constraints and facts

- Owner's Mac: Apple Silicon, 12 cores, 24 GB RAM, macOS 26, Swift 6.2,
  Xcode installed, Claude Code 2.1.304 logged into the owner's subscription.
- Headless Claude Code supports: `-p`, `--session-id`, `--resume`,
  `--output-format stream-json`, `--input-format stream-json`,
  `--mcp-config` + `--strict-mcp-config`, `--model`, `--fallback-model`,
  `--append-system-prompt`, `--permission-mode`, `--allowed-tools`,
  `--add-dir`, `--settings`. The design depends on these.
- Each live `claude` process costs roughly 200–400 MB RAM. On this Mac that
  means **tens, not hundreds, can truly execute at the same instant**. The
  design makes hundreds *exist and be schedulable*, and runs as many at once
  as is safe. (Builder: measure the real per-process cost early and set the
  default cap from it.)
- Subscription usage limits are the other ceiling. Max mode will hit them
  fast at high N; the scheduler must handle limit-hit gracefully.
- **[owner]** Owner will be on the **Max 20x** plan. Defaults are tuned for
  it (6.7).

## 6. Decided design (owner's decisions marked **[owner]**, mine **[call]**)

### 6.1 Form factor
- **[owner]** Local app, a Mac app (TUI was acceptable, browser was not
  preferred).
- **[call]** Native SwiftUI macOS app, because a TUI can't show the live
  product preview. Preview pane is a `WKWebView`.
- **[call]** The app also lives in the menu bar so the company keeps working
  when the main window is closed. Quitting the app pauses the company
  (all agents → Ready/Sleeping, sessions persist) and resumes on relaunch.

### 6.2 Main screen — "Mission control" (**[owner]** picked layout B)
- **Top half, side by side:**
  - **Live product preview**: the product running locally (e.g. a dev
    server URL). Before there's a runnable product, shows the latest design
    artifact (HTML mockups, diagrams, docs) the design/architecture agents
    have produced. Tabs/selector if the product has several surfaces.
  - **Live agent map**: the org chart as a graph. Edges pulse when two agents
    exchange a message; node color/badge shows thread state (6.4). Teams
    collapse into a single bubble at scale; click to expand. Click any agent
    → its DM/detail panel (role, state, current work item, what it's blocked
    on, kill/pause/wake).
- **Bottom: activity feed** — approvals needed, PRs opened/merged, sprint
  progress, requests to the owner, agents' state changes, owner-relevant
  milestones. Filterable.
- **Company rail (far left) [owner]:** Slack-style column of company icons
  with a running/paused dot and an unread/requests badge; "+" creates a new
  company. Selecting one switches the whole window to that company.
- **Slim left sidebar:** channels (e.g. `#exec-approvals`, `#architecture`,
  `#sprint-N`, one per team), DMs with any agent, the Backlog/Board view,
  Resources library, Requests inbox. Clicking a channel/DM opens the full
  chat view (replacing the top half or as a panel — builder's choice).
- **Menu bar extra:** totals across all companies (running agents,
  pending owner requests) and per-company pause/resume.
- **Top bar:** company name, current sprint + progress, usage mode dial,
  **Auto mode** toggle, global pause, count of agents per state.

### 6.3 The company: org chart and roles
- **[call]** On creation the owner enters a goal, an agent count N, and
  optionally drops in resources. The app generates a standard org chart
  scaled to N; the owner may edit it (add/remove/rename roles, reassign
  reporting lines) before starting and at any time.
- Roles (each is a system-prompt template + allowed tools + default model):
  - **C-suite:** CEO (owns goal, final internal approver), CPO (product,
    PRDs, priorities), CTO (technical approval).
  - **Architects:** system design, ADRs, interface contracts, review of
    cross-team changes.
  - **Engineering managers:** one per team; run sprint ceremonies for the
    team, assign work items, review/merge PRs into the team branch or main.
  - **Engineers:** frontend, backend, mobile, infra, etc.
  - **Designer(s):** UX flows, mockups (HTML artifacts shown in preview).
  - **QA:** test plans, writing/running tests, filing bugs as work items.
  - **DevOps/SRE:** build/run scripts, CI, the preview run command,
    deployment prep.
  - **Security:** reviews for secrets, auth, dependencies (at larger N).
- Rough ratios **[call]**: ~1 manager per 5–8 engineers; C-suite fixed at 3;
  1 architect per ~3 teams; QA ≈ 1 per team; designers 1 per ~2 teams.
  Small companies merge roles (e.g. N=5: CEO/CPO, CTO/Architect, 2 eng, QA).
- Hierarchy shapes communication: workers talk mainly within their team and
  to their manager; managers to architects/C-suite; this keeps message
  fan-out (and usage) low.
- Managers may request new hires or kill idle agents; within the company cap
  this is automatic in Auto mode, otherwise an owner approval.

### 6.4 Agent lifecycle — thread model (**[owner]** asked for this)
Each agent is always in exactly one state:

| State | Meaning |
|---|---|
| **Ready** | Has pending work/inbox; waiting for the scheduler to give it a turn. |
| **Running** | A `claude` process is currently executing its turn. |
| **Blocked** | Waiting on a specific thing: another agent's reply, a dependency work item, an owner approval/request, or a usage-limit reset. The blocker is recorded and shown. |
| **Sleeping** | Nothing to do; wakes on a new message, mention, or assignment. |
| **Killed** | Terminated by owner or manager; history retained; can't be scheduled. |

Transitions: Sleeping→Ready on inbox event; Ready→Running when scheduled;
Running→{Sleeping, Ready, Blocked} at end of turn depending on what it
reported and its inbox; Blocked→Ready when the blocker resolves; any→Killed.
The owner can pause (force Sleeping, no auto-wake), wake, or kill from the
map or DM.

### 6.5 How an agent runs — "turns", not long-lived sessions (**[call]**, key efficiency decision)
- An agent is **not** a permanently running process. It is a database record
  (role, prompt, memory, Claude session id, inbox, state).
- When scheduled, the orchestrator launches one short turn:
  `claude -p --resume <session_id> --output-format stream-json
  --mcp-config <company-mcp.json> --strict-mcp-config --model <m>
  --append-system-prompt <role prompt> --permission-mode <…>` in the agent's
  working directory, with a prompt that is a compact **inbox digest** (new
  messages addressed to it, assigned/changed work items, resolved blockers).
  First turn uses `--session-id` to create the session.
- The turn streams events (tool calls, messages) to the orchestrator for the
  activity feed and map, then exits. RAM is only used while Running.
- This is what makes hundreds of agents cheap: a Sleeping or Blocked agent
  costs zero RAM and zero usage.
- Agents interact with the company only through the **company tools** (6.6),
  not by writing chat text to stdout. Final stdout text is logged as a
  "turn summary".
- Guardrails per turn: max turns/wall-clock per turn; an agent that ends N
  consecutive turns with no work-item progress and only messages is flagged
  to its manager (anti-chatter).

### 6.5a Permission profiles — what agents may do on the Mac (**[owner]**: sandbox by default, other levels selectable)
Turns are headless, so permissions are fixed up front per company (with
optional per-role override). Three profiles:

| Profile | What agents can do |
|---|---|
| **Sandboxed** (default) | Every turn's tool execution is OS-sandboxed (macOS Seatbelt, via Claude Code's built-in sandbox settings passed with `--settings`, or `sandbox-exec` profiles if that's insufficient). Writes only inside the company workspace + its worktrees + per-project tool caches; reads limited to workspace, resources, and toolchains; network via an allow-list (package registries, docs, the owner-added domains) that the owner can widen; no system-wide installs. |
| **Workspace** | Not OS-sandboxed: a tool allow-list only — Claude Code edits go to the workspace, but **Bash is unrestricted** (it can reach the whole home directory and the Brahma database) until 5-lite; project-local installs only; open network. |
| **Full** | `bypassPermissions`: anything the owner's user account can do, including `brew` and global installs. Shown with a persistent warning badge. |

- Switching profile applies from each agent's next turn.
- An agent that needs more than its profile allows (a domain, a system
  install) files a `request_from_owner(kind=permission)`; owner can grant a
  one-off exception or change the profile.
- Builder: verify the exact Claude Code sandbox/permission settings keys
  against the installed CLI before building on them.

### 6.6 Company tools (MCP server)
A small MCP server, bundled with the app (e.g. the app binary in a
`--mcp` mode, talking to the orchestrator over a local Unix socket), gives
every agent these tools, filtered by role:

- Messaging: `post_message(channel, text)`, `send_dm(agent, text)`,
  `read_channel(channel, since)` (on demand, not pushed), `mention`.
- Work: `list_my_work`, `create_work_item`, `update_work_item(status,
  notes)`, `link_dependency`, `assign` (managers), `request_review`.
- Decisions: `propose_decision(kind, summary, details)` → routes to the
  right approver (CEO/CTO/CPO) and, at gates, to the owner.
- Owner requests: `request_from_owner(kind=secret|signin|money|info|
  resource, reason, details)` → Requests inbox + notifications (6.10).
- Secrets: `use_secret(name)` — never returns the value into the
  transcript; instead the orchestrator injects approved secrets as env vars
  into the agent's *next* turn's process (or into the run command). Names
  only ever appear in chat.
- Org (managers/C-suite): `hire(role, team)`, `kill(agent)`,
  `set_blocked(on)`.
- Preview: `publish_artifact(path, title)` (design agents),
  `set_preview_command(cmd, url)` (DevOps).

### 6.7 Scheduler and usage modes (**[owner]** asked for modes)
- One scheduler in the orchestrator owns all transitions into Running.
- **Low:** 1–2 Running at once. Priority = how many items/agents this agent
  is blocking (critical path) > role weight (approvers first so others
  unblock) > sprint priority > wait time. Managers' messages batched into
  fewer turns. Workers default to a cheaper model.
- **Balanced:** owner-set concurrency K (default ~4–6).
- **Max:** every Ready agent runs, bounded by the lowest of: a **machine
  safety cap** computed from free RAM and per-process cost (on this Mac,
  likely ~30–50), an **owner hard cap** (setting; default 16 on Max 20x,
  to avoid account-level throttling — owner may raise it), and usage limits.
- **Defaults for Max 20x [call]:** Low = 2, Balanced = 6, Max = owner hard
  cap (16).
- **Model per role per mode [call]:** C-suite/architects use Opus; managers
  and engineers use Sonnet; trivial roles/tasks may use Haiku in Low mode.
  Owner can override per role. `--fallback-model` set on every turn.
- **No paid overage [call]:** the app must never knowingly consume paid
  extra usage. If the CLI reports the account has moved into paid overage /
  extra usage, treat it exactly like a usage limit (below). Onboarding tells
  the owner to keep "extra usage" off in Claude account settings.
- **Multiple companies at once [owner]:** like Slack workspaces, the owner
  can create any number of companies; each is independently Running or
  Paused. The scheduler, caps, and usage backoff are global (machine- and
  account-wide). Concurrency slots are shared across running companies by
  weighted round-robin; each company has a priority weight (default 1) the
  owner can change. A company's usage mode (Low/Balanced/Max) sets its own
  ceiling; the global owner hard cap still bounds the total.
- **Usage-limit handling:** when a turn fails with a usage/rate-limit
  error, all agents not yet Running go Blocked(usage-limit); scheduler backs
  off and auto-resumes when the limit resets (parse reset time if given,
  else exponential backoff). Shown prominently in the top bar.

### 6.8 Work organization: backlog, work items, sprints (**[owner]** asked for this)
- **Work items** hierarchy: Epic → Story → Task, plus Bug and Spike. Fields:
  title, description, acceptance criteria, owner agent, team, status
  (Backlog / Ready / In progress / In review / Done / Blocked), priority,
  estimate (points), dependencies, linked PR/branch, comments.
- **Flow:**
  1. **Intake:** owner goal → CEO/CPO write a vision + PRD. **Gate: owner
     approves idea/PRD.**
  2. **Architecture:** CTO/architects write the architecture + ADRs, define
     teams and interfaces. **Gate: owner approves architecture.**
  3. **Backlog:** CPO + managers break the PRD into epics/stories/tasks.
  4. **Sprint loop** (sprint length in *work*, not wall-clock — e.g. a set
     of committed items; builder may choose a sensible definition):
     planning (managers pick from backlog, **gate: owner approves sprint
     plan**) → execution → async daily standup digest per team posted to
     its channel → sprint review (demo in the preview pane, posted to feed)
     → retro (lessons saved to agent/team memory).
  5. **Release:** QA sign-off + CTO approval → **gate: owner approves
     release/deploy.**
- **Auto mode** skips owner gates; C-suite approvals still happen. Money and
  secret requests are **never** auto-approved.
- Board view (kanban per sprint) and Backlog view in the app; owner can
  create/edit/reprioritize items directly.

### 6.9 Code workspace and preview
- **Greenfield by default [call].** A company may also be started from an
  existing repo; the app copies (clones) it into the workspace and never
  commits to the owner's original. Intake/architecture then begin by
  studying the existing code.
- Each company has a workspace folder `~/AgentCompany/<company>/` containing
  the product git repo, `resources/`, and `artifacts/`.
- Each engineer works in its own **git worktree/branch** per work item; PRs
  are local branches reviewed and merged by managers/architects (no GitHub
  required; optional later).
- **Product types — all of them in v1 [owner]:** web apps, iOS apps, macOS
  apps, CLIs, and backends/APIs. The preview pane uses a pluggable
  **preview adapter** chosen by product type (a product may have several,
  shown as tabs):
  - **Web:** run command + URL → `WKWebView`.
  - **iOS:** build with `xcodebuild`, install/launch in a Simulator via
    `simctl`; preview pane shows the Simulator live (ScreenCaptureKit window
    capture, or `simctl io screenshot` polling as fallback), with click-
    through to open the real Simulator.
  - **macOS app:** build and launch the app; live window capture via
    ScreenCaptureKit.
  - **CLI:** embedded terminal view showing the latest demo script run
    (DevOps/QA define a demo script), re-run on merge.
  - **Backend/API:** live log tail + a request runner showing the latest
    smoke-test requests/responses; if there's an OpenAPI spec, render it.
- DevOps sets each adapter's build/run command via
  `set_preview_command`; the orchestrator runs it from the main branch and
  rebuilds/restarts on merge. Before anything runs, preview shows the latest
  published artifact. Sprint review demos use the same adapters.
- Screen capture needs the macOS Screen Recording permission; onboarding
  asks for it only when a native-app preview is first used.

### 6.10 Owner requests and notifications (**[owner]** asked for email/text/notification)
- Requests inbox in the app, one item per request: kind, who asked, why,
  what's blocked on it. Owner actions: provide, approve, deny, reply.
- **Secrets:** owner pastes value into a secure field → stored in macOS
  Keychain → injected as env var (6.6). **[call]** Protection is
  best-effort, not absolute: the app redacts every known secret value from
  everything it stores or displays (stream-json, turn logs, DB, chat), role
  prompts forbid printing secrets, and a pre-commit hook in every worktree
  blocks commits containing a known secret value. An agent with a shell
  could still print one into Claude Code's own transcript; that residual risk
  is accepted so engineers can test with real keys.
- **Sign-ins/permissions:** owner performs the sign-in themselves (e.g. OAuth
  in their browser, or grants access) and marks done; resulting tokens, if
  any, go to Keychain.
- **Money:** superseded by §6.17 Funds — agents never see payment details;
  spending goes through a budgeted funds connector with owner approval.
- **Notifications [call]:** macOS notifications (always); iMessage text to
  the owner's own number via the Messages app (AppleScript) — no Twilio;
  email via the owner's Gmail (SMTP + app password in Keychain). Each
  channel toggleable, with a minimum urgency per channel. Notifications
  deep-link into the app; replies happen in the app in v1.

### 6.11 Resources (**[owner]** asked for easy drop-in)
- Drag files, folders, or URLs onto: the **Resources** library (company-
  wide), a **channel** (team), or a **DM** (one agent). Files are copied
  into the workspace `resources/<scope>/`; agents get the path in their next
  inbox digest and via `--add-dir`. URLs are stored as link resources.

### 6.11a External communication — email and social media (**[owner]** asked for this)
Agents (e.g. marketing, sales, support, recruiting roles) can talk to people
outside the company.
- **Accounts the owner connects [call]:** per company, the owner connects
  accounts in Settings — an email account (Gmail via OAuth, or any IMAP/SMTP
  mailbox; a dedicated company address is recommended over the owner's
  personal one) and social accounts through their official APIs (e.g.
  Bluesky, X, LinkedIn, Reddit, Discord, Slack). Credentials live in
  Keychain (6.10). Agents never get raw credentials; they use company tools.
- **Tools:** `send_email(to, subject, body, thread?)`,
  `post_social(account, text, media?, reply_to?)`,
  `send_social_dm(account, to, text)`, `read_external_inbox(account)`.
- **Approval by default [call]:** every outbound external message is a
  *draft* in an "Outbox" queue the owner approves, edits, or rejects. Auto
  mode may auto-send per account only if the owner explicitly enables it for
  that account, with a daily send cap (default 20) and only to contacts who
  already replied or were added by the owner. Unsolicited mass outreach is
  never auto-approved.
- **Inbound:** replies, mentions, and DMs are polled and appear in a per-
  company `#external` channel (and as threads per contact), waking the agent
  that owns the conversation.
- **Guardrails [call]:** agents disclose they are an AI assistant acting for
  the company when asked or where a platform requires it; they never pose as
  a specific real human; per-account rate limits respect each platform's API
  terms; email includes an unsubscribe line for marketing mail; a contacts
  list records consent/opt-outs and blocks re-contacting opted-out people.
- Everything sent/received is stored in history (6.12) and searchable.

### 6.12 Persistence (**[owner]** asked for local history)
- SQLite database in `~/Library/Application Support/AgentCompany/` (one DB
  per company or one shared — builder's choice), WAL mode, FTS5 for search
  across all chats and work items.
- Stores: companies, agents, org chart, channels, messages, DMs, work items,
  sprints, decisions, requests (without secret values), turn logs/summaries,
  scheduler events, resources index.
- Claude's own session transcripts remain where Claude Code stores them; DB
  stores the session id per agent.
- Crash/quit safe: every state transition is persisted before it takes
  effect; on launch, any agent recorded as Running whose process is gone is
  moved back to Ready.

### 6.13 Headless server mode (**[owner]** asked for this — later phase)
Eventually the engine runs headless on a Linux VM, and the owner talks to it
from a Mac companion app (and, later, possibly a phone).
- **[call]** Same Swift codebase: Swift runs on Linux, so `AgentCompanyCore`
  is kept Linux-portable from Plan 1 on (no AppKit/Apple-only Foundation APIs
  in the core; Mac-only features — Keychain, UserNotifications, Messages,
  ScreenCaptureKit, Simulator — sit behind protocols with Linux alternatives).
- **Server:** `agentco serve` — a long-running daemon (systemd unit) running
  the Orchestrator, with `claude` CLI installed and logged in on the VM.
  Linux equivalents: secrets in an encrypted file or the VM's secret store;
  notifications via email/push only; sandboxing via bubblewrap/containers;
  web previews served from the VM (and tunneled), native iOS/macOS previews
  unavailable (need a Mac build host — out of scope for the server).
- **Remote API:** the daemon exposes an authenticated API (HTTPS + WebSocket
  event stream) covering everything the app does: companies, channels/DMs,
  work items, requests, usage, activity, preview URLs.
- **Mac companion app:** the same SwiftUI app connects either to its embedded
  local engine or to a remote server; it's a client of the same API.
- **Security:** API only over TLS, behind token auth paired from the app
  (or reachable only via Tailscale/WireGuard by default); never exposed
  unauthenticated to the internet.

### 6.14 Personal agent workspaces and experimental modules (**[owner]** asked for this)
Every agent gets its own lab to tinker in while it works.
- **Lab folder [call]:** `~/AgentCompany/<company>/labs/<handle>/` — private
  scratch space with its own version-controlled repo, writable only by that
  agent (others can read it if granted). Contains `notes/` (persistent
  working memory the agent curates across turns), `modules/` (experiments),
  and `scratch/`.
- **Experimental modules:** an agent can build small tools for itself —
  scripts, CLIs, prompt snippets, test harnesses, data scrapers, MCP tools —
  each with a manifest (`module.json`: name, description, entry point, how to
  run, author, status `experimental|proposed|adopted`).
- **Using modules:** an agent's own modules are on its PATH / tool list in
  its later turns. Other agents only see adopted modules.
- **Promotion:** `propose_module(name)` → reviewed by the agent's manager
  (plus the architect for anything touching shared code) → `adopted` modules
  move to the company **Toolbox** (`toolbox/`), available to every agent,
  with per-module usage stats.
- **Guardrails:** labs live inside the company workspace, so the company's
  permission profile (6.5a) applies; disk quota (default 2 GB per agent);
  modules can't obtain secrets on their own — same request flow as 6.10.
- **UI:** each agent's detail panel has a Lab tab (files, notes, modules);
  the Toolbox has its own sidebar entry.

### 6.15 Self-evolving engine (**[owner]** asked for this)
The app improves itself: an orchestrating agent watches how companies work and
changes the system to fix what it finds.
- **The Steward [call]:** a built-in meta-agent per installation (not per
  company), reporting directly to the owner. It reads engine telemetry —
  stalled/blocked agents, chatter loops, failed turns, usage burned per work
  item, time-to-done, review rejection rates, owner overrides — plus agents'
  retro notes, and identifies workflow and agent problems.
- **Three levels of change, increasing risk:**
  1. **Company tuning** — role prompts (take effect for new hires / new
     sessions, since prompts are snapshotted), org changes, sprint settings,
     scheduler weights, per-role models. Automatic in Auto mode, otherwise an
     owner approval. Every change is logged with a before/after metric and
     auto-reverted if the metric worsens over a set window.
  2. **Playbooks and role templates** — the shared templates future
     companies start from. Same approval rules as level 1.
  3. **Engine code** — the Steward works on the `agentco` source itself (its
     own clone), on a branch, writing code and tests like any engineer.
- **Engine-code safety [call — owner may relax later; strengthened by §6.16]:**
  - Each change is a reviewable branch with a written rationale and the
    telemetry that motivated it. The full test suite must pass, plus a
    **simulation run**: the new build runs a scripted test company with fake
    turns and a short live company on Haiku, compared against the current
    build.
  - **The owner always approves engine-code changes, even in Auto mode.**
  - **Protected areas** need a separate, explicitly flagged owner approval:
    permission profiles/sandbox, secret handling/redaction, owner approval
    gates, the usage/overage gate, external-communication approvals, and the
    Steward's own permissions.
  - **Hot swap with rollback:** the last-known-good build is kept; an
    approved build is swapped in at a safe point (no turns running); if crash
    or error rates rise afterwards it rolls back automatically and tells the
    owner.
- **Changelog:** a "What changed" view lists every self-made change, why,
  its measured effect, and a one-click revert.

### 6.16 Coordination principles from research (**[owner]** approved 2026-10-20)
The full list — 25+ changes with sources and the plan each lands in — is in
`docs/superpowers/specs/2026-10-20-improvements-from-research.md`, and is
binding for Plans 3–10. The core principles:
- **Work items, files and git are the agents' coordination substrate;**
  channels/DMs are for discussion and owner visibility. Messages reference
  artifacts instead of pasting them.
- **The engine is the referee:** work is Done only on an engine-recorded pass
  of the item's executable check; agents can't edit their own acceptance
  criteria or checks; diffs that weaken tests need explicit reviewer
  approval (anti-reward-hacking).
- **One writer per work item / area**, read-only helpers in parallel;
  driver + navigator pairing as an option for hard items.
- **Structured hand-offs on disk** and turn-start orientation (role card,
  current item, progress file, recent git log).
- **Budgets, effort tiers, watchdog, team-size caps** to control cost and
  liveness.
- **Steward safety** per the proposal's section F (immutable evaluator,
  held-out scenarios, separate auditor, no self-granted resources, one
  change at a time, lineage archive, draining hot-swap); these supersede the
  rules in §6.15 where stricter.

### 6.17 Running the company: research, internet, browser, funds, integrations (**[owner]** asked for this)
The company doesn't just build the product — it researches, operates, and
runs it. It plugs in whatever capabilities it needs, where it needs them.

**Internet and research**
- Agents get web search and page fetching (Claude Code's WebSearch/WebFetch)
  per role; in the Sandboxed profile, network access follows the company's
  domain allow-list, which agents can request to widen
  (`request_from_owner(kind=permission)`; auto-approved in Auto mode for
  read-only browsing).
- A **Research** function (analyst/researcher roles) produces cited reports
  into a company **Knowledge Base** (`kb/`), searchable by every agent, so
  research is done once and reused.

**Browser [call]**
- Agents can drive a real browser (Chromium via Playwright, exposed as an
  MCP tool) for sites without APIs: sign-ups, dashboards, admin consoles,
  testing the product like a user.
- Each company has its own browser profile(s), isolated from the owner's
  personal browser. Agents never see saved passwords.
- **Sign-in hand-off:** when a site needs a login, 2FA, or a CAPTCHA, the
  agent files a sign-in request; the owner completes it once in an
  in-app browser window on that company's profile; the session cookie is
  then usable by the agent.
- The preview pane can show an agent's live browser, so the owner watches
  what it's doing. Submitting payments, accepting terms of service, or
  sending messages through a browser counts as an action requiring the
  same approval as the equivalent tool (funds / outbox).

**Integrations (plug-ins) [call]**
- Capabilities plug in as **connectors** — MCP servers (Gmail, Slack,
  GitHub, Stripe, Vercel/AWS/Fly, Google Workspace, Notion, Linear, analytics,
  CRM, …) or REST APIs wrapped as tools.
- A per-company **Integrations** page: the owner installs a connector,
  completes its auth (secrets → Keychain), and scopes it to roles (e.g.
  only DevOps gets the cloud connector, only Support gets the helpdesk).
- Agents can *propose* a new connector ("we need Stripe for billing") →
  owner approval → install. Agents may also build small connectors as lab
  modules (§6.14) and promote them.
- Every connector call is logged (who, what, when) and counted toward
  budgets.

**Funds [call — replaces the earlier "agents never hold money" rule with a
stricter, more useful one]**
- The owner gives each company a **budget**: monthly limit, per-purchase
  limit, and optional merchant/category allow-list.
- Money moves only through a **funds connector** the owner connects — e.g.
  a virtual-card provider with programmatic spend controls, or a payment
  platform account. Card numbers and credentials stay in Keychain/the
  provider; agents never see them.
- Agents spend via `request_spend(amount, merchant, purpose, work_item)`:
  within budget and below the auto-approve threshold (default $0 — i.e.
  every purchase needs approval until the owner raises it) the engine
  executes it; otherwise it goes to the owner's approval queue. Auto mode
  never raises spend limits.
- A **CFO/Finance** role tracks spend vs budget, subscriptions, and revenue;
  a Finance view shows every charge with its purpose and requesting agent.
  Refunds/cancellations are tracked as work items.
- Revenue (e.g. from a Stripe connector) is visible but agents can't move
  money out of revenue accounts.

**Business roles** added to the role catalog (Plan 3): Research analyst,
Marketing, Sales, Customer support, Finance (CFO), Legal/compliance
reviewer (flags terms, privacy, licensing — not legal advice), Operations.

**Guardrails**: everything above respects permission profiles (§6.5a),
owner gates, the external-communication outbox (§6.11a), and the funds
budget; all actions are in the activity history; the global kill switch
stops browsers and connectors too.

### 6.18 Any kind of company — industry packs (**[owner]** asked for this)
The engine (hierarchy, scheduler, channels, approvals, budgets, labs,
Steward) is industry-neutral. Everything software-specific becomes a
pluggable **industry pack**, so a company can be e-commerce, apparel, hard
tech/hardware, B2B SaaS, CPG, services, media, etc.

**What a pack defines [call]**
- **Org template:** roles and ratios for that kind of company — e.g. CPG:
  brand, product development/formulation, sourcing & supply chain,
  regulatory, marketing, retail/wholesale sales, finance; hard tech:
  mechanical/electrical/firmware engineers, test, manufacturing engineering,
  supply chain, compliance/certification; e-commerce: merchandising,
  storefront, growth marketing, customer support, fulfillment ops.
- **Work vocabulary:** item types and stages beyond epic/story/task —
  e.g. SKU, tech pack, BOM, supplier RFQ, prototype build, certification,
  launch campaign, listing, PO, shipment.
- **Cadence:** sprints are one option; packs can use stage-gates (concept →
  prototype → EVT/DVT/PVT → production), seasonal/collection calendars,
  campaign cycles, or milestones. The scheduler and gates don't change.
- **Deliverables & previews:** each artifact type has a preview adapter —
  code/app (as §6.9), storefront/landing page, brand board & mockups,
  product renders/CAD viewer (STEP/STL/glTF), tech packs & BOM tables,
  financial models/spreadsheets, decks, documents, ad creatives, dashboards.
- **Verification:** "done" checks generalize beyond tests: spreadsheet/BOM
  validators, spec checklists, rubric-graded review by a clean-context
  reviewer agent, cost/margin targets, compliance checklists, and owner
  sign-off for subjective work (brand, design). Engine-owned evidence (§6.16)
  still applies wherever a check can be executed.
- **Connectors:** pack-suggested integrations — e.g. Shopify/Amazon/Etsy,
  3PL and shipping, supplier & manufacturing marketplaces, ad platforms,
  accounting, CAD/PLM tools, QuickBooks/Xero, payment processors.
- **Playbooks:** starter goals and checklists (e.g. "launch a DTC apparel
  brand", "take a hardware prototype to DVT", "launch a B2B SaaS MVP").

**The real world [call]**
- Agents can't physically make, ship, or sign things. Physical-world steps
  (sample approval, factory visit, signing contracts, legal filings,
  certifications, receiving inventory) become **human tasks**: a queue the
  owner (or a contractor/vendor the owner designates) completes, with the
  agents preparing everything (specs, RFQs, comparison tables, drafted
  emails, checklists) and tracking status.
- Talking to suppliers, manufacturers, retailers and customers goes through
  the external-communication outbox (§6.11a); spending through the funds
  budget (§6.17); contracts and anything legally binding always need the
  owner.

**Creating a company**
- The owner picks a pack (or "custom") and describes the business; the
  CEO/CPO agents can propose pack adjustments (extra roles, item types) for
  owner approval. Packs are versioned files, so the Steward (§6.15/§6.16) can
  improve them over time from what works, and new packs can be added.
- Plan 1's engine needs no change for this; packs land with the role
  catalog / work items (Plan 3), previews (Plan 4) and connectors (Plan 11).

### 6.19 Efficiency meter, performance analysis, and earned trust (**[owner]** asked for this)
**Efficiency meter [call]** — engine-measured, never self-reported, per agent
and per team, per sprint and rolling:
- Throughput: work items done, weighted by effort tier.
- Quality: first-pass rate on the engine-run check, rework count, review
  rejections, escaped defects (bugs later traced to the item).
- Cost: usage/tokens per completed item vs the median for that item type.
- Flow: cycle time, time blocked, time in chatter (messages not followed by
  progress).
- Reliability: failed turns, watchdog interventions, budget overruns.
Shown to the owner as an efficiency meter on each agent (map badge + detail
panel) and as team/company scorecards.

**Performance analysis [call]** — an Ops/Performance function (per-company
agent, reporting to the CEO and the owner; the Steward consumes its output
installation-wide) publishes a scorecard each sprint, flags outliers and
trends, and proposes concrete changes (prompt/model tweaks, reassignment,
team splits, pairing, retraining notes). Changes go through the normal
approval rules (§6.15/§6.16).

**Anti-gaming rules [call]** (§6.16 reward-hacking principles apply):
- Multiple balanced measures, never a single score to maximize.
- Agents do not see their raw scores; they get specific, actionable feedback
  in retro notes instead.
- Item sizes/tiers are set by the planner/manager, not the worker; splitting
  or cherry-picking items to inflate counts is itself measured.

**Earned trust instead of "rewards" [call]** — agents don't experience
rewards, so incentives that work are changes in what an agent is trusted
with. Engine-granted trust levels based on the meter: promotion → harder/lead
items, larger budgets, stronger model, lighter (still engine-verified)
review, mentoring and planning input; sustained low performance → more
review, smaller items, pairing, reassignment, or replacement. Never
self-grantable.

**Trust levels — implemented as an engine ladder [owner: build it]:**
| Level | Gets |
|---|---|
| T0 Probation | small items only, pairing with a navigator on every item, every diff reviewed, cheapest adequate model, minimum budget |
| T1 Standard | normal items for its role, normal review, role-default model and budget |
| T2 Trusted | larger/lead items, 1.5× budget, lighter review (engine checks still mandatory), may mentor (be a navigator) |
| T3 Lead | can lead a sub-team or epic, proposes plans, stronger model eligible, 2× budget, input in sprint planning |
New hires start at T1 (or T0 if the owner chooses). The engine evaluates
promotion/demotion at each sprint end from the efficiency meter with
hysteresis (sustained performance over ≥2 sprints, minimum sample size),
logs the reason, and notifies the agent's manager; the owner can override.
Trust level feeds the scheduler (priority, model, budget), assignment
(item size), and review rules. Never self-grantable.

**Digital rewards [owner: build it]** — engine-awarded from the meter, shown in
the UI, purely cosmetic (no effect on scheduling or prompts, so nothing to
game): coffee ☕ for a clean first-pass item, a meal 🍜 for finishing a large
item under budget, a trophy 🏆 for "employee of the sprint", streak flames 🔥
for consecutive first-pass items, owner-given kudos ⭐. Agents show their
current perks on the map and in their profile; a company "break room" view
lists recent awards. (Theme kept to food/drink/trophies.)

**HR function [owner: build it]** — an HR agent (per company, reports to the
CEO; owner sees everything) runs performance management:
- **Performance reviews** every sprint from the meter + manager input,
  written to the agent's file (owner-visible).
- **Warnings → Performance Improvement Plan (PIP)**: an agent below the bar for
  a sprint gets a written warning (recorded; corrective notes go into its
  retro feedback, e.g. "your items fail on missing edge cases — run the
  edge-case checklist before submitting"); two consecutive sprints → a PIP:
  demotion to T0 probation with specific, measurable targets for the next
  sprint.
- **Root-cause first**: before disciplining, HR + the Performance function
  check whether the cause is the agent or the system (bad role prompt, wrong
  model, oversized items, broken tooling) and fix the system when it is —
  that change goes through the normal approval rules.
- **Termination & replacement**: failing a PIP → HR proposes termination; the
  agent is killed and a fresh hire replaces it with a clean session, the
  role card (improved if the root cause was the prompt), and a written
  handoff of the departing agent's open work and lessons. Terminations need
  the manager's sign-off and are owner-approved unless Auto mode is on.
- **Guardrails**: HR actions are engine-backed facts (meter data cited in each
  action), every action is logged and reversible by the owner, and HR can't
  act on agents above its reporting line or on the C-suite without the
  owner. Agents can't influence their own reviews.

Lands in Plan 3 (metrics collection, trust ladder, rewards, HR agent and
actions) and Plan 4 (meter, perks and HR views in the UI); the Steward
(Plan 10) uses it installation-wide.

### 6.20 Ideas pipeline — visionaries reach the C-suite through tickets (**[owner]** asked for this)
- **Idea tickets [call]:** any agent can file an **Idea** work item
  (`propose_idea`): problem/opportunity, proposal, expected impact, rough
  cost/effort, evidence (research links, lab prototype, metrics), risks. It
  lands on a company **Ideas board**, not in anyone's DMs, so it never
  interrupts the C-suite.
- **Visionary roles:** an R&D / "Visionary" role (and optionally a
  per-agent `visionary` flag) gets a small standing budget to research and
  build a quick lab prototype (§6.14) before pitching. Ideas backed by a
  prototype or data are scored higher.
- **Triage [call]:** a duplicate check (search the board + knowledge base)
  runs on filing; the filer's manager (or the CPO for cross-cutting ideas)
  adds a triage note within a sprint. Ideas are scored on impact,
  confidence, and effort (RICE-style) with the reasoning recorded.
- **C-suite review:** once per sprint, CEO/CPO/CTO hold an **Idea review**
  over the top-scored ideas and decide: **approve** (becomes an epic in the
  backlog, the filer credited and often assigned as lead), **prototype
  further** (small budget, revisit next review), **park** (kept with a
  reason), or **reject** (reason recorded and sent back to the filer).
  Owner-gated like other decisions unless Auto mode is on; ideas above a
  cost threshold always go to the owner.
- **Owner view:** the Ideas board (status columns, scores, who filed, decision
  history); the owner can file ideas too and fast-track any idea.
- **Guardrails:** per-agent idea quota (e.g. 3 open ideas) to prevent spam;
  idea quality feeds the efficiency meter (approved/shipped ideas count;
  rejected duplicates don't); approved-and-shipped ideas earn a 💡 perk.
- Lands in Plan 3 (item type, board, triage, review ceremony) and Plan 4 (UI).

### 6.21 Agent map — two view modes (**[owner]** asked for this; Plan 4)
The live agent map (§6.2) has a toggle between two modes driven by the same
live data (agents, states, teams, messages, hand-offs, perks).

**1. Hive (3D) [call: SceneKit]**
- A 3D hive: each team is a cluster of hexagonal cells; each agent is a cell
  (glowing by state: running = bright pulse, ready = steady, blocked = red
  rim, sleeping = dim, killed = hollow); C-suite at the core, teams around it.
- Connections drawn as edges between cells (reporting lines faint, recent
  communication bright); each live message travels as a particle along its
  edge; busy pairs get thicker edges; owner messages come from a distinct
  "owner" node.
- Orbit/zoom/pan; click a cell → agent detail; hover → name, role, current
  item, efficiency meter. Level-of-detail for hundreds of agents (teams
  collapse into single cells when zoomed out).

**2. Village (2D isometric) [call: SpriteKit]**
- A top-down/isometric village in an original cartoon style (no third-party
  game assets): each department/team is a building (HQ/castle = C-suite,
  workshop = engineering, studio = design, lab = R&D/visionaries, market =
  sales/marketing, warehouse = ops/fulfillment, bank = finance, HR office,
  QA tower); building size/level grows with team size and output.
- Each agent is a small worker sprite: works at its building while running
  (hammering/typing animation), idles when ready, sleeps (Zzz) when
  sleeping, shows a "!" bubble when blocked; killed agents leave.
- Communication and hand-offs are visible: a worker walks (or a courier/
  carrier pigeon flies) from one building to another carrying a scroll for a
  message or a crate for a hand-off; meetings (idea review, sprint planning)
  gather workers in the town square.
- Perks show on workers (☕, 🏆, 🔥); trust level shows as outfit/hat; the
  efficiency meter as a small bar over the head on hover.
- Click a worker → agent detail; click a building → team view; pan/zoom.

**Shared**
- Both render from one `MapModel` (positions, events) fed by the activity
  stream; animations are rate-limited and batched so hundreds of agents and
  bursts of messages stay smooth; a "follow agent" camera mode; a time
  scrubber to replay the last hour.
- Plan 4 may split the two modes into separate tasks/sub-plans; the Village
  mode needs a sprite asset set (drawn procedurally or as bundled original
  SVG/PDF art).

### 6.22 Full Claude Code capabilities for every agent (**[owner]** asked for this)
Every agent is a full Claude Code session, so it can use everything Claude
Code offers — but from a **company-curated toolkit**, never the owner's
personal setup (turn isolation, §6.5/§6.16, stays: `--setting-sources ""`, no
personal plugins/hooks/CLAUDE.md).
- **Built-in tools:** Read/Edit/Write/Glob/Grep/Bash, WebSearch/WebFetch,
  Task (sub-agents within its own turn), Todo, NotebookEdit — enabled per
  role. Harness tools that would bypass the company (Cron, wakeups, remote
  triggers, push notifications, cross-session messaging, worktree switching)
  stay disabled; the company provides those functions itself.
- **Skills:** a company **Skill library** (Anthropic Agent Skills format;
  includes promoted lab modules §6.14 and pack-provided skills) mounted per
  role via a company plugin directory (`--plugin-dir`), so agents can invoke
  skills and slash commands.
- **Plugins:** curated Claude Code plugins installed into the company plugin
  directory (not the owner's), enabled per role through generated
  `--settings`.
- **MCP servers:** the company MCP server (always) plus installed connector
  MCP servers (§6.17), merged into each turn's `--mcp-config` filtered by
  role and grants.
- **Sub-agents:** agents may spawn Claude Code sub-agents inside a turn;
  counted against the item budget; depth/concurrency capped per tier.
- **Hooks:** company-owned hooks (e.g. pre-commit secret scan, test
  guards) installed by the engine; agents can't edit them.
- **Permissions:** per role/agent from the permission profile (§6.5a) +
  grants (§6.23), compiled into each turn's `--settings` permission rules.

### 6.23 Integrations catalog and the Access Center (**[owner]** asked for this)
**Integrations catalog [call]** — one place to browse and install the
services any engineer (or any business role) needs, each packaged as a
connector = MCP server and/or CLI + credentials + role scopes + budget meter:
- Cloud & deploy: AWS, Google Cloud, Azure, Vercel, Fly.io, Cloudflare,
  Netlify, Docker/registries.
- Data: Postgres (incl. Neon/Supabase/RDS), MySQL, SQLite, Redis/Upstash,
  MongoDB, vector DBs, S3-compatible storage, BigQuery/Snowflake.
- Dev: GitHub/GitLab, CI, Sentry, Linear/Jira, Figma, package registries.
- Payments & funds: Stripe, agent wallets (e.g. AgentWallet-style
  programmatic wallets/virtual cards) as **funds connectors** under the
  budget rules of §6.17.
- Comms & business: Gmail/IMAP, Slack, Discord, social, Shopify, CRM,
  analytics, accounting.
- Anything else: "Add custom MCP server" (command or URL) or "Add CLI tool".
Each catalog entry declares: what it can do, the credential it needs, risk
level (read-only / writes / spends money / external comms), default roles,
and cost tracking. Agents can **request** a connector (with a reason and the
work item it unblocks); the owner installs with one click.

**Access Center [call]** — a single owner screen (and menu-bar badge +
notifications) for every approval the company needs, replacing scattered
queues:
- One inbox of **access requests**: tool/permission (e.g. a Bash command
  class, a network domain, a system install), plugin/skill install, MCP
  server / connector install, credential/sign-in, secret, spend, outbound
  message, and decision gates (§6.8) — each card shows who asks, why, the
  linked work item, risk level, and exactly what will be granted.
- **One-click answers with scope and duration:** Approve once · for this
  item · for this agent · for this role · company-wide; for this turn /
  this sprint / always; or Deny with a reason (sent back to the agent).
- **Policies and presets** so the owner isn't flooded: e.g. "auto-approve
  read-only network for engineers", "always ask for spend", "Auto mode may
  approve low-risk tool grants"; risk-based defaults per permission
  profile. High-risk classes (money, external messages, deleting data,
  production deploys, the Steward's protected areas) never auto-approve.
- **Grants ledger:** every active grant listed with scope, expiry, who
  approved, and usage; one-click revoke; everything audited.
- The engine compiles grants into each turn's settings/MCP config, so a
  grant takes effect on the agent's next turn and a revoke likewise.
- Same API in the headless server mode (§6.13) so the Mac/phone companion
  can approve remotely.

Lands in: Plan 5 (Access Center, grants, permission compilation, sandbox),
Plan 11 (integrations catalog, connectors, funds connectors), with the
skill/plugin directory mechanics in Plan 5.

### 6.24 Design review decisions (**[owner]** approved 2026-10-21)
Source: `docs/research/2026-10-21-design-review.md` (architecture critic).
These **override** earlier sections where they conflict.

**Build order:** Plan 2 → **3a (amended)** → **5-lite** → **Memory-lite (§6.25)** (sandbox via Claude
Code `--settings`, sandboxed checks, DB unreachable from agents, Inbox
notifications + daily digest, startup probe, DB backups) → 4a (batched merge
queue + previews) → 4b (**org chart map only**) → **dogfood one real company
at N≈8 for a week** → 3b (designed from that data) → 4c (Hive + Village as
optional skins) → 7, 11, 9, 8, 10.

**Foundation fixes (in 3a):** channel membership never wakes agents (only
@mention, DM, item notice, or rate-limited @team/@here by managers; system
posts never wake); one git worktree per work item with checks run there and
engine merges; weekly-aware usage pacing with an owner reserve (default 30% of
the 7-day window kept for the owner's own Claude use) and Opus reserved for
C-suite/architecture/tier-L; fresh Claude session per work item; `brahma
doctor` startup probe; verification flags modified tests and snapshots check
scripts; memory-pressure admission; only meter *facts* collected (no scores).

**One Inbox.** Every "needs the owner" thing — decisions, access requests,
grants, outbound drafts, spend, human tasks, staffing — is one `ask` with a
kind, a risk level, and a proposed scope/duration (§6.23 Access Center is the
UI for it). Auto mode is a named policy preset over (kind, risk). Resolves the
earlier contradictions: **Auto mode never spends money, never sends external
messages, never approves terminations or prompt changes**; those only
auto-approve under an explicit owner policy the owner set (e.g. a spend
threshold, a per-account send policy).

**Owner load defaults ("Important only"):** the owner approves PRD,
architecture, release, any money, secrets, outbound messages, and
terminations; sprint plans auto-approve after the C-suite with an FYI;
standups are engine-generated (no LLM turns); sprints are timeboxed with
carry-over; pending asks notify on macOS immediately; approval cards show the
document inline (sanitized Markdown).

**Concept budget.** The owner works with five nouns — **Company, People, Work,
Inbox, Budget**. Everything else (leases, review turns, hand-offs, trust,
meter, HR, ideas, pairing, judge…) is an engine internal shown under
"Insights", never something the owner must operate.

**Defaults:** new company size 6 (merged roles); Balanced mode; comms, funds,
browser and connectors off until the owner turns each on; >50 agents labelled
"experimental".

**Steward (§6.15) revised:** the Steward writes a weekly report and opens
code/config changes as branches for the owner to review and merge; no
self-hot-swapping runtime. Level-1/2 tuning proposals go through the Inbox
(owner-required for prompt changes).

**Security notes:** the workspace profile is a tool allow-list, not a
sandbox, until 5-lite lands; credentials default to engine-held, behind
connector tools (env-var injection only for keys marked "test"); metered
connectors (cloud, DB-as-a-service, LLM APIs) count as spend and require a
provider-side budget cap at install; browser automation is limited to the
owner's own accounts and the product under test (resolves §3 vs §6.17).
Items to verify before scaling or distributing: Claude subscription terms
for sustained automated use, remote-VM login (Plan 8), distribution requiring
API keys, AI-disclosure rules for outbound messages, platform automation ToS.

**Maps:** the Org Chart is the default and the first map built; Hive and
Village are optional skins (Plan 4c), exempt from the ops-console brief.

### 6.25 Company Memory — shared knowledge with permission-scoped access (**[owner]** asked; evaluated supermemory.ai)
Goal: every agent works with all the company knowledge it is permitted to see.
**Decision [call]:** build it locally inside Brahma; external memory services
(e.g. supermemory.ai) are optional connector backends, never the source of
truth — company data stays on the owner's machine/server and permissions are
Brahma's.
- **Store:** per company, in the Brahma DB: FTS5 now; optional on-device
  embeddings (e.g. a local vector index) later. Never leaves the machine
  unless the owner enables an external backend.
- **Auto-ingest:** messages, work items, decisions/asks, hand-offs, research
  reports and the Knowledge Base, retros/lessons, artifacts/documents, plus
  explicit `remember(fact, scope)` from agents. Each entry keeps provenance
  (source id, author, time).
- **Scopes & sensitivity:** every entry has a scope (company · team · role ·
  agent · item) and a sensitivity label (normal · internal · restricted ·
  hr/perf · secret-never-stored). Retrieval is filtered by the engine using
  the asking agent's company, team, role, trust level, current item and
  grants (§6.23) **before** results reach the agent; HR/performance records
  only for HR/Performance roles and the owner; no cross-company retrieval.
- **Tools:** `search_memory(query, scope?)` and `recall(topic)` return cited
  snippets (quoted, so they can't forge digest lines); `remember`; the
  turn-start orientation auto-includes the top-k relevant memories for the
  current item (bounded).
- **Hygiene:** dedupe on ingest, TTL for ephemeral entries, librarian
  consolidation (Plan 9), owner can browse/search/delete any memory; prompt-
  injection guard — retrieved text is always treated as data.
- **Build:** Memory-lite (scoped FTS, auto-ingest, tools, orientation
  integration) right after 5-lite and before dogfooding; embeddings,
  librarian, external backends in Plan 9.

### 6.26 Marketing studio — organic short-form video first (**[owner]** asked for this)
The first marketing capability is **organic short-form video** (TikTok,
Instagram Reels; YouTube Shorts later), produced end to end by a marketing team.
- **Roles (pack roles, any industry):** content strategist, scriptwriter,
  video producer, social/community manager, growth analyst (merged into one or
  two seats for small companies).
- **Pipeline (as work items, verification-first):**
  1. *Strategy:* audience, positioning, content pillars and a posting
     calendar derived from the product, the Knowledge Base and Company Memory.
  2. *Ideation → script → storyboard:* hooks, scripts, shot lists, on-screen
     text, captions, hashtags; brand kit (logo, colors, fonts, voice) applied.
  3. *Generation:* video via a **video-generation connector** (e.g.
     Higgsfield, or alternatives such as Runway, Kling, Luma, Veo (OpenAI's Sora API was shut down 2026-09-24 — excluded);
     avatars/voice via HeyGen/ElevenLabs-style services) plus product
     footage/screenshots from the preview pane; assembly/edit via an engine
     tool (ffmpeg pipeline: cuts, captions burn-in, aspect 9:16, safe zones,
     loudness).
  4. *Review:* an automated check (duration, resolution, aspect, captions
     present, brand-kit compliance, banned-claims list, AI-content label
     flag) + clean-context reviewer + owner approval in the **Inbox**
     (outbound content is always an owner-approved ask unless the owner sets
     an explicit per-account policy — §6.24).
  5. *Publish:* via official APIs (TikTok Content Posting API, Instagram
     Graph API Reels publishing for business/creator accounts) through the
     external-communication outbox (§6.11a); scheduled per calendar.
  6. *Learn:* analytics (views, watch time, retention, shares, saves,
     follows, link clicks) pulled back into Company Memory; the growth analyst
     proposes the next batch from what worked (A/B hooks, formats, times).
- **Preview:** generated videos play in the preview pane (the 4a artifact
  adapter must support MP4/MOV with a phone-frame 9:16 view) and on a
  content calendar board.
- **Budget:** generation credits are metered spend under the funds budget
  (§6.17); per-video and monthly caps; the Inbox shows cost per video.
- **Guardrails:** label AI-generated content where platforms require it;
  only licensed/royalty-free music; no real-person likeness or voice without
  rights; no fake testimonials, fabricated reviews or impersonation; FTC
  endorsement/disclosure rules for sponsored or affiliate content; respect
  platform ToS and rate limits; claims checked against a per-company
  approved-claims list (important for CPG: health/efficacy claims).
- **Platform corrections (research 2026-10-21):** TikTok's Content Posting
  API needs per-post user consent and an audited app (unaudited apps can only
  post privately to ≤5 users/day), so **every TikTok post is an owner ask —
  no auto-post policy for TikTok**; no added logos/watermarks on TikTok; the
  publish check sets the platforms' AI-content flags (TikTok `is_aigc`,
  Instagram/Meta AI label, YouTube `containsSyntheticMedia`); music only from
  a licensed library (e.g. Epidemic Sound-style); metrics are pulled by the
  engine (not agents); Instagram trial reels are used for A/B tests.
- **Engine executes approved actions:** for outbound posts/messages, spend,
  and connector writes, the engine performs exactly the approved payload,
  once (idempotent); agents never call publish/spend APIs directly.
- **Where it lands:** a dedicated **Marketing plan (Plan M)** built right after
  the dogfood week begins (so the test company can market itself), depending
  on Memory-lite, the Inbox/outbox, funds budget and the integrations
  catalog; connectors for the chosen video service and platforms are part of
  it.

### 6.27 Personal agent memory, full work records, and tiered storage (**[owner]** asked for this)
**Agents remember like people [call]** (model: the "memory stream + reflection"
pattern from generative-agents research, adapted). Each agent owns a personal
memory, in addition to Company Memory (§6.25):
- **Episodic** — what it did and saw: every turn's summary, items worked,
  conversations, decisions, outcomes (auto-recorded by the engine).
- **Semantic** — what it knows: facts, preferences, codebase/domain knowledge,
  who-knows-what about teammates (written by `remember` and by reflection).
- **Procedural** — how it works best: learned playbooks/checklists ("before
  submitting, run the edge-case checklist"), promoted from repeated lessons.
- **Working** — the current item's context (the orientation digest).
- **Reflection ("sleep") [call]:** at the end of each item and each sprint, a
  cheap consolidation step (plain code + one short Haiku turn, budgeted)
  turns recent episodes into durable semantic/procedural memories, dedupes,
  and marks contradictions; nothing is deleted, only demoted.
- **Recall:** each turn, the engine retrieves the top-k memories for the
  current item scored by **relevance × recency × importance** (importance
  set at write time and boosted when a memory is reused); the agent can also
  `recall(query)` explicitly. Old, unused memories fade in ranking (a
  forgetting curve) but stay searchable.
- **Privacy:** an agent's personal memory is readable by that agent, its
  manager chain (summary level), HR/Performance where relevant, and the owner;
  agents share knowledge by publishing to Company Memory.
- **Continuity:** a replacement hire can inherit a departing agent's
  procedural + semantic memory (owner/HR choice), not its private episodes.

**Everything is recorded [call]:** every channel/DM message, every inter-agent
hand-off, ask, review comment and decision, every turn's tool calls and
results summary, and each turn's full Claude Code transcript (the session
JSONL) are kept, linked to agent, item and time — an immutable, append-only
work record (corrections are new entries). The owner can replay any agent's
day or any item's full history.

**Storage that grows but stays fast [call] — hot / warm / cold tiers:**
- **Hot (last ~30 days, configurable):** the main SQLite DB (WAL) holds
  recent messages, events, memories and turn summaries, with FTS5 indexes
  and (later) a local vector index; all live UI and agent recall hits only
  this tier → millisecond queries regardless of total history.
- **Warm (older):** a background compactor moves aged rows into per-company,
  per-month archive databases (`archive/<company>/<yyyy-mm>.sqlite`) with
  their own FTS indexes; raw transcripts are stored zstd-compressed beside
  them. Search spans tiers transparently (hot first, then warm via
  `ATTACH`, newest-first, paginated); per-day/per-sprint/per-agent summaries
  are precomputed so browsing history never scans raw rows.
- **Cold (backup):** hourly `VACUUM INTO` snapshots (keep 48) + daily backups
  of the warm archives and transcript files + git bundles of company repos,
  to a local backup folder and optionally an external drive or an
  owner-chosen, client-side-encrypted cloud bucket; continuous WAL shipping
  (Litestream-style) as an option for near-zero data loss. `brahma restore`
  restores any point; integrity check at launch.
- **Budgets:** per-company storage meter in the Budget view; transcripts are
  the bulk and compress ~5–10×; retention is "keep forever" by default with an
  owner-set cap that archives (never silently deletes).

**Where it lands:** Memory-lite (after 5-lite) ships personal memory
(episodic + semantic, recall scoring, end-of-item reflection), full work
recording incl. transcript capture, and the hot/warm split with
cross-tier search; cold backups ship in 5-lite; vector index, procedural
promotion and sprint-level reflection in Plan 9.

### 6.28 Living knowledge base — the company handbook (**[owner]** asked for this)
As the company runs, it builds and maintains its own documentation, kept clean
and current — the readable, curated layer above raw chats and memory (§6.25,
§6.27).
- **Storage decision [owner: "use what we've been using"]:** the handbook
  lives in the **existing Brahma SQLite database (GRDB)** — no new store.
  Tables: `kbPage` (company, path, title, section, body Markdown, owner,
  status, lastReviewed, sources), `kbRevision` (append-only history with
  author, item, diff summary — gives versioning and rollback), `kbLink`
  (backlinks). Search via the same **FTS5** indexing used for messages;
  semantic search later reuses Company Memory's index (§6.25). Pages are
  exported to Markdown files on demand (and included in backups) for
  portability. Agents edit pages through company tools (`kb_read`,
  `kb_write` with item linkage), not raw files.
- **Structure (pack-defined, software default):** Company (mission, goals,
  org, policies, glossary) · Product (PRDs, specs, roadmap, release notes) ·
  Engineering (architecture, ADRs, API, data model, runbooks, on-call) ·
  Design (brand kit, design system) · Go-to-market (positioning, ICP,
  marketing playbooks, content calendar) · Operations (vendors, processes,
  incidents/postmortems) · Research (market/customer/competitor reports) ·
  Decisions log · Meeting notes. Packs swap sections (e.g. CPG: formulations,
  suppliers, regulatory, SKUs).
- **Auto-generated pages:** org chart, roster, decision log, release history,
  sprint summaries — rendered from the DB, regenerated by the engine, never
  hand-edited.
- **Kept current:** every doc has front-matter (owner, status
  draft/active/deprecated, last reviewed, sources/links to items, decisions,
  messages). Work items that change behavior must update the relevant doc
  (a check flag); a librarian job flags stale pages (not reviewed in N
  sprints, or linked code/decisions changed since) as small work items;
  duplicate/contradiction detection via search. Page edits are recorded as revisions linked to the work item;
  significant pages (policies, architecture, PRDs) require review; one
  writer per page at a time (lease).
- **Access:** agents read via `search_kb` / file reads within their scope
  (restricted sections, e.g. HR, finance, legal, only for permitted roles);
  each turn's orientation links the 3–5 most relevant pages. Company
  Memory indexes the handbook so recall cites docs first.
- **Owner UI:** a clean, ops-console-styled Handbook view (tree + search +
  backlinks + "recently changed" + staleness badges), sanitized Markdown
  rendering, export as a static site or zip.
- **Where it lands:** Memory-lite (handbook skeleton per pack, auto pages,
  FTS search, `search_kb`, orientation links, Handbook view); librarian
  staleness jobs and semantic search in Plan 9.

### 6.29 Per-agent workstation and permission layering (**[owner]** asked; consolidates §6.5a, §6.22, §6.23, 5-lite)
Every agent works in its **own sandboxed workstation**, compiled fresh by the
engine before each turn (`TurnProfile`):
- **Sandbox:** own `HOME` (shell prefix), writes only to its current item's
  worktree, its lab and caches; reads deny the owner's home (carve-outs for
  the company workspace and toolchains), the Brahma data home, credential
  directories and other companies; network per company allow-list.
- **Claude Code profile:** the shared `claude` binary and the owner's single
  subscription login, but a per-turn settings file with the role's built-in
  tools, skills (company skill library), plugins (company plugin dir), MCP
  servers (company server + the role's connectors), and model.
- **AI tools and services** (video/image/voice generation, Figma automation,
  cloud, DBs, commerce, ads…) are **connectors** installed per company and
  enabled per role; credentials stay engine-held and are used through
  connector tools, never handed to the agent.
- **Permission layers (each can only narrow, except explicit grants):**
  1. company permission profile (Sandboxed default / Workspace / Full);
  2. role defaults from the pack — role card + tool bundle (tools, skills,
     plugins, connectors, risk levels) — gstack-style role cards and the
     per-industry bundles live here (Plan G generates them);
  3. trust level (Plan 3b): budget, model, review depth;
  4. current work item: writable paths/branch, required check;
  5. owner grants from the Inbox (scope + duration; §6.23);
  6. taint (§5-lite): a turn that read external content loses send / spend /
     approve / secret / grant tools for that session.
- **Invariants:** no access to another agent's private memory or files,
  other companies, or raw credentials; any missing capability is an Inbox
  ask — agents can never grant themselves anything; the compiled profile for
  every turn is recorded in the work record for audit.

## 7. Architecture sketch

```
┌────────────── AgentCompany.app (SwiftUI + menu bar) ──────────────┐
│  UI: Mission control · Chat · Board · Requests · Resources        │
│        ▲ observes                                                  │
│  Orchestrator (in-process)                                         │
│   ├─ Scheduler (states, modes, caps, usage backoff)                │
│   ├─ TurnRunner → spawns `claude -p --resume …` per turn,          │
│   │               parses stream-json                               │
│   ├─ Message router / inbox digests                                │
│   ├─ Work tracker (backlog, sprints, gates)                        │
│   ├─ Preview runner (dev server process)                           │
│   ├─ Notifier (UserNotifications, Messages, SMTP)                  │
│   └─ Store (SQLite/FTS5) + Keychain                                │
│        ▲ Unix socket                                               │
│  company-mcp (same binary, --mcp mode) ◄── stdio ── claude turns   │
└────────────────────────────────────────────────────────────────────┘
```

## 8. Suggested build order (builder may adjust)
1. Store + agent records + TurnRunner running one agent turn end-to-end
   with the company MCP tools (post_message, send_dm).
2. Scheduler with thread states and Low/Balanced/Max; usage-limit backoff.
3. Chat UI (channels, DMs) and persistence/search.
4. Org chart generation + roles; work items, backlog, sprints, gates.
5. Mission control: map, activity feed, preview pane with the web adapter.
5b. Remaining preview adapters: iOS Simulator, macOS app, CLI, backend.
5c. Permission profiles: Workspace and Full first, then Sandboxed (default
    once ready).
6. Requests, Keychain secrets, notifications (macOS, iMessage, email).
7. Resources drag-and-drop.
8. Scale testing: 300 agents existing, safety cap, map collapsing.

## 9. Left to the builder
- Exact SwiftUI structure, graph layout algorithm for the map, DB schema.
- Precise role prompts and tool allow-lists (within 6.3/6.6).
- Definition of a sprint boundary in an agent world (6.8).
- Default concurrency numbers after measuring real per-process cost.
- Whether chat opens as a panel or replaces the top half.
- Visual design (should feel native macOS, readable at a glance).
