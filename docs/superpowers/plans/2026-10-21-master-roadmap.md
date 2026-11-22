# Brahma — Master Roadmap (final ordered build plan)

Date: 2026-10-21 (chief review). This file holds the build order, the contract each plan hands to the plans after it, and where every v2 requirement lands.

**Authority:** owner decisions (latest wins; log in `autonomous-run.md`) > `../specs/2026-10-21-brahma-design-v2.md` > older spec > plans. Requirement IDs (R-nnn) are in `../specs/2026-10-21-traceability.md`, whose Plan column this review updated.

This roadmap supersedes the following parts of v2:
- §2.2, the 3a status;
- §5, the "Not in the order" paragraph;
- the answers to §7 Q1–Q3;
- C-32, for the artifact preview only.

Everything else in v2 stands.

## 1. Order at a glance

| # | Plan | Status (2026-10-21) | Plan file | Hard dependencies |
|---|---|---|---|---|
| 1 | **P1 Core engine** | built, merged | `2026-10-20-plan1-core-engine.md` | — |
| 2 | **P2 Mac app** | built, merged (`569a0cd`, 241 tests) | `2026-10-20-plan2-mac-app.md` | P1 |
| 3 | **3a Work system (amended)** | **building**. Tasks 1–4 committed in worktree `plan3a-work` (`60b5319`); Tasks 5–16b remain (20 dispatches including the splits). Patch notes: `tmp/plan3a-patch-notes.md` | worktree `docs/superpowers/plans/2026-10-20-plan3a-work-system.md` | P1, P2 |
| 4 | **5L Safety floor** | written, 18 tasks (1a, 1b, 2–7, **7b, 7c**, 8–12, 13a–c); builder-check fixes folded in; this review's edits applied | `tmp/2026-10-21-plan5lite-safety.md` | 3a |
| 5 | **L "Live"** | written, 14 tasks; being amended (existing-repo import added by owner). Notes: `tmp/planL-4a-notes.md` L1–L6 | `tmp/2026-10-21-planL-live.md` | 3a, 5L |
| 6 | **ML Memory-lite (lean)** | **to write** (scope in §2.6) | — | 3a, 5L (taint, transcripts, redaction) |
| 7 | **4a Merge queue and non-web previews** | written, 10 tasks, re-cut on L; being re-planned. Notes: A1–A7 | `tmp/2026-10-21-plan4a-workspace-previews.md` | 3a, 5L, L |
| 8 | **4b Org-chart map** | written, 15 tasks (pre-build checks applied 2026-10-23); builds after C | `docs/superpowers/plans/2026-10-21-plan4b-maps.md` | 3a (+ layout left by L/4a) |
| 9 | **Dogfood week** | after 4b | — | all of the above |
| 10 | **Ops** | to write; after the dogfood week **[owner 18:16]** | — | L, 5L |
| 11 | **M Marketing** (v1 text/image, M2 video) | to write | — | L (human tasks), ML (memory ingest), 5L |
| 12 | **G Profile/pack generator** | to write | — | 3a packs, asks |
| 13 | **ML-2 Memory (full)** | to write; after dogfood **[owner 18:16]** | — | ML, dogfood data |
| 14 | **3b Performance and people** | written then shelved; rewrite on asks from dogfood data | `tmp/2026-10-21-plan3b-performance-people.md` (stale base) | 3a facts, G, dogfood |
| 15 | **4c Office view** (the map's easter egg; replaces the Village skin, which is superseded; Hive is not in 4c) | **building** (2026-11-22) in worktree `plan4c-office` (Tasks 1–10 and 12 done; Task 11, the header toggle, waits for Plan P) | `2026-11-21-plan4c-office.md` | 4b `MapModel`; 3b supplies live perks (optional) |
| 16 | **7 External comms** | to write | — | 5L (taint, timers, grants), asks |
| 17 | **11 Running the company** (connectors, funds, browser) | to write | — | 5L, 7 |
| 18 | **9 Labs and memory v2** | to write | — | ML-2, 5L |
| 19 | **8 Headless server** | to write | — | everything engine-side |
| 20 | **10 Steward** | to write | — | 8 (telemetry API), facts |

Why this order (v2 §5 and §6.24a, plus the owner's 18:16 answers):
- the safety floor comes before anything that runs agent code unattended;
- the first proof point (goal → live URL → launch post) comes before breadth;
- memory and the map come before the dogfood week;
- every redesign (3b, ML-2, Ops details, the deferred review recommendations) waits for dogfood data.

**Migration order (append-only, one chain):**
1. P1 `v1`, P2 `v2-owner-read`;
2. 3a `v3-org … v3-budgets`, with an optional `v3-asks-2`;
3. 5L `v5-sandbox, v5-owner-guard, v5-secrets, v5-plugins, v5-timers, v5-notices, v5-push, v5-stop, v5-digests, v5-grants, v5-taint, v5-transcripts, v5-targets`;
4. L `vL-preview, vL-hosting, vL-release, vL-human-tasks`, plus L1's import migration if it needs one;
5. ML `vML-*`;
6. 4a `v4a-merge, v4a-merge-journal, v4a-preview-kinds, v4a-artifacts, v4a-demos`;
7. 4b `v4b-vacancy-note`;
8. then each later plan in build order.

Every plan names its anchor as "after the previous plan's last migration".

## 2. Plans: scope, contract, requirements

Each plan below lists:
- **Consumes**: what it needs from earlier plans;
- **Produces**: the key types, tables and tools that later plans use;
- **R**: the requirement IDs it lands.

Names in the 3a contract are as built or as amended plus the patch notes.

### 2.1 P1 Core engine — built
- **Scope:**
  - the Store (GRDB, WAL, FTS5);
  - agents and their states;
  - channels, DMs, inbox and router;
  - the stream parser, usage gate, safety cap and weighted round-robin scheduler with modes;
  - the turn runner, orchestrator, `brahma mcp` messaging tools, the CLI and a live smoke test.
- **Produces:**
  - tables `company, agent, channel, channelMember, message (+messageFts), inboxItem, turn, activityEvent, rateLimit`;
  - `Store`, `Orchestrator` (actor, 1 s tick), `Scheduler`/`SchedulerConfig`, `UsageGate`, `SafetyCap`, `TurnRunning`/`ClaudeProcessRunner`, `StreamParser`/`StreamEvent`, `MessageRouter`, `CompanyTools`, `OrchestratorLock`, `BrahmaPaths`.
- **R:** 001, 002, 012, 013, 018, 019, 027, 028, 029, 032, 039, 040, 041, 045, 046, 056, 057, 060, 061, 215.

### 2.2 P2 Mac app — built
- **Scope:**
  - `Brahma.app` with the embedded engine (lock policy, takeover), login PATH and quit → stop;
  - rail, sidebar, chat and search, the mission-control skeleton and activity feed;
  - roster, hire and kill, and the menu bar;
  - the BrahmaTheme ops console, `--ui-snapshot` and `--smoke-test`.
- **Produces:**
  - `BrahmaAppModel` (`AppModel`, `Snapshot`, a 500 ms poller, `SelectTarget`, `LaunchOptions`, `SidebarItem`, `AppSheet`, presentation helpers);
  - `EngineHost`;
  - `BrahmaTheme` components;
  - `scripts/make-app.sh`, `ui-snapshot.sh`, `smoke-app.sh`, `seed-demo.sh`.
- **R:** 001, 003, 012, 014, 015, 020, 026, 028, 039, 230, 232, 233, 234, 235, 236, 237, 240, 243.

### 2.3 3a Work system (amended) — building
- **Scope:**
  - packs and role cards v2;
  - org generation with vacancies and seat budget;
  - no-wake channels and actionable notices;
  - the TurnProfile compiler, doctor and child-env allowlist;
  - the active clock, owner time zone, weekly share and pacing with burst and critical-path exemption, planTier caps, memory admission and the health gate;
  - work items, events and notices;
  - engine dispatch, leases, worktrees per lease, hardened git, path-overlap and hot-path guards;
  - engine-run checks on committed snapshots: flags, flake and infra handling, CheckPaths and the integrity guard;
  - clean-context review, engine merge, early conflict detection, freshness, conflict briefs, and risk-tiered auto-merge with audits;
  - fresh and warm-only sessions, hand-offs, orientation, operating rules, no empty turns;
  - the one Inbox of asks: brief, classes, presets, reserved floor, lifecycle, rescind, escalation;
  - attrition, the stall explainer, deadlocks and aging;
  - sprints with engine standups and timeboxes, gates that block only irreversible work, the combined gate for ≤ 8 agents;
  - $LE budgets, the watchdog and outcome facts;
  - app work, Inbox views and macOS notifications.
- **Consumes:** P1, P2.
- **Produces (later plans depend on these):**
  - **Org:** `PackCatalog`, `IndustryPack` (`triggerRoles`, `connectors`, `reservedCategories`, `askApprovers`), `RoleTemplate` (`playbooks`, `skills`, `connectors`), `CompanyToolNames` (base, work, lead, executive, review, **audit**), `OrgGenerator.staff`, `OrgVacancy` with `vacancies(companyId:)` and `fillVacancy` (table `orgVacancy`), `Store.seatBudget()` from planTier.
  - **Turns:**
    - `TurnKind {work, review, audit, notice}`, a single enum (patch note 1), with `ModelPolicy` and `ModelContext`;
    - `TurnProfile` / `TurnProfileCompiler.profile(for:)`, `arguments(_:)`, `settingsJSON(_:)`;
    - `ChildEnvironment.make(base:extra:purpose: .claude | .general | .check)`;
    - `Doctor`/`DoctorReport` (table `engineProbe`) and `StableHash`.
  - **Time and health:** `Store.activeNow(companyId:)`, `ownerTimeZone()`, `planTier()`, `weeklyShare`, `UsageGate.pace`, `UsageCalibration` (`pctPerDollar`), `MemoryPressure`, `EngineHealth`/`HoldReason` (table `engineHold`), `EngineAlerts.raise`, and the `isFrozen(companyId:)` hook for 5L's stop.
  - **Work:**
    - tables `workItem` (incl. `touchPaths`, `stopReason`), `workItemDependency`, `workItemEvent`, `workNotice`, `workLease`, `verificationRun`, `checkSnapshot`, `reviewAudit`, `itemFact`;
    - `WorkItem`, `WorkEventKind`, `WorkError`, `WorkPolicy`, `WakePolicy.noticeWakes`;
    - `GitWorkspace` + `GitCommand` (hardened), `CheckRunning`/`CheckOutcome`/`CheckSpec`, `CheckPaths` (`<ws>/.brahma/checks/<KEY>/rev<n>/`, `<ws>/.brahma/wt-check/<runId>`);
    - `approveForMerge` (one approval hook), `finishMerge(itemId:result:now:)` (owns the conflict brief), `MergeSafety.afterLanding`, `completeItem`;
    - `WorkItemObserver`, `AgentLifecycleObserver`, `ProgressFile` (`.brahma/progress/<KEY>.md`), `Handoff`, `TurnContext`/`TurnDigest`, `OperatingRules`, `RolePrompt`;
    - `Sprint`/`Cadences`, `Store.sprints(companyId:statuses:)`, `TierBudget`, `Watchdog`, `OutcomeFactsObserver`.
  - **Inbox:**
    - table `ask` (with `requestId`, `decisionClass`, `proposedGrant`);
    - `AskKind` (`prd, architecture, sprintPlan, release, other, info, engineAlert`; reserved `request, grant, deploy, humanTask, outbox, spend, staffing, stage, role`);
    - `AutonomyPolicy`, `ReservedMatters`;
    - `Store.propose`, `requestFromOwner`, `internalDecide`, `ownerDecide`, `ownerAnswer`, `ownerReplan`, `ownerRescind`/`reverseAskEffects`, `acknowledge`, `applyAskEffects`, `hasApproved`, `sweepAsks`;
    - `StallExplainer`.
  - **App:** `WorkSnapshot`, `InboxRows`, `SafeMarkdown`, `InboxNotifications.due`, `markAskNotified`, sidebar `.backlog`, `.board` and `.inbox`.
  - **CLI:** `company create --agents/--dry-run`, `org` (move, vacancies, fill, acting), `items`, `inbox`/`approve`/`answer`/`rescind`, `company autonomy|reserve`, `settings timezone|plan|share|hot-paths`, `sprint`, `why`, `perf facts`, `doctor`. `requireOwnerShell()` is on every owner write.
- **R:** 003, 005, 008, 009, 010, 017, 021, 022, 025, 029, 030, 032, 033–038, 042–044, 046–056, 058–060, 062–066, 069–077, 079, 083 (floor), 087–105, 107–109, 111–119, 124–127, 129–152, 154, 158, 163, 164, 173 (budget), 194 (pack field), 199 (pack prompts), 215, 232, 234, 235, 237, 239–242, 248, 283 (schema), 287 (reserved), 293 (counters), 294 (N=300 wake tests).

### 2.4 5L Safety floor — written
- **Scope:**
  - the Sandboxed profile as the default: Claude sandbox settings file, `--restricted --tools`, per-agent HOME through the shell prefix, narrow writes (item worktree, the item's ref, the progress file, own notes, lab, own cache), read denies, an egress CONNECT proxy, a keyed live canary and a per-command sentinel;
  - Seatbelt-sandboxed checks;
  - the DB made unreachable, plus owner-shell ancestry;
  - Keychain secrets (engine-held; test keys via `use_secret`), redaction everywhere, leak scans at submit and merge;
  - a structurally validated company plugin and skill library, and engine-owned hooks;
  - engine timers;
  - owner notices (quiet hours, batching, ask quota, badge, sleep prevention);
  - **phone alerts via ntfy or Pushover (7b)** and the **global kill switch (7c)**;
  - the daily digest; grants with scope, duration, ledger and safe presets;
  - the taint rule and impersonation flags; the Access Center and settings UI;
  - restorable backups (VACUUM INTO, integrity, atomic restore, FTS rebuild, repo re-adoption), export, transcript capture, data-home snapshots, external and rclone-crypt targets, and Litestream.
- **Consumes:** 3a.
- **Produces:**
  - `PermissionProfile.sandboxed`, `SandboxLayout` (`agentHome`, `lab`, `agentCache`, `sharedCache`, `pluginLib`, `hooksDir`, `shellPrefix`), `SandboxScope.forTurn`, `CompanyNetwork.scope`, `ClaudeSettings(Compiler)`, `ShellPrefix`;
  - `SandboxPolicy` / `SandboxNetwork {none, outbound(allow:), loopbackListen(allow:ports:)}`, `SandboxedRunner`/`SandboxedProcess`, `SandboxRunners.platformDefault`, `EgressProxy`, `DomainMatcher`, `SandboxedCheckRunner`;
  - `OwnerShellGuard`, `SandboxCanary` (table `sandboxCanary`, `turn.pid`);
  - `SecretVault`, `Redactor`, `Store.reloadRedactorIfNeeded`, `SecretScan.check` (tables `secret`, `secretUse`);
  - `PluginLibrary`, `CompanyHooks` (table `companyPlugin`);
  - `EngineTimer`, `TimerJobRegistry`, `SystemTimers` (table `timer`);
  - `Store.notifyOwner`, `NoticeDelivery`, `AskQuota`, `QuietHours` (tables `ownerNotice`, `ownerPrefs`);
  - `PushDispatcher`/`PushChannel` (`pushLog`, `ask.pushedAt`);
  - `EmergencyStop`/`EmergencyStopObserver` (table `engineStop`);
  - `Digest` (table `ownerDigest`);
  - `Grant`/`GrantResolver`/`AccessPresets` (tables `grant`, `accessPreset`);
  - `TaintPolicy` (`taintSafeTools`, `reviewedHighRisk`, plus `everyToolClassified`, which every later plan must extend), `UntrustedBlock`, `OwnerImpersonation`;
  - `BackupService`, `RestoreHooks.afterRestore`, `CompanyExporter`, `TranscriptCapture` (table `turnTranscript`), `HomeSnapshot`, `BackupTargets`, `WALShipping`.
- **R:** 007, 023, 031, 057, 058, 064, 100 (reuse), 110, 143 (request/grant), 153, 155–162, 164–181, 198, 209 (taint), 215, 216, 226–229, **238**, 239, 262 (timers), 273 (lab path), 295; **161** (7b).

### 2.5 L "Live" — written, being amended
- **Scope:**
  - the web preview from an engine-owned checkout of `main` (sandboxed, loopback, per-preview ports, crash loop, rebuild on merge);
  - hosting settings with Cloudflare Pages (default) and Vercel adapters, and engine-composed deploy plans;
  - the main smoke check and the red-main P1 bug; release records;
  - the owner-only `deploy` ask executed exactly once, with a staged upload, an engine-held token, a URL smoke and a recorded rollback; the main-backup ref and release tags;
  - `humanTask` asks: hosting account, domain, Stripe test keys, launch post;
  - the software-pack live path, `--demo live`, milestones and the live goal → URL test;
  - **new: start a company from an existing repo** (owner 18:16, note L1).
- **Consumes:** 3a (git, asks, ops tool group, `approveForMerge`/`finishMerge`), 5L (`SandboxedRunner`, `sharedCache`, vault, redactor, `notifyOwner`, `AskQuota`, `TaintPolicy`, `EmergencyStopObserver`).
- **Produces:**
  - `EngineLayout` (`.brahma/preview`, `.brahma/releases`; preview/release/smoke builds use fresh `EngineExport` trees with no `.git` — no persistent `.brahma/wt/.preview` or `.release` checkouts);
  - `PreviewKind`/`Status`/`Surface`/`State`, `PreviewAdapter`, `PreviewRunner`, `PortAllocator`, `HTTPProbing`, `SmokeRequest`/`SmokeResult`, `LoopbackURL`, `PreviewPolicy.server`;
  - `HostingAdapter(s)`, `DeployPlan`, `ReleaseExecutor`, `ReleaseStatus`, `ReleasePolicy.mainIsGreen`;
  - `HumanTask`/`HumanTaskTemplate`, `Store.fileTemplateTask`, `completeHumanTask`;
  - `CompanyMilestones` (plus $LE per phase and owner touches, note L6);
  - `AskKind.deploy`, `.humanTask`; `CompanyToolNames.ops`;
  - tables `previewSurface`, `previewState`, `hosting`, `mainSmokeRun`, `release`, and `workItem.blockedByAskId`;
  - app `PreviewPane`/`PreviewTabs` (WEB, LIVE), `ReleasesView` (Work › Releases), deploy and human-task Inbox cards, the HOSTING settings panel.
- **R:** 004, 030 (previews), **067**, 121 (backup ref), 122, 123, 143 (deploy/humanTask), 183, 185–188, 197 (deploy), 241 (releases), 250 (humanTask path for M), 287.

### 2.6 ML Memory-lite (lean) — to write
Owner 18:16: lean = search on demand plus recording. Push and reflection wait for ML-2 after the dogfood week.
- **Scope:**
  - **Company Memory, pull-only.**
    - A scoped FTS index over what already exists (messages, items and events, asks, hand-offs, handbook pages, artifact titles, resources text) plus a `memoryEntry` table for `remember(fact, scope, key, type, confidence)` with provenance.
    - Scope and sensitivity filtering in the engine *before* results reach the agent: company, team, role, agent, item and grants. No cross-company retrieval.
    - Tools `search_memory`, `recall` (cited, quoted snippets ranked by bm25 × recency) and `remember` (dedupe on key; marks contradictions).
    - Results are rendered as `UntrustedBlock` data. An entry whose provenance is external content (WebFetch-derived research, later inbound mail) taints the session per 5L's rule, so `recall` and `search_memory` are classified in `TaintPolicy` and taint on those entries.
  - **Personal memory (lean).** Episodic memory = the existing turn summaries and records (no new capture). Semantic memory = `remember` entries scoped to the agent. Privacy as in v2 §4.11.2: agent, manager chain at summary level, owner.
  - **Handbook.**
    - Tables `kbPage`, `kbRevision`, `kbLink` with FTS; `kb_read`, `kb_write` (item-linked, one-writer page lease), `search_kb`.
    - The pack-defined tree, and engine-rendered auto pages: org chart, roster, decision log, release history, sprint summaries.
    - Markdown export (also included in 5L export and backups).
    - The Handbook view: tree, search, backlinks, recently changed, sanitized Markdown.
  - **Recording UI.** Replay of any agent's day or any item's history from turns, events, messages and 5L transcripts (R-217), plus a storage meter on the Budget view.
  - **Resources drag-and-drop (owner 18:16, R-205).**
    - Files, folders or URLs dropped onto the Resources library (company), a channel (team) or a DM (agent) are copied into `resources/<scope>/`; URLs are stored as link records, never fetched by the app.
    - They are read-only to agents (5L `readOnlyDirs` already covers `resources/`), announced in the next digest as a non-waking notice, and text files are indexed for `search_memory`.
    - Size cap and type allowlist; symlinks refused; owner-only.
- **Not in ML (ML-2, after dogfood):** top-k memories pushed into orientation; orientation links to 3–5 handbook pages; end-of-item reflection turns; the warm-tier compactor and cross-tier search; the doc-update check flag and significant-page review.
- **Consumes:** 3a (`TurnContext`, asks, items, `WorkItemObserver`), 5L (`TaintPolicy`, `UntrustedBlock`, `Redactor`, transcripts, `readOnlyDirs`, export), L (release history page).
- **Produces:** migrations `vML-memory`, `vML-kb`, `vML-resources`; `MemoryIndex`, `MemoryScope`/`Sensitivity`, `memoryEntry`, `kbPage`/`kbRevision`/`kbLink`, `resource`; tools `search_memory, recall, remember, kb_read, kb_write, search_kb`; `Store.ingest(...)` for M (analytics) and 7 (inbound); app Handbook, Memory browser (owner delete), Replay.
- **R:** 199, **205**, 206, 207, 208 (tools), 209, 211, 214, 217, 218, 219 (tools), 220, 221 (lease), 223, 224, 229, 234 (Handbook, Resources), 242 (storage), 243 (memory search).

### 2.7 4a Merge queue and non-web previews — written, being re-planned
- **Scope:**
  - The batched merge queue replaces 3a's one-item merge step but keeps `finishMerge`. It takes both approved and auto-merged items via `approveForMerge`.
  - Journaled, crash-safe batches with bisect, and the company main check.
  - The main guard: only the queue moves `main`; foreign moves are saved as `refs/brahma/foreign/*` and restored; `adopt-main`.
  - Non-web preview kinds on L's engine (CLI, backend/API, iOS Simulator, macOS app).
  - Published artifacts (Markdown, HTML, PDF, images, tables, office documents and decks, spreadsheets and BOMs, glTF/STL 3D, MP4/MOV with the 9:16 phone frame; STEP/IGES as a file card). This **also carries non-software deliverable previews (owner 18:16, R-285)** and the artifact preview v2 had put in L (resolved here, R-184 and R-192).
  - Sprint-review demos; the merge-queue panel.
- **Consumes:** 3a (`GitWorkspace`/`GitCommand`, `finishMerge`, `approveForMerge`, `MergeSafety.afterLanding`, `CheckPaths` + integrity guard, `CheckRunning`), 5L (`SandboxedRunner`, `SecretScan`, `notifyOwner`, `RestoreHooks`, `EmergencyStopObserver`, `TaintPolicy`), L (`EngineLayout`, preview model and runner, `PreviewTabs`, `MainHealth`, ops tools).
- **Produces:** tables `mergeRequest`, `mergeRun`, `mergeBatch`, `artifact`, `previewDemo`; `company.mainCommit`/`mainCheck`; `MergeQueue`, `GitLock`, `MainGuard`, `ArtifactAdapter`, `publish_artifact`, `set_main_check`; app `MergeQueueView`, artifact, 3D, video, terminal, simulator and window views.
- **R:** 030, 120, 121 (main guard), **184**, 189, 190, 191, **192**, 241 (merge status), **285**.

### 2.8 4b Org-chart map — written (re-based by this review)
- **Scope:**
  - a live org chart (Board → CEO → C-suite → directors → managers → ICs) with state colors and current items;
  - message particles, hand-offs and broadcasts; collapse, search, follow and zoom;
  - **vacancies from 3a's `orgVacancy`**, with owner add, fill and remove;
  - dotted review lines, sprint meeting hulls, animated org changes;
  - a one-hour replay, pop-out window, `--map-demo` with 300 agents, and a bench (p95 ≤ 16.7 ms).
- **Consumes:** 3a (`managerId`, `team`, packs, `OrgVacancy`, `fillVacancy`, items, hand-offs, `Store.sprints`), P2 theme; the mission-control layout left by L and 4a.
- **Produces:** `BrahmaMapKit` (SpriteKit), a mode-agnostic `MapModel`, `OrgTree`/`OrgLayout`, `MapController`, `MapPeopleProviding` (the 3b and 4c hook), `ThemeHex` (the single color source); `Store` feed queries `messageFlows`/`handoffFlows`/`events`; `addVacancy`/`removeVacancy` (migration `v4b-vacancy-note`).
- **R:** 020 (map), 231, 244, 245, 294 (bench).

### 2.9 Dogfood week
- One real company at N ≈ 8 for a week, run with the dogfood protocol of v2 §4.20:
  - pause it for 2 days and resume;
  - kill the CEO;
  - pull the network;
  - hit the usage limit;
  - leave it with the owner away for 24 h;
  - reorg mid-sprint;
  - give it a flaky test.
- The scorecard combines L's milestones (time, $LE per phase, owner touches), 3a's facts and the stall reasons.
- **Entry checklist (R-011, owner, not code):** confirm the Claude subscription terms for sustained automated use, the AI-disclosure rules for anything posted, and the platform ToS for the hosting provider.
- **Exit decisions:**
  1. rewrite 3b;
  2. finalize the ML-2 scope;
  3. finalize the Ops scope;
  4. adopt or drop the deferred review recommendations: parked state, default checks per stack, research via sub-agents, duplicate-item check and item quotas, onboarding packet (owner ruling 18:16).
- **R:** 011 (checklist), 293.

### 2.10 Ops — to write (after the dogfood week, owner 18:16)
- **Scope:**
  - **Incidents and on-call:** an uptime check on the deployed URL as an engine timer reusing L's `DeploySmoke`; an incident is a P1 item plus an urgent owner ask, which 5L push breaks through quiet hours.
  - **Launch-readiness gate:** a `stage` ask with a checklist from the pack.
  - **Change freeze:** blocks the merge queue's landing and deploys.
  - **Lifecycle stages:** `company.stage` with values building, launched, operating, paused, winding down, archived. Each change is a reserved `stage` ask. The plan includes the wind-down checklist and archive, restore and delete (built on 5L export; deletion is reserved).
  - **Owner away mode:** time-boxed pre-delegation policies, never covering reserved matters.
  - **Resume brief** after a long pause.
  - **Secret-leak incident playbook:** rotate through a human task, revoke grants, scrub, record.
  - **Weekly board memo:** built from the digest.
- **Consumes:** L (hosting, `DeploySmoke`, releases, rollback, human tasks), 5L (timers, push, notices, secrets, grants, export, kill switch), 3a (asks, reserved `stage` category, sprints).
- **R:** 288, 289, 290, 291, 292.

### 2.11 M Marketing — to write
- **Scope:**
  - **v1, text and image** (v2 §4.13): a landing page and waitlist as software-pack items; launch-post drafts for X, LinkedIn, HN, Product Hunt and Reddit; image creatives; a brand kit and a content calendar.
  - Every post is an owner ask, published through L's `launch-post`-style human tasks, or through engine-executed connector payloads where a connector exists.
  - Analytics are pulled by the engine into ML's `Store.ingest`.
  - Recurring work items: cron plus a pre-check script.
  - **M2, video:** a generation connector, ffmpeg assembly, an automated check, review, and the official TikTok and Instagram APIs with AI flags. Sora is excluded, and there is no auto-post for TikTok, ever.
- **Consumes:** L (human tasks, artifacts via 4a for image and video previews), ML (ingest), 5L (spend counted as metered once 11 exists; timers), 3a (asks, reserved `outbound`).
- **R:** 197, 204 (marketing roles), 249–257.

### 2.12 G Profile/pack generator — to write
- **Scope:**
  - `propose_role` with a cited need; the role generator (card v2, toolkit, placement);
  - plain-code validation: schema, authority lint, reserved tools, caps, connectors;
  - a reserved prompt-change ask;
  - versioned company packs with diffs; `propose_role_change`;
  - hire from a description, new company from a description, save a company as a pack;
  - A/B evaluation; non-software built-in packs; pack cadences beyond sprints; rubric review templates; pack upgrade with a diff.
- **Consumes:** 3a packs, asks, `AskKind.role`; 5L plugins and skills; 11 connectors (catalog rows, when present).
- **R:** 078, 080–086, 128, 143 (role), 204, 252, 283, 284, 286.

### 2.13 ML-2 Memory (full) — to write (after dogfood)
- **Scope:**
  - top-k memories pushed into orientation, bounded and scored by relevance × recency × importance with a forgetting curve;
  - orientation links to 3–5 handbook pages;
  - end-of-item reflection (plain code plus one budgeted Haiku turn);
  - the warm-tier compactor (`archive/<company>/<yyyy-mm>.sqlite`) with cross-tier search and precomputed summaries;
  - the handbook doc-update check flag and significant-page review.
- **R:** 208 (push), 212, 219 (links), 221 (flag/review), 225.

### 2.14 3b Performance and people — rewrite after dogfood
- **Scope (v2 §4.15):**
  - the efficiency meter, behind FeedbackGuard;
  - the trust ladder T0–T3 (permission layer 3);
  - cosmetic rewards; the HR partner (warning → PIP → termination, all reserved);
  - the ideas pipeline;
  - pairing, smart-friend consults, interface contracts, staffing tools, per-agent post limits, the sprint judge;
  - a `MapPeopleProviding` implementation for 4b and 4c.
- The plan is rewritten on asks, not the old `decision` table.
- **R:** 106, 176 (trust layer), 214 (inheritance), 248 (meter/trust), 263–272.

### 2.15 4c Office view — building (`2026-11-21-plan4c-office.md`)
- The Office replaces the Village skin (superseded). It is a 3/4 top-down office floor in SpriteKit with original art drawn in code, on 4b's `MapModel` and `MapController`. Perks are shown on desks and in a break-room wall of fame.
- It is an easter egg: hidden until the owner finds it, then an `ORG | OFFICE` toggle in the map header, with no re-lock. Spec: `../specs/2026-11-21-office-view-design.md`.
- Hive (3D, SceneKit) is not in 4c and has no plan; it may return as its own plan.
- Superseded (historical): the original scope was "Hive (3D, SceneKit) and Village (2D isometric, SpriteKit, original art, perks shown)".
- It is exempt from the ops-console brief.
- **R:** 247 (Office view), 265 (break room display); 246 (Hive) has no plan.

### 2.16 7 External comms — to write
- **Scope (v2 §4.14):**
  - owner-connected mailbox and social accounts through official APIs;
  - outbox asks, with auto-send only under an explicit per-account policy;
  - inbound mail into `#external`, tainted and flagged for impersonation;
  - follow-up timers, loop caps, consent and opt-out lists;
  - legal, press and regulator messages as reserved asks;
  - a killed agent's threads reassigned through `AgentLifecycleObserver`.
- **Consumes:** 5L timers, taint, `UntrustedBlock`, grants; ML ingest.
- **R:** 024 (threads), 068, 143 (outbox), 153, 178, 197, 258–262.

### 2.17 11 Running the company — to write
- **Scope (v2 §4.10):**
  - the connector model and Integrations catalog with per-pack bundles;
  - connector install as a reserved ask; metered connectors count as spend;
  - sign-in asks;
  - the browser (Playwright MCP, isolated profiles, quarantine);
  - funds (budget, funds connector, `request_spend`, journaling, vendor register, reconciliation, runway); the CFO role and Finance view.
- The browser and connectors register with 5L's `EmergencyStopObserver`.
- **R:** 006, 008, 068, 143 (spend), 153, 182, 193–197, 200–204, 242 (funds), 256.

### 2.18 9 Labs and memory v2 — to write
- **Scope:**
  - per-agent labs (the path is reserved by 5L) and modules as skill packages, promoted into the Toolbox;
  - embeddings and optional external memory backends;
  - the librarian and its staleness jobs;
  - the experience store; procedural memory; sprint reflection;
  - lab maintainership on kill.
- **R:** 024 (labs), 210, 213, 222, 273–275.

### 2.19 8 Headless server — to write
- **Scope:**
  - `brahma serve` on Linux with Linux backends;
  - an HTTPS + WebSocket API, with the app as a client;
  - paired tokens, Tailscale by default, a version handshake;
  - XDG paths (Plan 1 follow-up);
  - phone alerts reuse 5L 7b.
- The plan re-runs the R-011 checklist (remote login, distribution).
- **R:** 011 (gate), 280–282.

### 2.20 10 Steward — to write
- **Scope:**
  - the weekly report;
  - tuning proposals as Inbox asks;
  - engine changes as branches for the owner to merge;
  - an immutable evaluator, held-out scenarios, an auditor and a lineage archive;
  - a "What changed" view.
- **R:** 276–279.

## 3. Owner decisions of 18:16, where they landed

| Item | Home | Where specified |
|---|---|---|
| Global kill switch (R-238) | **5L Task 7c** | 5L plan (added in this review) |
| Resources drag-and-drop (R-205) | **ML** (lean) | §2.6 above; ML plan to write |
| Start from an existing repo (R-067) | **L** | `planL-4a-notes.md` L1 (the L planner is adding it) |
| Non-software deliverable previews (R-285) | **4a Task 6** | `planL-4a-notes.md` A6, A7 |
| Phone alerts (R-161) | **5L Task 7b**: ntfy or Pushover, engine-sent, counts-only by default | 5L plan (added in this review) |
| Ops plan | **after the dogfood week** (#10) | §2.10 |
| Memory-lite | **lean**: pull-only search plus recording, handbook, resources; push and reflection → **ML-2** after dogfood | §2.6, §2.13 |
| Unadopted review recommendations | deferred to the dogfood exit decisions | §2.9 |

## 4. Contradictions found and resolved in this review

| # | Contradiction | Resolution | Authority |
|---|---|---|---|
| X-1 | `CheckPaths` defined by both 3a (amendment, `wt-check/`) and 5L Task 2 (`checkruns/`, "moves from the data home") | 3a owns it; 5L consumes it and only write-denies. 5L edited | latest owner-approved 3a amendment |
| X-2 | Artifact preview in L (v2 §4.9, C-32) vs in 4a (L plan, owner 18:16 "non-software previews → 4a") | 4a, with an ARTIFACT tab before any preview runs (R-192); traceability updated | owner 18:16 (latest) |
| X-3 | 4b's own `opening` table vs 3a's `orgVacancy` (v2 C-12) | 4b re-based on `orgVacancy`; adds only owner add/remove plus `note`/`removedAt` | v2 C-12 |
| X-4 | 3a `TurnKind {work, review, notice}` (built) vs Task 9's second `TurnKind` vs v2's four kinds | one enum `{work, review, audit, notice}` | v2 §4.3.1 (patch note 1) |
| X-5 | 5L item-turn writes excluded the agent-written progress file | progress file and own notes added to the item-turn writable set | v2 §4.6.10 / 3a T10 |
| X-6 | 5L's "branch moved" equality check would refuse every submit after an in-turn commit | ancestor (fast-forward) check | correctness ([call]) |
| X-7 | 3a's orphan-worktree sweep vs L's and 4a's engine checkouts under `.brahma/wt/.*` | the sweep skips dot names | patch note 3 |
| X-8 | `VACUUM`/`VACUUM INTO` can renumber TEXT-PK rowids behind `messageFts` (Plan 1 follow-up) vs 5L restore and export | FTS rebuild and integrity-check after restore and export; cursors re-seed | correctness ([call]); 5L edited |
| X-9 | 5L digest lacked v2's "awaiting review", "untouched 7 days" and "team gone quiet" | added to 5L Task 8 | v2 §4.7.6 |
| X-10 | L migration anchor `"v5-transcripts"` vs 5L's last `"v5-targets"` | after `"v5-targets"` | notes L2 |
| X-11 | The merge-safety features of 3a T9b lived in the tick step that 4a replaces | moved into `finishMerge` and `MergeSafety.afterLanding`; one `approveForMerge` hook | patch notes 7, 8 |
| X-12 | v2 §5 "Not in the order" and §7 Q1–Q3 | answered by the owner at 18:16; see §3 | owner 18:16 |
| X-13 | Taint gate per tool vs L's "templates allowed when tainted" test | the L planner picks handler-level enforcement (note L4) | 5L rule (v2 §4.8.4) |

Checked and found consistent, with nothing to fix:
- Max 5x caps (1/3/8) and `planTier` everywhere (no stale 20x text in 5L, L, 4a or 4b);
- one Inbox (5L grants and digest live under Inbox; L deploy and human tasks are ask kinds; no separate approvals surface);
- no plan builds anything from 3b (4b uses only the provider hook);
- text-first marketing (M scope); engine-held secrets;
- the role card on every turn (built, Task 4);
- the env allowlist (built: `ChildEnvironment`);
- `requireOwnerShell` on every owner write built so far.

## 5. Carry-over follow-ups (from Plans 1 and 2), with owners

- FTS rowid stability → 5L Task 12 (done in the plan).
- Sidebar arrow-key navigation and ⌘F search focus, lost in the P2 restyle → 3a Task 16a, which already modifies `Sidebar.swift`/`TopBar.swift`. Add `onKeyPress` stepping and a ⌘F shortcut if cheap; otherwise this goes to the dogfood triage.
- `TerminalText.sanitize` misses bidi controls → 4b `MapText.clean` covers the map; the app-wide fix goes to the dogfood triage.
- `OrchestratorLock` without `O_CLOEXEC`; Linux XDG data home → Plan 8.
- The remaining Plan 1 and Plan 2 minors stay in `2026-10-20-plan1-followups.md` and the Plan 2 driver report. A plan picks one up only when it touches that area.

## 6. Open owner questions

None. Every placement above follows an owner decision or a recorded call.


## Addendum 2026-10-21 23:17 (owner-approved)
- **Agent work modes** (`docs/superpowers/specs/2026-10-21-agent-modes-design.md`): Quick/Standard/Deep/Plan-first in 3a (Task 14c + patch notes W1–W12); Ultra + sub-agent gate in 5-lite (Task 14u + F1–F11). Plan tier max5x; defaults accepted.
- **Brahma Extensions** (`docs/superpowers/specs/2026-10-21-extensions-design.md`): split — **X-core** folded into 5-lite (skill-only extensions, importers, `ext new/lint/try`, `propose_extension`, Inbox card); **X-connectors** (MCP gateway, sandboxed connectors, per-tool routes, sign-in asks) as a new plan placed **after the dogfood week and before Plan M**.
- **Collaboration & universal preview** (`docs/superpowers/specs/2026-10-21-collab-preview-design.md`): **Collab-MVP (#7b, 7 tasks C1–C7)** after 4a and before 4b so the dogfood week uses it (migrations `vC-refs, vC-threads, vC-show` after `v4a-demos`); **Collab-2 (#13b)** after dogfood. Patch notes: 5L-1..4 (sandbox readable-by-enumeration privacy fix — essential), L Tasks 10–11 (namespaced tab ids, viewport web preview with AGENT-BUILT frame, embeddable turn stream), 4a Tasks 8–9 (FileBody, out-of-process rendering caps), Memory-lite ML-1..7 (vault-stored resources, per-reader memory/KB access) — build these right the first time.
