# Agent Company — Design

Date: 2026-10-20
Status: draft, awaiting owner approval

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
| **Workspace** | Not OS-sandboxed, but Claude Code permissions restrict file edits and Bash to the workspace dirs (`--add-dir`, allow/deny rules); project-local installs only (npm/pip/venv/SPM per project); open network. |
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
- **Money:** agents never hold payment details. A money request is a request
  for the owner to purchase/approve a specific charge; the owner does it and
  marks done. **[call]**
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
