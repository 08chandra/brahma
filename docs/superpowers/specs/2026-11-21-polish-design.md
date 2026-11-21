# Plan P — Polish before dogfood (design)

**Status:** design, 2026-11-21. The owner approved the scope (design analysis items 1–3). Build order: 4a → C → 4b leftovers → S → R → **P** → first dogfood run.
**Plan:** `docs/superpowers/plans/2026-11-21-planP-polish.md`.
**Inputs:**
- `2026-11-21-design-analysis-input.md` (*analysis §n*)
- `2026-10-21-brahma-design-v2.md` §1.3 (concept budget), §4.12 (app layout)
- `2026-10-20-visual-design.md` (BrahmaTheme)
- Plan R spec (`2026-11-21-restructure-service-design.md`, *R §n*)
- Ledgers under `*/.superpowers/sdd/` (4a, C, 5-lite, L)
- Code on `planC-collab` 91e84e9

P builds on R. It uses R's module split, R's in-process service host for tests, and R's control socket for change notifications.

---

## Owner questions (recommended defaults; the plan builds the defaults unless you say otherwise)

### PQ1 — The new sidebar (recommended: layout A)

Today: 14 fixed rows (Mission Control, Activity, Agents, Backlog, Board, Releases, Handbook, Resources, Budget, Inbox, Grants, Digest, Company, Backups), then channels and DMs. Plan C adds a CHANGES view and the ⌘K Show bar.

**Layout A (recommended): the five nouns, plus Settings and Insights pinned at the bottom. That is 7 fixed rows.**
```
┌────┬──────────────────────────┬────────────────────────────────────────────────────────────────┐
│ ▣A │ ◉ Mission Control        │ WORK   Backlog · Board · Changes · Releases · Handbook · Resources│  ← tab strip (28 pt header)
│ ▣B │ ▸ Inbox               5  │ ───────────────────────────────────────────────────────────────│
│ ＋ │ ▸ Work                   │  KEY    TITLE                         STATUS     OWNER   UPDATED │
│    │ ▸ People                 │  A-12   Login form                    inReview   @eng-1  09:41   │
│    │ ▸ Budget                 │  …                                                             │
│    │                          │                                                                │
│    │ CHANNELS                 │                                                                │
│    │  # general            2  │                                                                │
│    │  # eng                   │                                                                │
│    │ DIRECT MESSAGES       ＋ │                                                                │
│    │  @ceo                 1  │                                                                │
│    │ ▸ Agent conversations    │                                                                │
│    │                          │                                                                │
│    │ ─────────────────────    │                                                                │
│    │ ⚙ Settings               │                                                                │
│    │ ◌ Insights               │                                                                │
└────┴──────────────────────────┴────────────────────────────────────────────────────────────────┘
 ⌘1 Mission Control  ⌘2 Inbox  ⌘3 Work  ⌘4 People  ⌘5 Budget  ⌘, Settings  ⌘K Show/search (Plan C)
```

| Noun row | Tabs (left to right; the first is the default) | Comes from |
|---|---|---|
| Mission Control | — (one page: NEEDS YOU · STUCK · SHIPPED strip, PREVIEW + MAP, ACTIVITY) | Mission Control, Activity |
| Inbox | Asks · Requests (access, files, human tasks, secrets) · Grants · Digest | Inbox, Grants, Digest |
| Work | Backlog · Board · Changes (C) · Releases · Handbook · Resources | Backlog, Board, Releases, Handbook, Resources, C's CHANGES |
| People | Roster · Org chart (4b map, full size) | Agents |
| Budget | Pace · Spend · Storage | Budget |
| Settings | Company · Engine (R) · Backups · App | Company, Backups, R's engine panel |
| Insights (read-only) | Activity log · Merge queue (4a) · Timers · Health · Sandbox canary · Outcome facts | Activity (full log), plus read-only views of what today only the CLI shows |

- **Layout B (alternative):** the same seven rows, with Insights as a tab inside Settings instead of a row. That gives one fewer row, but Insights becomes hard to find.
- **Layout C (alternative):** keep today's rows and only group them under headers. This is the smallest change, and it still has 14 rows.

### PQ2 — Namespace for internal and recovery CLI commands
**Recommended: `brahma dev …`, the name you used.**
- It is listed in `brahma --help` as one line: "dev — internals, diagnostics and recovery".
- Its contents show only under `brahma dev --help`.
- Today's hidden `BRAHMA_DEV=1` test hooks move to `brahma dev test …` and stay gated.
- The alternative is `brahma admin …`, which reads better for recovery commands such as `main accept`.

### PQ3 — Top-level shortcuts that stay forever
**Recommended: keep `status`, `why`, `say`, `approve`, `answer`, `stop`, `resume` and `doctor` as permanent top-level verbs.**
- They are what you type daily, or in an emergency.
- Each is also reachable under its noun, for example `inbox approve`.
- The alternative is strict nouns only, where `brahma approve` becomes a deprecated alias.

### PQ4 — How long old command names keep working
**Recommended: until the first tagged release after the dogfood week, and at least 30 days.**
- Old names run the new command unchanged.
- On an interactive terminal only, they print one stderr line: `note: 'brahma items list' is now 'brahma work list'`.
- Scripts and pipes see no change in stdout or stderr.
- `brahma help moved` prints the whole old → new table.

### PQ5 — The standalone Activity page
**Recommended: fold it.**
- Mission Control keeps the live ACTIVITY panel, with filters.
- Insights › Activity log has the full searchable history.
- The People inspector shows the agent's own lines.
- Launch targets `--select activity` keep working and open Insights › Activity log.

The defaults change only what you see. No capability is removed: every view and every command remains reachable (§5 anti-goals).

---

## 1. Why

- **The owner surfaces leak engine internals** (*analysis §2, §4, §8 #13*).
  - The sidebar has 14 fixed destinations (`BrahmaAppModel/Presentation/Sidebar.swift:4-22`, `BrahmaApp/Views/Sidebar.swift:15-31`).
  - The CLI has 43 command files and 58 top-level entries (`Sources/brahma/Brahma.swift`). The help tree has 130 visible leaf commands on `planC-collab`, counted by walking `--help`. That is before the hidden `dev`/`hook` groups and before 4a's `artifacts`.
  - The v2 spec's concept budget (§1.3) says the owner operates five nouns, with internals read-only under Insights. The README is stale ("This is Plan 3a").
- **There is no golden-path test** (*analysis §2 must-haves, §6, §8 #7*). No test runs goal → org → backlog → work → check → review → merge → preview → owner Inbox on every plan merge. The real version (`LiveSmokeTests/goalToLiveURL`) needs `BRAHMA_LIVE=1` and real `claude`, and has never run as a gate.
- **The suite is slow and flaky** (*analysis §5*).
  - About 3,200 tests: 2,759 core, 411 app-model and 45 map.
  - Full runs take 252–508 s (`C2a-fullsuite.txt` 252.4 s, `C1a-fullsuite-c83e0b0.txt` 508.1 s).
  - About ten tests fail intermittently. Seven have recorded failures in the ledgers (§6.4).
  - Every implementer pays for this several times per task, and two worktrees cannot test at once.
- **The app polls the whole snapshot every 500 ms** (`AppModel.swift:316-324`, `Live/Snapshot.swift:50-91`). Each refresh reads every company's agents, channels, unread counts, Inbox count and stall report, plus the selected company's work, preview, releases, resources and last turns. The live map polls on its own loop (`MapController.swift:229`). *Analysis §3 Concurrency, §8 #15.*

## 2. Goals

1. **G1 App IA.** Seven fixed sidebar rows (layout A). The views become tabs under their noun. Mission Control answers, in order: what needs me, what is stuck and why, what shipped. Launch targets and deep links keep working.
2. **G2 CLI IA.** `brahma --help` shows the five nouns plus about ten system verbs (≈ 16 lines, down from 58). Internals move under `brahma dev`. Every old command path keeps working through a single rewrite table with a deprecation note, and every hint string the product prints names the new path.
3. **G3 Golden path.** One deterministic end-to-end test runs in the default suite in under 30 s. A black-box script version (`scripts/golden-path.sh`) runs on every plan merge.
4. **G4 Determinism and speed.** The ten listed flakes are fixed at the root. The default ("unit") tier has no wall-clock sleeps or real ports. Process, sandbox and timing tests move to an opt-in `process` tier, alongside the existing `live` tier. The unit tier runs in **under 90 s** on an idle machine (*analysis §8 #7*), and two worktrees can run it at the same time.
5. **G5 Change notifications.** The app refreshes from engine-pushed change topics instead of a 500 ms timer. Each refresh reads only the parts of the snapshot whose topics changed, and a change shows up within 250 ms. A cheap fallback keeps the app correct when the service is unreachable.

## 3. Non-goals

- **The cost-per-outcome view** (*analysis §2 must-haves*). The owner did not include it in P. It is listed as the first post-dogfood candidate.
- New owner features, new nouns, and redesigning any individual view's content beyond moving it into a tab. The exception is Mission Control's top strip, which reuses `why`/stall data that already exists (`Store+StallReport`).
- Changing the agent-facing CLI: `brahma mcp` and `brahma hook pre-tool|post-tool` keep their names and argv, because canary keys include the settings shape.
- Moving engine DB reads off the actor (R non-goal) and push-based map animation changes (the map keeps its render loop; only its data poll changes).
- Removing old CLI names before the window in PQ4 ends.

## 4. Anti-goals (binding)

- **No capability lost.** Every current sidebar destination is reachable in at most two clicks. Every current command is reachable under its new path and under its old path. `IACoverageTests` enumerates both.
- **No script breakage.** The stdout of every command is byte-identical, and the deprecation note is TTY-only. `--json` output is unchanged.
- **No weakened owner gating.** Moved commands keep `requireOwnerShell()` and `BRAHMA_AGENT_ID` refusals. `CLIOwnerGateTests` checks every new path against the old path's gate.
- **No safety by notification.**
  - Change notifications are a latency optimization, never a correctness or safety signal.
  - Holds, stops and Inbox counts are still read from the DB.
  - A missed notification costs at most one fallback interval.
- **No deleted tests.** A flaky test is fixed or moved to a tier. It is never deleted or `.disabled`. Each moved test keeps a deterministic unit-tier sibling that covers its logic.

---

## 5. Architecture and decisions

### 5.1 App information architecture (architect's call within PQ1)

**Model.** `SidebarItem` becomes:
```swift
public enum SidebarItem: Hashable, Sendable {
    case missionControl
    case inbox(InboxTab)        // .asks, .requests, .grants, .digest
    case work(WorkTab)          // .backlog, .board, .changes, .releases, .handbook, .resources
    case people(PeopleTab)      // .roster, .org
    case budget(BudgetTab)      // .pace, .spend, .storage
    case settings(SettingsTab)  // .company, .engine, .backups, .app
    case insights(InsightsTab)  // .activity, .mergeQueue, .timers, .health, .canary, .facts
    case channel(id: String)
    case dm(handle: String)
}
```
- Each noun remembers its last tab (`AppModel.lastTab[Noun]`).
- `SidebarItem.legacy(_:)` maps every old case: `.backlog → .work(.backlog)`, `.inboxGrants → .inbox(.grants)`, `.settingsBackups → .settings(.backups)`, `.activity → .insights(.activity)`, and so on.
- `SelectTarget` (launch options, notification deep links, `--select …`) keeps every existing spelling and maps it through `legacy`.

**Views.**
- The new `NounHeader` component is the 28 pt panel header strip with uppercase tab labels, the accent underline on the selected tab, and a mono count chip per tab where one applies (Inbox › Asks count, Work › Changes count).
- Tabs reuse today's views unchanged (`BacklogView`, `BoardView`, `ReleasesView`, `HandbookView`, `ResourcesView`, `GrantsView`, `DigestView`, `BackupsView`, `CompanySettingsView`, `BudgetView` and `StoragePanel`, plus C's `ChangesBoardView`).
- `DetailView`'s switch moves from 14 cases to 7 noun views.

**Mission Control top strip** (*analysis §4*: "make Mission Control answer three questions in order"). Three equal cards, about 96 pt tall, above the PREVIEW + MAP panels:

```
┌ NEEDS YOU ─────────────── 5 ┐┌ STUCK ──────────────────── 2 ┐┌ SHIPPED (7 days) ─────────── ┐
│ A-14 deploy v0.3 to prod    ││ nothing running: weekly pace ││ ▲ preview web · a1b2c3d 09:12│
│ A-15 grant npm registry     ││   closed until Thu 09:00     ││ ▲ v0.2 deployed  Tue 17:40   │
│ F-2  file request from @pm  ││ @eng-2 blocked on A-9 (you)  ││ 12 items merged              │
│ Open Inbox →                ││ Why? →  (brahma why)         ││ Releases →                   │
└─────────────────────────────┘└──────────────────────────────┘└──────────────────────────────┘
```
- **NEEDS YOU:** `WorkSnapshot.inbox`, the top 3 by the Inbox's own order.
- **STUCK:** `store.stallReport(companyId:).reasons` (already computed per company in `Snapshot.load`), plus agents blocked on the owner.
- **SHIPPED:** preview surfaces with their commits, the latest releases, and the merged count over 7 wall days.
- Only existing Store reads are used. 4b's deferred "Mission Control slot swap" lands before P. P places the strip **above** whatever slot layout 4b leaves, and Task 11 reads the merged layout first.

**The Insights pane** shows read-only views over existing data:
- Activity log: today's `ActivityFeedView` with its filter, full height.
- Merge queue: 4a's `merge list` data.
- Timers: `brahma timers`.
- Health: the hold history.
- Sandbox canary: the last result per key.
- Outcome facts: `perf facts`.

No action buttons, except "Copy command" for the matching `brahma dev …` line. That is the v2 §4.12.4 rule.

**Keyboard:** ⌘1–⌘5 select the nouns, ⌘, selects Settings, ⌃Tab and ⌃⇧Tab cycle tabs, and ⌘K stays C's Show bar.

### 5.2 CLI information architecture (architect's call within PQ2–PQ4)

**`brahma --help` after P:**
```
USAGE: brahma <command>

NOUNS
  company     Create, list, pause and configure companies (settings, secrets, extensions, hosting)
  people      Hire, list, move, pause, wake and kill agents; vacancies; the org chart
  work        Items, sprints, previews, releases, merges, artifacts, handbook, resources, memory
  inbox       Asks and requests waiting for you; grants; digest; notices
  budget      Weekly share, plan tier, pace and spend, storage

DAILY
  status      Every company's agents and usage          why       Why a company has nothing running
  say         Post to a #channel or DM an @agent         log       Recent messages in a channel or DM
  search      Search everything in a company (C)         approve   Approve or reject an ask
  answer      Answer an agent's question

SYSTEM
  stop / resume   Emergency stop and resume              engine    The background engine (R)
  doctor          Check Claude Code and the engine       backup    Snapshots, targets, WAL; `backup restore`
  settings        Owner-wide preferences                 dev       Internals, diagnostics and recovery
```

**Placement rules** (the full old → new table is Appendix A):
1. A command that changes or lists a **company-level setting** goes under `company` (`mode`, `weight`, `autonomy`, `auto`, `set`, `profile`, `network`, `presets`, `hosting`, `secret`, `ext`, `trust-import`, `export`).
2. An **agent or org** command goes under `people` (`hire`, `kill`, `pause`, `wake`, `org …`).
3. Anything **produced or shipped** goes under `work` (`items`, `sprint`, `preview`, `release`, `merge list|retry|resume|settings`, `artifacts`, `kb`→`handbook`, `resource`, `memory`, `replay item`).
4. Anything **waiting on the owner** goes under `inbox` (`inbox`, `approve`, `answer`, `rescind`, `task`, `access`, `grants`, `secret provide`, `digest`, `notices`).
5. **Usage** goes under `budget` (`settings plan|share|ultra-share`, `company reserve`, the spend view).
6. **Diagnostics and recovery** go under `dev`. That covers `canary`, `mode gates|ultra-status`, `perf facts`, `timers`, `transcript`, `replay agent`, `lab clear-taint`, `items readopt`, `main accept`, `merge adopt-main`, `settings hot-paths|auto-merge-paths`, `milestones` and `push test`, plus `dev test …` (today's `BRAHMA_DEV=1` hooks, still gated).
7. **Agent-facing commands** stay exactly as they are, hidden: `mcp`, `hook pre-tool`, `hook post-tool`.

**Mechanism: one rewrite table.**
- `LegacyRoutes.rewrite(_ argv: [String]) -> (argv: [String], note: String?)` runs before ArgumentParser.
- It matches the longest old prefix (`["items","list"] → ["work","list"]`, `["settings","plan"] → ["budget","plan"]`, …) and passes options through untouched.
- This is the architect's call over per-command `aliases:`, which cannot move a command between groups, and over wrapper structs, which would mean 130 new types.
- The note is printed only when `isatty(STDERR_FILENO)` and `BRAHMA_NO_MOVED_NOTE` is unset.
- `LegacyRoutesTests` checks three things:
  - every old path in the frozen `Appendix A` fixture parses to the same command type as its new path;
  - no new path is shadowed;
  - the table has no cycles.

**Hint strings.**
- 283 `brahma <verb>` hint strings in 125 files under `Sources/` tell the owner what to run (for example "run 'brahma main accept'", "See: brahma restore --list"). P rewrites them to the new paths.
- `CLIHintTests` scans every string literal in `Sources/` that matches `brahma [a-z-]+( [a-z-]+)*`. Each must resolve to a **non-legacy** command path in the parsed tree (`mcp` and `hook` excepted).
- The README has 162 `brahma …` lines and is rewritten in the same task. `scripts/smoke-app.sh` has 3.

### 5.3 Golden-path end-to-end test (architect's call)

Two layers, one scenario:

1. **`GoldenPathTests` (unit tier, < 30 s, in `BrahmaEngineTests`).**
   - It uses a real `Store`, real git, the real `Orchestrator` from R's in-process service host, and the real MCP tool dispatch (`CompanyTools`).
   - The `claude` side is a **`ScriptedTurnRunner`** (`TurnRunning`). It plays each role by issuing the tool calls a model would issue, through the same handler `brahma mcp` uses, keyed by role and turn number.
   - Preview processes use the existing `FakeSandbox` + `FakeHTTPProbe`. The clock is a `TestClock`.
   - Ticks are driven by `orchestrator.tick()` in a loop until a milestone or a step budget (≤ 400 ticks). There is no `runForever` and no sleeping.
   - Phases, each asserted:
     1. goal → company (software pack) → org chart generated;
     2. CEO turn writes the brief; lead turn creates backlog items with a check spec;
     3. dispatch leases item A-1 to `@eng-1` with its worktree;
     4. the engineer commits and submits;
     5. the engine check runs (fake runner, exit 0) and the review is routed;
     6. the reviewer approves;
     7. the merge queue lands on `main` (real git);
     8. the web preview reconciles to `running` at the merged commit;
     9. the deploy ask appears in the owner Inbox (`WorkSnapshot.inbox`);
     10. the owner approves through `Store.ownerDecide` and the release executes against the dev host.
   - It runs as part of the default suite on every task.
2. **`scripts/golden-path.sh` (process tier, about 2–4 minutes).**
   - The same scenario as a black box: a temp home, `brahma engine serve --unmanaged` (R), `BRAHMA_CLAUDE=scripts/fake-claude.sh` extended with a role script (`scripts/fake-claude-roles/`), real `sandbox-exec`, and a real loopback preview.
   - It asserts through the CLI only: `brahma status`, `brahma work list --json`, `brahma work preview list` reaching `running`, HTTP 200 from the preview URL, and `brahma inbox` showing the deploy ask.
   - It is run by the controller at every plan merge, and it is listed in the Global Constraints of every future plan.

`LiveSmokeTests/goalToLiveURL` (real `claude`, `BRAHMA_LIVE=1`) stays unchanged as the third, manual layer.

### 5.4 Determinism and speed (architect's call)

**Tiers**, as a trait in `BrahmaTestSupport` (R):
- `.unit` is the default and needs no trait.
- `.process` covers real child processes, `sandbox-exec`, real ports, real timers above 100 ms, and Python. It is enabled by `BRAHMA_TEST_TIER=process` or `all`.
- `.live` is today's `BRAHMA_LIVE=1`, unchanged.
- The traits are defined as `.enabled(if: TestTier.process)`. That is the gating style already used at 52 sites, because Swift Testing tags cannot be filtered from `swift test` reliably on this toolchain.
- `scripts/test.sh [unit|process|all] [--changed]` wraps `swift test`. With `--changed`, it runs only the test targets of modules whose sources changed versus `main`, using R's per-module test targets.

**Unit-tier rule.**
- No `Task.sleep`, `Thread.sleep`, `usleep`, shell `sleep N`, real `Process()`, real port binds or `Date()` deadlines in unit-tier tests.
- Waits are events: continuations, `FakeSandbox.waitForSpawn`, `Gate.waitUntilWaiting`, or a `ManualClock` advance.
- `UnitTierHygieneTests` (static) scans unit-tier test files for those constructs. It starts from a **baseline allowlist** generated in Task 1. Today's counts are 51 `Task.sleep`, 12 `Thread.sleep`, 9 `usleep`, 65 `Process()` and 90 shell `sleep N`. The allowlist may only shrink. The same shrinking-baseline approach is what the analysis recommends for lints.

**Systemic causes** (from the ledgers):

| Cause | Evidence | Fix |
|---|---|---|
| `@MainActor` app-model tests wait on each other while CPU-heavy core tests saturate the machine. 31–59 of them finish at the same second. | `C2a-fullsuite.txt` (31 tests at 110–112 s), `C1a-fullsuite-c83e0b0.txt` (59 at 350–353 s) | Remove wall-clock bounds from app-model tests (injected clocks, below). Move the process-heavy core suites to `.process`. Unit-tier app-model tests then have nothing to wait behind. |
| Real wall-clock assertions (`Date().timeIntervalSince(began) < 30`) | `CLIAdapterTests.swift:103` | Fakes plus `ManualClock`. Real timeouts are tested once, in `GroupRun` with a stepping clock. |
| Shared machine resources across worktrees: `PortAllocator.range = 47100...47999` taken first-free, the `/private/tmp/b-<uid>` agent temp root, the `TurnRegistry` static keyed by agent id, the `$TMPDIR` scratch sweep | `Supervision.swift:84-87`, `Orchestrator+Sandbox.swift:49`, `TurnProcess.swift:500`, `ScratchHygieneTests` incident (4a progress :261) | Add `PortAllocating` (an injectable range; tests get a per-process base from the pid). The agent temp root becomes per data home in tests through `SandboxEnvironment`. `TurnRegistry` gets an instance per Orchestrator, with the static kept as the default. The scratch sweep only touches roots whose owning pid is dead **and** that belong to this checkout (a marker file holding the repo path). |
| The Mac slept mid-run (15 `idleTimeout`s at ~334 s) | C progress :98–100 | The unit tier has no awake-time deadlines, only event waits and `.timeLimit`. `scripts/test.sh` runs under `caffeinate -i` and prints "machine slept during run: rerun" when the awake clock and the wall clock diverge by more than 30 s. |
| One implementer's `pkill` killed another worktree's run | C progress :75 | Already a hard rule. `scripts/test.sh` never kills anything it did not start, and it writes its own pid file. |

**Per-test fixes** (ledger evidence in Appendix B):

| Test | Root cause | Fix | Tier after |
|---|---|---|---|
| `MapControllerTests.peopleOptional` | `live()` builds `MapController` with the real clock. Under load, more than 10 s pass between two polls, so people reload. Failed 10×. | Pass `MapTestClock` (exists, `MapControllerTests.swift:34`) through `live()`. Add the positive leg: advance 10 s, then expect `calls == 2`. | unit |
| `WorkModelTests.retryEngineClearsAccountHold` | Starts a real embedded engine: a real lock, real caffeinate, and a 50 ms tick racing the owner write. `retryEngine` uses `Date()`. | After R, `EngineHost` is gone. The test uses R's fake `EngineConnection` (`recheck` → passing), and `retryEngine` uses `clock()`. | unit |
| `SeatbeltRunnerTests.loopbackListenOnlyOwnPorts` | Real kernel ports, probed then closed and reused (time-of-check to time-of-use), with other processes connecting first. Failed 2× after 5-lite's retries. | Unit: assert `SeatbeltProfile.render` emits exactly the `localhost:<p>` bind and inbound rules for `.loopbackListen`. Process tier: the kernel check with a per-run nonce in the payload; listener exit 0 without the nonce counts as raced and is retried. `.serialized`. | unit + process |
| `SearchModelTests.staleMemoryResultsDropped` | `eventually { gate.isWaiting }` polls every 20 ms against a 60 s deadline on a starved main actor. Failed 3× (`Timeout()`). | `Gate.waitUntilWaiting()` on a continuation. The suite's `.timeLimit` is the only bound. | unit |
| `PreviewSupervisionTests.stopKillsProcessGroup` | Real `sleep 300` children, `ps` polled through Foundation `Process`, a 5 s deadline. Failed about 4× under load. | Unit: the stop logic against a fake `SandboxedProcess`. Process tier: the child writes its pids to a ready file, and `ProcessTable` (`TurnProcess.swift:30`) replaces `ps`. | unit + process |
| `CLIAdapterTests.demoTimeout` | A real `sleep 60` and a 1 s timeout with a wall-clock assertion. Failed 3× (61.3 s). | A fake `SandboxedRunner` returns `timedOut: true` with partial output. Delete the wall-clock assertion. | unit |
| `LiveCLITests.devHostServesOnlyItsFolderAndGrantsOnlyTheCopy` | A real loopback server probed through URLSession with 30 s timeouts. Failed once (62 s; 1.9 s alone). | Add the `DevHostServer.serve(connection:)` seam and drive it over `socketpair()`. Path logic is already unit-tested through `response(method:target:root:)`. | unit + process |
| `TurnContainmentTests` (timing) | `pid(in:)` and `gone()` poll 10 ms on the continuous clock. Fixed 300 ms and 50 ms sleeps before `classify`. | Ready files written after `sandbox-exec` applies. `TurnRegistry` gets clock and sleeper seams (`TurnProcess.swift:507/534`), so `ManualClock` drives `waitFailsClosedOnDeadlineAndCancellation`. The escapee tests move to `.process`. | unit + process |
| `WebAdapterTests.realServerIfPythonAvailable` | Python plus a first-free shared port range (time-of-check to time-of-use across worktrees). The `port+1` bind passes when the port is merely busy. | Move to `.process`. Use `PortAllocating` with a per-process base. Assert "Operation not permitted" for the `port+1` bind. | process |
| `BackupTargetTests.stalePidHandled` | Real processes, pid file, argv read through `KERN_PROCARGS2`, signals. The cause of the "left running" failure is not confirmed (`ProcessArguments.of` under load, inferred). Failed 4× after `OutsideChild` and many times before. | Add a `ProcessInspecting` seam (argv, isAlive, signal) to `WALShipper.reapStale` (`WALShipping.swift:406-427`), exposed through the existing `WALShipper.init(sleeper:awakeUptime:…)`. Unit-test the decision table: stale litestream gets TERM then KILL, an unrelated pid is never signalled, an unreadable pid file is removed. The real-process version moves to `.process` and passes `note:` so a failure says why. | unit + process |

**Runtime budget.**
- Unit tier: < 90 s wall time on an idle machine, measured by `scripts/test.sh unit --report`, which prints the 15 slowest suites.
- The heaviest suites today are ReviewTests 252 s, BackupTargetTests 185 s, MergeBatchTests 149 s, MergeQueueTests 141 s, SecretWireTests 127 s, SeatbeltRunnerTests 125 s and VerificationTests 124 s, all in the C2a log.
- Each heavy suite is either split into a unit part on fakes plus a `.process` part, or kept and justified in the report.
- Git-heavy suites (457 `git([` fixture calls in 27 files) get a cached template repository: one `git init` and commit per process, copied with `cp -c` (APFS clone) per test.

### 5.5 Change notifications (architect's call)

**Change topics live in the DB.** Migration `"vP-change-topics"`, appended after the last migration on `main` when P starts:
```sql
CREATE TABLE changeTopic (topic TEXT PRIMARY KEY, seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE changeEpoch (id INTEGER PRIMARY KEY CHECK (id = 1), epoch TEXT NOT NULL);   -- new UUID on create and on restore
-- one trigger per (table, INSERT|UPDATE|DELETE) for every table in ChangeTopics.map:
CREATE TRIGGER ct_workItem_u AFTER UPDATE ON workItem BEGIN UPDATE changeTopic SET seq = seq + 1 WHERE topic = 'work'; END;
```
- Triggers make the counters **transactional and cross-process**. The engine, the app, the CLI and every `brahma mcp` write the same DB, and GRDB's `ValueObservation` only sees writes made in its own process.
- **Topic map** (`ChangeTopics.map: [table: Topic]`, in `BrahmaStore`): `companies`, `agents`, `turns`, `messages`, `work` (items, leases, sprints, reviews, verification, merge rows), `inbox` (asks, grants, human tasks, file asks, notices), `preview`, `releases`, `resources`, `handbook`, `memory`, `usage`, `engine` (stop, holds, probes), `events` (activity).
- `ChangeTopicsTests.everyTableMapped` lists `sqlite_master` and fails on any table that is neither mapped nor in `ChangeTopics.unobserved`, which needs a reason per entry. A future plan's new table therefore cannot silently skip notifications.
- Hot-table cost: one extra single-row `UPDATE` per row write. `ChangeTopicsBenchTests` (`.process` tier) pins insert throughput on `activityEvent` and `message` at ≥ 80 % of the no-trigger baseline. If that fails, the topic for that table uses `ActivityEvent` max-id polling, which the app already does through its cursor.

**The engine pushes.**
- R's service runs a `ChangeFeed`. On every tick, and on a 100 ms awake-time timer while there is at least one subscriber, it checks `PRAGMA data_version` (a free in-memory check).
- When the value moves, it reads `changeTopic` (≤ 20 rows) and pushes `changed { epoch, topics: [topic: seq] }` to subscribers over R's socket (the `subscribe` stream).
- Notifications are coalesced to at most one every 100 ms per connection.
- The feed has an injectable trigger and clock, so tests drive it without timers.

**The app consumes.**
- `ChangeSubscription` (in `BrahmaAppModel`) keeps the last `seq` per topic.
- On `changed`, `AppModel` reloads only the parts of the snapshot whose topics moved:
  - `Snapshot.load` splits into `CompanySummaries.load`, `WorkSnapshot.load`, `PreviewSnapshot.load`, `ReleasesSnapshot.load`, `ResourcesSnapshot.load` and `lastTurns`;
  - `SnapshotParts.dependencies` maps each part to its topics.
- The activity cursor read (`events(afterId:)`) runs on `events`. The chat refresh runs on `messages`. The live map's poll runs on `messages`, `agents` and `work`, in place of its timer. The map keeps its render loop.
- **Fallback (always correct):** without a service connection (service down, old build, crash loop), the app polls `changeTopic` directly every **2 s**. That is one small read, and the same diff logic applies. A **60 s safety refresh** reloads everything, so a missed topic can never stay stale for long. `epoch` changes (restore) trigger a full reload and re-seed the cursors.
- **Turn stream** (`observeTurnStream`, transcript files): this is not DB data. It keeps its own 1 s read, and only while a view observes it (as today).
- Notice delivery (`deliverNotices`, every 4th tick today) runs on the `inbox` topic plus the 60 s safety refresh.

**Measured outcome**, recorded in the Task 7 commit:
- DB reads per minute from an idle app go from ~120 snapshot loads to ≤ 1 (the safety refresh) plus the 2 s topic read only when the service is down.
- Change-to-screen latency is ≤ 250 ms with the service up.

---

## 6. Migration strategy (counts on `planC-collab`)

| What | Count | How |
|---|---|---|
| `SidebarItem` cases | 17 (14 fixed + channel, dm + …) | New enum plus `legacy(_:)`. The `DetailView` switch has 15 cases. `SelectTarget` cases are all kept. |
| Sidebar rows in `BrahmaApp/Views/Sidebar.swift` | 14 `NavRow`s | 7 rows plus the existing chat sections |
| CLI top-level entries | 58 | ≈ 16 visible plus `dev` |
| CLI leaf paths | 130 visible (+ `dev`'s 5, `hook`'s 2, 4a's `artifacts`) | All rows in Appendix A, frozen as a test fixture |
| Hint strings naming commands | 283 in 125 files | Rewritten. `CLIHintTests` keeps them current. |
| README `brahma …` lines | 162 | Rewritten (Task 12). The stale "This is Plan 3a" header is replaced. |
| Tests invoking the CLI | 19 files | Left on old names, which proves the aliases. New tests use new names. |
| `scripts/*.sh` CLI uses | 4 (`smoke-app.sh` 3, `fake-claude.sh` 1) | Moved to the new names |
| App polling loops | `AppModel` 500 ms, `MapController`, map header and panel `.task` loops (4) | Topic-driven (§5.5) |
| Flaky tests | 10 | §5.4 table |
| Unit-tier sleep/process constructs | 51 `Task.sleep`, 12 `Thread.sleep`, 9 `usleep`, 65 `Process()`, 90 shell `sleep` | Baseline allowlist; shrink-only |

**Rollback:** each P area is a separate task.
- The rewrite table and new command paths can be reverted on their own.
- The sidebar enum keeps `legacy(_:)`.
- Change notifications sit behind `AppModel.updateMode` (`.notifications` or `.polling`; default `.notifications`). Flipping it restores the 500 ms poll without a rebuild of the engine side.

## 7. Risks

| Risk | Mitigation |
|---|---|
| The IA moves something the owner uses daily one click deeper | ⌘1–⌘5, last-tab memory, PQ3 shortcuts. The dogfood week is the real test; tab order is a one-line change. |
| Hidden CLI breakage in owner scripts | Stdout is byte-identical, the note is TTY-only, the aliases stay for the PQ4 window, and the Appendix A fixture is tested. |
| Trigger overhead on hot tables | Bench test; per-table opt-out to cursor polling |
| The golden path becomes a slow, flaky test itself | Unit tier is in-process with `ScriptedTurnRunner`, `TestClock` and a tick loop, so it has no sleeps. The real-process version is a script run per merge, not per task. |
| Splitting heavy suites loses coverage | No deletions (anti-goal). Every moved test keeps a unit sibling. The reviewer checks the test-count diff per task (`scripts/test.sh --report` prints counts per tier). |
| 4b's Mission Control slot swap or C's views change before P | Tasks 10–11 re-read the merged views. Tabs reuse views as they are. |

---

## Appendix A — CLI old → new (frozen fixture `Tests/BrahmaCLITests/Fixtures/cli-moves.tsv`)

The old and new forms stay identical for: `status`, `why`, `say`, `log`, `search`, `approve`, `answer`, `stop`, `resume`, `doctor`, `mcp`, `hook …`, `backup …` (except `restore`), and `settings timezone`.

| Old | New |
|---|---|
| `company create\|list\|pause\|resume` | same |
| `company mode\|weight\|autonomy\|auto\|set\|profile\|trust-import` | `company set mode\|…` (`company mode` etc. kept as hidden spellings of `company set`) · `company import` (for `trust-import`) |
| `company reserve` | `budget reserve` |
| `network`, `presets` | `company network`, `company presets` |
| `hosting show\|set` (+ hidden probe) | `company hosting show\|set\|probe` |
| `secret set\|list\|rm\|load` | `company secret set\|list\|rm\|load` |
| `secret provide` | `inbox provide-secret` |
| `ext new\|lint\|add\|import-claude\|add-skill\|list\|show\|bind\|unbind\|rm\|rollback\|try` | `company ext …` (same verbs) |
| `export` | `company export` |
| `hire`, `kill`, `pause`, `wake` | `people hire\|kill\|pause\|wake` |
| `org show\|move\|vacancies\|vacancy add\|vacancy remove\|fill\|acting` | `people org\|move\|vacancies\|vacancy add\|vacancy remove\|fill\|acting` |
| `items list\|show\|add\|edit\|depend\|confirm` | `work list\|show\|add\|edit\|depend\|confirm` |
| `items readopt` | `dev readopt` |
| `sprint show\|list` | `work sprint show\|list` |
| `preview list\|set\|remove\|restart` | `work preview list\|set\|remove\|restart` |
| `release list\|show\|rollback\|smoke` | `work release list\|show\|rollback\|smoke` |
| `merge list\|settings\|retry\|resume` | `work merge list\|settings\|retry\|resume` |
| `merge adopt-main`, `main accept` | `dev adopt-main`, `dev main accept` |
| `artifacts …` (4a) | `work artifacts …` |
| `kb …` | `work handbook …` |
| `resource …`, `memory …` | `work resource …`, `work memory …` |
| `replay` | `work replay` (item) · `dev replay` (agent day); one command, both paths |
| `inbox` | `inbox` (= `inbox list`) |
| `rescind` | `inbox rescind` (`approve`, `answer` also as `inbox approve\|answer`) |
| `task list\|show\|done\|decline` | `inbox task list\|show\|done\|decline` |
| `access list\|approve`, `grants list\|revoke` | `inbox access list\|approve`, `inbox grants list\|revoke` |
| `digest`, `notices` | `inbox digest`, `inbox notices` |
| `settings plan\|share\|ultra-share` | `budget plan\|share\|ultra-share` |
| `settings auto-merge` | `company set auto-merge` (owner-wide form `settings auto-merge` kept visible) |
| `settings hot-paths\|auto-merge-paths` | `dev hot-paths\|auto-merge-paths` |
| `prefs show\|set quiet\|digest\|prevent-sleep\|notifications\|push\|push-detail` | `settings show\|quiet\|digest\|prevent-sleep\|notifications\|push\|push-detail` |
| `push test` | `dev push-test` |
| `owner init` | `settings owner-key init` |
| `restore` | `backup restore` |
| `transcript`, `timers`, `perf facts`, `milestones` | `dev transcript\|timers\|facts\|milestones` |
| `canary edit\|run`, `mode gates\|ultra-status`, `lab clear-taint` | `dev canary edit\|run`, `dev mode gates\|ultra-status`, `dev lab clear-taint` |
| `run` (R: `engine run`) | `engine run` |
| `dev release-scenario\|turn\|autopages\|digest` (`BRAHMA_DEV=1`) | `dev test release-scenario\|turn\|autopages\|digest` (still gated) |

Commands that Plan C adds after this table was written (for example `search`) are placed by the §5.2 rules in Task 8 Step 1, and the fixture is regenerated from the merged tree.

## Appendix B — Ledger evidence for the flaky tests

Roots:
- `WT=/Users/chandra/agent-company/.claude/worktrees`
- `L4A=$WT/plan4a-previews/.superpowers/sdd/2026-10-21-plan4a-workspace-previews`
- `LC=$WT/planC-collab/.superpowers/sdd/2026-10-21-planC-collab-mvp`
- `L5=$WT/plan5lite-safety/.superpowers/sdd/2026-10-21-plan5lite-safety`

The ledgers are gitignored, so search them with `/usr/bin/grep`, not the shell's grep function.

| Test | Recorded failures | Example |
|---|---|---|
| peopleOptional | 10 | `$L4A/task-2-fix2-fullsuite.txt:6800` "(provider.calls → 2) == 1" |
| retryEngineClearsAccountHold | 0 (flake list only, `$L4A/project-rules.md:30`) | — |
| loopbackListenOnlyOwnPorts | 2 after 5-lite's fix; several before | `$L4A/task-1b-fix1-fullsuite-run1.txt:6048` "own port not usable: own-exit=0" |
| staleMemoryResultsDropped | 3 | `$L4A/task-3-fullsuite-run1.txt:7028` "Caught error: Timeout()" |
| stopKillsProcessGroup | ~4 | `$L4A/task-3-fix3-fullsuite.txt:4819` |
| demoTimeout | 3 | `$LC/C2a-fullsuite.txt:3224` "61.345… < 30" |
| devHostServesOnlyItsFolder… | 1 | `$LC/C1b-fix1-fullsuite.txt:5015` |
| TurnContainmentTests timing | 0 (flake list only) | — |
| realServerIfPythonAvailable | 0 (flake list only) | — |
| stalePidHandled | 4 with `OutsideChild`, many before | `$LC/C2a-fullsuite.txt:7642` "the stale litestream was left running" |
| (systemic) sleep-poisoned run | 15 `idleTimeout`s at ~334 s | `$LC/progress.md:98-100` |
