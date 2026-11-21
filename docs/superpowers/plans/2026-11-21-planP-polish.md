# Plan P — Polish before dogfood Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before the first dogfood run:
- the owner sees five nouns: 7 sidebar rows, and a CLI of about 16 visible verbs, with every old name still working;
- a deterministic goal-to-preview test runs on every task;
- the ten recurring flakes are fixed at the root, and the unit tier runs in under 90 s;
- the app updates from engine change notifications instead of a 500 ms poll.

**Architecture:**
- **Test tiers.** There are three: `.unit` (the default, no sleeps or real processes), `.process` and `.live`. Event waits and injected clocks replace sleeps, a shrink-only hygiene scan holds the line, and a `scripts/test.sh` wrapper runs each tier.
- **Change notifications.** Change topics are SQLite trigger counters, so they work across processes. R's service pushes them over its socket, and the app reloads only the snapshot parts whose topics moved. A 2 s topic poll and a 60 s full refresh are the fallback.
- **App.** The sidebar becomes a seven-case noun enum with tabs. Old cases map through `legacy(_:)`.
- **CLI.** A single argv rewrite table keeps old command paths working. It prints a TTY-only note.

**Tech Stack:** Swift 6.2 toolchain (manifest `swift-tools-version: 6.0`, `.macOS(.v14)`), GRDB.swift 7.x (SQLite triggers, `PRAGMA data_version`), swift-argument-parser 1.5+, Swift Testing, SwiftUI/AppKit (app targets only), bash for scripts.

**Spec:** `/Users/chandra/agent-company/.claude/worktrees/plan-refactor-polish/docs/superpowers/specs/2026-11-21-polish-design.md` (cited as *spec §n*). It builds on the Plan R spec `2026-11-21-restructure-service-design.md` (*R §n*) and on R's plan.

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
- **The stdout of every command stays byte-identical.** The moved-command note goes to stderr, only when `isatty(STDERR_FILENO)` and `BRAHMA_NO_MOVED_NOTE` is unset. Its text is exactly `note: 'brahma <old>' is now 'brahma <new>'`.
- **Owner gates do not change.** A moved command keeps its `requireOwnerShell()` and its `BRAHMA_AGENT_ID` refusal.
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
| Mission Control strip | 3 cards, ≈ 96 pt, top 3 items each, SHIPPED window 7 wall days | `MissionStrip` |
| Sleep detector in `scripts/test.sh` | awake vs wall divergence > 30 s → "machine slept during run: rerun" | script |
| Old CLI names kept | until first tagged release after dogfood, ≥ 30 days (PQ4) | `LegacyRoutes.sunset` comment + README |

## Review Focus

1. **An old command path reaches a different command, or loses its owner gate, after the move.** Examples: `brahma secret provide A-3` vs `brahma secret set`; `brahma replay` with an item argument vs an agent argument; `brahma items readopt`. Expected: the same command type, the same gate, the same stdout. → Task 9 `LegacyRoutesTests.everyOldPathParsesToSameCommand`, `CLIOwnerGateTests.gatesUnchanged`, `longestPrefixWins`.
2. **A change made by another process never shows up** (a CLI `brahma approve`, an agent's `brahma mcp` write, a restore), or the app keeps a stale Inbox count. Expected: visible within 250 ms with the service up and within 2 s without it. A restore forces a full reload. → Task 5 `ChangeTopicsTests.crossProcessWriteBumpsTopic`; Task 7 `ChangeSubscriptionTests.epochChangeReloadsAll`, `fallbackPollsWithoutService`.
3. **A new table added by a later plan is silently not observed.** Expected: the build fails until the table is mapped or marked unobserved with a reason. → Task 5 `ChangeTopicsTests.everyTableMapped`.
4. **Deep links and notification banners open the wrong place after the IA change.** Examples: `--select backups`, `ask:<id>`, `release:<ref>`, `replay agent`, `kb:<path>`. Expected: the same content, now under its noun tab. → Task 10 `SidebarLegacyTests.everySelectTargetLands`.
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
Sources/BrahmaAppModel/Presentation/Sidebar.swift   SidebarItem nouns/tabs, legacy(_:)
Sources/BrahmaAppModel/Presentation/MissionStrip.swift
Sources/BrahmaAppModel/Insights/InsightsModel.swift
Sources/BrahmaApp/Views/{Sidebar,DetailView,MissionControlView}.swift (modified); Views/NounHeader.swift, Views/Insights/*.swift, Views/MissionStripView.swift (new)
Sources/brahma/Groups/{CompanyGroup,PeopleGroup,WorkGroup,InboxGroup,BudgetGroup,SettingsGroup,DevGroup}.swift   new tree; leaf commands unchanged and re-parented
Sources/brahma/LegacyRoutes.swift                   rewrite table + note
Tests/BrahmaCLITests/{LegacyRoutesTests,CLIOwnerGateTests,CLIHintTests}.swift + Fixtures/cli-moves.tsv
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

### Task 8: CLI tree restructure

**Files:**
- Create: `Sources/brahma/Groups/{CompanyGroup,PeopleGroup,WorkGroup,InboxGroup,BudgetGroup,SettingsGroup,DevGroup}.swift`. Each re-parents existing leaf command types: no leaf `run()` body changes, only `commandName` where the spec renames, for example `trust-import` → `import` and `kb` → `handbook`.
- Modify: `Sources/brahma/Brahma.swift`. The visible `subcommands` become exactly the spec §5.2 list. `mcp`, `hook` and old group types are kept with `shouldDisplay: false` where an old spelling must still parse natively, for example `company mode`.
- Create: `Tests/BrahmaCLITests/Fixtures/cli-moves.tsv` (spec Appendix A, completed from the merged tree)

**Interfaces:**
- Produces:
  - the new command tree;
  - `cli-moves.tsv` rows `old path<TAB>new path`;
  - `enum CommandTree { static func resolve(_ path: [String]) -> ParsableCommand.Type? }`, a helper that walks `Brahma.configuration`, for tests.

- [ ] **Step 1:** Walk `--help` on merged `main` (the method in spec §1). Complete `cli-moves.tsv` for every visible leaf, plus `dev`, `hook`, 4a's `artifacts`, and anything C added. Place each one by the spec §5.2 rules 1–7. Any leaf the rules do not place goes to the controller as a question before Step 2.
- [ ] **Step 2: Write `CLITreeTests`:**
  - `topLevelHelpMatchesSpec`: `brahma --help` lists exactly the spec's noun, daily and system names, plus `dev`.
  - `everyNewPathResolves`: every right-hand side of the fixture resolves.
  - `agentFacingUnchanged`: `mcp`, `hook pre-tool` and `hook post-tool` resolve to the same types as before.
- [ ] **Step 3:** Run them. Expected: FAIL. Implement the groups. Run again. Expected: PASS.
- [ ] **Step 4: Commit.**

### Task 9: Legacy routes and owner-gate parity

**Files:**
- Create: `Sources/brahma/LegacyRoutes.swift`, `Tests/BrahmaCLITests/{LegacyRoutesTests,CLIOwnerGateTests}.swift`
- Modify: `Sources/brahma/Brahma.swift`. Add a `static func main()` that calls `LegacyRoutes.rewrite(CommandLine.arguments.dropFirst())`, prints the note, then `parseAsRoot`/`run`. Add the `help moved` subcommand, which prints the table.

**Interfaces:**
- Produces:
  - `enum LegacyRoutes { static let table: [(old: [String], new: [String])]; static func rewrite(_ argv: [String], isTTY: Bool, environment: [String: String]) -> (argv: [String], note: String?) }`. The table is loaded from the same rows as `cli-moves.tsv`, embedded as a Swift literal generated by `scripts/cli-moves-gen.sh`. A test checks the literal matches the fixture.
  - The note is exactly `note: 'brahma \(old.joined(" "))' is now 'brahma \(new.joined(" "))'`.

- [ ] **Step 1: Write the tests:**
  - `LegacyRoutesTests.everyOldPathParsesToSameCommand`: for each fixture row, `CommandTree.resolve(rewrite(old).argv)` equals `CommandTree.resolve(new)`.
  - `longestPrefixWins`: `settings auto-merge-paths` → `dev auto-merge-paths`, not `company set auto-merge`.
  - `optionsPassThrough`: `items list --json --status ready` → `work list --json --status ready`.
  - `noteOnlyOnTTY`.
  - `noteSuppressedByEnv`.
  - `noCycles`.
  - `literalMatchesFixture`.
  - `CLIOwnerGateTests.gatesUnchanged`: for each fixture row, run old and new under `BRAHMA_AGENT_ID=a1` in a temp home through the built binary, using R's `BrahmaCLITests` helper. Both refuse with the same stderr first line, or both succeed. Mark it `.processTier` (it spawns the binary), and pair it with a unit sibling that compares `requiresOwner` flags on the resolved types.
  - `stdoutByteIdentical`: for 10 read-only rows, old and new stdout are equal.
- [ ] **Step 2:** Run them. Expected: FAIL. Implement. Run again. Expected: PASS.
- [ ] **Step 3:** Run the 19 existing CLI test files unchanged, on old names. Expected: green, which proves the aliases.
- [ ] **Step 4: Commit.**

### Task 10: App IA: sidebar nouns, tabs, deep links

**Files:**
- Modify:
  - `Sources/BrahmaAppModel/Presentation/Sidebar.swift` (the spec §5.1 enum, plus `InboxTab`, `WorkTab`, `PeopleTab`, `BudgetTab`, `SettingsTab`, `InsightsTab`, plus `legacy(_:)`)
  - `AppModel.swift` (`select`, `apply(_ target:)`, `lastTab`)
  - `LaunchOptions.swift` (old spellings kept)
  - `Sources/BrahmaApp/Views/Sidebar.swift` (7 rows + chats + bottom Settings/Insights)
  - `DetailView.swift` (7 noun views)
  - `BrahmaApp.swift` (⌘1–⌘5, ⌘,, ⌃Tab/⌃⇧Tab)
- Create: `Sources/BrahmaApp/Views/NounHeader.swift`, `Tests/BrahmaAppModelTests/{SidebarLegacyTests,IACoverageTests}.swift`

**Interfaces:**
- Produces:
  - `SidebarItem.legacy(_ old: LegacySidebarItem) -> SidebarItem`, where `LegacySidebarItem` is today's enum, renamed and kept for mapping.
  - `AppModel.lastTab: [Noun: AnyTab]`
  - `struct NounHeader<Tab: Hashable & CaseIterable>: View { title: String; selection: Binding<Tab>; counts: [Tab: Int] }`

- [ ] **Step 1: Write the tests:**
  - `SidebarLegacyTests.everyOldCaseMapsUniquely`: all 14 fixed cases map, and no two map to the same noun and tab.
  - `everySelectTargetLands`: for every `SelectTarget` case and parsed spelling (`backups`, `grants`, `digest`, `activity`, `releases`, `resources`, `budget`, `ask:<id>`, `release:<ref>`, `kb:<path>`, `replay` agent/item, `preview:<name>`, `map`), `apply` selects the expected noun and tab and sets the same side state as today (`selectedReleaseRef`, `highlightedAskId`, …).
  - `IACoverageTests.everyOldDestinationWithinTwoClicks`.
  - `lastTabRemembered`.
  - `fixedRowsAreSeven`: `Sidebar.fixedRows.count == 7` (layout A).
- [ ] **Step 2:** Run them. Expected: FAIL. Implement the model, then the views. Tabs reuse the existing views unchanged.
- [ ] **Step 3:** `scripts/make-app.sh debug && scripts/ui-snapshot.sh taskP10 mission work inbox settings insights`, then read the PNGs. Expected: 7 fixed rows, tab strips per noun, BrahmaTheme only.
- [ ] **Step 4:** Run the full suite. Commit.

### Task 11: Mission Control strip and Insights pane

**Files:**
- Create: `Sources/BrahmaAppModel/Presentation/MissionStrip.swift`, `Sources/BrahmaAppModel/Insights/InsightsModel.swift`, `Sources/BrahmaApp/Views/MissionStripView.swift`, `Sources/BrahmaApp/Views/Insights/{InsightsView,MergeQueueInsight,TimersInsight,HealthInsight,CanaryInsight,FactsInsight}.swift`, `Tests/BrahmaAppModelTests/{MissionStripTests,InsightsModelTests}.swift`
- Modify: `MissionControlView.swift` (the strip goes above the slot layout as 4b left it)

**Interfaces:**
- Produces:
  - `struct MissionStrip: Equatable { needsYou: [StripLine]; needsYouCount: Int; stuck: [StripLine]; stuckCount: Int; shipped: [StripLine]; static func make(snapshot: Snapshot, now: Date, timeZone: TimeZone) -> MissionStrip }`. Lines are `Text(verbatim:)`-ready strings with an optional `SelectTarget`.
  - `@MainActor final class InsightsModel { func load(_ tab: InsightsTab, companyId: String) async }`. It is read-only, and each tab loads through the same Store calls its CLI command uses (`merge list`, `timers`, holds, canary results, `perf facts`).
  - Each Insights row has a "Copy command" button with the `brahma dev …` line.

- [ ] **Step 1: Write the tests:**
  - `MissionStripTests.needsYouTopThreeInInboxOrder`.
  - `stuckUsesStallReasonsAndOwnerBlocked`.
  - `shippedWindowIsSevenWallDays`.
  - `emptyStatesSayNothingNeedsYou` (copy: "Nothing needs you", "Nothing stuck", "Nothing shipped this week").
  - `agentTextIsVerbatim`: an item title `"**bold** [x](y)"` appears unparsed.
  - `InsightsModelTests.everyTabLoadsReadOnly` (a write spy on the Store sees 0 writes).
  - `copyCommandsResolve`: every copied command resolves through `CommandTree`.
- [ ] **Step 2:** Run them. Expected: FAIL. Implement. Run again. Expected: PASS.
- [ ] **Step 3:** UI snapshot `scripts/ui-snapshot.sh taskP11 mission insights`, then read the PNGs.
- [ ] **Step 4: Commit.**

### Task 12: Hint strings, README, scripts

**Files:**
- Modify: the 125 `Sources/` files containing `brahma <verb>` hints (283 strings on `planC-collab`; Step 1 recounts), `README.md` (162 lines, plus the stale "This is Plan 3a" header), `scripts/smoke-app.sh`, `scripts/fake-claude.sh`
- Create: `Tests/BrahmaCLITests/CLIHintTests.swift`

**Interfaces:**
- Consumes: Task 8 `CommandTree`, Task 9 `LegacyRoutes.table`.

- [ ] **Step 1: Write `CLIHintTests`.**
  - `everyHintIsCanonical`: scan string literals in `Sources/**/*.swift` for `brahma ([a-z][a-z-]*)( [a-z][a-z-]*)*`. Take the longest word prefix that `CommandTree.resolve` accepts. It must resolve, and it must not be the left side of a `LegacyRoutes` row. `mcp` and `hook` are excepted.
  - `readmeHintsCanonical`: the same check on `README.md`.
- [ ] **Step 2:** Run it. Expected: FAIL, with the list of hints.
- [ ] **Step 3:** Rewrite each listed hint to its new path, changing the hint text only. The tests that assert hint text get the same string update, counted in the commit body.
- [ ] **Step 4:** Run the full suite. Expected: green.
- [ ] **Step 5: Commit.**

### Task 13: Golden path, in process

**Files:**
- Create: `Sources/BrahmaEngine/Testing/ScriptedTurnRunner.swift` (`package`; compiled into the engine target so tests and `scripts/golden-path.sh`'s Swift helper can share it), `Tests/BrahmaEngineTests/GoldenPathTests.swift`

**Interfaces:**
- Consumes: R's in-process `EngineService` (or `Orchestrator` directly), the real `CompanyTools` dispatch used by `brahma mcp`, `FakeSandbox`, `FakeHTTPProbe`, `TestClock`, `TemplateRepo`.
- Produces: `package final class ScriptedTurnRunner: TurnRunning { init(script: [RoleKey: [TurnScript]], tools: (Agent) -> CompanyToolDispatch) }`. `TurnScript` is a list of `ToolCall(name: String, arguments: JSONValue)` plus optional file writes and commits in the agent's worktree. The runner emits the same stream-json result lines `StreamParser` reads.

- [ ] **Step 1: Write `GoldenPathTests.goalToPreviewAndDeployAsk`.** It is `@Test(.timeLimit(.minutes(1)))`, drives `orchestrator.tick()` up to `maxTicks = 400`, and advances `TestClock` 1 s per tick. It asserts the spec §5.3 phases in order:
  1. The company exists with the software pack, and the org has a CEO, a lead, `@eng-1` and a reviewer.
  2. The brief exists, and the backlog has A-1 with a check spec.
  3. A-1 is leased to `@eng-1` with a worktree.
  4. A-1 is `inReview` after submit.
  5. A verification run is `passed`.
  6. The review is approved.
  7. `main` contains the engineer's commit (real git `rev-parse`).
  8. The web preview is `running` at that commit.
  9. `WorkSnapshot.load(...).inbox` contains a `deploy` ask.
  10. After `store.ownerDecide(.approve)`, the release reaches `deployed` against the dev host (fake adapter).

  Each phase failure message names the phase and the last 20 activity lines.
- [ ] **Step 2: Write `goldenPathIsDeterministic`.** It runs the scenario twice in one process and asserts the same tick count per phase.
- [ ] **Step 3:** Run them. Expected: FAIL (no runner). Implement `ScriptedTurnRunner` with the role scripts inline in the test.
- [ ] **Step 4:** Run them, then `scripts/test.sh unit --report`. Expected: PASS, golden path < 30 s.
- [ ] **Step 5: Commit.**

### Task 14: Golden path, black box

**Files:**
- Create: `scripts/golden-path.sh`, `scripts/fake-claude-roles/{ceo,lead,eng,reviewer}.sh`
- Modify: `scripts/fake-claude.sh`. It dispatches to a role script by `BRAHMA_AGENT_ID`'s role, read through `brahma mcp`'s tools like a real agent. Its existing doctor/canary answers stay.

**Interfaces:**
- Consumes: R's `brahma engine serve --unmanaged`, the Task 8 CLI paths.
- Produces: `scripts/golden-path.sh [--keep]`, which exits 0 on success. It prints one `PHASE n OK <name>` line per phase, and on failure prints the last 50 lines of `engine.log`.

- [ ] **Step 1:** Write the script.
  - Make a temp home under a short root (`/tmp/bgp-XXXX`) with `BRAHMA_OWNER_KEY_STORE=file` and `BRAHMA_SECRET_STORE=memory`, then `brahma settings owner-key init`.
  - Run `brahma company create … --pack software` with the Workspace profile, as `goalToLiveURL` does, because temp homes have no canary probes.
  - Start `brahma engine serve --unmanaged` with `BRAHMA_CLAUDE=scripts/fake-claude.sh`.
  - Poll `brahma work list --json` and `brahma work preview list` every 1 s, up to 240 s.
  - Check the preview with `curl -sf` (expect 200), then `brahma inbox` lists the deploy ask, then `brahma approve`, then the release is `deployed`.
  - Run `brahma engine stop`, and remove the home unless `--keep`.
  - Never kill anything but the service pid it started.
- [ ] **Step 2:** Run `scripts/golden-path.sh`. Expected: `PHASE 10 OK release deployed` and exit 0, in about 2–4 minutes.
- [ ] **Step 3:** Add one line to the README's "Before merging a plan" section: run `scripts/golden-path.sh`.
- [ ] **Step 4: Commit.**

### Task 15: Heavy suites to budget

**Files:**
- Modify: the suites `scripts/test.sh unit --report` lists above 10 s after Tasks 1–4. Expect, from the C2a log: ReviewTests, BackupTargetTests, MergeBatchTests, MergeQueueTests, SecretWireTests, SeatbeltRunnerTests, VerificationTests, MergeRecoveryTests, SessionTests and OrchestratorTests.

**Interfaces:**
- Consumes: Task 1 `TemplateRepo`, `.processTier`.

- [ ] **Step 1:** Run `scripts/test.sh unit --report` and save the slowest-15 list in the commit body.
- [ ] **Step 2:** For each listed suite:
  - git fixtures use `TemplateRepo.clone`;
  - tests that spawn real processes or `sandbox-exec` move to `.processTier`, each with a unit sibling on fakes, named `<original>_logic`;
  - Mac-wide resources (pasteboard, `/private/tmp`) are already isolated by Task 1.
  - One commit per suite, with the test count unchanged across tiers (`--report` prints the per-tier counts).
- [ ] **Step 3:** Run `scripts/test.sh unit --report` on an idle machine, 3 times. Expected: each run < 90 s. Record the three times. If a run exceeds 90 s, list the top 5 remaining suites in the commit body and continue with Step 2 on them.
- [ ] **Step 4:** Run the cross-worktree check: start `scripts/test.sh unit` in this worktree and in a scratch clone at the same time. Expected: both green. This is the only time two suites run at once, and it is deliberate. Do it only when no other lane is testing.
- [ ] **Step 5: Commit.**

### Task 16: Final docs and review

**Files:**
- Modify: `README.md` (CLI overview from the new `--help`, the "moved commands" note with the PQ4 window, test tiers and `scripts/test.sh`, golden path). Append an "After Plan P" note to v2 §4.12.2 (sidebar) without rewriting the original.

- [ ] **Step 1:** Run the full verification:
  - `scripts/test.sh all` (with `BRAHMA_LIVE` unset);
  - `scripts/golden-path.sh`;
  - `scripts/make-app.sh debug && scripts/smoke-app.sh`;
  - UI snapshots of all seven nouns.

  Expected: all green, and the snapshots read.
- [ ] **Step 2:** Final review (Opus, per the owner's model policy) of the branch against spec §4 anti-goals and the Review Focus.
- [ ] **Step 3: Commit.**

---

## Self-review notes (done inline)

- **Spec coverage:**
  - §5.1 IA → Tasks 10, 11
  - §5.2 CLI → Tasks 8, 9, 12
  - §5.3 golden path → Tasks 13, 14
  - §5.4 determinism and speed → Tasks 1–4, 15
  - §5.5 notifications → Tasks 5–7
  - §6 migration → Tasks 1, 5, 8, 12
  - Owner questions PQ1–PQ5 → the defaults are built in Tasks 10 (layout A, Activity folded), 8 (`dev`, shortcuts kept) and 9 (TTY note, window)
- **Execution order:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15 → 16. Determinism comes first, so every later task runs on a fast, stable suite.
- **Name consistency:** `Topic`, `ChangeTopics`, `ChangedEvent`, `ChangeFeed`, `ChangeSubscription`, `SnapshotPart`, `LegacyRoutes`, `CommandTree`, `SidebarItem.legacy`, `NounHeader`, `MissionStrip`, `ScriptedTurnRunner`, `PortAllocating`, `ProcessInspecting`, `Signal`, `TemplateRepo`, `TestTier`.
- **Estimated build effort:** 16 tasks. Tasks 1, 5–7, 9 and 13 carry most of the design risk; Tasks 12 and 15 are long but mechanical. That is about 7–9 implementer-days, roughly 1.5 calendar weeks with review rounds.
