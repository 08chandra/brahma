# Plan 3b — Brahma Performance & People Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The engine measures every agent and team from 3a's records (an efficiency meter with many measures and no single score) and snapshots the meter at every sprint close. It also runs a trust ladder (T0–T3) whose levels change scheduling, models, budgets, item eligibility, review and pairing. On top of that it adds cosmetic perks, a Performance analyst and an HR partner that work through sprint-close ceremonies, an ideas pipeline with a C-suite Idea review, and driver/navigator pairing. Four items moved in from the research proposal also land here: smart-friend consults, interface contracts, a sprint judge and staffing tools with channel post limits. All of it is usable from the `brahma` CLI and the Mac app.

**Architecture:** As in 3a, everything lives in `BrahmaCore` as SQLite tables and Store methods that enforce their own rules in one write transaction. Tools, the CLI and the app are thin callers. Facts are collected in three ways:
- a built-in `WorkItemObserver` (`MeterObserver`) writes one `itemOutcome` per completed item;
- small hooks in 3a's `claimLease`, `endTurn` and item writes record claims, incidents, turn progress and tier provenance;
- a SQLite trigger logs every status change.

`Meter.compute` is a pure function over those facts. At sprint close, `Store.closeSprint` runs `PeopleCycle` in the same transaction: snapshots, then trust, then perks, then HR rules. It then enqueues **queued turns**. This 3b mechanism, modelled on 3a's review turns, gives an agent a fresh-session turn with a digest prompt and a kind-specific tool set. It runs the Performance scorecard, the sprint judge, HR reviews, the Idea review, smart-friend consults and navigator turns. Owner gating reuses 3a decisions, extended with four kinds plus an explicit approver, a pre-approval, an owner-required flag and a JSON payload.

**Tech Stack:** Swift 6.2 toolchain (manifest stays `swift-tools-version: 6.0`), SwiftPM, GRDB.swift 7.x (SQLite FTS5 already used by Plan 1), swift-argument-parser 1.5+, Swift Testing, SwiftUI/Observation (app targets only), Claude Code CLI 2.1.304.

**Spec:** `docs/superpowers/specs/2026-10-20-agent-company-design.md` §6.19 (meter, performance analysis, anti-gaming, trust ladder, digital rewards, HR), §6.20 (ideas pipeline), §6.16 principles, §6.3 (managers hire and kill within caps), plus `docs/superpowers/specs/2026-10-20-improvements-from-research.md`: D2 15b and 15c (pairing, competing hypotheses), D16 (post rate limits), D15 (smart friend), B7 (interface contracts), D14 (planner/worker/judge) and D12 (spawn quotas). Builds on Plan 3a (`/Users/chandra/.claude/jobs/6d89b87c/tmp/2026-10-20-plan3a-work-system.md`), which must be merged first, and on Plan 2 (BrahmaTheme, Task 5b).

**Decisions this plan pins (with reasons):**
- **Agents never see meter numbers.** Agents see only their trust level and its title, PIP targets (thresholds, which the spec requires to be measurable) and actionable feedback notes. The perf digest, scorecards, reviews and agent files live under the data home (`<companyDir>/perf/`, `<companyDir>/agents/`), never in the workspace. The only agents who receive numbers are the ones whose ceremony needs them: the Performance analyst for its scorecard and HR for its review. `brahma perf` and `brahma hr` refuse to run when `BRAHMA_AGENT_ID` is set.
- **HR, Performance and Visionary are pack roles, not generated seats.** `OrgGenerator` is unchanged, so 3a's ratio tables stay valid. Each function resolves to the first non-killed agent covering role `hr` or `perf`, falling back to the CEO-covering executive. `brahma hr setup` (and the app) hires the dedicated agents. The software pack becomes **v2**.
- **Built-in observers always run.** `Store` always installs `MeterObserver`, `AwardObserver` and `IdeaObserver`, before any injected observer. Completions recorded in a `brahma mcp` process (where `review` runs) are therefore measured too.
- **Status time comes from a trigger.** `workItemStatusLog` is filled by an `AFTER UPDATE OF status` trigger that records `NEW.updatedAt`. Every write path is covered without touching each one, and tests stay deterministic because every 3a status write sets `updatedAt = now`. Task 1 pins this with a test.
- **The engine never demotes below T1.** T0 (probation) is reached only through an HR PIP or an owner override, so ladder demotion and HR discipline never double-count. Promotion needs 2 consecutive strong evaluated sprints (T2→T3 needs 3). Sprints with too few items are skipped, not counted.
- **Light review means auto-Done on the engine pass.** This applies to a T2 owner on tier S, or a T3 owner on S or M, with no review flags. It also requires that someone other than the owner authored the item, and that a manager, an executive, the owner or system set both its tier and its check. A contract touch or a navigator blocker adds a flag, so those items always get a full review. The reviewer is notified and can ask a manager to reopen.
- **Smart-friend consults and ceremonies are queued turns of the agent itself.** They have a fresh session and a model override, and never change Plan 1's argv apart from `--model`. A consult answer lands as a file plus a system DM.

## Global Constraints

Copied from Plan 3a and still binding:
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The manifest stays `swift-tools-version: 6.0` and `.macOS(.v14)`.
- `BrahmaCore` stays Linux-portable: no AppKit, SwiftUI, Observation, CryptoKit or `Bundle.module`. `Process`, `FileManager` and `/bin/sh` are fine. Hashes use the FNV-1a 64 in `StableHash` (3a Task 10).
- Turn isolation is unchanged. `ClaudeCommand.arguments(for:)` stays exactly as Plan 1 (the `CommandTests` argv assertions must keep passing). Only the `--model` value changes, through `ModelPolicy`. The prompt goes on stdin. `--append-system-prompt` is passed only when a session starts: the first turn, a fresh review session, or a reset session.
- Agent states stay exactly `ready, running, blocked, sleeping, killed`. Item statuses are exactly `backlog, ready, inProgress, inReview, done, blocked`, displayed as "Backlog", "Ready", "In progress", "In review", "Done", "Blocked".
- **Engine is the referee.** No MCP tool, CLI command or app action can set an item to `inReview` or `done`, or write a `verificationRun`. Agents may change only status fields (`status` within the allowed transitions, `notes`, `linkedBranch`) on items they are assigned to or lease. The assignee may never edit spec fields (title, description, acceptance criteria, check, type, tier, priority, points, parent, team, reviewer).
- **Owner approval exists only through `Store.ownerDecide`.** It is called only by `brahma approve` and the app, and never by `CompanyTools`. No message text from any sender changes a decision.
- Money and secret requests are Plan 5 and never auto-approved. Auto mode in this plan affects only the four gate kinds.
  (3b: the gate kinds become eight with `idea`, `termination`, `staffing`, `systemFix`; a decision with `ownerRequired` never auto-approves.)
- Agent-controlled text printed by the CLI goes through `safe()`. In the app it uses `Text(verbatim:)`. In prompts, single-line fields are newline-flattened like `InboxDigest`, and multi-line fields are rendered as a block where every line is prefixed `    | `.
- New stored properties on existing records (`Company`, `Agent`, `Turn`, `TurnResult`) get default values, so existing memberwise inits and Plan 2 code keep compiling.
- The workspace profile is not a sandbox (3a's paragraph and README text stand). Every turn and every check runs with `BRAHMA_AGENT_ID=<agent id>` and without `BRAHMA_DEV`. `brahma mcp` refuses an `--agent` that differs from `BRAHMA_AGENT_ID`. Owner-write CLI commands refuse to run when `BRAHMA_AGENT_ID` is set.
- **Cross-company ids.** Every Store method that takes an item, decision, sprint, lease or agent id from an agent-facing path (tools, and the `by:` and `agentId:` parameters) verifies that the object belongs to the acting agent's company, else `WorkError.forbidden("not in your company")`, and treats it as not found in the response text.
- Live tests run only with `BRAHMA_LIVE=1` and use `haiku`.
- Tests use Swift Testing, with one `@Suite struct <FileName>` per new test file (`@MainActor` for app models).
- Every commit message ends with:
  `Co-Authored-By: Claude <your model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`
- **UI uses the BrahmaTheme design system from Plan 2** (brief: `/Users/chandra/.claude/jobs/6d89b87c/tmp/brahma-visual-design.md`, the "ops console"): panels with uppercase header strips, dense zebra tables with an accent left bar on the selected row, status chips, monospace for item keys, decision refs, counts, timestamps and check output, and small bordered buttons with an accent primary. No ad-hoc colors, fonts or radii.

3b additions:
- Migrations append, in this order, after 3a's `"v3-budgets"`: `"v3b-meter-facts"`, `"v3b-meter-snapshots"`, `"v3b-trust"`, `"v3b-queued-turns"`, `"v3b-people-cycle"`, `"v3b-awards"`, `"v3b-hr"`, `"v3b-ideas"`, `"v3b-pairing"`, `"v3b-staffing-contracts"`. Never edit an earlier migration.
- **Cross-company tests.** Each new tool group's tests include one cross-company case:
  - Task 4 `QueuedTurnTests.crossCompanyConsultRefused`
  - Task 5 `ScorecardTests.crossCompanyFeedbackRefused`
  - Task 7 `HRTests.crossCompanyActionRefused`
  - Task 8 `IdeaTests.crossCompanyTriageRefused`
  - Task 9 `PairingTests.crossCompanyNavigatorRefused`
  - Task 10 `StaffingTests.crossCompanyKillRefused`
- **No perk, meter number or band ever appears in a prompt, role card, digest, tool result or notes file that an agent reads.** Trust level and title may. PIP targets may.
- Trust is never self-grantable. Only `Store.evaluateTrust` (engine), HR's PIP path (Task 7) and `Store.setTrust` (owner: CLI and app only) write `agent.trustLevel` on an existing agent; hiring (`hire(… trust:)`, owner-chosen T0/T1, replacements at T1) and the owner's reinstate set it only at creation.
- New `ActivityKind.people` (Task 3) is used for trust, perk, HR and idea events. Where a Plan 2/3a switch stops compiling, map it to symbol `person.2`.
- Color tokens for 3b chips:
  - Trust badges: T0 `warning`, T1 `text1`, T2 `success`, T3 `accent`.
  - Bands: strong `success`, meets `text1`, below `danger`, insufficient `text2`.
  - Gaming flags and PIPs: `warning`.
- Out of scope: map badges and Hive/Village perks (Plan 4); Steward consumption of scorecards (Plan 10); knowledge-base search (Plan 9, a `KnowledgeSearching` hook only); lab prototypes (Plan 9, ideas use spikes); sandbox enforcement of read-only navigators (Plan 5).

**Pinned numbers** (each is a `static let` on the owning type):

| Constant | Value | Owner |
|---|---|---|
| Tier weights | S 1 · M 3 · L 8 | `MeterWeights.tier` |
| Rolling window / type-median window / min median samples | 14 days / 90 days / 3 | `Meter` |
| Band min sample | 3 items done in the window | `PerformanceBar.minItems` |
| Below bar (any one) | first-pass < 0.5 · escaped ≥ 2 · cost× > 2.0 · watchdog escalations ≥ 2 · failed turns > 30 % (≥ 5 turns) · overruns ≥ 2 · 0 done in ≥ 10 turns with a claim | `PerformanceBar` |
| Strong bar (all) | first-pass ≥ 0.8 · cost× ≤ 1.0 (or nil) · 0 escaped, escalations, overruns · weighted throughput ≥ team median · no gaming flags | `PerformanceBar` |
| Gaming flags | self-authored > 50 % of ≥ 4 done · cherry-pick > 60 % of ≥ 5 claims · ≥ 3 splits | `Meter` |
| Promotion streak | T0→T1 2 sprints ≥ meets · T1→T2 2 strong · T2→T3 3 strong; demotion 2 below (floor T1) | `TrustPolicy` |
| Trust budget multiplier / max tier | T0 1.0 / S · T1 1.0 / L · T2 1.5 / L · T3 2.0 / L | `TrustLevel` |
| Light review | T2: tier S · T3: tiers S, M (no flags) | `ReviewRules` |
| Meal | tier L done within 75 % of the trust-scaled turns and tokens | `Awards.mealShare` |
| Streak milestones | 3, 5, 10, then every 10 | `Awards.streakMilestones` |
| Kudos note max | 280 chars | `Awards.kudosMax` |
| Queued-turn attempts | 3 | `QueuedTurns.maxAttempts` |
| Smart friend | 2 per item · 6 per agent per rolling 24 h · question ≤ 2000 chars · ≤ 10 paths · answer file ≤ 20 000 chars | `SmartFriend` |
| Channel posts per agent | 12 per rolling 60 min (DMs, owner, system exempt) | `ChannelRateLimit.postsPerHour` |
| Ideas | 3 open per agent · top 5 per review · owner-required effort ≥ 2.0 sprints · prototype 300 000 tokens · confidence cap 0.5 without evidence · review min interval 24 h | `IdeaPolicy` |
| Visionary research budget | 500 000 counted tokens per period (period = since the company's last sprint close) | `IdeaPolicy.researchTokens` |
| Staffing | company ≤ 500 non-killed · team ≤ 8 non-killed · 3 hire requests (any status but rejected) per requester per rolling 24 h | `StaffingPolicy` |
| HR ceremony batch / digest cap | 25 subjects / 60 000 chars | `HRHandler` |
| Fresh restarts per judge verdict | 10 | `SprintJudge.maxRestarts` |
| People refresh in app | 10 s | `AppModel.peopleRefreshInterval` |

## Review Focus

1. **An agent learning its own raw numbers** through `list_agents`, `show_work_item`, the orientation digest, notes files, scorecard or review files, perks, or `brahma perf` from its own shell. Only trust level and title, PIP targets and actionable feedback reach agents. → Task 2 `PerfCLITests.perfRefusesInsideAgentTurn`; Task 3 `TrustTests.orientationShowsLevelNotNumbers`; Task 5 `ScorecardTests.feedbackRejectsScores`, `ScorecardTests.scorecardFilesOutsideWorkspace`; Task 6 `AwardTests.awardsNeverInPrompts`; Task 3 `TrustTests.promotionAfterTwoStrongSprintsNotifiesManager` (fixed DM text); Task 7 `HRTests.guardrailTargets` (HR notes are guarded).
2. **Tiny or empty samples**: a new company, a first sprint, an agent with zero items, or item types with no median. Rates are nil (never NaN or a crash), the band is `insufficient`, and there is no trust move and no HR recommendation. → Task 2 `MeterTests.emptyWindowHasNoRates`; Task 3 `TrustTests.insufficientSampleNeverMoves`; Task 7 `HRTests.noActionWithoutEvidence`.
3. **HR acting where it may not**: on itself, the C-suite, its own manager chain, another company or a killed agent. Also a termination without the manager's sign-off outside Auto, a discipline when the root cause is the system, and the owner reversing an executed termination. → Task 7 `HRTests.guardrailTargets`, `HRTests.systemRootCauseBlocksDiscipline`, `HRTests.terminationNeedsManagerThenOwner`, `HRTests.reverseExecutedTerminationReinstates`. Staffing that bypasses the owner (kill or reassign in Auto mode, HR killing agents, hiring privileged roles) is covered by Task 10 `StaffingTests.killAndReassignAlwaysNeedOwner`, `StaffingTests.hrHasNoKillOrReassign`, `StaffingTests.hireAllowListAndManagerScope` and Task 5 `ScorecardTests.decideOnlyByAssignedApprover`.
4. **A queued turn that is interrupted, crashes the engine, never calls its tool, or whose agent is killed.** It is re-queued, makes at most 3 attempts, and then the owner is told. Sprint close never waits on it. → Task 4 `QueuedTurnTests.interruptedTurnRequeuesWithoutAttempt`, `QueuedTurnTests.failsAfterThreeAttemptsAndTellsOwner`, `QueuedTurnTests.runningRecoveredOnStart`, `QueuedTurnTests.killedAgentFailsItsQueue`.
5. **Gaming the meter**: a worker sets tier L on its own item, splits its work into many S items, cherry-picks S items while L items are ready, self-authors an S item with a trivial check to win light review and perks, files a sabotage `defect_of` against a peer, triages or decides its own idea, spams ideas or duplicates, or floods channels. Such items count as S (or earn nothing when the check is self-set), the behavior is flagged, the band is capped at `meets`, and the quota or rate limit refuses. → Task 1 `MeterFactsTests.workerSetTierIsNotTrusted`; Task 2 `MeterTests.gamingFlags`; Task 3 `TrustTests.gamingFlagsCapBand`; Task 8 `IdeaTests.openIdeaQuota`; Task 10 `StaffingTests.channelPostRateLimit`; Task 3 `TrustTests.selfAuthoredItemNotLightReviewed`; Task 1 `MeterFactsTests.defectOfAuthority`; Task 8 `IdeaTests.filerNeverDecidesOwnIdea`.

---

## File Structure

```
Sources/BrahmaCore/
  Perf/MeterFacts.swift          ItemOutcome, MeterIncidentKind, MeterIncident, ClaimRecord, StatusLogEntry
  Perf/MeterObserver.swift       MeterObserver (built-in WorkItemObserver)
  Store/Store+MeterFacts.swift   recordOutcome/recordClaim/recordIncident, statusLog, blockedSeconds
  Perf/Meter.swift               MeterWeights, MeterWindow, MeterFacts, MeterReading, Meter.compute
  Store/Store+Meter.swift        meterReading(s), MeterSnapshot, writeSnapshots, snapshots queries
  Perf/Trust.swift               TrustLevel, PerformanceBand, PerformanceBar, TrustPolicy, TrustChange, ReviewRules
  Store/Store+Trust.swift        evaluateTrust, setTrust, trustHistory
  Turns/QueuedTurns.swift        QueuedTurnKind, QueuedTurnStatus, QueuedTurn, QueuedTurnHandler, QueuedTurns
  Store/Store+QueuedTurns.swift  enqueue, next, begin, complete, settle, recover
  Perf/SmartFriend.swift         SmartFriend, ConsultDigest, ConsultHandler
  Perf/PeopleCycle.swift         PeopleRoles, PeopleFunction, PeopleCycle (sprint-close steps)
  Perf/Scorecard.swift           Scorecard, ScorecardDigest, ScorecardHandler, FeedbackGuard, SystemFix
  Perf/SprintJudge.swift         JudgeVerdict, JudgeDigest, JudgeHandler
  Perf/Awards.swift              AwardKind, Award, PerkSummary, Awards, AwardObserver
  Store/Store+Awards.swift
  People/HR.swift                HR (cycle steps), HRActionKind/Status, HRAction, PerformanceReview, ManagerNote, RootCause, HRPolicy, RootCauseHints, HRDigest, HRHandler
  Store/Store+HR.swift           reviews, actions, terminate, reinstate, reverse, agent files
  Ideas/Idea.swift               Ideas (cycle step), IdeaStatus, IdeaOutcome, IdeaDraft, Idea, IdeaPolicy, IdeaDigest, IdeaReviewHandler, IdeaObserver, KnowledgeSearching
  Store/Store+Ideas.swift        proposeIdea, similarItems (FTS5), triageIdea, decideIdea, research budget
  Work/Pairing.swift             PairingMode, PairingPolicy, NavigatorDigest, NavigateHandler, HypothesesTemplate
  Store/Store+Pairing.swift
  People/Staffing.swift          StaffingAction, StaffingPolicy
  Store/Store+Staffing.swift
  Work/Contracts.swift           InterfaceContract, PathGlob, ContractCheck
  Store/Store+Contracts.swift
  Messaging/RateLimit.swift      ChannelRateLimit
  Dev/DevScenario.swift          complete(item) through real engine paths (dev CLI, seed, live test)
  MCP/PeopleTools.swift          ask_smart_friend, publish_scorecard, judge_sprint, manager_feedback, HR tools, staffing tools
  MCP/IdeaTools.swift            propose_idea, triage_idea, decide_idea
  MCP/PairingTools.swift         navigator_note, start_hypotheses
  MCP/ContractTools.swift        register_contract, list_contracts
  (modified) Org/IndustryPack.swift Org/SoftwarePack.swift Org/ModelPolicy.swift Model/WorkItem.swift Model/Decision.swift
             Model/Agent.swift Model/Turn.swift Model/Company.swift Work/WorkPolicy.swift Work/Budget.swift Work/Review.swift
             Store/Store.swift Store/Store+WorkItems.swift Store/Store+Leases.swift Store/Store+Verification.swift
             Store/Store+Review.swift Store/Store+Decisions.swift Store/Store+Sprints.swift Store/Migrations.swift
             Scheduler/Scheduler.swift Turns/TurnDigest.swift Turns/ClaudeCommand.swift Messaging/MessageRouter.swift
             MCP/CompanyTools.swift MCP/WorkTools.swift MCP/LeadTools.swift Orchestrator.swift Lifecycle/AgentLifecycle.swift
Sources/brahma/
  PerfCommands.swift  HRCommands.swift  IdeaCommands.swift  KudosCommands.swift
  (modified) DevCommands.swift AgentCommands.swift ItemCommands.swift CLISupport.swift Brahma.swift
Sources/BrahmaAppModel/People/
  PeopleSnapshot.swift  PeoplePresentation.swift  IdeaForm.swift  AppModel+People.swift
  (modified) Presentation/Sidebar.swift Presentation/ActivityText.swift Agents/AgentDetail.swift Forms/HireForm.swift LaunchOptions.swift AppModel.swift
Sources/BrahmaApp/Views/
  PerformanceView.swift  BreakRoomView.swift  HRView.swift  IdeasBoardView.swift  IdeaEditorSheet.swift  TrustBadge.swift
  (modified) Sidebar.swift DetailView.swift AgentsView.swift MainWindow.swift ActivityFeedView.swift
Tests/BrahmaCoreTests/
  PeopleWorld.swift MeterFactsTests.swift MeterTests.swift PerfCLITests.swift TrustTests.swift QueuedTurnTests.swift
  ScorecardTests.swift JudgeTests.swift AwardTests.swift HRTests.swift IdeaTests.swift PairingTests.swift
  StaffingTests.swift ContractTests.swift (LiveSmokeTests: + one test; PackTests, MCPTests, SchedulerTests: edits)
Tests/BrahmaAppModelTests/
  PeoplePresentationTests.swift PeopleModelTests.swift
scripts/seed-demo.sh (extend)  README.md (extend)
```

---

### Task 1: Software pack v2 and meter fact collection

**Files:**
- Create: `Sources/BrahmaCore/Perf/MeterFacts.swift`, `Perf/MeterObserver.swift`, `Store/Store+MeterFacts.swift`
- Modify: `Org/IndustryPack.swift` (`CompanyToolNames` lists), `Org/SoftwarePack.swift` (v2), `Store/Migrations.swift` (`"v3b-meter-facts"`), `Store/Store.swift` (built-in observers), `Model/WorkItem.swift` (`tierSetById`, `defectOfId`; draft/patch `defectOfId`), `Model/Turn.swift` (`progressed`), `Store/Store+WorkItems.swift`, `Store/Store+Leases.swift` (claim record), `Orchestrator.swift` (`endTurn`: progressed + incidents), `MCP/WorkTools.swift` (`defect_of`), `Sources/brahma/ItemCommands.swift` (`--defect-of`); `Tests/BrahmaCoreTests/PackTests.swift`, `MCPTests.swift`
- Test: `Tests/BrahmaCoreTests/MeterFactsTests.swift`

**Interfaces:**
- Consumes: 3a `WorkItemObserver.itemCompleted(_:db:)`, `Store.init(path:catalog:observers:)`, `Store.itemUsage(itemId:)`, `VerificationRun`, `WorkItemEvent` kinds `leaseClaimed`/`changesRequested`/`budgetExceeded`, `Watchdog` verdicts in `endTurn`, `TierBudget`, `IndustryPack`, `RoleTemplate`, `RoleKind`.
- Produces:
  - Software pack **v2** (`version: 2`, 16 roles):
    - New roles `perf (Performance analyst, individual, perf, 0, sonnet×3, base+work)`, `hr (HR partner, individual, hr, 0, sonnet×3, base+work+[hire_agent])` (HR never gets `kill_agent`/`reassign_agent`; it removes agents only through `hr_action`) and `visionary (R&D visionary, individual, vis, 0, sonnet/sonnet/opus, base+work)`. Each gets a prompt of at most 1200 chars stating its §6.19/§6.20 duties.
    - Item type `idea (Idea, not container, not claimable, no check)`.
    - decisionApprovers add `idea [ceo, ceo-cpo]`, `systemFix [ceo, ceo-cpo]`, `staffing [ceo, ceo-cpo]` and `termination [ceo, ceo-cpo]`.
    - Executives' tools add `staffing`; `cto` and `cto-architect` add `architect`; `architect` adds `architect`; `manager` and `director` add `staffing`.
    - No new ratios: `OrgGenerator` output is unchanged.
  - `CompanyToolNames`:
    - `work` += `propose_idea, ask_smart_friend, list_contracts`
    - `lead` += `manager_feedback, triage_idea, start_hypotheses, decide`. **`decide` is authorized only by `caller == decision.internalApproverId`** (3a's `internalDecide` check `"only @<h> can decide D-<n>"`); 3a's "executives only" wording for the `decide` tool is replaced by this rule, so a manager can sign off a termination routed to it and nothing else. Test: Task 5 `ScorecardTests.decideOnlyByAssignedApprover`.
    - new `staffing = [hire_agent, kill_agent, reassign_agent]`
    - new `architect = [register_contract]`
    - new `ceremony = [publish_scorecard, judge_sprint, write_performance_review, hr_action, propose_system_fix, decide_idea, navigator_note]` (exposed only in queued turns, like `review`)
    - new `trustLead = [plan_sprint]` (granted to T3 individuals, Task 3)
    - `all` stays the union of every list.
  - Migration `"v3b-meter-facts"`:
    - `workItem` + `tierSetById TEXT`, `checkSetById TEXT`, `defectOfId TEXT REFERENCES workItem(id) ON DELETE SET NULL`.
    - `turn` + `progressed BOOLEAN` (nullable).
    - `workItemStatusLog(id INTEGER PK AUTOINCREMENT, itemId TEXT NOT NULL REFERENCES workItem(id) ON DELETE CASCADE, status TEXT NOT NULL, at DATETIME NOT NULL)`, with index `(itemId, id)`. Triggers `workItemStatusLogInsert AFTER INSERT ON workItem` and `workItemStatusLogUpdate AFTER UPDATE OF status ON workItem WHEN OLD.status IS NOT NEW.status`, each inserting `(NEW.id, NEW.status, NEW.updatedAt)`. The migration backfills one row per existing item from its `status`/`updatedAt`.
    - `itemOutcome(itemId TEXT PK REFERENCES workItem ON DELETE CASCADE, companyId TEXT NOT NULL, agentId TEXT, authorId TEXT NOT NULL, type TEXT NOT NULL, tier TEXT NOT NULL, tierTrusted BOOLEAN NOT NULL, checkTrusted BOOLEAN NOT NULL, sprintId TEXT, reviewRounds INT, checkRuns INT, firstPass BOOLEAN, changesRequested INT, turns INT, tokens INT, overBudget BOOLEAN, claimedAt DATETIME, doneAt DATETIME NOT NULL, cycleSeconds REAL, blockedSeconds REAL)`, with index `(companyId, agentId, doneAt)`.
    - `meterIncident(id INTEGER PK AUTOINCREMENT, companyId, agentId TEXT REFERENCES agent ON DELETE CASCADE, kind TEXT, itemId TEXT, turnId TEXT, at DATETIME)`.
    - `claimRecord(id INTEGER PK AUTOINCREMENT, companyId, agentId, itemId, tier TEXT, largerReadyCount INT, at DATETIME)`.
  - `WorkItem` + `var tierSetById: String? = nil`, `var defectOfId: String? = nil`; `WorkItemDraft` + `var defectOfId: String? = nil`; `WorkItemPatch` + `var defectOfId: String??`. `defectOfId` is a spec field (`WorkField.defectOf`, `isSpec`). It is allowed only on type `bug` and must name a same-company, non-container item (`WorkError.invalid("defect_of must name a task, bug or spike")`). `createWorkItem` sets `tierSetById = actor id` (`"owner"`/`"system"` for those senders). `updateWorkItem` sets it to the actor when `tier` changes. `checkSetById` is maintained the same way for `checkSpec` (set on create when a check is given, and on every check change).
  - `defect_of` authority (create or update): only manager or executive kinds, agents whose role is in `rolesCovering("qa")`, the referenced item's reviewer, the owner or system may set it, and never the referenced item's owner: `WorkError.forbidden("only QA, a manager, an executive or the item's reviewer can link a defect")`.
  - `enum ProvenanceRules { static func trusted(setterId: String?, db: Database) throws -> Bool }` is true iff the setter is nil, `"owner"`, `"system"`, or an agent of role kind manager or executive. It is the single rule used for `tierTrusted`, `checkTrusted` (this task) and light review (Task 3).
  - `Turn` + `var progressed: Bool? = nil`, set in `endTurn` for succeeded `work` turns from the watchdog's progress computation. Other turns keep nil.
  - `enum MeterIncidentKind: String, Codable, Sendable { case nudge, escalate, budgetOverrun }`; `struct MeterIncident: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord` (one property per column). `endTurn` inserts one row per watchdog `nudge` or `escalate` verdict and per `budgetExceeded` it raises (agent = the turn's agent).
  - `struct ClaimRecord` (columns). `claimLease` inserts it inside its transaction. `largerReadyCount` = items with `status == ready`, a claimable type, no live lease, `ownerId` nil or the claimer, the same `team` as the claimed item (both nil counts as same), and a tier weight above the claimed tier's weight.
  - `struct ItemOutcome: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord` (one property per column). `struct StatusLogEntry` (columns).
  - `struct MeterObserver: WorkItemObserver` writes an `ItemOutcome` for claimable items only (containers and ideas are skipped):
    - `agentId` is the owner at completion.
    - `tierTrusted = ProvenanceRules.trusted(tierSetById)`; `checkTrusted = item.authorId != ownerId && ProvenanceRules.trusted(checkSetById)` (a no-check type uses only the author rule).
    - `reviewRounds = item.reviewRound`; `checkRuns` = count of verification runs.
    - `firstPass`: the earliest run passed. For a no-check type: `reviewRound == 1`.
    - `changesRequested` = count of `changesRequested` events; `turns` and `tokens` come from `itemUsage`; `overBudget` = any `budgetExceeded` event.
    - `claimedAt` = the first `leaseClaimed` event; `cycleSeconds = doneAt − (claimedAt ?? createdAt)`; `blockedSeconds = Store.blockedSeconds(db:itemId:until:)`, summed from the status log intervals whose status is `blocked`.
  - `extension Store { static let builtinObservers: [any WorkItemObserver] = [MeterObserver()] }` (Task 6 appends `AwardObserver()`, Task 8 `IdeaObserver()`). `Store.init` runs `builtinObservers + observers`, built-ins first.
  - **Reentrancy rule (GRDB writes are not reentrant):** every observer, `PeopleCycle` step, decision effect and queued-turn hook runs inside an open write transaction and calls only `db:` variants. This task adds `Store.itemUsage(db:itemId:)` (the public one wraps it). Tasks 2–3 add `meterReading(db:…)`, `meterReadings(db:…)`, `snapshots(db:…)`, `agentSnapshots(db:…)` and `trustHistory(db:…)` the same way.
  - Internal `Store.recordOutcome(db:_:)` (also used by `PeopleWorld` in tests).
  - Tool `create_work_item` and `update_work_item` gain `defect_of: KEY`. CLI `items add|edit --defect-of KEY`.

- [ ] **Step 1: Write failing tests.**
  - Update `PackTests.builtinSoftwarePackIsValid` to `version == 2` and `roles.count == 16`. Update `filePackWithHigherVersionOverrides` to write a v3 file and to check that a v2 file is ignored.
  - Update `MCPTests.executiveSeesEveryTool`: its subject becomes the `cto` agent (the only executive template that also has `architect`), and it expects `Set(CompanyToolNames.all).subtracting(CompanyToolNames.review + CompanyToolNames.ceremony)`.

  Add `PackTests.v2OrgUnchanged`: `OrgGenerator.generate(count: 20)` role counts equal 3a's table row for 20.

  `MeterFactsTests` (World + FakeCheckRunner, 10-agent org):
```swift
@Test func outcomeRecordedOnApprove() async throws {
  /* mgr-1 creates task tier M check "true"; eng-1 claims, submits; check fails once (exit 1), resubmit, pass; mgr-1 requests changes once, then approves
     → itemOutcome: agentId eng-1, tier "m", tierTrusted true, checkRuns 2, firstPass false, changesRequested 1, reviewRounds 3, turns/tokens == itemUsage */ }
@Test func workerSetTierIsNotTrusted() throws { /* eng-1 authors a task with tier L → tierSetById eng-1; outcome.tierTrusted false; mgr-1 edits tier to L → tierSetById mgr-1 → trusted */ }
@Test func statusLogFromTrigger() throws { /* create (t0) → ready (t1) → claim (t2) → blocked (t3) → inProgress (t4) via store calls with explicit now → log statuses [backlog, ready, inProgress, blocked, inProgress] with at == those nows; blockedSeconds == t4 - t3 */ }
@Test func everyStatusWriteSetsUpdatedAt() async throws { /* for claimLease, releaseLease, submitForReview, finishVerification(fail), review(approve), reapLeases, budget block in endTurn: item.updatedAt == the now passed */ }
@Test func containersAndSpikesWithoutCheck() throws { /* epic rollup → no outcome row for epic; spike approved in round 1 → firstPass true */ }
@Test func claimRecordsCherryPick() throws { /* team-1 ready: one S, one L (unassigned) → eng-1 claims S → claimRecord tier "s", largerReadyCount 1; claim L → 0 */ }
@Test func incidentsRecorded() async throws { /* reuse 3a watchdog scenario: 3 no-progress turns → 1 nudge incident; budget overrun → budgetOverrun incident; turn.progressed false on those turns, true on a handoff turn */ }
@Test func defectOfValidation() throws { /* qa-1 bug defect_of ACME-1 (task) ok; defect_of an epic → invalid; on a task → invalid; Globex key → "not in your company" */ }
@Test func defectOfAuthority() throws { /* ACME-1 owned by eng-1, reviewer mgr-1: eng-1 (owner) → forbidden exact; eng-2 (peer engineer) → forbidden; qa-1, mgr-1, owner → ok */ }
@Test func selfAuthoredCheckNotTrusted() throws { /* eng-1 authors and owns a task with check "true" → outcome.checkTrusted false; mgr-1-authored check → true */ }
@Test func builtinObserverRunsWithoutInjection() throws { /* Store.inMemory() with no observers → approve → itemOutcome exists */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "MeterFactsTests|PackTests|MCPTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the pack v2, the tool lists, the migration and trigger, the observer and the hooks. Fix any 3a status write whose `updatedAt` is not its `now` (the test names them).
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS, 3a suites included.
- [ ] **Step 5:** Commit `feat(core): software pack v2 and engine-recorded meter facts` with the trailer lines.

---

### Task 2: Meter computation, sprint snapshots and `brahma perf`

**Files:**
- Create: `Sources/BrahmaCore/Perf/Meter.swift`, `Store/Store+Meter.swift`, `Perf/PeopleCycle.swift`, `Dev/DevScenario.swift`, `Sources/brahma/PerfCommands.swift`, `Tests/BrahmaCoreTests/PeopleWorld.swift`
- Modify: `Store/Migrations.swift` (`"v3b-meter-snapshots"`), `Store/Store+Sprints.swift` (`closeSprint` calls `PeopleCycle`), `Sources/brahma/DevCommands.swift` (`dev complete`), `Sources/brahma/CLISupport.swift` (`requireOwnerReader`), `Brahma.swift`
- Test: `Tests/BrahmaCoreTests/MeterTests.swift`, `PerfCLITests.swift`

**Interfaces:**
- Consumes: Task 1 facts tables; 3a `Sprint` (`startedAt`, `closedAt`, `team`), `Store.sprints`, `Agent.team`, `Message.senderId`, `Turn.kind`.
- Produces:
  - `enum MeterWeights { static func weight(_ t: EffortTier) -> Int /* s 1, m 3, l 8 */ }`
  - `enum MeterWindow: Equatable, Sendable { case sprint(id: String), rolling(end: Date) /* 14 days */ }`
  - `struct MeterFacts: Sendable { var outcomes: [ItemOutcome]; var typeMedians: [String: Double]; var turns, failedTurns, messages, chatterMessages: Int; var incidents: [MeterIncident]; var claims: [ClaimRecord]; var splitsCreated, escapedDefects: Int; var ideasFiled = 0, ideasApproved = 0, ideasShipped = 0 }`
  - `struct MeterReading: Codable, Equatable, Sendable { var itemsDone, weightedThroughput: Int; var firstPassRate: Double?; var reworkRounds, reviewRejections, escapedDefects: Int; var costRatio: Double?; var cycleMedianSeconds: Double?; var blockedSeconds: Double; var messages, chatterMessages, turns, failedTurns, watchdogNudges, watchdogEscalations, budgetOverruns, claims, cherryPickClaims, selfAuthoredDone, splitsCreated, ideasFiled, ideasApproved, ideasShipped: Int; var gamingFlags: [String]; static let empty }`
  - `enum Meter { static let rollingWindow: TimeInterval = 14 * 86_400; static let medianWindow: TimeInterval = 90 * 86_400; static let minMedianSamples = 3; static func compute(_ f: MeterFacts, agentIds: Set<String>) -> MeterReading }`. Pure. The rules:
    - `weightedThroughput = Σ weight(tierTrusted ? tier : .s)` over outcomes with `checkTrusted`; outcomes without it add 0;
    - `firstPassRate = firstPass count / count`, both over outcomes with `checkTrusted` (nil if none); `itemsDone` counts all outcomes;
    - `reworkRounds = Σ max(0, reviewRounds − 1)`;
    - `reviewRejections = Σ changesRequested`;
    - `costRatio` = the median of `tokens / typeMedians[type]` over outcomes whose type has a median (nil if none);
    - `cycleMedianSeconds` is the median of `cycleSeconds`; `blockedSeconds` is their sum;
    - `cherryPickClaims` = claims with tier `s` and `largerReadyCount > 0`;
    - `selfAuthoredDone` = outcomes whose `authorId` is in `agentIds`.

    `gamingFlags`, in this order and exact copy:
    - `"self-authored items: <k> of <n> done"` when n ≥ 4 and k/n > 0.5;
    - `"cherry-picking: <k> of <n> claims skipped larger ready items"` when n ≥ 5 and k/n > 0.6;
    - `"splitting: <k> items split from own work"` when k ≥ 3.

    Medians of even counts are the mean of the two middle values.
  - Fact queries (`Store.meterFacts(db:companyId:agentIds:window:) throws -> MeterFacts`). For a sprint window, outcomes are those with `sprintId == id`, and time-based facts use `[sprint.startedAt, sprint.closedAt ?? now]`. For a rolling window, outcomes are those whose `doneAt` falls in `[end − 14 d, end]`. The other facts:
    - turns: `work` turns of the agents started in the window; `failedTurns` = outcome `failed`;
    - messages: messages with a `senderId` in the set, created in the window;
    - `chatterMessages`: those created inside a work turn of the sender whose `progressed == false`;
    - `splitsCreated`: claimable items authored by the agent in the window whose `parentId` is non-nil and equals the parent of another item owned by the same agent;
    - `escapedDefects`: bugs whose `defectOfId` points to an outcome of the agents, created in the window and after that outcome's `doneAt`;
    - `typeMedians`: company-wide outcomes in the 90 days before the window end, for types with ≥ 3 samples.
  - `Store.meterReading(companyId: String, agentIds: Set<String>, window: MeterWindow) throws -> MeterReading` and the batched `Store.meterReadings(companyId: String, window: MeterWindow) throws -> [String: MeterReading]`, each with a `db: Database` overload used inside transactions (keyed by agent id; one query per fact table, grouped in Swift; non-killed agents plus any agent with an outcome in the window).
  - Migration `"v3b-meter-snapshots"`: `meterSnapshot(id INTEGER PK AUTOINCREMENT, companyId, sprintId TEXT NOT NULL, scope TEXT NOT NULL /* agent|team */, subject TEXT NOT NULL /* agent id | team name or "company" */, windowStart, windowEnd, reading TEXT NOT NULL /* JSON */, band TEXT, bandReasons TEXT NOT NULL DEFAULT '[]', createdAt)`, `UNIQUE(sprintId, scope, subject)`.
  - `struct MeterSnapshot` (columns; `reading: MeterReading`, `band: String?`, `bandReasons: [String]`). `Store.writeSnapshots(db: Database, sprint: Sprint, now: Date) throws -> [MeterSnapshot]` writes one agent snapshot per *sprint agent* (non-killed agents whose `team == sprint.team`, or every non-killed agent for a company-wide sprint, plus any agent with an outcome in the sprint) and one team snapshot (`subject` = the team or `"company"`). Band columns are filled in Task 3. `Store.snapshots(companyId:sprintId:) -> [MeterSnapshot]`; `Store.agentSnapshots(agentId:limit:) -> [MeterSnapshot]` (newest sprint first); both have `db:` overloads, which `PeopleCycle` steps use.
  - Test helper `PeopleWorld` (wraps 3a `World`, 10-agent org): `func outcome(_ handle: String, type: String = "task", tier: EffortTier = .m, trusted: Bool = true, checkTrusted: Bool = true, firstPass: Bool = true, tokens: Int = 1000, sprintId: String? = nil, doneAt: Date) throws` inserts via `recordOutcome` (creating a backing item); `func sprint(team: String?, startedAt: Date, closedAt: Date) throws -> Sprint` inserts an active sprint row; `func close(_ sprint: Sprint, by handle: String) throws` calls `Store.closeSprint` (gates are not needed for a raw row).
  - CLI (`PerfGroup`, command `perf`, default subcommand `table`; every subcommand calls `requireOwnerReader()`, which exits 1 with `brahma: performance and HR data is owner-only` when `BRAHMA_AGENT_ID` is set):
    - `brahma perf <company> [--sprint <n>] [--team <t>]` prints the header `Rolling 14 days` or `Sprint <n> [<team|company>]`. Then the line `AGENT  TRUST  ITEMS  WTP  1ST-PASS  REWORK  REJ  ESC  COST  CYCLE  BLOCKED  CHATTER  FAILED  WD  OVER  FLAGS`. Then one row per agent, sorted by handle, with fields separated by two spaces: `@h  T1  4  12  75%  1  1  0  0.9×  1.5h  0.0h  2  0  0  0  -`. Nil values print `—`. `WD` is nudges + escalations. `FLAGS` is the flag count or `-`. After the agent rows come `TEAM <t>` and `COMPANY` rows.
    - `brahma perf show <company> @h` prints `key: value` lines for the rolling reading, the band history (`Sprint <n>: <band> — <reasons>`) and the gaming flags verbatim.

- [ ] **Step 1: Write failing tests.** `MeterTests`:
```swift
@Test func computeFromFacts() {
  /* 4 outcomes for a: tiers (s,true),(m,true),(l,true),(l,false); firstPass [t,t,f,t]; changesRequested [0,1,0,0]; reviewRounds [1,2,1,1];
     tokens [100,300,800,200], typeMedians ["task":200]; cycle [3600,7200,10800,3600]
     → itemsDone 4, weightedThroughput 13, firstPassRate 0.75, reworkRounds 1, reviewRejections 1, costRatio 1.25, cycleMedianSeconds 5400 */ }
@Test func emptyWindowHasNoRates() { /* MeterFacts empty → reading == .empty: firstPassRate nil, costRatio nil, cycleMedianSeconds nil, all counts 0, gamingFlags [] */ }
@Test func typeWithoutMedianExcludedFromCost() { /* typeMedians [:] → costRatio nil; 2 samples in DB → no median */ }
@Test func gamingFlags() { /* 5 done, 3 self-authored → flag 1 exact text; 5 claims, 4 cherry-pick → flag 2; splits 3 → flag 3; 4 done 2 self → no flag */ }
@Test func untrustedCheckEarnsNoCredit() { /* 2 outcomes, one checkTrusted false → itemsDone 2, weightedThroughput = weight of the trusted one only, firstPassRate over 1 item */ }
@Test func sprintWindowUsesSprintOutcomes() throws { /* PeopleWorld: outcome in sprint S1 and one outside but in time window → sprint reading itemsDone 1 */ }
@Test func chatterCountsMessagesInNoProgressTurns() async throws { /* World: eng-1 posts 2 messages in a no-progress turn and 1 in a handoff turn → chatterMessages 2, messages 3 */ }
@Test func escapedDefectsCountAfterDoneOnly() throws { /* bug defect_of ACME-1 created before ACME-1 done → 0; after → 1, attributed to ACME-1's owner */ }
@Test func snapshotsWrittenAtClose() throws { /* PeopleWorld sprint team-1, outcomes for eng-1, eng-2; close → 6 agent snapshots (team-1 members) + 1 team snapshot; UNIQUE prevents duplicates on re-run */ }
@Test func batchedReadingsMatchSingle() throws { /* 300-agent org, 600 outcomes → meterReadings(...)[x] == meterReading(agentIds:[x]) for 5 sampled agents; completes < 2 s */ }
```
  `PerfCLITests` (subprocess `brahma(_:env:)` helper from `WorkCLITests`):
  - `perfTablePrintsRows`: seed outcomes through `brahma dev complete` (Task 2 adds `DevScenario.complete` and `dev complete <company> <KEY> --as @h [--fail-first] [--reviewer @h]`, which run claim → submit → a scripted check outcome via `finishVerification` → `review(approve)` using the real Store paths and require `BRAHMA_DEV=1`). `perf Acme` contains a line starting `@eng-1  T1  1  3  100%`.
  - `perfRefusesInsideAgentTurn`: with `BRAHMA_AGENT_ID=x`, `perf Acme` and `perf show Acme @eng-1` exit 1 with the owner-only message.
  - `perfShowListsFlags`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "MeterTests|PerfCLITests"`. Expected: FAIL.
- [ ] **Step 3:** Implement `Meter`, the fact queries, snapshots, `DevScenario` (in `Sources/BrahmaCore/Dev/DevScenario.swift`: `static func complete(store: Store, itemKey: String, companyId: String, by handle: String, reviewer: String?, failFirst: Bool, now: Date) throws`), the dev command and `brahma perf`. Wire `Store.writeSnapshots` into `closeSprint` through `PeopleCycle.sprintClosed(db:store:sprint:now:)` in `Perf/PeopleCycle.swift`, whose only step so far is `writeSnapshots`. Later tasks append steps in the order fixed in Task 5.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core,cli): efficiency meter, sprint snapshots and brahma perf` with the trailer lines.

---

### Task 3: Trust ladder T0–T3 and its effects

**Files:**
- Create: `Sources/BrahmaCore/Perf/Trust.swift`, `Store/Store+Trust.swift`
- Modify: `Store/Migrations.swift` (`"v3b-trust"`), `Model/Agent.swift` (`trust`, `trustPinned`), `Model/Turn.swift` (`ActivityKind.people`), `Perf/PeopleCycle.swift` (step 2), `Store/Store+Meter.swift` (bands in snapshots), `Scheduler/Scheduler.swift` (`Candidate.trustRank`), `Orchestrator.swift` (candidates, model, budget), `Org/ModelPolicy.swift`, `Work/Budget.swift` (`TierBudget.of(_:trust:)`), `Store/Store+Leases.swift` (eligibility), `Store/Store+WorkItems.swift` (assignment eligibility), `Store/Store+Verification.swift` (light review on pass), `Store/Store+Sprints.swift` (`planSprint` accepts T3), `MCP/CompanyTools.swift` (T3 `plan_sprint`), `Turns/TurnDigest.swift` (trust in Org line), `Store/Store.swift` (`hire(… trust:)`), `Sources/brahma/AgentCommands.swift` (`hire --trust`), `Sources/brahma/PerfCommands.swift` (`perf trust`); `Tests/BrahmaCoreTests/SchedulerTests.swift`
- Test: `Tests/BrahmaCoreTests/TrustTests.swift`

**Interfaces:**
- Consumes: Task 2 `MeterReading`, `writeSnapshots`, `agentSnapshots`; 3a `Agent.trustLevel` (`"T1"` default), `ModelPolicy.resolve(agentModel:role:mode:tier:)`, `TierBudget.of`, `claimLease`, `finishVerification`, `completeItem`, `Store.review`, `TurnDigest` Org line, `planSprint`, `MessageRouter.sendDM(db:…)`.
- Produces:
  - Migration `"v3b-trust"`: `agent` + `trustPinned BOOLEAN NOT NULL DEFAULT 0`; `trustChange(id INTEGER PK AUTOINCREMENT, companyId, agentId TEXT REFERENCES agent ON DELETE CASCADE, fromLevel TEXT, toLevel TEXT, reason TEXT, evidence TEXT NOT NULL DEFAULT '[]', actor TEXT /* engine | owner | hr:<agentId> */, sprintId TEXT, createdAt)`.
  - `enum TrustLevel: String, Codable, CaseIterable, Comparable, Sendable { case t0 = "T0", t1 = "T1", t2 = "T2", t3 = "T3"; var title: String /* Probation, Standard, Trusted, Lead */; var rank: Int /* 0…3 */; var budgetMultiplier: Double /* 1.0, 1.0, 1.5, 2.0 */; var maxTier: EffortTier /* s, l, l, l */; var canNavigate: Bool /* t2, t3 */; var canLeadContainers: Bool /* t2, t3 */; var requiresPairing: Bool /* t0 */ }`. `Agent` + `var trust: TrustLevel { TrustLevel(rawValue: trustLevel) ?? .t1 }`, `var trustPinned: Bool = false`.
  - `ActivityKind` + `case people`.
  - `enum PerformanceBand: String, Codable, Sendable { case strong, meets, below, insufficient }`
  - `enum PerformanceBar { static let minItems = 3; static func band(_ r: MeterReading, teamMedianThroughput: Double) -> (PerformanceBand, [String]) }`. Below-reason copy, in this order:
    - `"first-pass rate below 50%"`
    - `"2 or more escaped defects"`
    - `"cost per item over 2× the type median"`
    - `"2 or more watchdog escalations"`
    - `"over 30% failed turns"`
    - `"2 or more budget overruns"`
    - `"no items done in 10+ turns"`

    The rules:
```
if itemsDone < minItems:
   reasons = escalations ≥ 2 → [r4]; (claims ≥ 1 && itemsDone == 0 && turns ≥ 10) → + [r7]
   return reasons.isEmpty ? (.insufficient, []) : (.below, reasons)
reasons = every below rule that holds (r5 only when turns ≥ 5)
if !reasons.isEmpty → (.below, reasons)
if !gamingFlags.isEmpty → (.meets, ["gaming signals: " + flags.joined("; ")])
if firstPass ≥ 0.8 && (costRatio ?? 1) ≤ 1.0 && escaped == 0 && escalations == 0 && overruns == 0 && Double(wtp) ≥ teamMedian
   → (.strong, ["quality, cost and throughput at or above the bar"])
→ (.meets, [])
```
    `writeSnapshots` now fills `band`/`bandReasons` for agent snapshots. `teamMedianThroughput` is the median `weightedThroughput` of that sprint's agents with `itemsDone ≥ 1` (0 if none).
  - `enum TrustPolicy { static func next(current: TrustLevel, bands: [PerformanceBand] /* newest first, only sprints closed after the agent's last trustChange, insufficient removed */, pinned: Bool) -> (TrustLevel, String)? }`:
```
pinned → nil
t0: bands.count ≥ 2 && bands[0..<2] all ∈ {strong, meets} → (t1, "2 sprints at or above the bar on probation")
t1: first 2 strong → (t2, "2 strong sprints in a row")
t2: first 3 strong → (t3, "3 strong sprints in a row")
t2/t3: first 2 below → (one level down, "2 sprints below the bar in a row")
else nil            // the engine never demotes T1 → T0; that is HR's PIP (Task 7) or the owner
```
  - `struct TrustChange` (columns; `evidence: [String]` = the band reasons of the deciding sprints, `"Sprint <n>: <band>"` lines).
  - `Store.evaluateTrust(db: Database, sprint: Sprint, now: Date) throws -> [TrustChange]` (PeopleCycle step 2). It runs for each agent snapshot of the sprint. On a change it:
    - writes `agent.trustLevel` (column write) and a `trustChange` row (actor `engine`);
    - posts an `ActivityEvent(kind: .people, text: "@<h> trust <from> → <to>: <reason>")`;
    - sends a system DM to the agent's manager (else the owner) of exactly `"Trust: @<h> is now <to> <title>."`. The reason stays in the owner-visible `trustChange` row.
    - Inside the transaction it reads bands through `agentSnapshots(db:…)` and `trustHistory(db:…)`.
  - `Store.setTrust(agentId: String, level: TrustLevel, pin: Bool = true, note: String?, now:) throws -> Agent`: owner override (actor `owner`); `trustPinned = pin`. It is reachable only from the CLI and the app.
  - `Store.trustHistory(agentId:) -> [TrustChange]` (+ `db:` overload).
  - Effects:
    - **Scheduler:** `Candidate` + `var trustRank: Int = 1`. The sort is blockingCount, then roleWeight, then **trustRank desc**, then readySince, then name. The orchestrator fills it from `agent.trust.rank`.
    - **Model:** `ModelPolicy.resolve(agentModel:role:mode:tier:trust: TrustLevel = .t1)`. For `"auto"`: t0 → `role.models["low"] ?? "sonnet"`; t3 with tier `.m` → `"opus"`; otherwise 3a's rule. An explicit model is unchanged.
    - **Budget:** `TierBudget.of(_ tier: EffortTier, trust: TrustLevel) -> TierBudget` = turns and tokens × `budgetMultiplier`, rounded down, with the same model. 3a's `endTurn` budget check uses the item owner's trust.
    - **Eligibility.** `claimLease` refuses when the item's tier weight is above `trust.maxTier`: `"<KEY> is tier <T>; on probation (T0) you can take S items only"`. `updateWorkItem` and `createWorkItem` refuse:
      - an owner on probation for a non-S item: `"@<h> is on probation (T0) and can take S items only"`;
      - an individual-kind owner below T2 on a container: `"leading <KEY> needs trust T2 or higher"`. Manager and executive kinds are exempt.
    - **Review rules:** `enum ReviewRules { static func light(item: WorkItem, ownerTrust: TrustLevel, db: Database) throws -> Bool }` is true iff all of these hold: `reviewFlags.isEmpty`; the type requires a check; `item.authorId != item.ownerId`; `ProvenanceRules.trusted(tierSetById)`; `ProvenanceRules.trusted(checkSetById)`; and (`t2` && tier `.s`) or (`t3` && tier ∈ {s, m}). In `finishVerification`'s pass branch, if `light`, the engine approves as `Sender.system`: same effects as `review(approve)` (done, `reviewedRound`, lease deleted, completion rollup), event `reviewApproved` with text `"light review: engine check passed (trust <T>)"`, and a notice to the reviewer. T0 owners never get light review.
    - **T3 planning input:** `planSprint` accepts an individual-kind agent at T3 only when `team` equals its own non-nil team. A nil team is refused with `"a company-wide sprint needs a manager or executive"`, and another team with `"you can plan only for <own team>"`. `CompanyTools.specs()` adds `CompanyToolNames.trustLead` for T3 agents.
    - **Orientation:** the `TurnDigest` Org line appends ` · trust: <T> <title>`. TurnDigest never shows bands or meter values.
    - **New hires:** `Store.hire(companyId:name:role:model:managerId:team:trust: TrustLevel = .t1)`. CLI `brahma hire … --trust T0|T1` (other values: `"new hires start at T1, or T0 if you choose"`).
  - CLI `brahma perf trust <company> @h <T0|T1|T2|T3> [--unpin] [--note <text>]` (`requireOwnerShell`) prints `@h is now <T> <title> (pinned)` (or `(engine-managed)` with `--unpin`).

- [ ] **Step 1: Write failing tests.** `SchedulerTests.trustBreaksTiesAfterRole`: two engineers, equal blocking, T3 is picked before T0, and a ceo at T0 still precedes an engineer at T3. `TrustTests`:
```swift
@Test(arguments: [/* (current, bands, expected) */
  (TrustLevel.t1, [PerformanceBand.strong, .strong], TrustLevel.t2), (.t1, [.strong, .meets], nil), (.t2, [.strong, .strong], nil),
  (.t2, [.strong, .strong, .strong], .t3), (.t2, [.below, .below], .t1), (.t1, [.below, .below], nil), (.t0, [.meets, .strong], .t1),
  (.t3, [.below, .strong], nil)])
func ladderTable(current: TrustLevel, bands: [PerformanceBand], expected: TrustLevel?) { /* TrustPolicy.next(...)?.0 == expected; pinned → nil */ }
@Test func bandRules() { /* exact reasons per rule; 2 items → insufficient; 0 done, 12 turns, 1 claim → below ["no items done in 10+ turns"] */ }
@Test func gamingFlagsCapBand() { /* otherwise-strong reading + 1 flag → .meets with "gaming signals: …" */ }
@Test func insufficientSampleNeverMoves() throws { /* PeopleWorld: 3 sprints with 1 item each → no trustChange, still T1, no manager DM */ }
@Test func promotionAfterTwoStrongSprintsNotifiesManager() throws {
  /* eng-1 strong in S1 → T1; strong in S2 → T2; trustChange reason "2 strong sprints in a row", actor engine; mgr-1 system DM text == "Trust: @eng-1 is now T2 Trusted." exactly */ }
@Test func hysteresisRestartsAfterChange() throws { /* promoted at S2; S3 strong → still T2 (needs 3 strong since change) */ }
@Test func ownerOverridePins() throws { /* setTrust T3 pin → strong/below sprints change nothing; unpin → engine resumes */ }
@Test func budgetAndModelFollowTrust() async throws { /* T2 owner of S item: budget 9 turns/450_000; T0 engineer auto → "sonnet" (engineer low); T3 on M → request model "opus" */ }
@Test func probationLimitsItemSize() throws { /* setTrust T0; claim M → exact message; mgr assigns L to T0 eng → exact message; T1 individual owner on epic → "leading ACME-1 needs trust T2 or higher" */ }
@Test func selfAuthoredItemNotLightReviewed() async throws { /* T2 eng-1 authors and owns an S task with check "true" (tier and check set by eng-1) → passes → stays inReview, review turn runs; after approval: no coffee/streak award, outcome adds 0 weighted throughput */ }
@Test func lightReviewAutoApproves() async throws { /* mgr-1-authored S item with mgr-1's check, owner T2 eng-1, passes → done, actor system event text "light review: engine check passed (trust T2)", no review turn; same item tier M → review turn; flagged S item → review turn */ }
@Test func t3IndividualCanPlanOwnTeamSprint() throws { /* eng-1 T3 tools include plan_sprint; planSprint(team: team-1) ok; team-2 → "you can plan only for team-1"; team nil → "a company-wide sprint needs a manager or executive" */ }
@Test func orientationShowsLevelNotNumbers() throws { /* TurnDigest Org line ends " · trust: T2 Trusted"; output contains no "%", "first-pass", "band", "strong", "below" */ }
@Test func trustNotSelfGrantable() throws { /* no CompanyTools spec name or arguments path changes agent.trustLevel: call every spec with {"agent":"@eng-1","level":"T3"} → trustLevel unchanged */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "TrustTests|SchedulerTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the types, the evaluation step, the overrides and each effect.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS (3a `BudgetTests` still pass at T1).
- [ ] **Step 5:** Commit `feat(core,cli): engine trust ladder with hysteresis wired into scheduling, models, budgets and review` with the trailer lines.

---

### Task 4: Queued special turns and the smart-friend consult

**Files:**
- Create: `Sources/BrahmaCore/Turns/QueuedTurns.swift`, `Store/Store+QueuedTurns.swift`, `Perf/SmartFriend.swift`, `MCP/PeopleTools.swift`
- Modify: `Store/Migrations.swift` (`"v3b-queued-turns"`), `Model/Turn.swift` (`TurnKind` cases, `queuedTurnId`), `Turns/ClaudeCommand.swift` (`MCPConfig.write(… queuedTurnId:)`), `Sources/brahma/MCPCommand.swift` (`--queued-turn`), `MCP/CompanyTools.swift` (queued mode, dispatch), `Orchestrator.swift` (selection, `start()` recovery, settle in `endTurn`), `Store/Store+WorkItems.swift` (`hasPendingWork`), `Work/Budget.swift` (`itemUsage` counts `consult`), `Lifecycle/AgentLifecycle.swift` (kill fails the agent's queue)
- Test: `Tests/BrahmaCoreTests/QueuedTurnTests.swift`

**Interfaces:**
- Consumes: 3a review-turn machinery (fresh `sessionId`, `appendSystemPrompt`, per-kind MCP config, `setTurnContext`, skipped `markSessionStarted`/`resetSession`/delivery), `RoleCards.load`, `ModelPolicy.resolve`, `TurnResult.text`, `Sender.system`, `ChildEnvironment`.
- Produces:
  - Migration `"v3b-queued-turns"`: `queuedTurn(id TEXT PK, companyId TEXT NOT NULL, agentId TEXT NOT NULL REFERENCES agent ON DELETE CASCADE, kind TEXT NOT NULL, subjectId TEXT, payload TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL, attempts INT NOT NULL DEFAULT 0, model TEXT, createdAt, finishedAt)`, with index `(agentId, status, createdAt)`; `turn` + `queuedTurnId TEXT`.
  - `TurnKind` + `case ceremony, consult, navigate`; `Turn` + `var queuedTurnId: String? = nil`.
  - `enum QueuedTurnKind: String, Codable, Sendable { case scorecard, sprintJudge, hrReview, ideaReview, consult, navigate; var title: String /* "Scorecard", "Sprint judge", "HR review", "Idea review", "Smart-friend consult", "Navigator review" */; var turnKind: TurnKind }`
  - `enum QueuedTurnStatus: String, Codable, Sendable { case queued, running, done, failed }`; `struct QueuedTurn: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord` (columns; `payload` stays a JSON string, decoded by the handler).
  - `protocol QueuedTurnHandler: Sendable { var kind: QueuedTurnKind { get }; var tools: [String] { get }; var instructions: String { get }; func prompt(store: Store, paths: BrahmaPaths, queued: QueuedTurn, agent: Agent, company: Company) throws -> String; func succeeded(db: Database, store: Store, paths: BrahmaPaths, queued: QueuedTurn, result: TurnResult, now: Date) throws /* default no-op */ }`. `enum QueuedTurns { static let maxAttempts = 3; static func handler(_ k: QueuedTurnKind) -> (any QueuedTurnHandler)?; static func kind(forTool name: String) -> QueuedTurnKind? /* the handler whose tools contain name, ceremony tools only */ }` is a registry literal that each later task extends.
  - Store:
    - `enqueueTurn(db: Database, companyId:agentId:kind:subjectId:payload: String = "{}", model: String? = nil, now:) throws -> QueuedTurn` is idempotent per `(agentId, kind, subjectId)` while one is `queued`/`running` (it returns the existing one), and wakes a sleeping agent.
    - `nextQueuedTurn(agentId:) -> QueuedTurn?` returns the oldest `queued`.
    - `beginQueuedTurn(id:) -> QueuedTurn?` (queued → running, atomic).
    - `completeQueuedTurn(db: Database, id: String, now:)` (→ done; tools call it).
    - `settleQueuedTurn(db: Database, id: String, outcome: TurnOutcome, now:)`: done stays done; `interrupted` → queued, with attempts unchanged; otherwise attempts += 1, back to queued, or at 3 → failed. A failure sends a system DM to the owner: `"<kind title> for <subject key or sprint name> did not complete after 3 turns by @<h>."`, plus an `ActivityEvent(.people)`.
    - `recoverQueuedTurns(now:) -> Int` (running → queued; `Orchestrator.start()` calls it).
    - `queuedTurns(companyId:statuses:) -> [QueuedTurn]`.

    `hasPendingWork` is also true for a `queued` row. Killing an agent marks its queued and running rows `failed` (no DM).
  - Orchestrator `performTurn` order: 3a review turn if any; else `nextQueuedTurn` → a queued turn; else a work turn. A queued turn:
    - uses the agent copy with a fresh `sessionId` and `sessionStarted = false`, and model = `queued.model ?? ModelPolicy.resolve(…, trust:)`;
    - sets `appendSystemPrompt` = role card + `"\n\n" + handler.instructions`, and the prompt = `handler.prompt(...)`;
    - uses an MCP config from `MCPConfig.write(paths:executable:agent:reviewItemId: nil, queuedTurnId:)` (file `<agentId>.queued.mcp.json`, args + `["--queued-turn", id]`);
    - records `setTurnContext(kind: kind.turnKind, itemId: subject if an item)` and `turn.queuedTurnId`;
    - skips `markSessionStarted`, `resetSession`, inbox and notice delivery, the budget check and the watchdog counter (`turnsWithoutProgress` unchanged).

    In `endTurn`, a succeeded queued turn first calls `handler.succeeded`, then `settleQueuedTurn`.
  - `CompanyTools` + `queuedTurnId: String?` (init parameter, default nil). When set, `specs()` = the handler's `tools` that exist, and every call re-checks that the queued turn is `running` and belongs to the caller (`"this turn has ended"`). When nil, any name in `CompanyToolNames.ceremony` is refused with `"<tool> runs only in its own <kind title> turn"`.
  - `enum SmartFriend { static let perItem = 2; static let perAgentPerDay = 6; static func stronger(_ model: String) -> String /* haiku→sonnet, sonnet→opus, opus→opus */ }`.
  - Tool `ask_smart_friend {question, key?, context_paths?: [string]}` (in `work`). It validates the question (non-blank, ≤ 2000 chars), the paths (≤ 10, relative, no `..`) and the key (same company). It enforces the caps with `"you already asked a smart friend 2 times on <KEY>"` and `"you can ask a smart friend 6 times per day"`. It enqueues `consult` with subject = the item id (or nil), payload `{question, paths, itemKey}` and model = `stronger(current effective model)`. It returns `"Asked a smart friend (<model>); the answer arrives from @system after this turn."`.
  - `ConsultHandler`: `tools = []`. The prompt is `ConsultDigest.render(question:item:paths:askerHandle:roleTitle:)`, with this exact layout (`|` blocks quoted):
```
# Smart-friend consult
You are a senior <role title> consulted for one turn by @<asker>. Read any files you need; do not edit files. Answer concretely: the approach, the specific change, and how to verify it.
Item: <KEY> <title…1>                 (only with an item)
Acceptance criteria:                   (only with an item)
    | <criteria ≤ 1500>
Context files: <p1>, <p2>             (or "none")
Question:
    | <question>
```
    `succeeded` writes `TurnResult.text` (capped at 20 000 chars) to `<workspace>/.brahma/consults/<queuedTurnId>.md` and sends the asker the system DM `"Smart friend (<model>) answered[ on <KEY>]: <first 300 chars…1> Full answer: .brahma/consults/<id>.md"`, then completes the turn. Consult turns carry `turn.itemId`, and `Store.itemUsage` now sums `work` and `consult` turns.

- [ ] **Step 1: Write failing tests** in `QueuedTurnTests` (World + FakeTurnRunner, 10-agent org):
```swift
@Test func consultRunsAsFreshStrongerTurn() async throws {
  /* eng-1 (sonnet) holds ACME-1; ask_smart_friend → queued consult model "opus"; cycle → request.agent.model == "opus", sessionId != eng-1's,
     prompt starts "# Smart-friend consult", contains "Item: ACME-1", MCP args contain "--queued-turn"; tools/list in that config is empty;
     fake result text "Use a binary search" → file .brahma/consults/<id>.md == text; eng-1 DM from system contains "Smart friend (opus) answered on ACME-1: Use a binary search"; row done */ }
@Test func consultCountsTowardItemBudget() async throws { /* consult turn usage counted in itemUsage(ACME-1) */ }
@Test func consultCaps() throws { /* 3rd ask on ACME-1 → exact message; 7th in 24 h → exact message */ }
@Test func queuedTurnPrecedesWorkButFollowsReview() async throws { /* agent with pending review and queued consult → review turn first, then consult, then work */ }
@Test func interruptedTurnRequeuesWithoutAttempt() async throws { /* script interrupted → status queued, attempts 0; next cycle runs it again with a new session id */ }
@Test func failsAfterThreeAttemptsAndTellsOwner() async throws { /* consult whose turn fails 3 times (advance the clock past each retry backoff) → failed, owner DM "Smart-friend consult for ACME-1 did not complete after 3 turns by @eng-1." */ }
@Test func runningRecoveredOnStart() async throws { /* beginQueuedTurn; new Orchestrator.start() → queued */ }
@Test func killedAgentFailsItsQueue() throws { /* enqueue; kill → failed; hasPendingWork false */ }
@Test func ceremonyToolsRefusedOutsideTheirTurn() throws { /* normal CompanyTools: publish_scorecard → "publish_scorecard runs only in its own Scorecard turn" */ }
@Test func enqueueIsIdempotent() throws { /* same agent/kind/subject twice → one row */ }
@Test func crossCompanyConsultRefused() throws { /* key of a Globex item → "not in your company"; nothing queued */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter QueuedTurnTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the queue, the orchestrator branch, the MCP mode, `SmartFriend` and the tool. Register `ConsultHandler`.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS (`CommandTests` argv unchanged; MCP config unchanged when `queuedTurnId == nil`).
- [ ] **Step 5:** Commit `feat(core): queued special turns and budgeted smart-friend consults` with the trailer lines.

---

### Task 5: Sprint-close cycle, decision extensions, Performance scorecard and the sprint judge

**Files:**
- Create: `Sources/BrahmaCore/Perf/Scorecard.swift`, `Perf/SprintJudge.swift`
- Modify: `Store/Migrations.swift` (`"v3b-people-cycle"`), `Model/Decision.swift` (kinds, `ownerRequired`, `payload`), `Store/Store+Decisions.swift` (`proposeDecision` parameters, `internalDecide`, effects registry), `Model/Sprint.swift` (`carriedOver`, `judgeVerdict`, `judgeReason`), `Store/Store+Sprints.swift` (records `carriedOver`, calls `PeopleCycle`), `Perf/PeopleCycle.swift` (`PeopleRoles`, full step list), `MCP/PeopleTools.swift` (`publish_scorecard`, `judge_sprint`)
- Test: `Tests/BrahmaCoreTests/ScorecardTests.swift`, `JudgeTests.swift`

**Interfaces:**
- Consumes: Task 4 `enqueueTurn`, `completeQueuedTurn`, `QueuedTurnHandler`; Task 3 `trustHistory`, bands; Task 2 `snapshots`, `meterReading`; 3a `proposeDecision`, `internalDecide`, `ownerDecide`, `applyDecisionEffects`, `closeSprint`, `RoleCards.path`, `Store.reports`, `resetSession` columns.
- Produces:
  - Migration `"v3b-people-cycle"`: `decision` + `ownerRequired BOOLEAN NOT NULL DEFAULT 0`, `payload TEXT`; `sprint` + `carriedOver TEXT NOT NULL DEFAULT '[]'`, `judgeVerdict TEXT`, `judgeReason TEXT`; `scorecard(id TEXT PK, companyId, sprintId TEXT UNIQUE, authorId TEXT, summary TEXT, path TEXT, createdAt)`.
  - `DecisionKind` + `idea` ("Idea"), `termination` ("Termination"), `staffing` ("Staffing") and `systemFix` (raw `"systemFix"`, "System change"). `isGate` is true for these four as well. `Decision` + `var ownerRequired: Bool = false`, `var payload: String? = nil`.
  - `Store.proposeDecision(companyId:by:kind:title:summary:detailsPath:subjectId:approverId: String? = nil, internallyApprovedBy: String? = nil, ownerRequired: Bool = false, payload: String? = nil, now:)`:
    - `approverId` replaces pack routing (it must be a non-killed agent of the company, not the proposer);
    - `internallyApprovedBy` skips `pendingInternal` and applies the internal-approve branch at once, with `internalApproverId` set to it;
    - `ownerRequired` makes the internal-approve branch go to `pendingOwner` even in Auto mode (and `internalDecide` honors it).

    `applyDecisionEffects` dispatches through `enum DecisionEffects { static func apply(db:store:decision:now:) throws }` with one case per kind (3a's `sprintPlan` effects move here unchanged). Tasks 7, 8 and 10 add theirs.
  - `enum PeopleFunction { case performance, hr }`; `enum PeopleRoles { static func cover(_ roleId: String, companyId: String, db: Database, catalog: PackCatalog) throws -> Agent? /* first non-killed agent, oldest first, whose role ∈ pack.rolesCovering(roleId) */; static func agent(_ f: PeopleFunction, companyId:db:catalog:) throws -> Agent? /* cover("perf"|"hr") ?? cover("ceo") */ }`
  - `PeopleCycle.sprintClosed(db:store:sprint:now:)` runs inside 3a's `closeSprint` transaction, after its own effects. Its fixed step order is:
    1. `writeSnapshots` (Task 2)
    2. `evaluateTrust` (Task 3)
    3. `Awards.sprintClosed` (Task 6)
    4. `HR.sprintClosed` (Task 7, rules and PIP evaluation)
    5. enqueue `scorecard` (this task)
    6. enqueue `sprintJudge` (this task)
    7. enqueue `hrReview` (Task 7)
    8. `Ideas.sprintClosed` (Task 8: idea review, triage reminders, visionary period)

    Steps owned by later tasks are added by those tasks. `closeSprint` also stores `carriedOver` = the keys of its unfinished items (before clearing their `sprintId`).
  - `Scorecard` (columns). `ScorecardDigest.render(sprint: Sprint, sprintName: String, rows: [(handle: String, role: String, trust: TrustLevel, reading: MeterReading, band: PerformanceBand?, reasons: [String])], team: MeterReading, previousTeam: MeterReading?, trustChanges: [(String, TrustChange)]) -> String`. It renders one block per agent with every meter field, the team totals with the delta against the previous team snapshot, gaming flags and trust changes, then the instructions. It excludes the Performance agent's own row. The handler `scorecard` (subject = sprint id):
    - tools: `show_work_item, publish_scorecard`;
    - assigned to `PeopleRoles.agent(.performance)`; skipped with an `ActivityEvent(.people, "No Performance agent for <name>; scorecard skipped")` when nil;
    - `instructions` (exact): `"You are the company's Performance analyst. You see engine-measured numbers that the agents themselves never see. Publish one scorecard: a short summary, outliers and trends, and concrete recommendations (prompt or model changes, reassignment, team splits, pairing, retraining notes). Feedback to an agent must be specific, actionable advice without numbers, scores or levels. Look for system causes (oversized items, wrong model, weak role prompt) before blaming an agent."`
  - Tool `publish_scorecard {summary, outliers?: [{agent, note}], recommendations?: [{kind: "prompt"|"model"|"reassign"|"team_split"|"pairing"|"retraining"|"other", subject: "@h"|"<team>"|"<role id>", change, reason}], feedback?: [{agent, note}]}`:
    - It writes `<companyDir>/perf/sprint-<n>[-<team>].md`: `# Scorecard: <name> [<team>]`, the summary quoted, the engine table (same columns as `brahma perf`), outliers, recommendations with their `D-<n>` refs, and feedback lines.
    - It inserts the `scorecard` row.
    - Each recommendation (its `change` and `reason` must pass `FeedbackGuard`) becomes `proposeDecision(kind: .systemFix, by: author, title: "<kind>: <subject> — <change…1>", summary: reason, subjectId: agent id if @h, payload: JSON {kind, subject, change}, ownerRequired: kind == "prompt")`, routed under normal rules. A `reassign` recommendation is a record-only `systemFix`; the manager uses `reassign_agent` if it agrees.
    - Each feedback note passes `FeedbackGuard` and is appended to `<workspace>/.brahma/notes/<handle>.md` under `## <name> feedback (<yyyy-MM-dd>)` as `- <note>`. Feedback for an agent outside the company is refused with `"not in your company"`.
    - It completes the queued turn and returns `"Published the <name> scorecard with <k> recommendation(s): D-…"`.
  - `enum FeedbackGuard { static func check(_ text: String, maxLength: Int = 500) throws }` throws `WorkError.invalid("feedback must be specific advice, not scores or levels: <text…1>")` when the text contains any digit or `%`, matches `(?i)\b(scores?|rank(ed|ing|s)?|bands?|quartiles?|medians?|percentiles?|averages?|peers?|first-pass|throughput|below the bar|above the bar|T[0-3])\b`, is empty, or is longer than `maxLength`. **It applies to every agent-authored text another agent can read:**
    - scorecard feedback notes;
    - recommendation `change` and `reason`;
    - HR `corrective_note`, and HR `note` (which reaches the manager's DM);
    - `propose_system_fix` `change` and `reason`.

    Engine-written texts (PIP targets, trust DMs) are fixed copy and do not pass through it.
  - `enum SystemFix { static func apply(db:store:decision:now:) throws }` (the `systemFix` effect on approval):
    - payload kind `model` with an `@h` subject and a change in `opus|sonnet|haiku|auto` → sets `agent.model` (column write);
    - kind `prompt` (always `ownerRequired`) with an `@h` subject → appends `## Coaching (D-<n>)\n<change>\n` to that agent's coaching file `<companyDir>/roles/<handle>.coaching.md`, or with a role-id subject → to every non-killed agent of that role. `RoleCards.load` now returns `card.prefix(4000 − c.count − 2) + "\n\n" + c`, where `c` is the last 1500 chars of the coaching file (if any), so truncation never drops coaching;
    - other kinds → recorded only.

    Every case sends a system DM to the proposer and to the subject's manager: `"D-<n> approved: <title>. <applied | Act on it: no automatic change for <kind>>"`.
  - `enum JudgeVerdict: String, Codable, Sendable { case `continue`, replan, stop }`. Handler `sprintJudge` (subject = sprint id; tools `show_work_item, judge_sprint`):
    - The judge is the sprint's `sprintPlan` decision `internalApproverId` if non-killed and not the planner, else the first non-killed executive other than the planner, else none (skipped).
    - `JudgeDigest.render(sprint:name:done:total:carriedOver:blocked: [(key, reason)], team: MeterReading, goal:, summary:)` holds team-level numbers only.
    - `instructions` (exact): `"You are the judge for this sprint. Planners created the items and workers finished them independently; you decide what happens next: continue toward the goal, replan (the carried-over work goes back to Backlog for a new plan), or stop (the owner decides). You may name agents whose sessions should restart fresh to fight drift."`
  - Tool `judge_sprint {verdict, reason, fresh_restart?: [@h]}` sets `judgeVerdict`/`judgeReason` and completes the turn. Effects:
    - continue: system DM to the planner `"Judge @<j> on <name>: continue — <reason…1>. Plan the next sprint."`
    - replan: `carriedOver` items in `ready` → `backlog`; DM to the planner and the CPO-cover `"Judge @<j> on <name>: replan — <reason…1>. Carried-over items are back in Backlog."`
    - stop: system post to `#general` and an owner DM `"Judge @<j> recommends stopping <team|company> work after <name>: <reason…1>. The owner decides."`; the team's `ready` items → `backlog`.
    - `fresh_restart` (≤ 10, same company, non-killed): new `sessionId`, `sessionStarted = false`, `ActivityEvent(.people, "@<h> session restarted by the sprint judge")`.

- [ ] **Step 1: Write failing tests.** `ScorecardTests` (PeopleWorld + World orchestrator):
```swift
@Test func closeEnqueuesScorecardForPerfOrCeo() throws { /* no perf agent → queued scorecard for ceo; hire perf-1 → next close queues for perf-1 */ }
@Test func digestExcludesAuthorAndCarriesNumbers() throws { /* perf-1 in team: rendered digest has "@eng-1" block with "first-pass" value, no "@perf-1" block */ }
@Test func publishWritesFileDecisionsAndFeedback() throws {
  /* publish with 1 model rec for @eng-1 → "opus", 1 feedback "Run the edge-case checklist before submitting"
     → file at companyDir/perf/sprint-1-team-1.md; decision kind systemFix pendingInternal (approver ceo); notes file of eng-1 contains "## Sprint 1 feedback (" and the note; queued turn done */ }
@Test func feedbackRejectsScores() throws { /* notes "your first-pass rate is 40%", "you are T0", "low score", "bottom quartile vs peers", "3 of your items failed", and a recommendation reason "below the median" → each WorkError.invalid exact prefix; nothing appended or proposed */ }
@Test func reassignRecommendationIsRecordOnly() throws { /* reassign rec → decision kind systemFix, payload kind reassign; approved → no agent change, DM "Act on it" */ }
@Test func decideOnlyByAssignedApprover() throws { /* decision with approverId mgr-1: mgr-2 decide → "only @mgr-1 can decide D-1"; ceo decide → same; mgr-1 → ok */ }
@Test func scorecardFilesOutsideWorkspace() throws { /* scorecard path hasPrefix(companyDir), !hasPrefix(workspace) */ }
@Test func approvedModelFixApplies() throws { /* ceo approves, owner approves → eng-1.model "opus"; mgr-1 DM "D-1 approved"; prompt fix (ownerRequired, owner approves) → coaching file has "## Coaching (D-2)", and RoleCards.load output ends with it even with a 6000-char card */ }
@Test func ownerRequiredSurvivesAuto() throws { /* proposeDecision(kind: .other, ownerRequired: true), autoMode on, approver approves → pendingOwner */ }
@Test func explicitApproverAndPreApproval() throws { /* approverId mgr-1 → internalApproverId mgr-1; internallyApprovedBy ceo with gate + auto → approved decidedBy "auto" */ }
@Test func crossCompanyFeedbackRefused() throws { /* feedback agent "@globex-eng" → "not in your company" */ }
```
  `JudgeTests`:
```swift
@Test func judgeIsApproverNotPlanner() throws { /* mgr-1 plans, cpo approves → judge queued for cpo; only ceo approver alive & ceo planned → next exec */ }
@Test func replanMovesCarriedOverToBacklog() throws { /* 1 of 2 items done; close; judge replan → other item backlog; mgr-1 + cpo DMs exact */ }
@Test func stopTellsOwner() throws { /* owner DM and #general post exact copy */ }
@Test func freshRestartResetsSessions() throws { /* fresh_restart ["@eng-1"] → eng-1.sessionStarted false, new sessionId; 11 handles → isError */ }
@Test func closeNeverWaitsOnCeremonies() throws { /* closeSprint returns closed with queued rows present */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ScorecardTests|JudgeTests|DecisionTests|SprintTests"`. Expected: the new tests FAIL; 3a decision and sprint tests stay green.
- [ ] **Step 3:** Implement the migration, decision extensions, `PeopleRoles`, the cycle, both handlers and both tools.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core): sprint-close people cycle, Performance scorecards and sprint judge` with the trailer lines.

---

### Task 6: Digital rewards, kudos and the break room

**Files:**
- Create: `Sources/BrahmaCore/Perf/Awards.swift`, `Store/Store+Awards.swift`, `Sources/brahma/KudosCommands.swift`
- Modify: `Store/Migrations.swift` (`"v3b-awards"`), `Model/Agent.swift` (`firstPassStreak`), `Store/Store.swift` (`builtinObservers` + `AwardObserver`), `Perf/PeopleCycle.swift` (step 3), `Brahma.swift`
- Test: `Tests/BrahmaCoreTests/AwardTests.swift`

**Interfaces:**
- Consumes: Task 1 `ItemOutcome` (written first by `MeterObserver`); Task 3 `TierBudget.of(_:trust:)`, bands; Task 2 snapshots.
- Produces:
  - Migration `"v3b-awards"`: `award(id INTEGER PK AUTOINCREMENT, companyId, agentId TEXT REFERENCES agent ON DELETE CASCADE, kind TEXT, itemId TEXT, sprintId TEXT, note TEXT, givenBy TEXT /* engine | owner */, createdAt)`, with index `(companyId, id)`; `agent` + `firstPassStreak INTEGER NOT NULL DEFAULT 0`.
  - `enum AwardKind: String, Codable, CaseIterable, Sendable { case coffee, meal, trophy, streak, kudos, idea; var emoji: String /* ☕ 🍜 🏆 🔥 ⭐ 💡 */; var title: String /* "Coffee", "Meal", "Employee of the sprint", "Streak", "Kudos", "Shipped idea" */ }`; `struct Award` (columns).
  - `enum Awards { static let mealShare = 0.75; static let streakMilestones = [3, 5, 10]; static let kudosMax = 280; static func isStreakMilestone(_ n: Int) -> Bool /* 3, 5, 10, 20, 30, … */; static func employeeOfSprint(_ rows: [(agentId: String, handle: String, reading: MeterReading)]) -> String? }`. Eligible agents have `itemsDone ≥ 3`, `firstPassRate ≥ 0.8`, 0 escaped and no gaming flags. Ties go by `weightedThroughput` desc, then `firstPassRate` desc, then handle.
  - `struct AwardObserver: WorkItemObserver` (built-in, after `MeterObserver`) acts on items whose outcome has `checkTrusted`; other items earn nothing and leave the streak unchanged:
    - firstPass → `coffee` (note `"<KEY> passed its check first time"`) and `firstPassStreak += 1`; otherwise the streak resets to 0;
    - at a milestone → `streak` (note `"<n> first-pass items in a row"`);
    - tier L with `turns ≤ 0.75 × budget.maxTurns` and `tokens ≤ 0.75 × budget.maxTokens` (trust-scaled, owner's trust) → `meal` (note `"<KEY> (L) finished under budget"`).

    Each award appends `ActivityEvent(.people, "<emoji> @<h> <title>: <note>")`.
  - `Awards.sprintClosed(db:sprint:snapshots:now:)` (PeopleCycle step 3) gives a `trophy` (note `"Employee of <name>"`).
  - `Store.giveKudos(companyId: String, agentId: String, note: String, now:) throws -> Award`: owner only (CLI and app). The note must be non-blank and ≤ 280 chars (`"kudos notes are at most 280 characters"`). The agent must be non-killed.
  - `Store.awards(companyId: String, limit: Int = 50) -> [Award]` (newest first, the break room); `struct PerkSummary: Equatable, Sendable { var counts: [AwardKind: Int] /* last 30 days */; var streak: Int }`; `Store.perks(companyId:) -> [String: PerkSummary]` (by agent id).
  - CLI `KudosGroup` (command `kudos`, default `list`): `brahma kudos <company>` (`requireOwnerReader`) prints the newest 30 as `MM-dd HH:mm  <emoji>  @h  <title> — <note>` (sanitized); `brahma kudos give <company> @h <note…>` (`requireOwnerShell`) prints `⭐ Kudos to @h`.

- [ ] **Step 1: Write failing tests** in `AwardTests`:
```swift
@Test func coffeeAndStreakMilestones() throws { /* 5 first-pass completions for eng-1 (mgr-1-authored items with mgr-1 checks) → 5 coffee, streak awards at 3 and 5, firstPassStreak 5; a failed-first item → streak 0, no coffee */ }
@Test func mealForLargeUnderBudget() throws { /* L item, 10 turns/1_000_000 tokens at T1 (budget 30/3_000_000) → meal; 25 turns → none */ }
@Test func employeeOfTheSprint() { /* table: highest wtp eligible wins; flagged agent excluded; < 3 items excluded; tie → handle */ }
@Test func trophyAtClose() throws { /* PeopleWorld close → one trophy row with sprintId */ }
@Test func kudosIsOwnerOnly() throws { /* giveKudos ok; 281 chars → exact; no CompanyTools spec mentions kudos */ }
@Test func awardsNeverInPrompts() async throws {
  /* give every kind to eng-1; then TurnDigest.render(load(eng-1)), RolePrompt, ReviewDigest, ConsultDigest, list_agents result, show_work_item result
     → none contains any AwardKind emoji, "Kudos", "Coffee", "Employee of", "streak" */ }
@Test func breakRoomOrder() throws { /* awards newest first; perks counts last 30 days only */ }
```
  `PerfCLITests.kudosGiveAndList`: `kudos give Acme @eng-1 Great hand-off`, then `kudos Acme` contains `⭐  @eng-1  Kudos — Great hand-off`; with `BRAHMA_AGENT_ID` set, `give` exits 1.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "AwardTests|PerfCLITests"`. Expected: FAIL.
- [ ] **Step 3:** Implement awards, the observer, the cycle step, kudos and the CLI.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core,cli): cosmetic perks, owner kudos and the break room` with the trailer lines.

---

### Task 7: HR partner — reviews, warnings, PIPs, terminations with replacement

**Files:**
- Create: `Sources/BrahmaCore/People/HR.swift`, `Store/Store+HR.swift`, `Sources/brahma/HRCommands.swift`
- Modify: `Store/Migrations.swift` (`"v3b-hr"`), `Paths.swift` (`agentFile`, `perfDir`), `Perf/PeopleCycle.swift` (steps 4 and 7), `Store/Store+Decisions.swift` (`termination` effects), `MCP/PeopleTools.swift` (HR tools, `manager_feedback`), `Brahma.swift`
- Test: `Tests/BrahmaCoreTests/HRTests.swift`

**Interfaces:**
- Consumes: Task 5 `proposeDecision(approverId:ownerRequired:payload:)`, `DecisionEffects`, `PeopleRoles`, `FeedbackGuard`, `SystemFix`; Task 4 queued turns; Task 3 `PerformanceBand`, `setTrust`-style writes, `trustChange`; Task 2 snapshots and `meterReading`; 3a kill path (reaps leases, clears ownership, reparents reports), `Store.hire(db:…)`, `RoleCards`, `Handoff`, `ProgressFile`, `Store.latestHandoff`.
- Produces:
  - `BrahmaPaths` + `func agentFile(companyId: String, handle: String) -> URL /* companyDir/agents/<handle>.md */`, `func perfDir(companyId:) -> URL /* companyDir/perf */`. Agent files are owner-visible and never in the workspace.
  - Migration `"v3b-hr"`:
    - `performanceReview(id TEXT PK, companyId, agentId TEXT REFERENCES agent ON DELETE CASCADE, sprintId TEXT, authorId TEXT, summary TEXT, band TEXT, evidence TEXT NOT NULL DEFAULT '[]', createdAt)`, `UNIQUE(agentId, sprintId)`;
    - `managerNote(id INTEGER PK AUTOINCREMENT, companyId, agentId, authorId, note TEXT, createdAt)`;
    - `hrAction(id TEXT PK, companyId, number INT NOT NULL, agentId TEXT REFERENCES agent, kind TEXT, status TEXT, rootCause TEXT, evidence TEXT NOT NULL DEFAULT '[]', targets TEXT NOT NULL DEFAULT '[]', note TEXT, decisionId TEXT, sprintId TEXT, actorId TEXT, priorTrust TEXT, replacementId TEXT, createdAt, resolvedAt)`.
  - `enum HRActionKind: String, Codable, Comparable, Sendable { case none, warning, pip, termination /* ordered */ }`; `enum HRActionStatus: String, Codable, Sendable { case proposed, active, resolved, completed, rejected, reversed }`; `enum RootCause: String, Codable, Sendable { case agent, rolePrompt = "role_prompt", model, itemSize = "item_size", tooling }`; `struct HRAction` (columns, `var ref: String { "HR-\(number)" }`), `struct PerformanceReview`, `struct ManagerNote`.
  - `enum HRPolicy`:
    - `static func recommendation(bands: [(band: PerformanceBand, closedAt: Date)] /* newest first, insufficient removed */, active: [HRAction]) -> HRActionKind`. Only bands of sprints closed after an active action was created can escalate it:
```
active PIP p:      b = bands closed after p.createdAt; b.first ∈ {meets, strong} → none (Store resolves p); b.first == below → termination; b empty → none
active warning w:  b = bands closed after w.createdAt; b.first == below → pip; else none (meets/strong resolves w)
no active action:  bands[0] == below && bands[1] == below → pip; bands[0] == below → warning; else none
```
    - `static func pipTargets(reasons: [String]) -> [String]`, each mapped and always ending with `"at least 3 items done"`:
      - `"first-pass rate below 50%"` → `"first-pass rate at least 50%"`
      - `"2 or more escaped defects"` → `"at most 1 escaped defect"`
      - `"cost per item over 2× the type median"` → `"cost per item at most 2× the type median"`
      - `"2 or more watchdog escalations"` → `"at most 1 watchdog escalation"`
      - `"over 30% failed turns"` → `"at most 30% failed turns"`
      - `"2 or more budget overruns"` → `"at most 1 budget overrun"`
      - `"no items done in 10+ turns"` → `"at least 3 items done"`, deduplicated.
  - `enum RootCauseHints { static func compute(reading: MeterReading, outcomes: [ItemOutcome], peersBelowSameRole: Int, model: String) -> [String] }` gives engine hints:
    - `"item_size suspected: <k> items over budget"` (k ≥ 2);
    - `"role_prompt suspected: <k> other <role>s also below the bar"` (k ≥ 1);
    - `"tooling suspected: <k> failed turns"` (failedTurns ≥ 3);
    - `"model suspected: L items on haiku"`.
  - `HR.sprintClosed(db:store:sprint:now:)` (PeopleCycle step 4). For each sprint agent, it computes the recommendation from its snapshot bands and stores it in the HR ceremony payload. A PIP whose agent's newest band is meets or strong becomes `resolved` (system DM to its manager `"@<h> met the PIP targets (HR-<n>)."`). A warning is resolved on a meets or strong band. Some sprint agents need no HR attention: recommendation `none`, no active action, and a band other than `below`. Each of them gets an engine-written review (`authorId "system"`, summary `"Engine review: <band>; no HR attention needed."`, with the same evidence and agent-file section). Step 7 enqueues `hrReview` turns for `PeopleRoles.agent(.hr)` covering only the remaining agents, minus the HR agent. They come in batches of 25 (subject `<sprintId>:<batch>`, batches numbered from 1), and nothing is enqueued when no agent remains. When the HR agent is itself a sprint agent, a second `hrReview` with that single subject goes to the HR agent's manager (else the CEO-cover).
  - `HRDigest.render(subjects: [(agent, roleTitle, trust, band, reasons, reading, managerNotes: [ManagerNote], activeActions: [HRAction], recommendation: HRActionKind, hints: [String])], sprintName:)` with `HRHandler` (tools `show_work_item, write_performance_review, hr_action, propose_system_fix`). The digest is capped at 60 000 chars (manager notes: the last 5 per subject, 300 chars each). `instructions` (exact): `"You are the HR partner. For each agent listed, write a performance review from the engine's meter and the manager's notes, then record one hr_action. Root cause first: if the cause is the system (role prompt, model, item size, tooling), choose action none and call propose_system_fix instead of disciplining the agent. Actions can never exceed the engine's recommendation, and every action cites the meter evidence attached by the engine."`. The ceremony is done when every subject has both a review for this sprint and an hr_action.
  - Tools:
    - `write_performance_review {agent, summary}`. It refuses self (`"you can't review yourself"`) and non-subjects (`"@<h> is not part of this review"`). It inserts the row with the engine `evidence` (`"band: <band>"`, reasons, key meter lines) and appends `## <name> review by @<hr> (<yyyy-MM-dd>)\nBand: <band>\n<evidence lines>\n<summary>` to the agent file.
    - `hr_action {agent, action: "none"|"warning"|"pip"|"terminate", root_cause, note, corrective_note?}` first applies the same checks as `write_performance_review` (self, non-subject, killed, cross-company), and `note` passes `FeedbackGuard`. Then:
      - an action above the recommendation → `"the meter supports at most <rec> for @<h> this sprint"`;
      - root_cause ≠ `agent` with an action ≠ none → `"root cause is <x>; fix the system with propose_system_fix instead of disciplining @<h>"`;
      - a subject that is an executive kind or an ancestor of the HR agent → the action is recorded `proposed` with a decision and runs only when the owner approves:
        - a warning or PIP uses `kind: .other` (title `"HR: <action> for @<h>"`, no internal approver, `ownerRequired: true`, payload `{hrActionId}`); `DecisionEffects` for `.other` executes the HR action when the payload has `hrActionId`, and is otherwise record-only;
        - a termination uses `kind: .termination` with `ownerRequired: true` and no internal approver;
      - `warning` requires `corrective_note` (through `FeedbackGuard`), appended to the workspace notes under `## <name> feedback`; status `active`; system DM to the manager `"HR-<n>: warning for @<h>: <note…1>"`;
      - `pip`: `priorTrust` saved; trust → T0 (a `trustChange` with actor `hr:<id>`, reason `"PIP HR-<n>"`, `trustPinned` cleared, and if it was set the owner gets the system DM `"HR-<n> put @<h> on a PIP; their trust pin was cleared."`); `targets = pipTargets(reasons)`; workspace notes get `## Performance improvement plan (HR-<n>)` with one `- <target>` line each; status `active`; DM to the manager;
      - `terminate` → `termination` decision (`approverId` = the subject's manager if non-killed and not the HR agent, else none with `ownerRequired: true`; payload `{hrActionId}`); action status `proposed`.
    - `propose_system_fix {subject, kind: "prompt"|"model"|"item_size"|"tooling", change, reason}` → `systemFix` decision under normal routing (the same `SystemFix.apply`).
    - `manager_feedback {agent, note}` (lead tools) is limited to the caller's reports subtree (`"@<h> is not in your reporting line"`), refuses self (`"you can't give feedback on yourself"`) and goes into the HR digest.
  - Termination effect (`DecisionEffects` for `termination`, on `approved`) → `Store.terminate(db:hrActionId:now:) throws -> Agent /* the replacement */`, in order:
    0. Capture the departing agent's open items (non-done items whose `ownerId` is that agent) **before** the kill, because the kill clears `ownerId`.
    1. Write the departure hand-off `<workspace>/.brahma/handoffs/departures/<handle>-<yyyyMMdd-HHmmss>.md`, with sections `## Reason` (HR ref, root cause, evidence lines), `## Open work` (each captured item: `- <KEY> <title> (<status>) progress: <path> hand-off: <path|none>`) and `## Lessons` (the agent's workspace notes, last 4000 chars).
    2. Kill through the 3a path.
    3. Hire the replacement through `Store.hire(db:…)`: same role, team, manager and model; trust T1; handle = next free `<prefix>-<n>`; its role card file is a copy of the departed agent's card file (owner edits and coaching appends carry over).
    4. Assign the captured items to the replacement (event `assigned` `"reassigned from @<old> (terminated)"`).
    5. Send the replacement the system DM `"Welcome. You replace @<old>. Read <hand-off path> first. Your items: <KEYs|none>."`.
    6. Mark the action `completed` with `replacementId`; `ActivityEvent(.people)`.

    A rejected decision marks the action `rejected`.
  - `Store.reverseHRAction(companyId: String, ref: String, note: String?, now:) throws -> HRAction` is owner only:
    - active warning → `reversed`;
    - active pip → `reversed`, trust restored to `priorTrust` (actor owner);
    - proposed → its decision rejected through `ownerDecide(approve: false)`, then `reversed`;
    - completed termination → **reinstate**: hire a new agent with the departed role, team, manager, model, `priorTrust` (else T1), copied role card, and `sessionId`/`sessionStarted` copied from the departed row so its Claude conversation resumes; handle = next free; then `reversed`.

    Anything else → `.conflict("HR-<n> is already <status>")`.
  - `Store.hrActions(companyId:statuses:) -> [HRAction]`, `Store.reviews(companyId:sprintId:) -> [PerformanceReview]`.
  - CLI `HRGroup` (command `hr`, default `summary`; reads use `requireOwnerReader`, writes use `requireOwnerShell`):
    - `brahma hr <company>` prints `Reviews: <k> this sprint`, then `Active:` lines `HR-<n>  <kind>  @h  <rootCause>  <note…1>` (PIP targets indented), then `Pending terminations:` lines `HR-<n>  @h  D-<m>  waiting on <@h|the owner>`;
    - `brahma hr show <company> @h` prints the agent file;
    - `brahma hr reverse <company> HR-<n> [--note]` prints `HR-<n> reversed` (and `reinstated as @<h>`);
    - `brahma hr setup <company> [--perf] [--visionary]` hires `hr-<n>` (role `hr`) and optionally `perf-<n>` (role `perf`), both with manager = CEO-cover, and `vis-<n>` (role `visionary`, manager = CPO-cover), printing each handle.

- [ ] **Step 1: Write failing tests** in `HRTests` (PeopleWorld; bands are forced through outcomes):
```swift
@Test func recommendationTable() { /* [below] → warning; [below, below] → pip; warning at t + [below after t] → pip; warning at t + only [below before t] → none; pip at t + [below after t] → termination; pip at t + [meets after t] → none; pip at t + nothing after t → none; [] → none */ }
@Test func noActionWithoutEvidence() throws { /* insufficient sprints only → recommendation none; hr_action warning → "the meter supports at most none for @eng-1 this sprint" */ }
@Test func onlyFlaggedAgentsReachHR() throws { /* team-1 with eng-1 below, others meets → hrReview subjects == [eng-1]; the other 5 get engine reviews "Engine review: meets; no HR attention needed."; 60 flagged agents → 3 queued turns, subjects "<sprintId>:1"…":3" */ }
@Test func reviewCeremonyWritesAgentFile() throws { /* close (eng-1 below) → hrReview queued for hr-1 (after hr setup) with subject eng-1; write_performance_review → agentFile contains "## Sprint 1 review by @hr-1" and "Band: below"; workspace has no such text */ }
@Test func warningThenPip() throws {
  /* below S1 → warning with corrective note → notes "## Sprint 1 feedback"; below S2 → pip → trust T0, notes "## Performance improvement plan (HR-2)" with "- first-pass rate at least 50%" and "- at least 3 items done" */ }
@Test func systemRootCauseBlocksDiscipline() throws { /* root_cause item_size + warning → exact refusal; propose_system_fix → systemFix decision */ }
@Test func guardrailTargets() throws {
  /* self → "you can't review yourself"; subject ceo → hr_action recorded proposed with ownerRequired decision, trust unchanged until owner approves;
     manager_feedback on non-report → exact; on self → exact; killed subject → "@eng-1 is not part of this review"; hr_action on self, a non-subject or a killed agent → the same messages; hr_action note "bottom of the team" → FeedbackGuard refusal;
     the owner approves the ceo warning → the .other effect runs it (hrAction active); ceo terminate → decision kind termination, ownerRequired, no internal approver */ }
@Test func pipClearsPinAndTellsOwner() throws { /* setTrust T2 pinned; PIP → T0, trustPinned false, owner DM exact */ }
@Test func terminationNeedsManagerThenOwner() throws {
  /* active PIP, below again → terminate → decision termination internalApproverId mgr-1; mgr-1 decide approve → pendingOwner (auto off);
     autoMode on variant → approved immediately on mgr-1's approval */ }
@Test func terminationReplacesWithHandoff() throws {
  /* eng-2 owns ACME-3 (inProgress, leased) → terminate approved by owner → eng-2 killed, lease nil; replacement "eng-5" (next free) same team/manager, T1, sessionStarted false;
     ACME-3 ownerId replacement (captured before the kill cleared it); departure file has "## Open work" with "ACME-3" and "## Lessons"; replacement role card == eng-2's card text; welcome DM exact */ }
@Test func reverseExecutedTerminationReinstates() throws { /* reverse → new agent with eng-2's sessionId, sessionStarted true, trust == priorTrust; action reversed; second reverse → "HR-3 is already reversed" */ }
@Test func reversePipRestoresTrust() throws { /* T2 → PIP T0 → reverse → T2 */ }
@Test func pipResolvedWhenTargetsMet() throws { /* PIP then meets sprint → resolved, mgr DM "met the PIP targets"; trust stays T0 until the ladder promotes */ }
@Test func crossCompanyActionRefused() throws { /* Globex HR hr_action on Acme agent handle → "not in your company" */ }
```
  `PerfCLITests.hrSummaryAndSetup`: `hr setup Acme --perf` prints `@hr-1` and `@perf-1`; `hr Acme` prints `Reviews: 0 this sprint`; both refuse under `BRAHMA_AGENT_ID`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "HRTests|PerfCLITests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the HR model, policy, cycle steps, ceremony, tools, termination, reversal and CLI.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core,cli): HR partner with root-cause-first reviews, PIPs and owner-reversible terminations` with the trailer lines.

---

### Task 8: Ideas pipeline and visionaries

**Files:**
- Create: `Sources/BrahmaCore/Ideas/Idea.swift`, `Store/Store+Ideas.swift`, `MCP/IdeaTools.swift`, `Sources/brahma/IdeaCommands.swift`
- Modify: `Store/Migrations.swift` (`"v3b-ideas"`), `Model/Agent.swift` (`visionary`), `Store/Store+WorkItems.swift` (type `idea` only via `proposeIdea`), `Store/Store.swift` (`builtinObservers` + `IdeaObserver`), `Store/Store+Decisions.swift` (`idea` effects), `Perf/PeopleCycle.swift` (step 8), `Store/Store+Meter.swift` (idea facts), `Orchestrator.swift` (`endTurn` research budget), `Turns/TurnDigest.swift` (research line), `Sources/brahma/AgentCommands.swift` (`hire --visionary`), `Brahma.swift`
- Test: `Tests/BrahmaCoreTests/IdeaTests.swift`

**Interfaces:**
- Consumes: Task 5 `proposeDecision(internallyApprovedBy:ownerRequired:payload:)`, `DecisionEffects`, `PeopleRoles.cover`; Task 4 queued turns; Task 6 `AwardKind.idea`; Task 3 container-lead rule; 3a `createWorkItem`, `commentWorkItem`, `itemEvents`, Plan 1 FTS5 usage (`messageFts`).
- Produces:
  - Migration `"v3b-ideas"`:
    - `idea(itemId TEXT PK REFERENCES workItem ON DELETE CASCADE, companyId, filerId TEXT /* agent id or "owner" */, problem, proposal, impact, cost, evidence TEXT NOT NULL DEFAULT '', risks TEXT NOT NULL DEFAULT '', scope TEXT NOT NULL DEFAULT 'team', status TEXT NOT NULL, reach INT, impactScore REAL, confidence REAL, effort REAL, rice REAL, scoreReason TEXT, triageNote TEXT, triagedById TEXT, triagedAt, duplicates TEXT NOT NULL DEFAULT '[]', outcomeReason TEXT, decisionId TEXT, epicId TEXT, prototypeItemId TEXT, lastReviewedAt, createdAt, updatedAt)`;
    - `CREATE VIRTUAL TABLE workItemFts USING fts5(title, description, content='workItem', content_rowid='rowid')`, with insert/update/delete triggers mirroring Plan 1's `messageFts`, then `INSERT INTO workItemFts(workItemFts) VALUES('rebuild')`;
    - `agent` + `visionary BOOLEAN NOT NULL DEFAULT 0`.
  - `enum IdeaStatus: String, Codable, CaseIterable, Sendable { case open, triaged, prototyping, approved, parked, rejected, shipped; var title: String; static let openSet: Set<IdeaStatus> = [.open, .triaged, .prototyping] }`; `enum IdeaOutcome: String, Sendable { case approve, prototype, park, reject }`; `struct IdeaDraft: Sendable { var title, problem, proposal, impact, cost: String; var evidence = ""; var risks = ""; var scope = "team" }`; `struct Idea` (columns).
  - `enum IdeaPolicy { static let openQuota = 3; static let reviewTopN = 5; static let ownerEffortThreshold = 2.0; static let prototypeTokens = 300_000; static let noEvidenceConfidenceCap = 0.5; static let reviewMinInterval: TimeInterval = 86_400; static let researchTokens = 500_000; static let impactValues: Set<Double> = [0.25, 0.5, 1, 2, 3] }`
  - `protocol KnowledgeSearching: Sendable { func similar(companyId: String, text: String, limit: Int) -> [String] /* titles */ }`. `Store` + `var knowledge: (any KnowledgeSearching)? = nil` (Plan 9 plugs in).
  - `Store.similarItems(companyId: String, text: String, excluding: String?, limit: Int = 3) throws -> [WorkItem]`: FTS5 `MATCH` over the sanitized OR-joined tokens (alphanumeric runs of ≥ 3 chars, lowercased, the first 12, each double-quoted), ordered by `bm25`, same company only.
  - `Store.proposeIdea(companyId: String, by: Sender, draft: IdeaDraft, now:) throws -> (WorkItem, Idea, [WorkItem])`:
    - Validation: title, problem and proposal non-blank; every field ≤ 2000 chars; scope `team|company`.
    - Agent quota → `"you have 3 open ideas (<KEY>, <KEY>, <KEY>); wait for their review before filing more"`.
    - It creates a `workItem` (type `idea`, status `backlog`, author = filer, description = `Problem:\n…\n\nProposal:\n…\n\nImpact: …\nCost: …\nEvidence: …\nRisks: …`) through an internal path. `createWorkItem` with type `idea` from any other caller → `"file ideas with propose_idea"`.
    - The idea row has status `open` and `duplicates` = the keys from `similarItems` (plus knowledge titles).
    - The triager gets a notice (event `created`, `alsoNotify`): the filer's manager for `team` scope, else the CPO-cover; owner-filed ideas → CPO-cover.
  - `Store.triageIdea(itemId: String, by: Sender, note: String, reach: Int, impact: Double, confidence: Double, effort: Double, reasoning: String, now:) throws -> Idea`:
    - Allowed for the filer's manager, any manager or executive kind, or the owner (`"only the filer's manager, a manager, an executive or the owner can triage ideas"`), but never the filer itself (`"you filed <KEY>; someone else triages it"`).
    - Validation: reach 1...10 000; impact ∈ `impactValues`; confidence in (0, 1]; effort in (0, 50]; note and reasoning non-blank.
    - Confidence is capped at 0.5 when `evidence` is blank, and the reason then gets `" (confidence capped at 0.5: no evidence)"`.
    - `rice = reach × impact × confidence / effort`; status `triaged`.
  - `Ideas.sprintClosed(db:store:sprint:now:)` (PeopleCycle step 8):
    1. Enqueue `ideaReview` for the CEO-cover when there is at least one `triaged` idea or a `prototyping` idea whose `lastReviewedAt` is nil or before `sprint.startedAt`, unless an `ideaReview` is queued or running or one finished within 24 h. The payload holds the top 5 keys (prototyping first, then rice desc). Ideas the CEO-cover filed are left out of its payload and go into a second `ideaReview` for the first other non-killed executive. When there is none, the owner gets the system DM `"Idea review needed from you: <KEYs> (filed by @<h>)."`.
    2. Send a system DM to each triager with `open` ideas older than `sprint.startedAt`: `"Ideas waiting for triage: <KEYs>."`.
    3. Start a new research period for visionaries: ready any agent blocked `.owner(reason: "research budget used until the next sprint closes")`, and send each visionary the DM `"New research period: <500>k tokens. File what you find with propose_idea."`.
  - `IdeaDigest.render(ideas: [(item, idea, filerHandle, comments: [WorkItemEvent], prototype: WorkItem?)])` lists each idea with key, title, filer, `RICE <r> = reach × impact × confidence / effort`, reasoning, triage note, the quoted problem/proposal/evidence/risks/cost, duplicates, the last 5 comments (quoted) and the prototype status with its hand-off path. `IdeaReviewHandler` (tools `show_work_item, comment_work_item, decide_idea`) has `instructions` (exact): `"You chair the C-suite Idea review. The CPO and CTO comment on idea items before this review. For each idea listed, decide: approve (becomes an epic; credit the filer and name a lead), prototype (a small spike to gather evidence), park (keep it, with a reason) or reject (with a reason the filer will read)."`. The turn is done when every listed key has a decision.
  - Tools:
    - `propose_idea {title, problem, proposal, impact, cost, evidence?, risks?, scope?}` (work) returns `"Filed <KEY> on the Ideas board; triage by @<h>."` plus, if any, `" Possible duplicates: <KEY> (<title…1>), …"`.
    - `triage_idea {key, note, reach, impact, confidence, effort, reasoning}` (lead).
    - `decide_idea {key, outcome, reason, lead?: @h, prototype_tokens?}` (ceremony) → `Store.decideIdea(itemId:by:outcome:reason:leadId:prototypeTokens:now:)`. The decider may never be the filer (`"you filed <KEY>; another executive decides it"`), so `internallyApprovedBy` is never the filer and Auto mode cannot approve an idea on its filer's word alone:
      - park or reject → status set, `outcomeReason`, `lastReviewedAt`, and a DM to the filer `"<KEY> <parked|rejected> by @<h>: <reason…1>"`;
      - approve or prototype → `proposeDecision(kind: .idea, by: decider, title: "Idea <KEY>: <outcome> — <title…1>", summary: reason, subjectId: itemId, internallyApprovedBy: decider, ownerRequired: effort ≥ 2.0, payload: {outcome, leadId, prototypeTokens})`. `lastReviewedAt` is set and the result names the decision.
  - `idea` decision effects:
    - approved approve → an epic created by `system` (title = idea title, description = proposal + `"\n\nFrom idea <KEY> by @<filer>"`, `ownerId` = lead). The default lead is the filer if the filer is a manager or executive kind or at T2+, else the filer's manager; the lead must pass Task 3's container rule (`"leading <KEY> needs trust T2 or higher"`). Then `status approved`, `epicId`, and a DM to the filer `"<KEY> approved: epic <EKEY>, lead @<h>."`.
    - approved prototype → a spike `"Prototype: <title>"` (tier S, owner = filer, created by system), `prototypeItemId`, `status prototyping`, and a DM to the filer.
    - rejected (owner) → status back to `triaged`, plus a DM to the filer with the owner note.
  - Owner fast-track: `Store.ownerDecideIdea(itemId:outcome:reason:leadId:now:)` creates the decision already approved by the owner (`decidedBy "owner"`) and applies the effects; it is used by the CLI and the app.
  - `struct IdeaObserver: WorkItemObserver` (built-in): when a completed epic is some idea's `epicId` → idea `shipped`, plus a `💡` award to the filer (if an agent) with note `"<KEY> shipped as <EKEY>"`.
  - Ideas stay out of work:
    - `planSprint` refuses an idea key with `"<KEY> is an idea; approve it into an epic first"`;
    - `list_work` gains `type?: string` and excludes type `idea` unless `type == "idea"`;
    - Task 11 excludes ideas from 3a's `ItemRows.backlog` and `BoardColumns.make`.
  - Meter: the idea facts fill `ideasFiled` (created in the window), `ideasApproved` (status approved or shipped, decided in the window) and `ideasShipped`. Rejected ideas are never counted.
  - Visionaries: `Agent` + `var visionary: Bool = false`; `isVisionary` = `visionary || role == "visionary"`. In `endTurn` for a visionary's succeeded work turn with `itemId == nil`, research usage = Σ counted tokens of its no-item work turns since the period start (latest company sprint `closedAt`, else agent `createdAt`). At ≥ 500 000 the agent ends `blocked(.owner(reason: "research budget used until the next sprint closes"))`. `TurnDigest` adds `Research budget: <k>k/500k tokens this period` for visionaries. CLI `brahma hire … --visionary`.
  - CLI `IdeaGroup` (command `ideas`, default `board`):
    - `brahma ideas <company>` prints status sections (`## Open (n)` …) of `KEY  RICE <r|—>  @filer  title`;
    - `ideas show <company> KEY`;
    - `ideas add <company> --title … --problem … --proposal … --impact … --cost … [--evidence] [--risks] [--scope team|company]` (owner);
    - `ideas triage <company> KEY --reach --impact --confidence --effort --note --reasoning` (owner);
    - `ideas decide <company> KEY approve|prototype|park|reject --reason r [--lead @h]` (owner fast-track).

    Writes use `requireOwnerShell`; reads (`ideas`, `ideas show`) use `requireOwnerReader`.

- [ ] **Step 1: Write failing tests** in `IdeaTests`:
```swift
@Test func proposeIdeaLandsOnBoardNotDMs() throws { /* eng-1 propose_idea → KEY type idea, status backlog, idea open; mgr-1 has a work notice; no DM to any executive */ }
@Test func duplicateCheckFindsSimilarItems() throws { /* existing task "Offline sync for habits" → idea "Habit offline sync" result contains "Possible duplicates: ACME-1 (Offline sync for habits)"; punctuation-only text → no crash, no duplicates */ }
@Test func openIdeaQuota() throws { /* 3 open → 4th exact message; owner unlimited; after one parked → allowed */ }
@Test func createWorkItemRefusesIdeaType() throws { /* create_work_item type idea → "file ideas with propose_idea" */ }
@Test func triageScoresRice() throws { /* reach 100, impact 2, confidence 0.8, effort 4, evidence "link" → rice 40; no evidence → confidence 0.5, rice 25, reason has cap note; impact 1.5 → invalid; eng-2 → forbidden; mgr-1 triaging its own idea → "you filed <KEY>; someone else triages it" */ }
@Test func filerNeverDecidesOwnIdea() throws { /* ceo files an idea; close → ceo's ideaReview excludes it, a second ideaReview for cpo includes it; ceo decide_idea on it → exact refusal; only ceo alive → owner DM "Idea review needed from you" */ }
@Test func ideasStayOutOfWork() throws { /* planSprint with an idea key → "<KEY> is an idea; approve it into an epic first"; list_work scope all excludes ideas; list_work type "idea" lists them */ }
@Test func reviewCeremonyAtSprintClose() throws { /* 6 triaged ideas → ideaReview for ceo, payload top 5 by rice; second close within 24 h → none queued */ }
@Test func approveCreatesEpicWithLeadAfterOwner() throws {
  /* decide_idea approve lead @mgr-1, effort 1 → decision idea pendingOwner (auto off); owner approves → epic "From idea ACME-2 by @eng-1", owner mgr-1, idea approved; filer DM exact */ }
@Test func costThresholdAlwaysOwner() throws { /* effort 3, autoMode on → pendingOwner; effort 1 auto → approved immediately */ }
@Test func prototypeSpikeAndRevisit() throws { /* prototype → spike tier S owner filer, status prototyping; next close → included in review again */ }
@Test func parkAndRejectTellFiler() throws { /* reason DM'd exact; not gated */ }
@Test func shippedIdeaEarnsPerk() throws { /* epic rolls up done → idea shipped, award idea for filer */ }
@Test func ownerFastTrack() throws { /* ownerDecideIdea approve → epic exists, decision decidedBy owner */ }
@Test func visionaryResearchBudget() async throws { /* visionary no-item turns totalling 500_000 → blocked with exact reason; sprint close → ready + DM "New research period" */ }
@Test func crossCompanyTriageRefused() throws { /* Globex mgr triage_idea Acme key → "not in your company" */ }
```
  `PerfCLITests.ideasBoard`: `ideas add Acme …` prints `ACME-1`, and `ideas Acme` shows `## Open (1)` and `ACME-1  RICE —  @owner`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "IdeaTests|PerfCLITests"`. Expected: FAIL.
- [ ] **Step 3:** Implement ideas, FTS, triage, the ceremony, decisions, the observer, the research budget and the CLI.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core,cli): ideas pipeline with triage, RICE, C-suite review and visionary budgets` with the trailer lines.

---

### Task 9: Driver + navigator pairing and competing hypotheses

**Files:**
- Create: `Sources/BrahmaCore/Work/Pairing.swift`, `Store/Store+Pairing.swift`, `MCP/PairingTools.swift`
- Modify: `Store/Migrations.swift` (`"v3b-pairing"`), `Model/WorkItem.swift` (`navigatorId`, `pairing`, `riskTags`, `navigatedManifest`; draft/patch), `Work/WorkPolicy.swift` (`WorkField.pairing, .riskTags, .navigator` are spec fields), `Model/Company.swift` (`pairingInLow`), `Store/Store+Leases.swift` (navigator at claim; navigator can't claim), `Orchestrator.swift` (scan after a driver turn, enqueue navigation), `MCP/WorkTools.swift` (`pairing`, `risk_tags`, `navigator` args; `show_work_item` shows navigator), `Turns/TurnDigest.swift` (`Navigator: @h` line), `Sources/brahma/ItemCommands.swift` (`--pairing`, `--risk`), `CompanyCommands.swift` (`company pairing-in-low on|off`)
- Test: `Tests/BrahmaCoreTests/PairingTests.swift`

**Interfaces:**
- Consumes: Task 4 `enqueueTurn`, `QueuedTurnHandler`; Task 3 `TrustLevel.canNavigate`, `.requiresPairing`; 3a `PathManifest.scan/diff`, `FileStamp`, `claimLease`, `latestVerification`, `ProgressFile`, `MessageRouter.post(db:…)`, `create_channel` semantics.
- Produces:
  - Migration `"v3b-pairing"`: `workItem` + `navigatorId TEXT`, `pairing TEXT NOT NULL DEFAULT 'auto'`, `riskTags TEXT NOT NULL DEFAULT '[]'`, `navigatedManifest TEXT`; `company` + `pairingInLow BOOLEAN NOT NULL DEFAULT 0`.
  - `enum PairingMode: String, Codable, Sendable { case auto, on, off }`; `WorkItem` + `var navigatorId: String? = nil; var pairing: PairingMode = .auto; var riskTags: [String] = []; var navigatedManifest: [String: FileStamp]? = nil`. `Company` + `var pairingInLow: Bool = false`.
  - Invariants: the navigator ≠ owner and ≠ reviewer (`"an item's navigator must be someone other than its assignee and reviewer"`); the navigator must have `trust.canNavigate` (`"@<h> needs trust T2 or higher to navigate"`); `claimLease` by the item's navigator → `"you are this item's navigator; navigators don't write"`.
  - `enum PairingPolicy { static let riskTags: Set<String> = ["security", "concurrency", "architecture"]; static func required(item: WorkItem, ownerTrust: TrustLevel, mode: UsageMode, pairingInLow: Bool) -> Bool; static func pickNavigator(candidates: [Agent], item: WorkItem, load: [String: Int]) -> Agent? }`:
```
ownerTrust == .t0 → true
item.pairing == .off → false
mode == .low && !pairingInLow → false
item.pairing == .on → true
mode == .max → item.tier == .l || !riskTags ∩ item.riskTags isEmpty
mode == .balanced → false            // opt-in only
mode == .low (pairingInLow) → item.tier == .l || risk
```
    `pickNavigator` picks from non-killed, non-paused agents in the item's team (else the owner's team), excluding the owner and reviewer, with `canNavigate`. It sorts by fewest current navigations (non-done items with `navigatorId` = them), then handle.
  - At `claimLease` (same transaction): if `required` and `navigatorId == nil`, set `navigatorId = pickNavigator ?? nil`, event `assigned` `"navigator @<h>"` (`alsoNotify` the navigator). When none is found: event `commented` `"pairing required but no T2+ navigator is available"` plus a system DM to the owner's manager.
  - Navigator turns: after a driver's **succeeded work turn** on an item with a navigator, the orchestrator scans the item's declared check paths (outside the transaction; skipped on `tooManyFiles`). If the scan differs from `navigatedManifest`, it enqueues `navigate` for the navigator (subject = the item; payload = the scan JSON; deduplicated per item). `NavigateHandler`:
    - tools `show_work_item, comment_work_item, navigator_note`;
    - the prompt is `NavigatorDigest.render(item:changed:latestRun:progressPath:driverHandle:)`, holding the item spec, criteria, check, last run, progress file path and the changed paths since the last navigation (added/removed/modified, max 100 each). It holds no messages.
    - `instructions` (exact): `"You are the navigator on this item: read-only, clean context. You see the spec and what changed since your last look, not the driver's conversation. Inspect files and run tests, but do not edit files and do not claim the item. Leave concrete notes with navigator_note; use severity blocker only for something that must not ship."`
    - On the `navigator_note` call or at turn success, `navigatedManifest` = the payload scan.

    Navigator turns never count toward the driver's item budget.
  - Tool `navigator_note {key, note, severity: "info"|"concern"|"blocker"}` (ceremony list; only the item's navigator) → event `commented` with text `"[navigator <severity>] <note>"`, which notifies the driver. `blocker` also appends review flag `"navigator blocker: <note…1, ≤ 120 chars>"`. It completes the queued turn.
  - Tool `start_hypotheses {key, question, agents: [@h]}` (lead tools; also allowed for the item's owner). It takes 2–3 distinct, non-killed same-company agents (`"competing hypotheses need 2 or 3 agents"`). It creates channel `hyp-<key lowercased>` (caller + agents; an existing name gets `-2`…), posts `HypothesesTemplate.render(key:question:assignments:)` from system (exact text below), comments on the item `"competing hypotheses in #hyp-…"`, and sends each participant the system DM `"You hold hypothesis <A|B|C> for <KEY> in #<channel>."`. It returns `"Started #<channel>."`.
```
Competing hypotheses for <KEY>: <question…1>
Rules: each of you owns one hypothesis. Before anyone writes a fix:
1. Post your hypothesis and the cheapest test that would disprove it.
2. Try to disprove the others' hypotheses; post evidence (commands, paths), not opinions.
3. A hypothesis survives only if nobody disproved it. The item's owner writes the fix for the survivor.
Assigned: @a → A, @b → B[, @c → C]
```
  - Tools `create_work_item`/`update_work_item` gain `pairing: "auto"|"on"|"off"`, `risk_tags: [string]` (each ∈ `riskTags`, else `"risk tags are security, concurrency, architecture"`) and `navigator: @h|"none"`. CLI `items add|edit --pairing … --risk …`; `brahma company pairing-in-low <company> on|off` (owner).

- [ ] **Step 1: Write failing tests** in `PairingTests`:
```swift
@Test(arguments: [/* (trust, pairing, mode, inLow, tier, risk, expected) */
  (TrustLevel.t0, PairingMode.off, UsageMode.low, false, EffortTier.s, [String](), true),
  (.t1, .auto, .max, false, .l, [], true), (.t1, .auto, .max, false, .m, ["security"], true), (.t1, .auto, .max, false, .m, [], false),
  (.t1, .auto, .balanced, false, .l, [], false), (.t1, .on, .balanced, false, .s, [], true), (.t1, .on, .low, false, .s, [], false),
  (.t1, .auto, .low, true, .l, [], true), (.t2, .off, .max, false, .l, ["security"], false)])
func pairingDefaults(...) { /* PairingPolicy.required == expected */ }
@Test func navigatorPickedAtClaim() throws { /* Max mode, L item; eng-2 T2, eng-3 T2 with 1 navigation → navigatorId eng-2; event "navigator @eng-2"; T1-only team → no navigator, comment + mgr DM */ }
@Test func navigatorCannotWrite() throws { /* eng-2 claim_lease → exact message; set navigator = owner → exact invariant message; T1 navigator → "@eng-4 needs trust T2 or higher to navigate" */ }
@Test func navigatorTurnAfterDriverChange() async throws {
  /* driver turn writes a file under declared paths → navigate queued for eng-2; cycle → eng-2 fresh session, prompt lists the changed path, no "SECRET-DRIVER-CHAT";
     navigator_note concern → driver notice "[navigator concern] …"; no change on next driver turn → no new navigate */ }
@Test func blockerNoteFlagsItem() throws { /* severity blocker → reviewFlags contains "navigator blocker: …"; light review then impossible */ }
@Test func navigatorTurnsNotInDriverBudget() async throws { /* itemUsage unchanged after a navigate turn */ }
@Test func probationAlwaysPairs() throws { /* T0 owner, Low mode, pairing off → navigator assigned */ }
@Test func hypothesesTemplate() throws { /* start_hypotheses with @eng-2,@eng-3 → channel hyp-acme-1 members, system post equals template exactly, DMs "You hold hypothesis A for ACME-1 in #hyp-acme-1."; 1 agent → exact error */ }
@Test func crossCompanyNavigatorRefused() throws { /* update navigator to a Globex handle → "not in your company" */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PairingTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the fields, the policy, navigator assignment, the navigator turns and both tools.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core): driver/navigator pairing with clean-context navigator turns and competing hypotheses` with the trailer lines.

---

### Task 10: Staffing tools, channel post limits and interface contracts

**Files:**
- Create: `Sources/BrahmaCore/People/Staffing.swift`, `Store/Store+Staffing.swift`, `Messaging/RateLimit.swift`, `Work/Contracts.swift`, `Store/Store+Contracts.swift`, `MCP/ContractTools.swift`
- Modify: `Store/Migrations.swift` (`"v3b-staffing-contracts"`), `Messaging/MessageRouter.swift` (rate limit), `MCP/PeopleTools.swift` (staffing tools), `Store/Store+Decisions.swift` (`staffing` effects), `Store/Store+Verification.swift` (contract check at submit), `Turns/TurnDigest.swift` (`Contracts:` line)
- Test: `Tests/BrahmaCoreTests/StaffingTests.swift`, `ContractTests.swift`

**Interfaces:**
- Consumes: Task 5 `proposeDecision(ownerRequired:payload:)`, `DecisionEffects`; Task 3 `hire(… trust:)`; 3a `Store.hire(db:…)`, `setManager`, `setTeam`, kill path, `reports`, `OrgShape`, `PathManifest.diff`, `submitForReview`, review flags, `rolesCovering`.
- Produces:
  - `enum ChannelRateLimit { static let postsPerHour = 12; static let window: TimeInterval = 3600 }`. `MessageRouter.post` (and `post(db:)`) with an `.agent` sender counts that agent's messages in non-DM channels created in the last hour. At ≥ 12 it throws `RouterError.rateLimited(count: Int)`, whose tool text is `"rate limit: you posted 12 channel messages in the last hour (limit 12). Put details in the work item and reference it, or DM the one person who needs it."`. DMs, owner and system are exempt.
  - `enum StaffingPolicy { static let companyCap = 500; static let teamCap = 8; static let hiresPerDay = 3 }`; `enum StaffingAction: Codable, Equatable, Sendable { case hire(role: String, team: String?, managerId: String?), kill(agentId: String), reassign(agentId: String, managerId: String??, team: String??) }`.
  - `Store.requestStaffing(companyId: String, by agentId: String, action: StaffingAction, reason: String, now:) throws -> Decision` checks authority and caps first. Exact refusals:
    - acting on yourself → `"you can't hire, remove or move yourself"`
    - an executive subject (kill or reassign) → `"only the owner can remove or move an executive"`
    - a subject outside the reports subtree for manager kinds → `"@<h> is not in your reporting line"`
    - a manager hiring into a team other than one in its subtree → `"you can hire only into your own teams"`
    - an unknown role → `"unknown role <r>"`
    - a role outside the hire allow-list (individual-kind roles only, never `hr`, `perf`, `visionary`, executive or architect roles) → `"hire_agent can hire only individual contributors; ask the owner for a <role>"`
    - an explicit `manager` that is neither the requester nor in its reports subtree → `"@<h> is not in your reporting line"` (for HR, the CEO-cover or its subtree). With no `manager`, the default is the requester for manager and executive kinds, and the CEO-cover for HR, so a hire never becomes an unmanaged root
    - the company cap → `"the company has 500 agents (cap 500)"`
    - the team cap → `"<team> has 8 agents (cap 8)"`
    - the requester's hire quota → `"you can hire 3 agents per day"` (it counts the requester's `staffing` hire decisions from the last 24 h in any status except `rejected`, so pending requests count)
    - 3a's org errors pass through for 7 reports or a cycle.

    It then calls `proposeDecision(kind: .staffing, by:, title: "Staffing: hire <role> into <team>" | "Staffing: remove @<h>" | "Staffing: move @<h>", summary: reason, ownerRequired: action is kill or reassign, payload: JSON action)`. Routing follows `decisionApprovers["staffing"]` ([ceo, ceo-cpo], never the requester). Once that approver approves a hire, Auto mode approves it and the effects run in the same transaction; otherwise it waits for the owner. Kill and reassign always wait for the owner.
  - Staffing effects on approval:
    - hire → `hire(db:)` with handle next free `<prefix>-<n>`, model `auto`, trust T1, the validated manager (or its default), team;
    - kill → 3a kill;
    - reassign → `setManager`/`setTeam`.

    Each sends a system DM to the requester: `"D-<n> done: <title>"`. Caps are rechecked at execution: on failure the decision stays approved, and a DM `"D-<n> could not run: <error>"`.
  - Tools (`staffing` list): `hire_agent {role, team?, manager?, reason}`, `kill_agent {agent, reason}`, `reassign_agent {agent, manager?: @h|"none", team?: name|"none", reason}`. Each returns `"Requested D-<n>; waiting on @<approver>."` or `"Requested D-<n>; waiting on the owner."`. Staffing tools are in the executive, director and manager templates; HR has only `hire_agent`.
  - Migration `"v3b-staffing-contracts"`: `interfaceContract(id TEXT PK, companyId, name TEXT NOT NULL, docPath TEXT NOT NULL, governs TEXT NOT NULL /* JSON [glob] */, ownerId TEXT REFERENCES agent ON DELETE SET NULL, summary TEXT, version INT NOT NULL, createdAt, updatedAt)`, `UNIQUE(companyId, name)`.
  - `enum PathGlob { static func matches(_ pattern: String, _ path: String) -> Bool }`: `**` matches any number of path segments, `*` any run within one segment, `?` one character. A pattern without glob characters matches the path itself or anything under it as a directory.
  - `struct InterfaceContract` (columns). `enum ContractCheck { static func touched(_ contracts: [InterfaceContract], changed: [String], declared: [String]) -> [InterfaceContract] }`: a contract is touched when any changed or declared path matches one of its `governs` globs or equals its `docPath`.
  - `Store.registerContract(companyId:by:name:docPath:governs:summary:now:) throws -> InterfaceContract`:
    - only agents whose role kind is `architect` or whose role is in `rolesCovering("cto")` (`"only architects can own interface contracts"`);
    - name `^[a-z][a-z0-9-]{0,40}$`; `docPath` relative and existing in the workspace (`"<path> does not exist in the workspace"`); 1–20 globs;
    - an existing name owned by another agent → `"contract <name> is owned by @<h>"`; otherwise `version += 1`;
    - posts from system to `#architecture` and every `team-*` channel: `"Contract <name> v<n> by @<h>: <summary…1>. Build against <docPath>."`.
  - Tool `register_contract {name, doc_path, governs: [glob], summary}` (architect list); `list_contracts {}` (work) returns a JSON array `{name, doc_path, governs, owner, version}`.
  - `submitForReview` addition: after computing the change diff, for each touched contract it appends the review flag `"touches contract <name>; needs review by @<owner>"`. When the current reviewer is neither the contract owner nor in `rolesCovering("cto")`, it sets `reviewerId` = the contract owner (unless that agent is the item's owner), which notifies the new reviewer. The flags make approval explicit and rule out light review.
  - `TurnDigest` adds, under Current work, `Contracts: <name> (<docPath>), …` for contracts touched by the item's declared paths.

- [ ] **Step 1: Write failing tests.** `StaffingTests`:
```swift
@Test func channelPostRateLimit() throws { /* eng-1 posts 12 to #general ok; 13th → exact text; DM still ok; owner and system unaffected; after window passes → ok */ }
@Test func managerHiresIntoOwnTeamWithOwnerGate() throws { /* mgr-1 hire_agent engineer team-1 → "Requested D-1; waiting on @ceo."; ceo decide approve → pendingOwner; owner approves → eng-5 in team-1, manager mgr-1, T1, model auto */ }
@Test func autoModeHiresAfterExecApproval() throws { /* autoMode on → still pendingInternal; ceo approves → approved, agent exists; the ceo's own hire request routes to the owner (no other approver) */ }
@Test func killAndReassignAlwaysNeedOwner() throws { /* autoMode on: mgr-1 kill_agent @eng-1 → ceo approves → pendingOwner (ownerRequired); owner approves → killed */ }
@Test func hireAllowListAndManagerScope() throws { /* hire_agent hr, perf, visionary, architect, cto → exact allow-list message; manager @mgr-2 by mgr-1 → "@mgr-2 is not in your reporting line"; no manager → mgr-1; hr-1 hire → manager ceo */ }
@Test func pendingRequestsCountTowardQuota() throws { /* 3 pending hire requests → 4th refused "you can hire 3 agents per day"; a rejected one frees a slot */ }
@Test func staffingGuards() throws { /* self, exec subject, outside subtree, other team, unknown role, team cap 8, 8th report (hire with team nil, manager mgr-1, so the team cap does not apply) → each exact message */ }
@Test func killAndReassignThroughGate() throws { /* mgr-1 kill_agent @eng-1 approved by ceo and owner → killed, leases reaped; reassign @eng-2 team none → team nil */ }
@Test func hrHasNoKillOrReassign() throws { /* hr-1 tools/list has hire_agent only among staffing tools; kill_agent call → "kill_agent is not available to your role" */ }
@Test func capsRecheckedAtExecution() throws { /* request at 7 members, another hire approved first → second approval DM "could not run: team-1 has 8 agents (cap 8)" */ }
@Test func engineersHaveNoStaffingTools() throws { /* eng-1 tools/list has none of hire_agent/kill_agent/reassign_agent */ }
@Test func crossCompanyKillRefused() throws { /* mgr-1 kill_agent Globex handle → "not in your company" */ }
```
  `ContractTests`:
```swift
@Test(arguments: [("api/**", "api/v1/users.ts", true), ("api/*.ts", "api/v1/users.ts", false), ("api", "api/x.ts", true), ("src/?.c", "src/a.c", true), ("docs/contracts/auth.md", "docs/contracts/auth.md", true), ("api/**", "apix/a", false)])
func globMatching(pattern: String, path: String, expected: Bool) { #expect(PathGlob.matches(pattern, path) == expected) }
@Test func onlyArchitectsRegister() throws { /* eng-1 → exact; arch-1 ok v1, posts to #architecture and #team-1; re-register v2; cto-architect other name ok; other architect same name → owned message; missing doc → exact */ }
@Test func touchingContractForcesArchitectReview() async throws {
  /* contract governs ["api/**"] owned by arch-1; item declared paths ["api"], reviewer mgr-1; submit → flag "touches contract auth-api; needs review by @arch-1", reviewerId arch-1;
     T2 owner tier S → not light-reviewed; approve without approve_flags → refused */ }
@Test func orientationListsContracts() throws { /* TurnDigest contains "Contracts: auth-api (docs/contracts/auth.md)" */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "StaffingTests|ContractTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the rate limit, staffing (policy, store, effects, tools), the contracts, the submit hook and the digest line.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS (3a's `RouterTests` post fewer than 12 per agent).
- [ ] **Step 5:** Commit `feat(core): staffing tools within caps, channel post limits and architect-owned interface contracts` with the trailer lines.

---

### Task 11: App model layer for performance and people

**Files:**
- Create: `Sources/BrahmaAppModel/People/PeopleSnapshot.swift`, `People/PeoplePresentation.swift`, `People/IdeaForm.swift`, `People/AppModel+People.swift`
- Modify (Plan 2/3a files): `Presentation/Sidebar.swift` (cases), `Presentation/ActivityText.swift` (`ActivityFilter.people`), `Agents/AgentDetail.swift` (meter, trust, perks), `Forms/HireForm.swift` (`trust`, `visionary`), `LaunchOptions.swift` (`SelectTarget` cases), `AppModel.swift` (people loading cadence); the `Sources/BrahmaApp` switches get `ContentUnavailableView` placeholders until Task 12
- Test: `Tests/BrahmaAppModelTests/PeoplePresentationTests.swift`, `PeopleModelTests.swift`

**Interfaces:**
- Consumes: Plan 2 `AppModel` (`store`, `snapshot`, `tick(forceSnapshot:)`, `selectedCompanyId`, `sidebarSelection`, `errorMessage`, `handles`), `SidebarItem`, `SelectTarget`, `AgentDetail`, `HireForm`, `ActivityFilter`; 3a `WorkSnapshot`, `ApprovalRow`/`ApprovalRows`, `AppModel.decide`; Store APIs from Tasks 2–10.
- Produces:
  - `struct PeopleSnapshot: Equatable, Sendable { var window: MeterWindow; var readings: [String: MeterReading] /* agent id */; var bands: [String: PerformanceBand]; var teamReadings: [String: MeterReading] /* team or "company" */; var companyReading: MeterReading; var closedSprints: [Sprint]; var perks: [String: PerkSummary]; var awards: [Award] /* 50 */; var hrActions: [HRAction]; var reviews: [PerformanceReview] /* latest sprint */; var pendingTerminations: [Decision]; var ideas: [IdeaEntry]; var trustHistory: [String: [TrustChange]] /* selected agent only */; static let empty; static func load(store: Store, companyId: String, window: MeterWindow, selectedAgentId: String?) throws -> PeopleSnapshot }`, with `struct IdeaEntry: Equatable, Sendable { var item: WorkItem; var idea: Idea }`. For a sprint window it reads stored snapshots; for rolling it uses the batched `meterReadings`. The company reading is the rolling reading over all agents.
  - `AppModel` + `var people: PeopleSnapshot = .empty`, `var meterWindow: MeterWindow = .rolling(end: .now)`, `static let peopleRefreshInterval: TimeInterval = 10`. People data loads off-main when `sidebarSelection ∈ {.agents, .performance, .breakRoom, .hr, .ideas}`: on selection change, after any people action, and otherwise at most every 10 s from `tick`.
  - 3a's `ItemRows.backlog` and `BoardColumns.make` skip items of type `idea` (ideas live on the Ideas board only).
  - `SidebarItem` + `.performance`, `.breakRoom`, `.hr`, `.ideas`. `SelectTarget` parses `performance`, `breakroom`, `hr` and `ideas`. `ActivityFilter` + `.people` (title `"People"`, includes `.people`).
  - Presentation (pure):
    - `enum MeterText { static func percent(_ d: Double?) -> String /* "75%" | "—" */; static func ratio(_ d: Double?) -> String /* "0.9×" */; static func hours(_ s: Double?) -> String /* "1.5h" */ }`
    - `struct AgentMeterRow: Equatable, Identifiable, Sendable { var id: String; var handle: String; var role: String; var trust: TrustLevel; var band: PerformanceBand?; var items: Int; var throughput: Int; var firstPass, cost, cycle, blocked: String; var rework, rejections, escaped, chatter, failedTurns, watchdog, overruns: Int; var flags: [String]; var perks: String }`; `enum MeterRows { static func make(_ p: PeopleSnapshot, agents: [Agent]) -> [AgentMeterRow] }` covers non-killed agents sorted by handle.
    - `enum PerkText { static func summary(_ p: PerkSummary?) -> String }`, e.g. `"☕3 🍜1 🏆1 🔥5 ⭐2 💡1"`. It omits zero counts, shows `🔥<streak>` only when the streak ≥ 3, and returns `""` when there is nothing.
    - `struct ScorecardCard: Equatable, Identifiable, Sendable { var id: String; var title: String /* "TEAM-1" | "COMPANY" */; var lines: [ScorecardLine] }` with `struct ScorecardLine: Equatable, Sendable { var label: String; var value: String }`; `enum Scorecards { static func make(_ p: PeopleSnapshot) -> [ScorecardCard] }` builds one card per team plus the company card. Its labels are exactly `ITEMS, WEIGHTED, FIRST-PASS, REWORK, REJECTIONS, ESCAPED, COST ×, CYCLE, BLOCKED, CHATTER, FAILED TURNS, WATCHDOG, OVERRUNS`.
    - `struct BreakRoomRow: Equatable, Identifiable, Sendable { var id: Int64; var time: String; var emoji: String; var handle: String; var title: String; var note: String }`; `enum BreakRoomRows { static func make(_ p: PeopleSnapshot, handles: [String: String], timeZone: TimeZone = .current) -> [BreakRoomRow] }`.
    - `struct HRRow: Equatable, Identifiable, Sendable { var id: String; var ref: String; var handle: String; var kindTitle: String; var statusTitle: String; var rootCause: String; var targets: [String]; var note: String; var reversible: Bool }`; `enum HRRows { static func make(_ p: PeopleSnapshot, handles:) -> (reviews: [String] /* "@h · Sprint n · <band> — <summary…1>" */, actions: [HRRow], pendingTerminations: [ApprovalRow]) }`. An action is `reversible` when its status is active, proposed or completed.
    - `struct IdeaCard: Equatable, Identifiable, Sendable { var id: String; var key: String; var title: String; var filer: String; var rice: String /* "RICE 40.0" | "UNTRIAGED" */; var hasEvidence: Bool; var duplicates: Int }`; `struct IdeaColumn: Equatable, Identifiable, Sendable { var id: IdeaStatus; var title: String; var cards: [IdeaCard] }`; `enum IdeaColumns { static func make(_ p: PeopleSnapshot, handles:) -> [IdeaColumn] }`. Columns are in order Open, Triaged, Prototyping, Approved, Shipped, Parked, Rejected, with cards sorted by rice desc and then key.
    - `struct IdeaForm: Equatable, Sendable { var title = "", problem = "", proposal = "", impact = "", cost = "", evidence = "", risks = "", scope = "team"; func validate() -> String? /* "Title, problem and proposal are required" | "Each field is at most 2000 characters" */; var draft: IdeaDraft }`
    - `AgentDetail` + `var meter: AgentMeterRow?; var trustTitle: String; var trustPinned: Bool; var perks: String; var trustHistory: [String] /* "MM-dd T1 → T2 — reason (engine)" */`. `HireForm` + `var trust: TrustLevel = .t1 /* t0 or t1 */; var visionary = false`.
  - `extension AppModel` (owner writes, then reload people and `tick(forceSnapshot: true)`; errors set `errorMessage`):
    - meter: `var meterRows: [AgentMeterRow]`, `var scorecards: [ScorecardCard]`, `func setMeterWindow(_ w: MeterWindow) async`;
    - trust and perks: `func setTrust(agentId: String, level: TrustLevel, pin: Bool) async`, `var breakRoomRows: [BreakRoomRow]`, `func giveKudos(agentId: String, note: String) async`;
    - HR: `var hrRows: (reviews: [String], actions: [HRRow], pendingTerminations: [ApprovalRow])`, `func reverseHRAction(ref: String, note: String?) async`, `func setupHR(perf: Bool, visionary: Bool) async`;
    - ideas: `var ideaColumns: [IdeaColumn]`, `var selectedIdeaId: String?`, `func fileIdea(_ f: IdeaForm) async throws -> WorkItem`, `func decideIdea(itemId: String, outcome: IdeaOutcome, reason: String, leadHandle: String?) async`.

    `AppSheet` + `.newIdea`, `.kudos(agentId: String)`.

- [ ] **Step 1: Write failing tests.** `PeoplePresentationTests` (pure):
  - `meterTextFormats`: 0.754 → `"75%"`, nil → `"—"`, 0.92 → `"0.9×"`, 5400 s → `"1.5h"`;
  - `meterRowsSortedAndFlagged`;
  - `perkSummaryOmitsZeros`: streak 2 hides 🔥 and streak 5 shows `🔥5`;
  - `scorecardLabelsExact`;
  - `breakRoomNewestFirst`;
  - `hrRowsReversibility`;
  - `ideaColumnsOrderAndRice`: an untriaged idea shows `"UNTRIAGED"`;
  - `ideaFormValidation`;
  - `ideasNotInBacklogOrBoard`: a WorkSnapshot with an idea item → absent from `ItemRows.backlog` and from every `BoardColumn`.

  `PeopleModelTests` (`@MainActor`, file-backed store via Plan 2 `makeHome`):
```swift
@Test func peopleLoadsOnlyForPeopleViews() async throws { /* selection .missionControl → people == .empty after tick; select .performance → readings populated */ }
@Test func sprintWindowUsesSnapshots() async throws { /* closed sprint via PeopleWorld-style seed → setMeterWindow(.sprint(id)) rows match snapshot readings */ }
@Test func ownerSetsTrustAndGivesKudos() async throws { /* setTrust T3 pin → agent T3, trustPinned; giveKudos → breakRoomRows.first.emoji "⭐" */ }
@Test func reverseFromApp() async throws { /* active PIP → reverseHRAction → trust restored; errorMessage nil */ }
@Test func fileAndFastTrackIdea() async throws { /* fileIdea → card in Open; decideIdea approve lead @mgr-1 → Approved column, epic exists */ }
@Test func hireFormTrustChoice() async throws { /* HireForm trust .t0 → hired agent trustLevel "T0" */ }
@Test func selectTargets() async throws { /* apply(.performance/.breakRoom/.hr/.ideas) → sidebarSelection matches */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "PeoplePresentationTests|PeopleModelTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the snapshot, presentation, forms and model extension, plus the app-target placeholder cases.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: the build is green for every target, and all tests PASS.
- [ ] **Step 5:** Commit `feat(app-model): meter rows, scorecards, trust, perks, HR and ideas presentation` with the trailer lines.

---

### Task 12: App views, demo seed, README and live end-to-end test

**Files:**
- Create: `Sources/BrahmaApp/Views/PerformanceView.swift`, `BreakRoomView.swift`, `HRView.swift`, `IdeasBoardView.swift`, `IdeaEditorSheet.swift`, `TrustBadge.swift`
- Modify: `Sources/BrahmaApp/Views/Sidebar.swift`, `DetailView.swift`, `AgentsView.swift`, `MainWindow.swift` (sheets), `ActivityFeedView.swift` (People filter, `person.2` glyph), `HireSheet.swift` (trust picker, visionary toggle), `Sources/brahma/DevCommands.swift` (`dev plan-sprint`, `dev close-sprint`), `scripts/seed-demo.sh`, `README.md`, `Tests/BrahmaCoreTests/LiveSmokeTests.swift`
- Test: UI snapshots (manual read), `LiveSmokeTests.peopleCeremoniesEndToEnd`

**Interfaces:**
- Consumes: Task 11 model API; Plan 2 BrahmaTheme components, `Harness --ui-snapshot`, `scripts/make-app.sh`, `scripts/ui-snapshot.sh <name> <target>`; Task 2 `DevScenario.complete`.
- Produces (views stay thin, styled with BrahmaTheme; every agent-sourced string uses `Text(verbatim:)`):
  - Sidebar: a section header `PEOPLE` under the work rows, with rows "Performance" (`gauge.with.dots.needle.33percent`), "Break room" (`cup.and.saucer`), "HR" (`person.text.rectangle`, count chip = pending terminations + active PIPs) and "Ideas" (`lightbulb`, count chip = open ideas).
  - `TrustBadge(level:)` is an 18 pt status chip with the label `T0`…`T3`, colored per Global Constraints, with `.help(level.title)`.
  - PerformanceView has three parts:
    - a panel header `PERFORMANCE` with a window `Picker` (`ROLLING 14D` plus one entry per closed sprint, `SPRINT <n> [TEAM]`);
    - a row of `ScorecardCard` panels (key–value grids in mono);
    - a dense zebra `Table` of `meterRows` with columns AGENT, TRUST (badge), BAND (chip), ITEMS, WTP, 1ST-PASS, REWORK, REJ, ESC, COST, CYCLE, BLOCKED, CHATTER, FAILED, WD, OVER, FLAGS (`exclamationmark.triangle` in `warning` with the flags as help) and PERKS.

    Selecting a row selects the agent and opens the Agents inspector.
  - AgentsView changes:
    - the roster gains a TRUST badge column and a METER column (`"<items> · <firstPass> · <cost>"`, mono) plus a PERKS column (`PerkText`);
    - the inspector adds a `METER` section (key–value grid of the row), `TRUST` (badge, pinned marker, history lines, a menu "Set trust ▸ T0…T3" plus "Return to engine", which call `setTrust`), `PERKS` and a "Give kudos" button (`presentedSheet = .kudos`, a note field ≤ 280 with a live count).
  - BreakRoomView is a log-style panel `BREAK ROOM`: lines `MM-dd HH:mm` (mono `text2`) · emoji · `@handle` · title — note. When empty: mono `NO AWARDS YET`.
  - HRView has three panels:
    - `REVIEWS` (the latest sprint's lines);
    - `WARNINGS & PIPS` (a table of `HRRow` with targets as an indented list and a "Reverse" button when reversible, which confirms with the alert `"Reverse HR-<n>?"`);
    - `PENDING TERMINATIONS` (`ApprovalRow`s with Approve/Reject calling 3a `decide`).

    With no HR agent the header shows a "Hire HR partner" button (`setupHR(perf: true, visionary: false)`).
  - IdeasBoardView is a horizontal board of `ideaColumns` (220 pt columns, header `TITLE · n`; cards show the mono key, title, `@filer`, a RICE chip, an evidence glyph and a duplicates count) with a "New Idea" toolbar button (`.newIdea`). Its inspector (320 pt) shows the problem, proposal, impact, cost, evidence, risks, triage note, RICE breakdown, duplicates, outcome and decision refs, plus fast-track buttons Approve (lead `Picker`), Prototype, Park and Reject, each with a reason field. `IdeaEditorSheet` holds the `IdeaForm` fields with a validation line in `danger`.
  - Dev commands (`BRAHMA_DEV=1`):
    - `dev plan-sprint <company> --as @h --goal g --items K1,K2 [--team t]` (calls `planSprint`);
    - `dev close-sprint <company> <n> --as @h --summary s [--lesson l]…` (calls `closeSprint`).
  - `seed-demo.sh` appends, for Initech (from 3a's seed):
    - `hr setup Initech --perf`;
    - owner `approve` of D-1;
    - `dev propose`/`dev decide` + `approve` for an architecture gate;
    - three `items add` tasks in team-1 (`--check true`): tier S `--owner @eng-1`, tier M `--owner @eng-2`, tier L `--owner @eng-3`;
    - `dev plan-sprint` as `@mgr-1`, then `dev decide` as `@cpo` and `approve`;
    - `dev complete` for each as its owner (the M item with `--fail-first`) and `dev close-sprint Initech 1 --as @mgr-1 --summary "Streaks shipped" --lesson "Write the check first"`;
    - `kudos give Initech @eng-1 "Clear hand-off notes"`;
    - `ideas add Initech --title "Offline mode" --problem "No signal on the subway" --proposal "Queue check-ins locally" --impact "Retention" --cost "1 sprint" --evidence "40 support tickets this month"`;
    - `ideas triage Initech <KEY> --reach 500 --impact 2 --confidence 0.8 --effort 1 --note "Strong ask" --reasoning "Top support request"`.
  - README gains a "Performance & people" section. It covers:
    - the meter's measures and that agents never see them;
    - the trust ladder table and its effects;
    - perks (cosmetic only);
    - HR (reviews, warning → PIP → termination, root cause first, owner reversal);
    - ideas (board, triage, RICE, Idea review, quota, visionaries);
    - pairing (when it turns on), smart-friend consults, contracts, the sprint judge, staffing tools and post limits;
    - the commands `perf`, `perf trust`, `hr`, `hr setup`, `hr reverse`, `ideas …`, `kudos …`, `company pairing-in-low`.

    It also carries the note: `"Under the workspace profile an agent's shell can read the database directly; brahma perf and brahma hr refuse inside agent turns, but only the Sandboxed profile (Plan 5) makes meter data truly private."`

- [ ] **Step 1:** Add `peopleCeremoniesEndToEnd` to `LiveSmokeTests` (time limit 6 min, `BRAHMA_LIVE=1`, all agents haiku):
  1. Create a company and hire `ceo` (role `ceo`), `lead` (role `manager`) and `eng` (role `engineer`), with `eng` under `lead` in team `t`.
  2. As the owner approve prd and architecture decisions via `ownerDecide`.
  3. As `lead`, plan a sprint for team `t` with three ready tasks (check `true`); the `ceo` approves internally and the owner approves.
  4. Complete each task with `DevScenario.complete` (reviewer `lead`, one with `failFirst`), then `closeSprint` as `lead`.
  5. Run a real `Orchestrator` (ClaudeProcessRunner, ProcessCheckRunner), ticking every 1 s, until the `scorecard` row exists and `sprint.judgeVerdict` is set, or the time limit passes.

  Expect: `ceremony`-kind turns for `ceo` (the scorecard and HR review fall back to the CEO, and the CEO is the judge) with a recorded `scorecard` whose file exists under `companyDir/perf/`; a judge verdict recorded by `ceo`; both queued turns `done`; and no meter number in any `.brahma/notes/*.md` (no `%`). On timeout, cancel in-flight turns before failing.
- [ ] **Step 2:** Implement the views, sheets, dev commands, seed and README. Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`. Expected: it builds with no warnings in new files.
- [ ] **Step 3: UI smoke.** Run `scripts/make-app.sh debug`, then:
  - `scripts/ui-snapshot.sh task3b-perf performance`
  - `scripts/ui-snapshot.sh task3b-agent agent:eng-1`
  - `scripts/ui-snapshot.sh task3b-breakroom breakroom`
  - `scripts/ui-snapshot.sh task3b-hr hr`
  - `scripts/ui-snapshot.sh task3b-ideas ideas`

  Read each PNG under `.superpowers/ui/`. Expected:
  - Performance shows the COMPANY and TEAM-1 scorecards and a meter table with `@eng-1` (TRUST T1, ITEMS 1, 1ST-PASS 100%) and `@eng-2` (1ST-PASS 0%, the fail-first item).
  - The agent inspector shows METER, TRUST T1 and PERKS `☕1` or more with the kudos star.
  - The break room lists ⭐ "Clear hand-off notes" and ☕ lines (no 🏆: no agent has the 3 items it needs).
  - HR shows REVIEWS (empty until the ceremony runs, which the fake runner doesn't do) and the three panels.
  - Ideas shows "Offline mode" in Triaged with `RICE 800.0`.

  Everything uses BrahmaTheme panels, chips and mono numbers.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (expected: all PASS, live skipped) and `scripts/smoke-app.sh` (expected: Plan 2's `SMOKE OK … lifecycle=ok`). Then, with quota available, run `BRAHMA_LIVE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LiveSmokeTests` (expected: PASS, 3a's live test included). If you skip the live run, say so.
- [ ] **Step 5:** Commit `feat(app): performance, break room, HR and ideas views; trust and perks on agents; seed, docs and live ceremony test` with the trailer lines.
