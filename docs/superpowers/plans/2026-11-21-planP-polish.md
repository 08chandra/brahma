# Plan P — Polish before dogfood Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before the first dogfood run:
- every existing screen gets a polish pass against the visual-design spec, keeping its layout and content (owner decision 01:13). Hard-to-use spots go to the owner as a write-up and are not changed until approved;
- every CLI command, kept exactly as it is, gets clear help, examples and actionable errors (owner decision 01:16);
- a deterministic goal-to-preview test runs on every task;
- the ten recurring flakes are fixed at the root, and the unit tier runs in under 90 s;
- the app updates from engine change notifications instead of a 500 ms poll.

**Architecture:**
- **Test tiers.** There are three: `.unit` (the default, no sleeps or real processes), `.process` and `.live`. Event waits and injected clocks replace sleeps, a shrink-only hygiene scan holds the line, and a `scripts/test.sh` wrapper runs each tier.
- **Change notifications.** Change topics are SQLite trigger counters, so they work across processes. R's service pushes them over its socket, and the app reloads only the snapshot parts whose topics moved. A 2 s topic poll and a 60 s full refresh are the fallback.
- **App.**
  - A frozen accessibility inventory per screen guards the layout.
  - The theme gets type and spacing scale tokens, two contrast-fixing token values (`text2`, `accentText`) and shared empty/loading/error components, enforced by a shrink-only theme lint.
  - Heavy views are measured with `--perf-bench`.
- **CLI.** The command tree is frozen by a fixture. Help text gets examples that a test parses, error messages follow one shape, and hint strings are checked to resolve.

**Tech Stack:** Swift 6.2 toolchain (manifest `swift-tools-version: 6.0`, `.macOS(.v14)`), GRDB.swift 7.x (SQLite triggers, `PRAGMA data_version`), swift-argument-parser 1.5+, Swift Testing, SwiftUI/AppKit (app targets only), bash for scripts.

**Spec:** `/Users/chandra/agent-company/.claude/worktrees/plan-refactor-polish/docs/superpowers/specs/2026-11-21-polish-design.md` (cited as *spec §n*), including its "Owner decisions, 2026-11-21" (01:13 app, 01:16 CLI and engine). It builds on the Plan R spec `2026-11-21-restructure-service-design.md` (*R §n*) and on R's plan.

**Builds on, all merged first:** 4a, C, the 4b leftovers, S and **R**. P uses these R deliverables:
- the module and test targets;
- `BrahmaTestSupport`;
- `EngineService`, which runs in process for tests;
- `EngineClient` and the `Subscribe` stream;
- `EngineConnection` and `FakeEngineClient`;
- `scripts/split-tests.sh`.

From Plan S, P relies on these:
- S moved the loopback probes for `WebAdapter`/`BackendAdapter` readiness, smoke and demo, plus `DeploySmoke`, into `brahma-helper` (S9).
- S moved `ProcessTable`, `GroupRun` and `AwakeTime` into `BrahmaSafety` (S3).
- `SafetyLintTests` applies to P's code too.

The counts in this plan were taken on `planC-collab` 91e84e9. **Task 1 Step 1 regenerates them on merged `main`.**

## Global Constraints

All of Plan R's Global Constraints still apply. Copied here:
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Core targets stay Linux-portable.
- Durations use awake or company-active time, and every clock is injected.
- Owner decisions go only through `Store.ownerDecide`, `ownerAnswer`, `ownerRescind` and `acknowledge`.
- CLI output of agent text goes through `safe()`. The app shows it with `Text(verbatim:)` or `SafeMarkdown`.
- No test touches the Keychain or launchd.
- Use Swift Testing, with one `@Suite struct <FileName>` per new file.
- Every task ends with a green `swift build` and a green full suite.
- Never `pkill`/`kill` a process you did not start.
- Every commit ends with:
  `Co-Authored-By: Claude <your actual model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`

P additions:
- **UI uses BrahmaTheme** (Plan 2; `docs/superpowers/specs/2026-10-20-visual-design.md`):
  - 24 pt sidebar rows; 28 pt panel header strips with uppercase labels;
  - an accent 2 pt bar or underline marks a selection;
  - mono count chips; zebra tables;
  - no ad-hoc colors, fonts or radii.
- **Agent-facing CLI is frozen.** `brahma mcp`, `brahma hook pre-tool` and `brahma hook post-tool` keep their names and argv.
- **The CLI is frozen except for text** (decision 01:16).
  - No command is added, removed, renamed or regrouped, and no option or argument changes.
  - Exit codes, normal stdout and `--json` output stay byte-identical. Only `--help` output and stderr error text change.
- **The app's layouts are frozen** (decision 01:13).
  - Every screen keeps its panels, columns, controls, rows and order, and the sidebar keeps its 14 fixed rows.
  - The `ScreenInventoryTests` baseline (Task 10) may gain labels, help and identifiers only.
- **Usability findings are proposals.** Nothing in `docs/superpowers/audits/2026-11-planP-usability-findings.md` is built until the owner marks it `approved`.
- **Owner gates do not change.** Message edits never move a `requireOwnerShell()` or `BRAHMA_AGENT_ID` check.
- **Tests are never deleted or `.disabled`** to fix a flake. A test moved to `.process` keeps a unit-tier sibling that covers its logic.
- **Tiers.**
  - `.unit` is the default and has no trait. It allows no `Task.sleep`, `Thread.sleep`, `usleep`, shell `sleep N`, `Process()`, real port bind, or `Date()` deadline, except for entries on the shrink-only baseline (Task 1).
  - `.process` runs only when `BRAHMA_TEST_TIER` is `process` or `all`.
  - `.live` is the existing `BRAHMA_LIVE=1`.
- **S's safety lint.** P adds no `SafetyLintTests` baseline entry. `ProcessInspecting` uses `kill`/`sysctl`, which the lint does not cover. Anything needing `Process()`/`open(` goes through S's `Spawn`/`Place`.
- **Migration.** One new migration, `"vP-change-topics"`, appended after the last migration on merged `main`. Earlier migrations are never edited.
- **Pinned numbers** (each is a `static let` on the named type):

| Constant | Value | Owner |
|---|---|---|
| Unit-tier budget | < 90 s wall on an idle machine | `scripts/test.sh --report` |
| Golden-path unit test | < 30 s, ≤ 400 ticks | `GoldenPathTests.maxTicks` |
| Change feed check while subscribed | every 100 ms awake + every tick | `ChangeFeed.checkInterval` |
| Notification coalescing | ≤ 1 per 100 ms per connection | `ChangeFeed.coalesce` |
| App fallback topic poll (no service) | 2 s | `ChangeSubscription.fallbackInterval` |
| App safety full refresh | 60 s | `ChangeSubscription.safetyRefresh` |
| Notice delivery | on `inbox` topic + safety refresh | `AppModel` |
| Trigger overhead gate | insert throughput on `activityEvent`, `message` ≥ 80 % of no-trigger | `ChangeTopicsBenchTests` |
| `text2` / new `accentText` | #84919E / #609FF3 (`accent` fill stays #2D72D2) | `ThemeHex` |
| Contrast minimums | text 4.5 : 1, UI components 3 : 1 (WCAG AA) | `ThemeContrastTests` |
| `LoadingState` delay | 300 ms | `LoadingState.delay` |
| Heavy-view budgets | spec §5.1.5 table (first render 150–300 ms by view; scroll p95 ≤ 16.7 ms) | `PerfBudgets` |
| Help abstract | ≤ 80 chars, imperative | `CLIHelpTests` |
| Sleep detector in `scripts/test.sh` | awake vs wall divergence > 30 s → "machine slept during run: rerun" | script |

## Review Focus

1. **Polish quietly changes a screen.** Examples: a removed column, a reordered panel, a control moved into an overflow menu, agent text cut with no way to read the rest. Expected: the inventory diff shows only added labels and help, and full text stays reachable through `.help`. → Task 10 `ScreenInventoryTests.inventoryUnchanged`; Task 12 `TruncationTests.fullTextInHelp`.
2. **A change made by another process never shows up** (a CLI `brahma approve`, an agent's `brahma mcp` write, a restore), or the app keeps a stale Inbox count. Expected: visible within 250 ms with the service up and within 2 s without it. A restore forces a full reload. → Task 5 `ChangeTopicsTests.crossProcessWriteBumpsTopic`; Task 7 `ChangeSubscriptionTests.epochChangeReloadsAll`, `fallbackPollsWithoutService`.
3. **A new table added by a later plan is silently not observed.** Expected: the build fails until the table is mapped or marked unobserved with a reason. → Task 5 `ChangeTopicsTests.everyTableMapped`.
4. **A help example or hint names a command or option that does not exist,** or an improved error message leaks agent text unescaped or drops the original cause. Expected: every example parses, every hint resolves, `safe()` still wraps agent text, and the cause is still present. → Task 8 `CLIHelpTests.examplesParse`; Task 9 `CLIHintTests.everyHintResolves`, `CLIErrorStyleTests.causeKept`, `agentTextStillSafe`.
5. **A flake fix that only hides the race.** Examples: a longer timeout, or a test that now passes because it checks less. Expected: every fixed test asserts at least what it asserted before, plus the positive leg where one was missing. The unit tier has no wall-clock waits. → Tasks 2–4 (each fix lists the kept assertions); Task 1 `UnitTierHygieneTests.baselineOnlyShrinks`.

---

## File Structure

```
Tests/BrahmaTestSupport/TestTier.swift              TestTier, .process / .live traits
Tests/BrahmaTestSupport/EventWait.swift             Signal (continuation-backed), waitFor(_:)
Tests/BrahmaTestSupport/TemplateRepo.swift          cached git template, cp -c clone
Tests/BrahmaGuardTests/UnitTierHygieneTests.swift   + Fixtures/unit-tier-baseline.tsv
scripts/test.sh                                     tiers, --changed, --report, caffeinate, sleep detector
Sources/BrahmaDomain/Preview/PortAllocating.swift   protocol + SystemPortAllocator (was PortAllocator)
Sources/BrahmaEngine/Turns/TurnRegistry.swift       clock/sleeper seams, instance per Orchestrator
Sources/BrahmaDomain/Backup/ProcessInspecting.swift seam for WALShipper.reapStale
Sources/BrahmaDomain/Release/DevHost.swift          serve(connection:) seam
Sources/BrahmaStore/ChangeTopics.swift              Topic, map, unobserved, trigger SQL, read
Sources/BrahmaStore/Migrations.swift                "vP-change-topics"
Sources/BrahmaService/ChangeFeed.swift              data_version watch, push `changed`
Sources/BrahmaEngineClient/Wire/Messages.swift      Stream.changes, ChangedEvent
Sources/BrahmaAppModel/Live/ChangeSubscription.swift
Sources/BrahmaAppModel/Live/SnapshotParts.swift     split of Snapshot.load + dependencies
Sources/BrahmaApp/Theme/{BrahmaTheme,ThemeHex}.swift   type/spacing scale tokens, text2/accentText values
Sources/BrahmaApp/Theme/States.swift                EmptyState, LoadingState, ErrorState
Sources/BrahmaApp/Harness.swift                     --ui-inventory, --ui-state, --perf-bench
Sources/BrahmaApp/Views/**                          polish edits only (no layout change)
Sources/BrahmaAppModel/Presentation/PerfBudgets.swift
Tests/BrahmaAppModelTests/{ThemeContrastTests,TruncationTests,PresentationPerfTests}.swift
Tests/BrahmaGuardTests/ThemeLintTests.swift         + Fixtures/theme-lint-baseline.json
Tests/Fixtures/ui-inventory/<screen>.json           frozen before polish; scripts/ui-inventory.sh; Tests/BrahmaAppTests/ScreenInventoryTests.swift
docs/superpowers/audits/2026-11-planP-ui-audit.md, 2026-11-planP-usability-findings.md
Sources/brahma/*.swift                              abstracts, discussions (EXAMPLES), option help, error text only
Tests/BrahmaCLITests/{CLITreeFrozenTests,CLIHelpTests,CLIErrorStyleTests,CLIHintTests}.swift + Fixtures/cli-tree.tsv
scripts/{cli-tree,perf-bench}.sh
Sources/BrahmaEngine/Testing/ScriptedTurnRunner.swift   (package; test support for the golden path)
Tests/BrahmaEngineTests/GoldenPathTests.swift
scripts/golden-path.sh, scripts/fake-claude-roles/{ceo,lead,eng,reviewer}.sh
README.md
```

---

### Task 1: Tiers, the hygiene baseline, `scripts/test.sh`, shared-resource isolation

**Files:**
- Create: `Tests/BrahmaTestSupport/TestTier.swift`, `EventWait.swift`, `TemplateRepo.swift`, `Tests/BrahmaGuardTests/UnitTierHygieneTests.swift`, `Fixtures/unit-tier-baseline.tsv`, `scripts/test.sh`, `Sources/BrahmaDomain/Preview/PortAllocating.swift`
- Modify:
  - `Preview/Supervision.swift`: `PortAllocator.range`/`allocate` move behind `SystemPortAllocator`. `PreviewRunner` takes `any PortAllocating`, with the same default range `47100...47999`.
  - `Orchestrator+Sandbox` successor (R's `TurnLauncher`): `defaultClaudeTmpRoot` comes from `SandboxEnvironment.claudeTmpRoot`. The default stays `/private/tmp/b-<uid>`. Tests set it under the scratch root.
  - `TestScratch.swift` (the support target): the startup sweep removes only roots whose pid is dead **and** whose `.owner` marker names this checkout's path.

**Interfaces:**
- Produces:
  - `enum TestTier { static var process: Bool; static var live: Bool }`. `process` is true when `BRAHMA_TEST_TIER` is `process` or `all`. `live` keeps the existing `BRAHMA_LIVE == "1"`.
  - `extension Trait where Self == ConditionTrait { static var processTier: Self; static var liveTier: Self }`
  - `final class Signal: Sendable { func fire(); func wait() async }`, backed by a continuation and safe to fire before `wait`.
  - `func waitFor(_ signal: Signal) async`
  - `enum TemplateRepo { static func clone(into dir: URL) throws }`. It makes one `git init` plus one commit per process, then `cp -c -R`.
  - `public protocol PortAllocating: Sendable { func allocate(excluding: Set<Int>) throws -> Int }`
  - `struct SystemPortAllocator: PortAllocating { var range: ClosedRange<Int> = 47100...47999 }`
  - In test support: `RangePortAllocator(base: 47100 + (getpid() % 80) * 10, width: 10)`.
  - `scripts/test.sh [unit|process|all] [--changed] [--report]` exits with the `swift test` status. `--report` prints the 15 slowest suites and the test count per tier.

- [ ] **Step 1:** Regenerate the spec §6 counts on merged `main`. Write `unit-tier-baseline.tsv`, one `file<TAB>construct<TAB>count` row per test file per construct, with the constructs from the Global Constraints. Generate it with a scan script kept at `scripts/unit-tier-scan.sh`.
- [ ] **Step 2: Write `UnitTierHygieneTests`.**
  - `baselineOnlyShrinks`: for each unit-tier file (any file whose suite lacks `.processTier`/`.liveTier`), the current counts are ≤ the baseline's.
  - `noNewFileInBaseline`: a file not in the baseline has 0 of each construct.
- [ ] **Step 3:** Run it. Expected: PASS against the freshly generated baseline.
- [ ] **Step 4:** Implement the seams above. Then write:
  - `PortAllocatingTests.rangeAllocatorStaysInRange`;
  - `ScratchSweepTests.foreignCheckoutRootsUntouched` (a root with a live-looking marker for another path survives the sweep);
  - `SandboxEnvironmentTests.claudeTmpRootDefaultUnchanged`.
- [ ] **Step 5:** Write `scripts/test.sh`.
  - It runs `caffeinate -i` around `swift test`.
  - It records `AwakeTime`-equivalent uptime (`sysctl kern.monotonicclock_usecs` vs `date +%s`) at start and end, and prints the sleep warning when they diverge by more than 30 s.
  - It exports `BRAHMA_TEST_TIER`.
  - With `--changed`, it maps `git diff --name-only main...` source paths to their test targets and passes `--filter` per target.
- [ ] **Step 6:** Run `scripts/test.sh unit --report`. Expected: green, with a report. Record the baseline wall time in the commit body.
- [ ] **Step 7: Commit.**

### Task 2: App-model flakes: `peopleOptional`, `retryEngineClearsAccountHold`, `staleMemoryResultsDropped`

**Files:**
- Modify: `Tests/BrahmaAppModelTests/MapControllerTests.swift` (`live()` takes a `MapTestClock`), `WorkModelTests.swift:136`, `SearchModelTests.swift` (`Gate`), `Sources/BrahmaAppModel/Work/AppModel+Work.swift` (`retryEngine` uses `clock()`)

**Interfaces:**
- Consumes: Task 1 `Signal`; R's `FakeEngineClient`.

- [ ] **Step 1: `peopleOptional`** (spec §5.4 row 1). `live(_:_:people:clock:)` passes the clock to `MapController(…, clock:)`. The test pins the clock, then asserts:
  - first poll: `calls == 1`;
  - second poll, clock unchanged: `calls == 1` (kept assertion);
  - after `clock.advance(10)` and a poll: `calls == 2` (new positive leg).
- [ ] **Step 2: `retryEngineClearsAccountHold`.**
  - Use `FakeEngineClient(recheck: .passing)` and an injected `AppModel` clock. There is no engine process or lock.
  - Kept assertion: `#expect(try w.store.engineHold() == nil)`.
  - Add: `#expect(try w.store.events(...).contains { $0.text.contains("hold cleared") })`, matching today's activity text exactly. Read it from `clearHoldAfterDoctor`.
- [ ] **Step 3: `staleMemoryResultsDropped`.**
  - `Gate` gains `let waiting = Signal()`, fired inside the gate before it blocks.
  - The test awaits `gate.waiting.wait()` instead of `eventually`, with the suite's `.timeLimit(.minutes(1))` as the only bound.
  - The assertions are unchanged.
- [ ] **Step 4:** Run each test 50 times: `for i in $(seq 50); do swift test --filter '<name>' || break; done`. Then run the unit tier. Expected: 50/50, then green.
- [ ] **Step 5:** Regenerate the baseline (counts must drop). Commit.

### Task 3: Process-bound flakes: `stopKillsProcessGroup`, `demoTimeout`, `devHost…`, `realServerIfPythonAvailable`, `loopbackListenOnlyOwnPorts`

**Files:**
- Modify:
  - `Tests/.../PreviewSupervisionTests.swift`
  - `CLIAdapterTests.swift`
  - `LiveCLITests.swift`
  - `WebAdapterTests.swift`
  - `SeatbeltRunnerTests.swift`
  - `Sources/BrahmaDomain/Release/DevHost.swift`, adding `func serve(connection fd: Int32)` (`package`), which is the body of today's private `handle(_:)`
- Create: `Tests/BrahmaSafetyTests/SeatbeltProfileLoopbackTests.swift` (or the test target S created for the profile)

**Interfaces:**
- Consumes: Task 1 `PortAllocating`, `RangePortAllocator` and `.processTier`.
- First read the merged versions of these tests. S9 moved the adapters' loopback probes into the helper, so `WebAdapterTests` and `PreviewSupervisionTests` may already drive `HelperClient` fakes. Apply each fix below to the test as merged, and keep its assertions.

- [ ] **Step 1: `stopKillsProcessGroup`.**
  - Unit test `PreviewStopLogicTests.stopTerminatesThenKills`: a fake `SandboxedProcess` records `terminate(grace:)` → SIGTERM, then SIGKILL after the grace on `ManualClock`. Assert the order and the 5 s grace value.
  - The real-process test moves to `.processTier`. Its script writes `echo $! >> pids` per child, and the test reads the pids file and checks them through `ProcessTable`, not `ps`.
  - Kept assertions: three or more members, the leader alive before stop, and every member gone after.
- [ ] **Step 2: `demoTimeout`.**
  - `FakeSandboxRunner` returns `CheckOutcome(timedOut: true, output: "started\n")`.
  - Assert the `PreviewUpdate` message equals today's timeout message (read it from `CLIAdapter.runDemo`) and contains `started`.
  - Delete the `Date()` assertion. Real timeout enforcement is covered by `GroupRunTests` with a stepping clock: add `GroupRunTests.timeoutKillsOnSteppingClock` if no such test exists.
- [ ] **Step 3: `devHostServesOnlyItsFolderAndGrantsOnlyTheCopy`.**
  - The unit leg uses `socketpair(AF_UNIX, SOCK_STREAM)`, writes `GET / HTTP/1.1\r\n\r\n`, calls `server.serve(connection:)`, and reads the status line.
  - It asserts `404`, then `serve(folder: "R-1")`, then `200`. These are the same assertions as today.
  - The TCP + URLSession leg moves to `.processTier`.
- [ ] **Step 4: `realServerIfPythonAvailable`** moves to `.processTier`. It uses `RangePortAllocator`. The `port+1` assertion becomes "the second run's output contains `Operation not permitted`".
- [ ] **Step 5: `loopbackListenOnlyOwnPorts`.**
  - The unit test `SeatbeltProfileLoopbackTests.rendersOwnPortsOnly` renders `.loopbackListen(allow: true, ports: [p])` and asserts the exact `(allow network-bind network-inbound (local ip "localhost:<p>"))` line, with no line for `p+1`.
  - The kernel test moves to `.processTier, .serialized`, with a per-run nonce payload. A listener that exits 0 without the nonce is retried up to 3 times.
- [ ] **Step 6:** Run the unit tier, then `scripts/test.sh process`. Expected: both green. Run each unit sibling 50 times. Expected: 50/50.
- [ ] **Step 7:** Regenerate the baseline. Commit.

### Task 4: Containment and WAL flakes: `TurnContainmentTests`, `stalePidHandled`

**Files:**
- Modify:
  - `Sources/BrahmaEngine/Turns/TurnRegistry.swift`: inject `clock: AwakeClock` and `sleep: @Sendable (Duration) async throws -> Void` into `claim` and `waitUntilGone`. Add an instance per Orchestrator, with `TurnRegistry.shared` kept as the default.
  - `Sources/BrahmaDomain/Backup/WALShipping.swift`: `reapStale` uses `ProcessInspecting`, exposed on `WALShipper.init`.
  - `Tests/.../TurnContainmentTests.swift`, `BackupTargetTests.swift`
- Create: `Sources/BrahmaDomain/Backup/ProcessInspecting.swift`, `Tests/.../WALReapTests.swift`

**Interfaces:**
- Produces:
  - `public protocol ProcessInspecting: Sendable { func arguments(of pid: pid_t) -> [String]?; func isAlive(_ pid: pid_t) -> Bool; func signal(_ pid: pid_t, _ sig: Int32) -> Bool }`
  - `struct SystemProcesses: ProcessInspecting`, with today's `ProcessArguments.of`, `kill(pid,0)` and `kill`.
  - `WALShipper.init(…, processes: any ProcessInspecting = SystemProcesses())`.

- [ ] **Step 1: Write `WALReapTests`** (unit):
  - `staleLitestreamGetsTermThenKill`: the fake process stays alive after TERM. Assert TERM, then a `grace` sleep on the injected sleeper, then KILL, with argv re-checked before KILL.
  - `unrelatedPidNeverSignalled`.
  - `unreadablePidFileRemoved`.
  - `argvChangedBetweenChecksNotKilled`.
- [ ] **Step 2:** Run them. Expected: FAIL. Implement the seam. Run again. Expected: PASS.
- [ ] **Step 3:** `stalePidHandled` moves to `.processTier`. It passes `note: { lines.append($0) }` and prints `lines` in the `#require` message. The kept assertion is "the stale litestream was left running" → `!stale.isRunning`.
- [ ] **Step 4: `TurnContainmentTests`.**
  - `waitFailsClosedOnDeadlineAndCancellation` uses an injected `ManualClock` and sleeper, which makes it unit tier.
  - The scripts behind `pid(in:)`, `gone()` and `markerProbeMatchesOnlyThisTurnsSandbox` write a `ready` file after `sandbox-exec` applies, for example `touch ready` as the first command inside the profile. The fixed 300 ms and 50 ms sleeps go.
  - The escapee tests (spec §5.4 row) move to `.processTier`, keeping `.serialized`.
- [ ] **Step 5:** Run the unit tier and `scripts/test.sh process`. Run the unit siblings 50 times. Expected: green, 50/50.
- [ ] **Step 6:** Regenerate the baseline. Commit.

### Task 5: Change topics (migration, map, triggers)

**Files:**
- Create: `Sources/BrahmaStore/ChangeTopics.swift`, `Tests/BrahmaStoreTests/{ChangeTopicsTests,ChangeTopicsBenchTests}.swift`
- Modify: `Sources/BrahmaStore/Migrations.swift` (`"vP-change-topics"`), and `Restore` (it writes a new `changeEpoch` after replacing the DB)

**Interfaces:**
- Produces:
  - `public enum Topic: String, CaseIterable, Codable, Sendable { case companies, agents, turns, messages, work, inbox, preview, releases, resources, handbook, memory, usage, engine, events }`
  - `public enum ChangeTopics { static let map: [String: Topic]; static let unobserved: [String: String] /* table → reason */; static func triggerSQL(table: String, topic: Topic) -> [String]; }`
  - `extension Store { public func changeSeqs() throws -> (epoch: String, seqs: [Topic: Int64]) }`
  - The migration creates the two tables of spec §5.5, seeds one row per `Topic` with `seq = 0`, writes `changeEpoch` with a new UUID, and creates three triggers (INSERT, UPDATE, DELETE) per mapped table.

- [ ] **Step 1: Write the tests:**
  - `everyTableMapped`: every table in `sqlite_master` (excluding `sqlite_%`, `grdb_%` and FTS shadow tables) is in `map` or `unobserved`.
  - `insertUpdateDeleteBumpOnce`: one row write bumps its topic by exactly 1 and the others by 0.
  - `crossProcessWriteBumpsTopic`: a second `Store` instance on the same file (standing in for another process) writes, and the first reads the bumped seq.
  - `rollbackDoesNotBump`.
  - `restoreChangesEpoch`.
  - `ChangeTopicsBenchTests.triggerOverheadWithinGate` (`.processTier`): 10,000 inserts into `activityEvent` and `message` with and without triggers (an in-memory copy of the schema). Ratio ≥ 0.80. If it fails, move that table to `unobserved` with reason "cursor-polled (bench)", and the app keeps its cursor for it (Task 7).
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement. The map is generated from merged `main`'s table list in Step 1, and every table gets a decision.
- [ ] **Step 4:** Run the store tests, `RestoreTests`, `StoreMigrationTests` and the full suite. Expected: green.
- [ ] **Step 5: Commit.**

### Task 6: `ChangeFeed` in the service

**Files:**
- Create: `Sources/BrahmaService/ChangeFeed.swift`, `Tests/BrahmaServiceTests/ChangeFeedTests.swift`
- Modify: `Sources/BrahmaEngineClient/Wire/Messages.swift` (`Stream.changes`, `ChangedEvent`), `EngineService.swift` (owns a feed, hooks the tick and subscribers)

**Interfaces:**
- Produces:
  - `public struct ChangedEvent: Codable, Equatable, Sendable { public var epoch: String; public var seqs: [Topic: Int64] }`
  - `final class ChangeFeed { init(store: Store, clock: AwakeClock, trigger: ChangeFeedTrigger = .timer(.milliseconds(100))); func check() -> ChangedEvent? /* nil when data_version and seqs unchanged */; func subscribe(_ send: @escaping @Sendable (ChangedEvent) -> Void) -> SubscriptionToken }`. It coalesces to ≤ 1 per 100 ms per subscriber.
  - `ChangeFeedTrigger.manual` exists for tests.

- [ ] **Step 1: Write the tests:**
  - `unchangedDataVersionReadsNothing`: a spy counts `changeTopic` reads, and the count is 0 when `PRAGMA data_version` did not move.
  - `externalWritePushesTopics`.
  - `coalescesBursts`: 50 writes within 100 ms on `ManualClock` produce one event with the final seqs.
  - `subscriberGetsCurrentSeqsOnSubscribe`.
  - `serviceStreamDeliversChanged`: the in-process service and an `EngineClient` subscribed to `.changes`, then a write through a second `Store`, then an event.
- [ ] **Step 2:** Run them. Expected: FAIL. Implement. Run again. Expected: PASS.
- [ ] **Step 3: Commit.**

### Task 7: App consumes change notifications

**Files:**
- Create: `Sources/BrahmaAppModel/Live/ChangeSubscription.swift`, `Live/SnapshotParts.swift`, `Tests/BrahmaAppModelTests/ChangeSubscriptionTests.swift`
- Modify:
  - `AppModel.swift`: `startPolling` becomes `startUpdates(mode:)`. `updateMode: UpdateMode` (`.notifications` default, `.polling` keeps today's 500 ms loop).
  - `Live/Snapshot.swift`: `load` composes the parts and is kept for `.polling` and the safety refresh.
  - `Map/MapController.swift`: polls on the `messages`/`agents`/`work` topics instead of its timer while subscribed.
  - `Chat/ChatModel.swift` (refresh on `messages`).

**Interfaces:**
- Consumes: Task 6 `ChangedEvent`, R's `EngineConnection`.
- Produces:
  - `enum SnapshotPart: CaseIterable { companies, selectedAgents, channels, work, preview, releases, resources, lastTurns, usage, engine }`
  - `SnapshotParts.dependencies: [SnapshotPart: Set<Topic>]` and `static func load(_ parts: Set<SnapshotPart>, into: inout Snapshot, store: Store, selectedCompanyId: String?) throws`
  - `@MainActor final class ChangeSubscription { init(connection: EngineConnection?, store: Store, clock: AwakeClock); var onChange: (Set<Topic>, _ epochChanged: Bool) async -> Void; func start(); func stop() }`. It follows the service stream when one is connected, else polls `store.changeSeqs()` every 2 s, and always runs a full refresh every 60 s.

- [ ] **Step 1: Write the tests** (`FakeEngineClient` and `ManualClock`):
  - `onlyChangedPartsReload`: a `work` bump reloads `.work` only (a spy counts `SnapshotParts.load` calls per part).
  - `eventsTopicAdvancesActivityCursor`.
  - `messagesTopicRefreshesChat`.
  - `epochChangeReloadsAll`, which also re-seeds the cursor.
  - `fallbackPollsWithoutService`: no connection, the clock advances 2 s, a topic read happens.
  - `safetyRefreshEvery60s`.
  - `noticesDeliveredOnInboxTopic`.
  - `pollingModeUnchanged`: `.polling` runs today's tick every 500 ms.
- [ ] **Step 2:** Run them. Expected: FAIL. Implement. Run again. Expected: PASS.
- [ ] **Step 3:** Measure with the app against a demo home (`scripts/seed-demo.sh`): count `Snapshot` part loads per minute while idle, and the change-to-screen latency for `brahma approve` from Terminal, read from a timestamped log line. Record both in the commit body. Expected: ≤ 1 full load per minute idle, ≤ 250 ms.
- [ ] **Step 4:** Run the full suite and `scripts/smoke-app.sh`. Expected: green, `SMOKE OK`.
- [ ] **Step 5: Commit.**

### Task 8: CLI tree freeze, help text and examples

**Files:**
- Create: `Tests/BrahmaCLITests/{CLITreeFrozenTests,CLIHelpTests}.swift`, `Tests/BrahmaCLITests/Fixtures/cli-tree.tsv`, `scripts/cli-tree.sh` (walks `--help` recursively and prints `path<TAB>options<TAB>arguments`, with no prose)
- Modify: `Sources/brahma/*.swift`, changing `abstract:`, `discussion:` and `help:` strings **only**

**Interfaces:**
- Produces: `enum CommandTree { static func all() -> [(path: [String], type: ParsableCommand.Type)] }`, a test helper that walks `Brahma.configuration` including hidden commands.

- [ ] **Step 1:** Run `scripts/cli-tree.sh` on merged `main` and write `cli-tree.tsv`. Record the counts (top-level entries, leaves, abstracts, discussions, option help) in the commit body.
- [ ] **Step 2: Write the tests:**
  - `CLITreeFrozenTests.treeMatchesFixture`: `CommandTree.all()` plus each command's option and argument names equal the fixture.
  - `CLIHelpTests.everyCommandHasAbstract`: non-empty, ≤ 80 characters, first word is an imperative verb from a fixed list (Show, List, Set, Add, Remove, Create, Approve, Answer, Run, Stop, Resume, Hire, Kill, Pause, Wake, Move, …; extend the list when a real abstract needs it).
  - `everyLeafHasExamples`: the `discussion` contains `EXAMPLES:` followed by 1–3 lines starting with `brahma `.
  - `examplesParse`: every example line parses with `Brahma.parseAsRoot`.
  - `destructiveCommandsWarn`: `kill`, `stop`, `restore`, `grants revoke`, `secret rm`, `resource purge` and `memory` delete each say what cannot be undone.
  - `optionHelpStatesUnits`: options whose names end in `-minutes`, `-seconds`, `timeout`, `cap`, `share` or `weight` mention a unit or range.
- [ ] **Step 3:** Run them. Expected: `treeMatchesFixture` PASS, the others FAIL with a list.
- [ ] **Step 4:** Rewrite the strings. Add the root `discussion` "Start here: brahma status · brahma inbox · brahma why <company> · brahma doctor". Keep the root's flat list and order. Use seeded demo names in examples (`acme`, `@eng-1`, `A-3`).
- [ ] **Step 5:** Run the tests and the full suite. Tests that snapshot `--help` text get the same string updates, counted in the commit body. Expected: green, and `treeMatchesFixture` still PASS.
- [ ] **Step 6: Commit.**

### Task 9: CLI error messages and hint strings

**Files:**
- Create: `Tests/BrahmaCLITests/{CLIErrorStyleTests,CLIHintTests}.swift`, `Fixtures/cli-error-allowlist.tsv`
- Modify: `fail(`/`ValidationError(` literals in `Sources/brahma` (204 + 34 on `planC-collab`); `description`s of `StoreError`, `WorkError` and `RestoreError` printed verbatim by the CLI; stale hint strings found in Step 3; `README.md` (CLI section: the stale "This is Plan 3a" header, a "Start here" block, and examples)

**Interfaces:**
- Consumes: Task 8 `CommandTree`.

- [ ] **Step 1: Write `CLIErrorStyleTests`.**
  - `everyErrorSaysWhatToDo`: each literal argument of `fail(`/`ValidationError(` ends with a sentence that starts with Run/Open/Use/Check/Try/Set/Ask/Wait or contains a quoted `'brahma …'`, unless it is listed in `cli-error-allowlist.tsv` with a reason. The allowlist is shrink-only.
  - `causeKept`: for 10 representative errors (doctor fail, owner key missing, engine running, database check failed, not found, forbidden, invalid timezone, no such company, secret held, merge refused), the new message still contains the original cause text. Use golden strings.
  - `agentTextStillSafe`: an error built from an agent-controlled name containing `\u{1b}[31m` and `\n` prints escaped.
  - Exit codes are unchanged for the same 10 cases.
- [ ] **Step 2: Write `CLIHintTests.everyHintResolves`.** Scan string literals in `Sources/**/*.swift` and `README.md` for `brahma ([a-z][a-z-]*)( [a-z][a-z-]*)*( --[a-z-]+)*`. The longest command prefix must exist in `CommandTree`, and each `--option` must exist on it. `mcp` and `hook` are excepted.
- [ ] **Step 3:** Run them. Expected: FAIL with lists.
- [ ] **Step 4:** Rewrite the messages to the spec §5.2 shape: `brahma: <what failed>: <why>. <what to do>`. Fix stale hints. Update the README's CLI section. Tests asserting stderr text get the same updates, listed in the commit body.
- [ ] **Step 5:** Run the tests and the full suite. Expected: green, and `CLITreeFrozenTests` still PASS.
- [ ] **Step 6: Commit.**

### Task 10: UI audit and the frozen screen inventory

**Files:**
- Modify: `Sources/BrahmaApp/Harness.swift`. Add `--ui-inventory <out.json>`, which walks the key window's accessibility tree and writes role, identifier, label and order, with no values, then quits. Add the states `--ui-state=empty|loading|error|long` (it seeds or injects through the existing harness: a fresh home, a slowed store, a failing store, generated long content).
- Create: `scripts/ui-inventory.sh` (every screen × state, through the existing `--select` targets), `Tests/Fixtures/ui-inventory/*.json`, `Tests/BrahmaAppTests/ScreenInventoryTests.swift` (`.processTier`; it launches the built app), `docs/superpowers/audits/2026-11-planP-ui-audit.md`

**Interfaces:**
- Produces:
  - the frozen inventory baseline;
  - the audit sheet, whose rows have the columns screen, state, finding, rule, class (Polish/Usability/Perf) and screenshot path.

- [ ] **Step 1:** `scripts/make-app.sh debug`, then `scripts/ui-inventory.sh --write-baseline`. Commit the baseline **before any visual change**.
- [ ] **Step 2: Write `ScreenInventoryTests.inventoryUnchanged`.** It runs the script without `--write-baseline` and diffs the result. Allowed: added labels, help and identifiers. Anything else fails, and the diff is printed. Run it. Expected: PASS.
- [ ] **Step 3:** Run `scripts/ui-snapshot.sh` for every screen × state of spec §5.1.1, and read every PNG. Fill the audit sheet against spec §5.1.2–§5.1.5 and the visual-design spec lines. Classify each finding. A finding that changes content, location or flow is **Usability**, never Polish.
- [ ] **Step 4: Commit** the audit sheet, its screenshots (`docs/superpowers/audits/img/`) and the harness flags.

### Task 11: Usability write-up for the owner (owner-gated)

**Files:**
- Create: `docs/superpowers/audits/2026-11-planP-usability-findings.md`

**Interfaces:**
- Consumes: Task 10's audit rows classed **Usability**.
- Produces: the owner-facing file in the spec §5.1.6 format.

- [ ] **Step 1:** For each Usability row, write one entry:
  - **Screen:** the view and state, plus a snapshot path.
  - **Problem:** one sentence.
  - **Why:** the evidence, such as clicks or steps counted, a misleading label, a hidden state, an error without a next step, or a citation to the analysis.
  - **Proposed fix:** the smallest change, with an ASCII before/after sketch.
  - **Effort:** S, M or L.
  - **Status:** `proposed`.

  Order the entries by impact on the dogfood week, highest first. Leave out any navigation restructure (decision 01:13).
- [ ] **Step 2:** Check that no polish task touches a screen element named in a `proposed` entry's fix. List those elements at the top of the file under "Hold: do not polish". Tasks 13–15 skip them.
- [ ] **Step 3: Commit**, then tell the controller that the file is ready for the owner. **Do not build any entry.** If an entry is marked `approved` before Task 15 ends, the controller appends a task for it. Later approvals become a follow-up plan.

### Task 12: Theme tokens, contrast, shared states, theme lint

**Files:**
- Modify: `Sources/BrahmaApp/Theme/BrahmaTheme.swift` and `ThemeHex` (wherever 4b put the single source). Add the type and spacing scale tokens of spec §5.1.2. Set `text2` = #84919E, add `accentText` = #609FF3, and add `killedName` (= `text2` + strikethrough modifier).
- Create: `Sources/BrahmaApp/Theme/States.swift`, `Tests/BrahmaAppModelTests/ThemeContrastTests.swift` (tests `ThemeHex` in the model target), `Tests/BrahmaGuardTests/ThemeLintTests.swift`, `Fixtures/theme-lint-baseline.json`, `Tests/BrahmaAppModelTests/TruncationTests.swift`

**Interfaces:**
- Produces:
  - `BrahmaTheme.Font.{label, panelTitle, body, bodyStrong, mono, monoSmall, companyName}`
  - `BrahmaTheme.space{XXS=2, XS=4, S=8, M=12, L=16}`, keeping existing names as aliases where the values match
  - `struct EmptyState: View { init(_ text: String) }`
  - `struct LoadingState: View { static let delay: Duration = .milliseconds(300) }`
  - `struct ErrorState: View { init(_ message: String, retry: (() -> Void)?) }`
  - `enum ThemeContrast { static func ratio(_ a: String, _ b: String) -> Double; static let allowedPairs: [(text: String, background: String, kind: Kind)] }`
  - `enum TruncatedText { static func cell(_ s: String) -> (shown: String, help: String) }`. This is the model-side helper for one-line cells. The help always carries the full verbatim text.

- [ ] **Step 1: Write the tests:**
  - `ThemeContrastTests.textPairsMeetAA` (≥ 4.5) and `componentPairsMeet3to1`.
  - `disallowedPairsListed`: `text2` on `bg4` is not in `allowedPairs`.
  - `measuredValues`: `ratio("84919E","1A2129")` is between 5.03 and 5.05, and `ratio("609FF3","2A3540")` is between 4.60 and 4.62.
  - `ThemeLintTests.baselineOnlyShrinks` and `noNewFileHits`.
  - `TruncationTests.fullTextInHelp`.
- [ ] **Step 2:** Run them. Expected: the contrast tests FAIL (old `text2`). Generate the lint baseline. It is expected to be non-empty.
- [ ] **Step 3:** Change the token values. Add the states and tokens. Replace every `accent` used as a text colour with `accentText`, which `grep` lists. On `bg4` rows use `text1` for tertiary text.
- [ ] **Step 4:** Run the tests and `ScreenInventoryTests`. Take before/after snapshots of Mission Control, Backlog and Inbox for the owner. Expected: PASS, with the inventory unchanged.
- [ ] **Step 5: Commit**, with the before/after PNG paths in the body. This is the one commit to revert if the owner vetoes the lighter `text2`.

### Task 13: Polish A — shell, Mission Control, Activity, Agents, chat

**Files:**
- Modify: `Sources/BrahmaApp/Views/{CompanyRail,Sidebar,TopBar,MenuBarContent,EngineBanner,StartupErrorView,MissionControlView,ActivityFeedView,AgentsView,ReplayView,ChatView,Composer,NewDMPicker,HireSheet,OrgPreview}.swift`, `Views/Map/{AgentMapPanel,MapHeader,MapHoverCardView,FillVacancySheet}.swift`, `Views/Preview/*`

**Interfaces:**
- Consumes: Task 12's tokens, states and `TruncatedText`. Task 11's "Hold" list.

- [ ] **Step 1:** For every audit row classed Polish on these screens, apply the fix: spacing, alignment, type scale, hairlines, chips, states, hover (`bg3`, 120 ms), focus ring, keyboard (Tab order, arrows in lists, Return opens, Esc closes), `.help` and accessibility labels on icon-only buttons, truncation per spec §5.1.4, the top-bar collapse order, and Reduce Motion. Mark each audit row `done` with its commit.
- [ ] **Step 2:** Micro-interactions per the brief:
  - activity lines flash `bg3` for 600 ms;
  - a status chip pulses only for `running`;
  - list insert and remove animate in 120–200 ms;
  - copy actions confirm inline for 1.5 s.

  All of these are off under Reduce Motion.
- [ ] **Step 3:** Run `ThemeLintTests` (its baseline must shrink, so update it down), `ScreenInventoryTests` and the full suite. Take UI snapshots of each screen and read them. Expected: green, with the inventory unchanged.
- [ ] **Step 4: Commit.**

### Task 14: Polish B — Work screens

**Files:**
- Modify: `Views/{BacklogView,BoardView,WorkComponents,ItemEditorSheet,ReleasesView,DeployCardView,HostingPanel,BudgetView,StoragePanel,SearchResultsView}.swift`, `Views/Handbook/*`, `Views/Resources/*`, `Views/Changes/*` (C), `Views/Refs/*` (C)

- [ ] **Step 1:** Run the same cycle as Task 13, Steps 1–3, for these screens.
- [ ] **Step 2: Commit.**

### Task 15: Polish C — Inbox, Grants, Digest, Settings, Backups, sheets

**Files:**
- Modify: `Views/{InboxView,AccessCardView,HumanTaskCardView,LiveCardFallbackView,GrantsView,DigestView,CompanySettingsView,BackupsView,SecretSheet,NewCompanySheet}.swift`, plus any sheet not covered by Tasks 13–14

- [ ] **Step 1:** Run the same cycle as Task 13, Steps 1–3, for these screens.
- [ ] **Step 2:** Confirm every audit row classed Polish is `done`, or moved to Usability with a reason.
- [ ] **Step 3: Commit.**

### Task 16: Heavy-view performance

**Files:**
- Modify: `Sources/BrahmaApp/Harness.swift` (`--perf-bench=<view>`: seeds spec §5.1.5's load into a temp home, opens the view, scrolls with a synthetic scroll for 5 s, and prints JSON `{firstRenderMs, p95FrameMs}` measured with `os_signpost` and 4b's `FrameStats`). Also modify the presentation builders and views that miss their budget.
- Create: `Sources/BrahmaAppModel/Presentation/PerfBudgets.swift`, `Tests/BrahmaAppModelTests/PresentationPerfTests.swift` (`BRAHMA_PERF=1`, existing `PerfGate`), `scripts/perf-bench.sh`

**Interfaces:**
- Produces: `enum PerfBudgets { static let firstRenderMs: [PerfView: Double]; static let p95FrameMs = 16.7 }`, where `PerfView` is `backlog`, `board`, `activity`, `chat`, `inbox`, `handbookPage`, `changesDiff` or `search`.

- [ ] **Step 1:** Run `scripts/perf-bench.sh` for every view and record the "before" table in the commit body.
- [ ] **Step 2: Write `PresentationPerfTests`.** For each view's presentation builder (for example `WorkPresentation.rows` for 500 items), time it with `ContinuousClock` over 20 runs. The median must be ≤ 25 % of the view's `firstRenderMs` budget.
- [ ] **Step 3:** Fix the misses using only the spec §5.1.5 allowed fixes:
  - lazy containers with stable ids;
  - presentation rows precomputed off the main actor;
  - `Equatable` views;
  - no DB read on the main actor;
  - shared cached formatters.

  **Never page or truncate what the screen shows.**
- [ ] **Step 4:** Run `scripts/perf-bench.sh` again (the "after" table), then `ScreenInventoryTests` and the full suite. Expected: every view within budget, or listed in the commit body with the reason and remaining gap. Inventory unchanged.
- [ ] **Step 5: Commit.**

### Task 17: Golden path, in process

**Files:**
- Create: `Sources/BrahmaEngine/Testing/ScriptedTurnRunner.swift` (`package`, compiled into the engine target so tests can share it), `Tests/BrahmaEngineTests/GoldenPathTests.swift`

**Interfaces:**
- Consumes: R's in-process `EngineService` (or `Orchestrator` directly), the real `CompanyTools` dispatch used by `brahma mcp`, `FakeSandbox`, `FakeHTTPProbe` or S's helper fake for loopback probes, `TestClock`, and `TemplateRepo`.
- Produces: `package final class ScriptedTurnRunner: TurnRunning { init(script: [RoleKey: [TurnScript]], tools: (Agent) -> CompanyToolDispatch) }`. A `TurnScript` is a list of `ToolCall(name: String, arguments: JSONValue)`, plus optional file writes and commits in the agent's worktree. The runner emits the stream-json result lines `StreamParser` reads.

- [ ] **Step 1: Write `GoldenPathTests.goalToPreviewAndDeployAsk`.** It is `@Test(.timeLimit(.minutes(1)))`, drives `orchestrator.tick()` up to `maxTicks = 400`, and advances `TestClock` 1 s per tick. It asserts these phases in order:
  1. The company exists with the software pack, and the org has a CEO, a lead, `@eng-1` and a reviewer.
  2. The brief exists, and the backlog has A-1 with a check spec.
  3. A-1 is leased to `@eng-1` with a worktree.
  4. A-1 is `inReview` after submit.
  5. A verification run `passed`.
  6. The review was approved.
  7. `main` contains the engineer's commit (real git `rev-parse`).
  8. The web preview is `running` at that commit.
  9. `WorkSnapshot.load(...).inbox` contains a `deploy` ask.
  10. After `store.ownerDecide(.approve)`, the release reaches `deployed` against the dev host (fake adapter).

  Each phase failure message names the phase and the last 20 activity lines.
- [ ] **Step 2: Write `goldenPathIsDeterministic`.** It runs the scenario twice in one process and asserts the same tick count per phase.
- [ ] **Step 3:** Run them. Expected: FAIL (no runner). Implement `ScriptedTurnRunner` with the role scripts inline in the test.
- [ ] **Step 4:** Run them, then `scripts/test.sh unit --report`. Expected: PASS, golden path < 30 s.
- [ ] **Step 5: Commit.**

### Task 18: Golden path, black box

**Files:**
- Create: `scripts/golden-path.sh`, `scripts/fake-claude-roles/{ceo,lead,eng,reviewer}.sh`
- Modify: `scripts/fake-claude.sh`. It dispatches to a role script by the agent's role, read through `brahma mcp`'s tools like a real agent. Its existing doctor and canary answers stay.

**Interfaces:**
- Consumes: R's `brahma engine serve --unmanaged` and today's CLI commands (unchanged).
- Produces: `scripts/golden-path.sh [--keep]`, which exits 0 on success. It prints `PHASE n OK <name>` lines, and on failure the last 50 lines of `engine.log`.

- [ ] **Step 1:** Write the script.
  - Create a temp home under a short root (`/tmp/bgp-XXXX`) with `BRAHMA_OWNER_KEY_STORE=file` and `BRAHMA_SECRET_STORE=memory`, then run `brahma owner init`.
  - Run `brahma company create … --pack software` with the Workspace profile, as `goalToLiveURL` does, because a temp home has no canary probes.
  - Start `brahma engine serve --unmanaged` with `BRAHMA_CLAUDE=scripts/fake-claude.sh`.
  - Poll `brahma items list --json` and `brahma preview list` every 1 s, for up to 240 s.
  - Check the preview with `curl -sf` (expect 200). Check that `brahma inbox` lists the deploy ask, run `brahma approve`, and check that the release is `deployed`.
  - Run `brahma engine stop`, and remove the home unless `--keep`.
  - Never kill anything but the service pid the script started.
- [ ] **Step 2:** Run `scripts/golden-path.sh`. Expected: `PHASE 10 OK release deployed` and exit 0, in about 2–4 minutes.
- [ ] **Step 3:** Add one line to the README's "Before merging a plan" section: run `scripts/golden-path.sh`.
- [ ] **Step 4: Commit.**

### Task 19: Heavy suites to budget

**Files:**
- Modify: the suites that `scripts/test.sh unit --report` lists above 10 s after Tasks 1–4. From the C2a log, expect ReviewTests, BackupTargetTests, MergeBatchTests, MergeQueueTests, SecretWireTests, SeatbeltRunnerTests, VerificationTests, MergeRecoveryTests, SessionTests and OrchestratorTests.

**Interfaces:**
- Consumes: Task 1 `TemplateRepo` and `.processTier`.

- [ ] **Step 1:** Run `scripts/test.sh unit --report` and save the slowest-15 list in the commit body.
- [ ] **Step 2:** For each listed suite:
  - git fixtures use `TemplateRepo.clone`;
  - tests that spawn real processes or `sandbox-exec` move to `.processTier`, each with a unit sibling on fakes, named `<original>_logic`;
  - commit once per suite, with the test count unchanged across tiers (`--report` prints counts per tier).
- [ ] **Step 3:** Run `scripts/test.sh unit --report` 3 times on an idle machine. Expected: each run < 90 s. Record the times. If a run is over 90 s, list the top 5 remaining suites in the commit body and continue Step 2 on them.
- [ ] **Step 4:** Cross-worktree check: run `scripts/test.sh unit` in this worktree and in a scratch clone at the same time. Expected: both green. This is the only deliberate concurrent run. Do it only when no other lane is testing.
- [ ] **Step 5: Commit.**

### Task 20: Final docs and review

**Files:**
- Modify: `README.md` (test tiers and `scripts/test.sh`, golden path, theme token notes). Append an "After Plan P" note to v2 §4.12.1 (tokens: `text2`, `accentText`) without rewriting the original.

- [ ] **Step 1:** Run the full verification:
  - `scripts/test.sh all` (with `BRAHMA_LIVE` unset);
  - `scripts/golden-path.sh`;
  - `scripts/make-app.sh debug && scripts/smoke-app.sh`;
  - `ScreenInventoryTests`;
  - `scripts/perf-bench.sh`;
  - UI snapshots of every screen, read one by one.

  Expected: all green, every budget met or explained, and the inventory unchanged.
- [ ] **Step 2:** Hand the usability file (Task 11) to the controller for the owner, with each entry's status.
- [ ] **Step 3:** Final review (Opus, per the owner's model policy) of the branch against spec §4 anti-goals, the owner decisions and the Review Focus.
- [ ] **Step 4: Commit.**

---

## Self-review notes (done inline)

- **Spec coverage:**
  - §5.1 polish: Task 10 (audit and inventory), Task 12 (tokens and contrast), Tasks 13–15 (screens), Task 16 (performance), Task 11 (usability).
  - §5.2 CLI: Tasks 8–9.
  - §5.3 golden path: Tasks 17–18.
  - §5.4 determinism and speed: Tasks 1–4 and 19.
  - §5.5 notifications: Tasks 5–7.
  - §6 migration: Tasks 1, 5, 8–10 and 12.
  - Owner decisions: 01:13 is covered by Tasks 10–16 with the frozen inventory. 01:16 CLI is covered by Tasks 8–9 with the frozen tree. 01:16 engine is in Plan R.
- **Execution order:** 1 → 20 as numbered. Determinism comes first, so every later task runs on a fast, stable suite. The usability write-up (Task 11) goes to the owner early, so approvals can land while polish runs.
- **Name consistency:** `Topic`, `ChangeTopics`, `ChangedEvent`, `ChangeFeed`, `ChangeSubscription`, `SnapshotPart`, `CommandTree`, `PortAllocating`, `ProcessInspecting`, `Signal`, `TemplateRepo`, `TestTier`, `EmptyState`/`LoadingState`/`ErrorState`, `ThemeContrast`, `TruncatedText`, `PerfBudgets`, `ScriptedTurnRunner`.
- **Estimated build effort:** 20 tasks. Tasks 1, 5–7, 12, 16 and 17 carry most of the design risk. Tasks 8–9 and 13–15 are long but mechanical. Roughly 9–11 implementer-days, or about 2 calendar weeks with review rounds.
