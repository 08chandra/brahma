# Plan R — Restructure and engine service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `BrahmaCore` into layered SwiftPM targets, break the `Orchestrator` tick into `TickParticipant`s and the `Store` into a thin core plus feature extensions, and run the engine as a per-user launchd service (`brahma engine serve`) with the app and CLI as clients over a local control socket. Owner-visible behaviour stays identical, except that the engine survives an app quit.

**Architecture:**
- **Coarse layers first.** The targets are BrahmaSafety (Plan S, the bottom kernel) → BrahmaFoundation → BrahmaModel → BrahmaStore → BrahmaGit → BrahmaDomain → BrahmaAgentTools → BrahmaEngine → BrahmaCore (umbrella, `@_exported`) → BrahmaEngineClient / BrahmaService.
- `ModuleGraphTests` enforces the graph, and cross-module internals use `package` access.
- Tick steps become non-Sendable participants isolated to the Orchestrator actor through `isolated` parameters, so the tick has no new suspension points and runs in the same order.
- The service is the existing `brahma` helper binary under a generated LaunchAgent plist. The socket is a control plane only, and the DB stays the message bus.

**Tech Stack:** Swift 6.2 toolchain (manifest `swift-tools-version: 6.0`, `.macOS(.v14)`), SwiftPM `package` access (SE-0386), GRDB.swift 7.x, swift-argument-parser 1.5+, Swift Testing, launchd/`launchctl` (Darwin only), POSIX Unix-domain sockets.

**Spec:** `/Users/chandra/agent-company/.claude/worktrees/plan-refactor-polish/docs/superpowers/specs/2026-11-21-restructure-service-design.md` (cited as *spec §n*). Background: `docs/superpowers/specs/2026-11-21-design-analysis-input.md`.

**Builds on, all merged first:** 4a (`plan4a-previews`), C (`planC-collab`), the 4b leftovers, and **Plan S** (it delivers `BrahmaSafety`, `brahma-helper`, `Decision`/`AlertScope`, `Spawn`/`ToolPaths`, `SandboxPolicyFactory` and `SafetyLintTests`; spec §4 maps each to what R does with it) (`plan-engine-safety`: `docs/superpowers/specs/2026-11-21-engine-safety-design.md`, `docs/superpowers/plans/2026-11-21-planS-engine-safety.md`). Every table in this plan was generated on `planC-collab` 91e84e9. **Task 0 regenerates them from the merged `main`, and later tasks use Task 0's numbers.**

## Global Constraints

Copied from earlier plans and still binding:
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The manifest stays `swift-tools-version: 6.0` and `.macOS(.v14)`.
- Every core target (everything except BrahmaApp, BrahmaAppModel, BrahmaMapKit and BrahmaKeychain) stays Linux-portable: no AppKit, SwiftUI, Observation, UserNotifications, CryptoKit or `Bundle.module`. Darwin-only code (launchd, `getpeereid`, `LOCAL_PEERPID`, `kqueue`, `bindat`) sits behind `#if canImport(Darwin)`.
- Agent states stay exactly `ready, running, blocked, sleeping, killed`. Item statuses stay exactly `backlog, ready, inProgress, inReview, done, blocked`.
- Durations use awake time (`AwakeTime`) or company-active seconds, never `Date` differences. Clocks are injected.
- Owner decisions exist only through `Store.ownerDecide`, `ownerAnswer`, `ownerRescind` and `acknowledge`.
- Agent-controlled text printed by the CLI goes through `safe()`. In the app it goes through `Text(verbatim:)`/`SafeMarkdown`. Text read off the socket is treated the same way.
- No test touches the Keychain or launchd. `NoKeychainTests` stays green. The new `ServiceGuardTests` bans `launchctl`, `SMAppService` and `bootstrap gui/` outside `Sources/BrahmaService/Install/`.
- Tests use Swift Testing, one `@Suite struct <FileName>` per new test file.
- Every task ends with `DEVELOPER_DIR=… swift build` green for all targets, and `DEVELOPER_DIR=… timeout -k 30 1800 swift test` green. Rerun the listed known flakes alone before calling a failure real.
- Never `pkill`/`kill` processes you did not start. Never run two worktrees' full suites at once.
- Every commit message ends with:
  `Co-Authored-By: Claude <your actual model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`

R additions:
- **Behaviour identical.** The tick order, gating, DB rows, CLI stdout, prompts and agent argv do not change. In particular, `brahma mcp` and `brahma hook pre-tool|post-tool` keep their argv, and `SandboxCanaryKey` inputs do not change.
- **Moves are `git mv`.** One module per commit, with no edits to moved file bodies in the same commit except imports and `internal` → `package`.
- **Access:**
  - Never add `public` to make something compile. Use `package`.
  - `PublicSurfaceTests` (Task 1) pins the umbrella's public names.
- **Guard allowlists:**
  - Static guard tests are renamed through `MovedPaths` (Task 1) and never grow.
  - `GuardAllowlistTests` pins each allowlist's count.
  - This covers: `EngineGitGuardTests.gitCommandFiles`, the `MainGuardTests` path list, the `EmergencyStopTests` MCP dir, the `NoKeychainTests` roots, `SecretTests` file reads, the `AwakeTimeTests` roots, `ExtensionImporterTests`, and S's raw-I/O lint baseline.
- **S's safety lint keeps covering moved code.**
  - Task 1 widens `SafetyLintTests` roots from `Sources/BrahmaCore` and `Sources/brahma` to every Brahma source target except BrahmaApp, BrahmaAppModel and BrahmaMapKit, and re-keys `safety-lint-baseline.json` through `MovedPaths` with identical counts.
  - R's new code adds **no** baseline entry: processes go through S's `Spawn` with `ToolPaths`, data-home files through `Place`/`EngineFiles`, and sockets through `LocalSocket` (Task 14).
  - **R never edits code inside `Sources/BrahmaSafety` except `LocalSocket` and `ToolPaths.launchctl`.** Both are security-reviewed on Opus (high), as S's kernel tasks are.
- **No migration.** R adds no DB migration (P adds `"vP-change-topics"`).
- **Engine mode switch until Task 19.** `BRAHMA_ENGINE_MODE=embedded` keeps the old in-app `EngineHost` path working until Task 19 deletes it. It is the rollback switch while the service tasks land.
- **Service constants** (`EngineServiceConfig`, `static let`):

| Constant | Value |
|---|---|
| Socket path / lock / starts file | `<home>/run/engine.sock` (0600), `<home>/run/service.lock`, `<home>/run/service-starts` |
| Log | `<home>/logs/engine.log` 0600, dir 0700; rotate at start over 20 MB, keep 3, cap 100 MB total |
| Frame cap | 1 MiB; 4-byte big-endian length + UTF-8 JSON `Envelope` |
| Protocol | `1` |
| Upgrade drain | 600 s awake |
| Upgrade exit code | 75 |
| Crash loop | 5 unclean starts within 600 s (injected clock) |
| Client reconnect backoff | 0.1 s doubling to 5 s, reset on success |
| Shutdown bound (⌥ Quit, `engine stop`) | 15 s (today's `EngineHost.stop`) |
| launchd | `RunAtLoad true`, `KeepAlive {SuccessfulExit false}`, `ThrottleInterval 10`, `ExitTimeOut 30`, `ProcessType Standard`, `LimitLoadToSessionType Aqua` |
| Label | `dev.brahma.engine` (default home) or `dev.brahma.engine.<fnv1a64(canonicalHomePath) lowercase hex, first 8>` |
| Owner defaults (spec RQ1–RQ4) | `keepRunningOnQuit = true`, `autostart = true`, `upgradePolicy = .drain`, `foregroundRunAllowed = true` |

## Review Focus

1. **The service is reachable by an agent.** A sandboxed turn connects to `<home>/run/engine.sock`, or a Workspace-profile turn's Bash sends `resume`. Expected: the sandboxed connect is denied by Seatbelt (the canary probe proves it), and a non-sandboxed agent without the owner key gets `ownerProofRequired`. → Task 15 `ServiceAuthTests.mutationWithoutProofRefused`, `peerUnderTurnLeaderRefused`; Task 18 `CanaryProbeTests.engineSocketDenied`.
2. **The emergency stop while the service is wedged, crash-looping or mid-upgrade.** Expected: `brahma stop` still writes the row and signals every recorded group, and no new turn starts after the service comes back. → Task 16 `ServiceKillSwitchTests.stopWorksWithServiceWedged`, `stopDuringUpgradeDrainHolds`.
3. **Two engines on one data home**: launchd plus `--unmanaged` plus `brahma engine run` plus the app on an old build. Expected: exactly one holds `orchestrator.lock`, the second `serve` exits 0 with a message, and `engine run` refuses. → Task 15 `ServiceLockTests.secondServeExitsZero`; Task 17 `EngineRunCommandTests.refusesWhileServiceRuns`.
4. **Upgrade and downgrade around a migration.** Expected: the pre-migration snapshot exists before the first new write, an older binary on a newer DB refuses with "database is newer", and drained turns are recorded as interrupted, never lost. → Task 16 `ServiceUpgradeTests.drainThenExit75`, `olderEngineRefusesNewerSchema`.
5. **A tick-order or gating drift hidden in the participant extraction, or a safety lint that silently stops covering moved code**, for example memory ingest running under the owner's stop, or the canary hold computed after admission. Expected: identical order and gates. → Task 9 `TickOrderTests.orderIsPinned`, `TickGatesTests.gatesMatchToday`; every Task 10–11 commit runs the full `OrchestratorTests`; Task 1 `SafetyLintRootsTests.coversEveryCoreTarget`, `baselineKeysRenamedNotDropped`.

---

## File Structure

```
Package.swift                                   targets per spec §6.1; BrahmaCore becomes the umbrella
Sources/BrahmaFoundation/   (moved) the Util/* files S left (Blocking, StableHash, DirectoryListing, EngineGitGuard, OwnerKey), Paths.swift, TerminalText.swift, Platform/*, OwnerKey.swift, OrchestratorLock.swift→EngineLock.swift
Sources/BrahmaModel/        (moved) Model/* + value types pulled down (Task 2 Step 1 lists them)
Sources/BrahmaSafety/       Plan S's target (bottom layer; Task 3 verifies). R adds only Net/LocalSocket.swift (Task 14) and ToolPaths.launchctl (Task 17)
Sources/BrahmaStore/        Store.swift, Migrations.swift, core Store+*.swift, CompanyScope.swift
Sources/BrahmaGit/          Git/GitCommandRunner.swift Git/GitWorktrees.swift Git/GitMainGuard.swift Git/GitQueries.swift (split of GitWorkspace.swift), Merge/*, Store+Merge*.swift, Store+MainGuard.swift
Sources/BrahmaDomain/       Work Org Modes Lifecycle Messaging Access Owner Timers Turns(prompts/digest) Memory Handbook Resources Refs Collab Show Changes Extensions Preview Release Hosting Backup Inbox/AskService.swift + their Store+*.swift
Sources/BrahmaAgentTools/   MCP/*
Sources/BrahmaEngine/       Orchestrator.swift, Tick/*.swift (participants), Tick/TickParticipant.swift, Tick/TaskRegistry.swift, Turns/TurnLauncher.swift, Scheduler/*, Engine/*, Verify/*
Sources/BrahmaCore/         Umbrella.swift (@_exported imports), StandardStore.swift (Store.standard)
Sources/BrahmaEngineClient/ Wire/Envelope.swift Wire/Messages.swift Wire/Framing.swift EngineClient.swift EngineStatusReport.swift BuildStamp.swift OwnerProof.swift
Sources/BrahmaService/      EngineService.swift ServiceState.swift ServiceLocks.swift IPCServer.swift PeerAuth.swift CrashLoopGuard.swift ServiceLog.swift Suspension.swift UpgradeDrain.swift ToolEnvironment.swift (ToolLocator, EngineSetup moved here)
                            Install/ServiceInstaller.swift Install/LaunchAgentPlist.swift Install/Launchctl.swift Install/UnmanagedLauncher.swift
Sources/brahma/             EngineCommands.swift (engine group), EngineRunCommand.swift (was RunCommand.swift), BuildInfo.swift (generated); modified DoctorCommand, StatusCommand, StopCommand, BackupCommands (restore), LabCommands, CompanyCommands (trust-import), HostingCommands, DevCommands
Sources/BrahmaAppModel/Engine/EngineConnection.swift (replaces EngineHost.swift)   modified AppModel.swift AppModel+Secrets.swift AppModel+Work.swift MenuBar/MenuBarSummary.swift
Sources/BrahmaApp/          modified AppDelegate.swift Harness.swift Views/EngineBanner.swift Views/MenuBarContent.swift; new Views/EngineSettingsPanel.swift
Tests/BrahmaTestSupport/    TestSupport.swift GitFixture.swift FakeSandbox.swift ManualClock.swift TestScratch.swift MovedPaths.swift Fixtures/ (moved)
Tests/{BrahmaStoreTests,BrahmaGitTests,BrahmaDomainTests,BrahmaEngineTests,BrahmaServiceTests,BrahmaCLITests,BrahmaGuardTests}/   (split of BrahmaCoreTests, Task 12)
Tests/BrahmaGuardTests/     ModuleGraphTests PublicSurfaceTests GuardAllowlistTests ServiceGuardTests  (+ moved static guards)
scripts/make-app.sh         writes Sources/brahma/BuildInfo.swift; scripts/smoke-app.sh
README.md                   "Running the engine"
```

---

### Task 0: Inventory and spikes

**Files:**
- Create: `.superpowers/sdd/planR/inventory.md` (ledger, not product docs)
- Create: `Tests/BrahmaCoreTests/LaunchAgentSpikeTests.swift` (`BRAHMA_LIVE=1` only; deleted in Task 20 if superseded)

**Interfaces:**
- Produces: the regenerated tables every later task uses:
  - (a) the `schedule(now:)` step list with file:line;
  - (b) every `Orchestrator` stored member, mapped to a spec §6.2 participant;
  - (c) every `Store+*.swift` file mapped to its target;
  - (d) the directory dependency scan (spec §6.1 method), with the cycle-cut list;
  - (e) every `OrchestratorLock.acquire` site;
  - (f) S's delivered names mapped to spec §4 assumptions.

- [ ] **Step 1:** Generate tables (a)–(f) on merged `main` and write them to the inventory. For (d), use the type-reference scan: declared type names per directory, then cross-directory references. For (f), read S's spec and plan as merged, then mark each spec §4 row "delivered as `<name>`" or "not delivered → R does it in Task N".
- [ ] **Step 2: Spike: `claude -p` under launchd.**
  - Write a throwaway plist (label `dev.brahma.spike`) whose program is `/bin/zsh -lc 'claude -p "say ok" --output-format json > <tmp>/out.json'` with `LimitLoadToSessionType Aqua`.
  - `launchctl bootstrap gui/$(id -u)`, wait for the file, `bootout`, delete the plist.
  - Expected: JSON with `"result"` containing `ok`. If it fails with an auth error, **stop and report to the controller**. That blocks spec item 5 (spec §6.4.11).
- [ ] **Step 3: Spike: Keychain dialog from a LaunchAgent.** Same method, running the built `brahma secret load` against a `BRAHMA_HOME` demo home with one secret written by a different build. Expected: the system dialog appears in the owner session. Record the result. A failure means the app's "Load secrets" keeps an in-app read and posts a DB signal instead; note it for Task 19.
- [ ] **Step 4: Spike: `bindat`/`connectat`.** A 20-line C or Swift check under `#if canImport(Darwin)` binding a Unix socket relative to a directory fd on macOS 14. Record whether it works. If it does not, Task 15 uses the absolute path with the ≤ 103-byte check.
- [ ] **Step 5: Schema guard check.** Open a DB migrated by a newer test migrator with today's `Store.init`, in a scratch test. Record whether it refuses. If it does not, Task 16 adds `StoreError.databaseNewer(known:applied:)`.
- [ ] **Step 6: Commit** the inventory with the spike results in the commit body.

### Task 1: Guard rails before any move

**Files:**
- Create: `Tests/BrahmaCoreTests/ModuleGraphTests.swift`, `PublicSurfaceTests.swift`, `GuardAllowlistTests.swift`, `Support/MovedPaths.swift`, `Fixtures/public-surface.txt`, `Fixtures/module-graph.json`
- Modify: the 8 path-pinning test files (spec §9 M3) so they read paths through `MovedPaths.current(_:)` Also modify S's `SafetyLintTests` (roots) and `Fixtures/safety-lint-baseline.json` (keys).
- Create: `Tests/BrahmaCoreTests/SafetyLintRootsTests.swift`

**Interfaces:**
- Produces:
  - `enum MovedPaths { static func current(_ oldPath: String) -> String; static let table: [String: String] }`. It is empty now and filled by each move task.
  - `ModuleGraphTests.allowedEdges: [String: Set<String>]`, which is the spec §6.1 graph.
  - `public-surface.txt`, which lists the umbrella's public type and function names, one per line, sorted.

- [ ] **Step 1: Write `GuardAllowlistTests.countsArePinned`.** It asserts the current allowlist sizes, for example `#expect(EngineGitGuardTests.gitCommandFiles.count == 2)`, with the numbers from Task 0. Do the same for every allowlist in the Global Constraints.
- [ ] **Step 2: Write `PublicSurfaceTests.surfaceUnchanged`.** It runs `swift package dump-symbol-graph` on the umbrella (or, if too slow, parses `public` declarations in `Sources/BrahmaCore/**`), then compares to `public-surface.txt`.
- [ ] **Step 3: Write `ModuleGraphTests.graphIsLayered`.** It parses the target dependencies from `swift package dump-package` JSON. Every edge must be in `allowedEdges`. Targets not yet created are ignored, so the test passes today.
- [ ] **Step 4:** Route each path-pinning test through `MovedPaths.current`. Run the full suite. Expected: green, with counts unchanged.
- [ ] **Step 4b: Write `SafetyLintRootsTests`.**
  - `coversEveryCoreTarget`: every non-test target except BrahmaApp, BrahmaAppModel and BrahmaMapKit has its `Sources/<Target>` directory in the lint roots.
  - `baselineKeysRenamedNotDropped`: the baseline's per-rule totals equal Task 0's recorded totals.
  
  Make the roots computed: `SafetyLintTests.roots(from:)` reads the `dump-package` targets. Run it. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 2: BrahmaFoundation and BrahmaModel

**Files:**
- Modify: `Package.swift`. Add the targets `BrahmaFoundation` (→ BrahmaSafety) and `BrahmaModel` (→ BrahmaFoundation, BrahmaSafety, GRDB). `BrahmaCore` depends on both. `BrahmaKeychain` depends on Foundation + Model.
- Move: the `Sources/BrahmaCore/{Util,Platform}/*` files that S left (S moved `AwakeTime`, `SHA256`, `SHA1` and `EngineFiles` into `BrahmaSafety`), `Paths.swift`, `TerminalText.swift`, `OrchestratorLock.swift` (renamed `EngineLock.swift`; `public typealias OrchestratorLock = EngineLock`, `OrchestratorLockError` kept) → `Sources/BrahmaFoundation/`. `Model/*` plus the pulled-down value types → `Sources/BrahmaModel/`.
- Create: `Sources/BrahmaCore/Umbrella.swift` (`@_exported import BrahmaFoundation`, `@_exported import BrahmaModel`)

**Interfaces:**
- Produces: the targets `BrahmaFoundation` and `BrahmaModel`. `EngineLock.acquire(paths:) throws -> EngineLock` keeps today's behaviour.

- [ ] **Step 1:** From Task 0 table (d), list the value types that `Model` and `Util` reference in feature directories (spec §6.1 cycle cuts: Model 12 refs, Util 3 refs). Move each one into `BrahmaModel`/`BrahmaFoundation` in its own file named after the type. Record the moves in `MovedPaths.table`.
- [ ] **Step 2:** `git mv` the directories, then fix imports. Change `internal` → `package` only where the compiler asks. Build.
- [ ] **Step 3:** Run `ModuleGraphTests`, `PublicSurfaceTests`, `GuardAllowlistTests`, then the full suite. Expected: green, and the surface file is unchanged.
- [ ] **Step 4: Commit:** `refactor(core): extract BrahmaFoundation and BrahmaModel targets`.

### Task 3: Verify the BrahmaSafety boundary

**Files:**
- Modify: `Tests/BrahmaCoreTests/ModuleGraphTests.swift`, adding the `BrahmaSafety` edges. It has no Brahma dependencies, only `CSandboxCheck`. `brahma-helper` depends on `BrahmaSafety` only.

**Interfaces:**
- Consumes: Task 0 (f). S delivered the target in S3, so R moves none of its files.

- [ ] **Step 1:** Add the edges to `allowedEdges`. Assert that `BrahmaFoundation`, `BrahmaModel` and every later target may import `BrahmaSafety`, and that `BrahmaSafety` imports none of them. S's own no-GRDB/no-Store test stays in `BrahmaSafetyTests`.
- [ ] **Step 2:** Check where the `Safety/` files that S left in `BrahmaCore` belong, using Task 0 (d): `Taint`, `Secrets`, `EmergencyStop`, `OwnerShellGuard`, `SandboxCanary`, `CanaryProbes`, `SleepGuard` and `SecretScan+Text`. Record their destination for Task 6 (Domain or Engine) in the inventory. Do not move them yet.
- [ ] **Step 3:** Run `ModuleGraphTests` and the full suite. Expected: green.
- [ ] **Step 4: Commit.**

### Task 4: BrahmaStore core

**Files:**
- Modify: `Package.swift` (`BrahmaStore` → Foundation, Model, Safety, GRDB)
- Move: `Store/Store.swift`, `Store/Migrations.swift`, plus core extensions (company, agent, turn, events, channels/messages, sessions, usage, owner prefs, engine stop/hold, secrets meta, notices, transcripts; the exact list is Task 0 (c)) → `Sources/BrahmaStore/`
- Modify: `Store.init(path:catalog:lifecycleObservers:observers:backupsDir:)`. It no longer prepends `OutcomeFactsObserver`, `EpisodeObserver` or `TaintedCommitObserver`.
- Create: `Sources/BrahmaCore/StandardStore.swift`

**Interfaces:**
- Produces:
  - `extension Store { public static func standard(path: String, catalog: PackCatalog = .builtin, lifecycleObservers: [any AgentLifecycleObserver] = [], observers: [any WorkItemObserver] = [], backupsDir: URL? = nil) throws -> Store }`. It builds the same observer order as today: `[OutcomeFactsObserver, EpisodeObserver, TaintedCommitObserver] + observers`.
  - `package var writer` access for other targets.

- [ ] **Step 1: Write `StandardStoreTests.observerOrderUnchanged`.** It asserts that `Store.standard(...).observers` type names equal `["OutcomeFactsObserver", "EpisodeObserver", "TaintedCommitObserver"]`.
- [ ] **Step 2:** Replace every `Store(path:` call in Sources/ and Tests/ with `Store.standard(path:`. In Task 0's tree that is the app, the CLI `openStore`, `AppModel.reopenStore` and the test helpers. Grep the count first and record it in the commit body.
- [ ] **Step 3:** `git mv` the core files. Build. Run the full suite. Expected: green.
- [ ] **Step 4: Commit.**

### Task 5: BrahmaGit with the GitWorkspace split

**Files:**
- Move: `Git/*`, `Merge/*`, `Store/Store+Merge.swift`, `Store+MergeQueue.swift`, `Store+MergeSettings.swift`, `Store+MainGuard.swift` → `Sources/BrahmaGit/`
- Split: `GitWorkspace.swift` (3,944 lines on `main`) into `GitCommandRunner.swift` (hardened command running and config overrides), `GitWorktrees.swift` (worktree lifecycle), `GitMainGuard.swift` (main guard and queue helpers) and `GitQueries.swift` (read-only queries), each `extension GitWorkspace`. **Skip any part S already moved into its helper.**

**Interfaces:**
- Produces: the `BrahmaGit` target (→ Foundation, Model, Safety, Store). `GitWorkspace`'s API is unchanged.

- [ ] **Step 1:** Cut the `Git → {Org, Scheduler, Extensions, Owner, Turns, Platform}` references (8, Task 0 (d)) by moving the values to `BrahmaModel` or injecting them.
- [ ] **Step 2:** Split the file by moving whole functions only. There are no body edits. Diff check: `git diff --stat -M` shows only moves, plus the 4 new files.
- [ ] **Step 3:** Update `EngineGitGuardTests.gitCommandFiles` through `MovedPaths`. It must stay **2 entries**: `GitCommandRunner.swift` and S's `SafeGit` path. `GuardAllowlistTests` must be green.
- [ ] **Step 4:** Run `GitWorkspaceTests`, `MergeQueueTests`, `MergeBatchTests`, `MergeRecoveryTests`, `MainGuardTests`, then the full suite. Expected: green.
- [ ] **Step 5: Commit.**

### Task 6: BrahmaDomain, BrahmaAgentTools, BrahmaEngine

**Files:**
- Move: every remaining `Sources/BrahmaCore/<Dir>` per spec §6.1, and the remaining `Store+*.swift` to `BrahmaDomain` beside their feature directory (for example `Sources/BrahmaDomain/Release/Store+Release.swift`). `MCP/*` → `BrahmaAgentTools`. `Orchestrator*.swift`, `Scheduler`, `Engine`, `Verify` → `BrahmaEngine`.
- Create: `Sources/BrahmaDomain/Verify/CheckBaseline.swift` (was `Orchestrator.checkBaseline`; `Orchestrator.checkBaseline` stays as a forwarding `static func`)

**Interfaces:**
- Produces: the three targets. `CheckBaseline.make(store:paths:) -> [String: String]`, with the same body as today's `Orchestrator.checkBaseline`.

- [ ] **Step 1:** Cut the 9 `Domain → Orchestrator` references (Task 0 (d)) by moving the static helpers into domain types. Keep forwarding statics on `Orchestrator` so call sites compile.
- [ ] **Step 2:** `git mv` in three commits, one per target. Each must build and pass the full suite.
- [ ] **Step 3:** Run `ModuleGraphTests`, `PublicSurfaceTests` and `GuardAllowlistTests`. Expected: green, and the surface is unchanged.
- [ ] **Step 4: Commit** (three commits).

### Task 7: `CompanyScope`

S4 already made `AlertScope` required, so this task covers the Store half only (S §3 leaves it to R).

**Files:**
- Create: `Sources/BrahmaStore/CompanyScope.swift`, `Tests/BrahmaStoreTests/CompanyScopeTests.swift`
- Modify: the company-owned write functions of `Store+Merge*`, `Store+Asks`, `Store+AskLifecycle` and `Store+Release`, and their callers

**Interfaces:**
- Produces:
  - `public struct CompanyScope: Sendable, Equatable { public let companyId: String }`
  - `extension Store { public func scope(_ companyId: String) -> CompanyScope }`
  - Converted write functions take `_ scope: CompanyScope` in place of `companyId: String`. Their SQL is unchanged.

- [ ] **Step 1: Write `CompanyScopeTests`.**
  - `mergeBatchWriteStaysInScope`: a batch write through company A's scope leaves company B's rows untouched, the same result as today's SQL.
  - `askWriteStaysInScope`.
  - `releaseWriteStaysInScope`.
  - `scopedSignaturesOnly`: a static scan of the four files finds no `public func` that writes and still takes `companyId: String`.
- [ ] **Step 2:** Run them. Expected: FAIL (`CompanyScope` is undefined).
- [ ] **Step 3:** Convert the four repositories. Callers pass `store.scope(id)`. List the remaining unconverted company-owned writers in the inventory as follow-ups.
- [ ] **Step 4:** Run the full suite. Expected: green.
- [ ] **Step 5: Commit.**

### Task 8: `AskService`

**Files:**
- Create: `Sources/BrahmaDomain/Inbox/AskService.swift`, `Tests/.../AskServiceTests.swift`
- Modify: `Store+Asks.swift`, `Store+AskLifecycle.swift`. They become persistence plus delegation, with signatures unchanged.

**Interfaces:**
- Produces:
  - `struct AskService { let store: Store; func decide(_ input: OwnerDecision, now: Date) throws -> Ask; func answer(askId: String, text: String, now: Date) throws -> Ask; func rescind(askId: String, now: Date) throws -> RescindOutcome; func sweep(now: Date) throws -> AskSweepResult }`
  - `enum AskTransition { static func next(_ ask: Ask, event: AskEvent, now: Date) -> Result<Ask, WorkError> }` (pure)
  - `Store.ownerDecide`/`ownerAnswer`/`ownerRescind`/`acknowledge`/`sweepAsks` keep their exact signatures and delegate.

- [ ] **Step 1: Write `AskServiceTests.transitionTableMatchesStore`.** For every (status, event) pair, `AskTransition.next` gives the same result as running today's Store path on a fixture DB. Write the table first from today's code, then assert it.
- [ ] **Step 2:** Run the test against today's code. Expected: FAIL to compile (`AskTransition` is not defined).
- [ ] **Step 3:** Extract the transition logic and leave the SQL in the Store files.
- [ ] **Step 4:** Run `AskTests`, `AskLifecycleTests`, `InboxTests` and the full suite. Expected: green, with no test edits besides the new file.
- [ ] **Step 5: Commit.**

### Task 9: `TickParticipant` scaffolding, `TaskRegistry`, order and gate pins

**Files:**
- Create: `Sources/BrahmaEngine/Tick/TickParticipant.swift`, `Tick/TickContext.swift`, `Tick/TaskRegistry.swift`, `Tests/.../TickOrderTests.swift`, `TickGatesTests.swift`
- Modify: `Orchestrator.swift`. The 12 task maps become `TaskRegistry`, and `schedule(now:)` gains an `observer: TickObserver?` test hook (`package`) that records step ids.

**Interfaces:**
- Produces (spec §6.2):
  - `package protocol TickParticipant: AnyObject { var id: TickStepID { get }; var gates: TickGates { get }; func recover(_ ctx: RecoveryContext, on engine: isolated Orchestrator) async throws; func tick(_ ctx: TickContext, on engine: isolated Orchestrator) throws; func shutdown(on engine: isolated Orchestrator) }`
  - `package struct TickGates: OptionSet { static let stop, hold, secrets, pressure, companyRunning }`
  - `package struct TickStepID: RawRepresentable, Hashable` with the 20 ids of spec §6.2: `stop`, `secrets`, `health`, `ultraReservations`, `leases`, `restoreMarker`, `sweeps`, `knowledge`, `audits`, `blockerExpiry`, `timers`, `push`, `usage`, `checks`, `mainGuard`, `merge`, `preview`, `smoke`, `release`, `canary`, plus `admission` and `dispatch`
  - `package final class TaskRegistry { func insert(_ task: Task<Void, Never>, owner: TickStepID, key: String); func remove(owner:key:); func count(owner: TickStepID) -> Int; var isIdle: Bool { get }; func all() -> [Task<Void, Never>]; var awakeWork: Int { get } }`
  - `package struct TickContext { now, stopped, held, secretsPending, pressure, config, companies, tasks }`

- [ ] **Step 1: Write `TickOrderTests.orderIsPinned`.** It runs one tick on a fixture with every subsystem active and asserts the recorded id list equals the literal list above. Add any step Task 0 (a) found that is not in the list, at its position. Then write `TickGatesTests.gatesMatchToday` with a literal table copied from today's guards:
  - `knowledge`: `[.stop, .secrets]`
  - `restoreMarker`: `[.stop]`
  - `leases`: `[]`, because it takes `held` as a parameter
  - and so on for the rest.
- [ ] **Step 2:** Run both. Expected: `orderIsPinned` passes against the step hook. `gatesMatchToday` fails to compile until Task 10 adds participants, so mark it `.disabled("Task 10")` and **remove** the disable in Task 10.
- [ ] **Step 3:** Replace the task maps with `TaskRegistry`. `resumeIdleWaitersIfIdle` hangs off the registry, and `runForever`'s tail uses `registry.all()`.
- [ ] **Step 4:** Run `OrchestratorTests`, `TickOrderTests` and the full suite. Expected: green.
- [ ] **Step 5: Commit.**

### Task 10: Participants 1–12

**Files:**
- Create: `Sources/BrahmaEngine/Tick/{StopStep,SecretsStep,HealthStep,UltraReservationStep,LeaseStep,RestoreMarkerStep,SweepStep,KnowledgeStep,AuditStep,BlockerExpiryStep,TimerStep,PushStep}.swift`
- Delete after the move: `Orchestrator+Stop.swift`, `+Health.swift`, `+Leases.swift`, `+Restore.swift`, `+Timers.swift` (their bodies move into steps)

**Interfaces:**
- Consumes: Task 9.
- Produces: one `final class <Name>Step: TickParticipant` per row 1–12 of spec §6.2, each holding exactly the state listed in that row. `Orchestrator.participants: [any TickParticipant]` is built in `init` in that order.

- [ ] **Step 1:** One commit per participant. Move the state and the body, and call the participant from `schedule` at the same position. `TickOrderTests` and `OrchestratorTests` must be green after each commit.
- [ ] **Step 2:** Enable `TickGatesTests.gatesMatchToday` for rows 1–12. Run it. Expected: PASS.
- [ ] **Step 3:** Move `recover` steps into `recover(_:on:)` in today's `start()` order. Write `RecoveryOrderTests.recoverOrderUnchanged`, which records the recovery hook order and compares it to today's literal list: leftovers reap, interrupted turns, checks, smokes, releases, merges, merge journal, hooks, labs, extensions, timers, WAL.
- [ ] **Step 4:** Run the full suite. Expected: green.
- [ ] **Step 5: Commit** (one per participant, plus one for recovery order).

### Task 11: Participants 13–20 and `TurnLauncher`

**Files:**
- Create: `Tick/{UsageStep,CheckStep,MainGuardStep,MergeStep,PreviewStep,SmokeStep,ReleaseStep,CanaryStep}.swift`, `Sources/BrahmaEngine/Turns/TurnLauncher.swift`
- Delete after the move: `Orchestrator+Budget`, `+Ultra`, `+Checks`, `+Merge`, `+Preview`, `+Release`, `+Canary`, `+Sandbox`, `+Modes`, `+Review` (whatever remains of it)

**Interfaces:**
- Produces:
  - `UsageStep.tick` writes `ctx`-scoped `UsageDecisions { decisions: [String: UsageDecision], paceClosed: Set<String>, paceStrict: Set<String> }` into an `Orchestrator`-owned slot that admission reads in the same tick.
  - `CanaryStep` exposes `heldAgentIds(ready:companies:) -> Set<String>`, which is today's `canaryTick`.
  - `final class TurnLauncher { func launch(_ agent: Agent, now: Date, on engine: isolated Orchestrator); nonisolated func performTurn(agent: Agent, turn: Turn) async; func turnEnded(agentId: String, companyId: String, on engine: isolated Orchestrator) }`, with the same bodies as today.
- `Orchestrator.swift` ends ≤ 600 lines. It holds admission, dispatch, the participant list, `start`, `runForever`, `tick` and `waitUntilIdle`.

- [ ] **Step 1:** Run the same per-participant commit cycle as Task 10, rows 13–20.
- [ ] **Step 2:** Move the turn path into `TurnLauncher`. `EngineGitGuardTests`' engine-prefix scan (`Sources/BrahmaCore/Orchestrator*`) is re-pointed through `MovedPaths` to `Sources/BrahmaEngine/{Orchestrator.swift,Tick/,Turns/TurnLauncher.swift}`. Its assertion is unchanged.
- [ ] **Step 3:** Enable the remaining `TickGatesTests` rows. Run `wc -l Sources/BrahmaEngine/Orchestrator.swift`. Expected: ≤ 600.
- [ ] **Step 4:** Run the full suite plus `BRAHMA_LIVE=1 … swift test --filter LiveSandboxProbeTests` once. Expected: green.
- [ ] **Step 5: Commit.**

### Task 12: Test targets and `BrahmaTestSupport`

**Files:**
- Modify: `Package.swift`, adding the test targets of spec §9 M4 and the `BrahmaTestSupport` library target (resources `.copy("Fixtures")`)
- Move: 189 `Tests/BrahmaCoreTests/*.swift` files into the per-module test targets, by the module of the code under test (Task 0 maps each file). Shared helpers go to `Tests/BrahmaTestSupport/`. The `TestScratch.swift` copies in the AppModel and MapKit targets are replaced by the support target.

**Interfaces:**
- Produces: the test targets. Each test file imports `BrahmaTestSupport` plus `@testable import` of every module it touches (script-added, then pruned by the compiler's "unused" warnings only if trivial).

- [ ] **Step 1:** Write the script `scripts/split-tests.sh` (kept for P). It reads the Task 0 mapping, runs `git mv`, and prepends the import block. Run it.
- [ ] **Step 2:** Build. Fix only imports and the `package`/`internal` access that the compiler reports.
- [ ] **Step 3:** Run the full suite. Expected: the same test count as before the split (record both numbers), and green.
- [ ] **Step 4: Commit.**

### Task 13: Optional `BrahmaDomain` split (measure first)

**Files:**
- Modify (only if the gate passes): `Package.swift`, and move directories into `BrahmaWork`, `BrahmaKnowledge` and `BrahmaShip` (spec §6.1)

- [ ] **Step 1:** Re-run the Task 0 (d) scan restricted to `BrahmaDomain`, grouped as in spec §6.1. Count the back-edges against the order Work → Knowledge → Ship.
- [ ] **Step 2:** If there are ≤ 10 and each is a value type, move those types to `BrahmaModel`, split the target, and add the edges to `ModuleGraphTests`. If there are more, record the count and the top offenders in the inventory as "deferred" and stop.
- [ ] **Step 3:** Measure the cold `swift build` time and the time after touching one file in `BrahmaDomain/Release/`, before and after. Record both in the commit body.
- [ ] **Step 4: Commit.**

### Task 14: `BrahmaEngineClient`: wire protocol and client

**Files:**
- Create: `Sources/BrahmaEngineClient/{Wire/Envelope.swift,Wire/Messages.swift,Wire/Framing.swift,EngineClient.swift,EngineStatusReport.swift,BuildStamp.swift,OwnerProof.swift}`, `Tests/BrahmaServiceTests/WireTests.swift`
- Create (kernel, security-reviewed): `Sources/BrahmaSafety/Net/LocalSocket.swift`, `Tests/BrahmaSafetyTests/LocalSocketTests.swift`
- Modify: `Package.swift` (`BrahmaEngineClient` → BrahmaSafety, BrahmaFoundation, BrahmaModel)
- Modify: `scripts/make-app.sh` (it writes `Sources/brahma/BuildInfo.swift` and `Sources/BrahmaApp/BuildInfo.swift` from `git describe --always --dirty`; `swift build` without the script uses a checked-in default `"dev"`)

**Interfaces:**
- Produces:
  - `public struct Envelope: Codable, Sendable { public var v: Int; public var id: UInt64; public var kind: Kind; public var type: String; public var body: JSONValue }`, where `Kind` is `request`, `response` or `event`.
  - `public enum Framing { static let maxFrame = 1 << 20; static func encode(_ e: Envelope) throws -> Data; static func decode(from: inout Data) throws -> Envelope? }`. Throws `.oversize` and `.malformed`.
  - Requests: `Hello(protocol: Int, role: ClientRole, build: BuildStamp, pid: Int32)`, `Welcome(protocol: Int, build: BuildStamp, schemaVersion: String, engineId: String, state: ServiceState, nonce: Data)`, `StatusRequest`, `Subscribe(streams: Set<Stream>)`, `Nudge`, `Recheck`, `LoadSecrets(interactive: Bool)`, `Suspend(reason: String, holderPid: Int32)`, `Resume`, `Shutdown(mode: ShutdownMode)`, `RestartForUpgrade`. Errors: `ownerProofRequired`, `buildMismatch(engine:client:)`, `protocolMismatch`, `refused(String)`.
  - `public enum ServiceState: Codable, Equatable { case starting, doctoring, recovering, running, suspended(reason: String), draining, stopping, stopped, failed(String), crashLoop }`
  - `public struct EngineStatusReport: Codable, Equatable { state, pid, build, startedAt, lastTickAt, runningByCompany: [String: Int], holds: [HoldLine], secretsHeldNames: [String], canary: CanaryLine?, doctor: DoctorLine?, installer: InstallerStatus }`
  - `public struct BuildStamp: Codable, Equatable { version: String; build: String; static let current: BuildStamp }`
  - `public enum OwnerProof { static func make(key: Data, nonce: Data, type: String, id: UInt64) -> Data; static func verify(...) -> Bool }`. This is HMAC-SHA256, implemented on top of S's `SHA256` in `BrahmaSafety`, with no CryptoKit.
  - `public enum LocalSocket { public static func listen(in runDir: String, name: String) throws(LocalSocketError) -> Int32; public static func connect(in runDir: String, name: String) throws(LocalSocketError) -> Int32 }`, in `BrahmaSafety`.
    - It opens `runDir` with `O_DIRECTORY|O_NOFOLLOW` and requires the directory to be owned by `getuid()` with mode 0700.
    - `listen` unlinks a stale entry only if it is a socket. It binds relative to the directory descriptor (`bindat`) when Task 0 Step 4 passed, else by absolute path of ≤ 103 bytes. It then applies `fchmod` 0600 and `listen(16)`.
    - Every failure is a typed refusal; there is no `try?` (S's lint applies).
  - `public actor EngineClient { init(socketPath: URL, role: ClientRole); func connect() async throws -> Welcome; func status() async throws -> EngineStatusReport; func events(_ streams: Set<Stream>) -> AsyncThrowingStream<ServiceEvent, Error>; func send<R: OwnerRequest>(_ r: R, ownerKey: Data) async throws -> R.Response; func nudge() async }`. It reconnects with the Global Constraint backoff.

- [ ] **Step 0: Write `LocalSocketTests`:**
  - `refusesSymlinkedRunDir`
  - `refusesGroupReadableRunDir`
  - `socketIs0600`
  - `staleNonSocketNotUnlinked` (a regular file named `engine.sock` stays and the call is refused)
  - `connectRoundTrip`
- [ ] **Step 1: Write `WireTests`:**
  - `roundTripEveryMessage`
  - `oversizeFrameRejected` (1 MiB + 1)
  - `malformedJSONRejected`
  - `partialFrameWaits` (half a frame returns nil)
  - `hmacKnownVector` (RFC 4231 test case 2)
  - `proofBindsTypeAndId` (the same nonce with a different type fails verify)
- [ ] **Step 2:** Run them. Expected: FAIL (types undefined).
- [ ] **Step 3:** Implement. `EngineClient`'s socket I/O uses `LocalSocket.connect` on a dedicated thread with blocking reads, bridged into AsyncStream. `connectat` relative to the run-dir fd is used when Task 0 Step 4 passed.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 15: `BrahmaService`: host, locks, IPC server, auth, crash loop, logs

**Files:**
- Create: `Sources/BrahmaService/{EngineService.swift,ServiceState.swift,ServiceLocks.swift,IPCServer.swift,PeerAuth.swift,CrashLoopGuard.swift,ServiceLog.swift,ToolEnvironment.swift}`
- Move: `BrahmaAppModel/Engine/ToolLocator.swift` and `EngineSetup.resolveTools` → `ToolEnvironment.swift` (the app imports them from here)
- Modify: `DataHomeGuard.lockDown` (adds `paths.logsDir`), `BrahmaPaths` (`logsDir`, `serviceSocket`, `serviceLock`, `serviceStarts`)
- Test: `Tests/BrahmaServiceTests/{ServiceLifecycleTests,ServiceLockTests,ServiceAuthTests,CrashLoopGuardTests,ServiceLogTests}.swift`

**Interfaces:**
- Consumes: Task 14 and `Orchestrator`.
- Produces:
  - `public final class EngineService { public init(paths: BrahmaPaths, config: EngineServiceConfig, deps: EngineServiceDeps); public func run() async -> Int32 /* exit code */; public var state: ServiceState { get async } }`
  - `EngineServiceDeps { makeOrchestrator: (Store, EngineTools) -> Orchestrator; doctor: (String) async -> DoctorReport; vault: any SecretVault; ownerKeyStore: any OwnerKeyStore; clock: @Sendable () -> Date; awake: AwakeClock; peer: PeerInspecting }`. Tests inject a fake runner and doctor.
  - `public protocol PeerInspecting { func uid(fd: Int32) -> uid_t?; func pid(fd: Int32) -> pid_t? }`
  - `public struct CrashLoopGuard { static func record(start: Date, at: URL) throws; static func markClean(at: URL) throws; static func isLooping(at: URL, now: Date) -> Bool }`
  - `ServiceLog.open(paths:) throws -> FileHandle`, which rotates per the Global Constraint.
  - All service files (lock, starts file, log, socket) are opened through S's `Place`/`EngineFiles` APIs rooted at the data home, or through `LocalSocket`. `flock` is applied to the descriptor those APIs return, so `SafetyLintTests` needs no new baseline entry.

- [ ] **Step 1: Write the tests** (the in-process service on a temp home with a short root, `StubRunner`, and an injected passing doctor):
  - `ServiceLifecycleTests.reachesRunningAndTicks`: state goes starting → doctoring → recovering → running, and `status.lastTickAt` advances when a nudge is sent.
  - `doctorFailureReportsFailedThenRecheckRecovers`.
  - `shutdownNowInterruptsLikeQuit`: a hanging turn ends `interrupted` and the agent is `ready`, the same rows that `EngineHost.stop` leaves today (compare with the fixture produced by today's `EngineHost` path under `BRAHMA_ENGINE_MODE=embedded`).
  - `sigtermTakesShutdownPath`.
  - `ServiceLockTests.secondServeExitsZero`: a second `EngineService.run()` on the same home returns 0 with the "already running (pid N)" log line.
  - `staleSocketReplacedOnlyUnderLock`.
  - `ServiceAuthTests.mutationWithoutProofRefused` (`Resume` without proof → `ownerProofRequired`), `peerUnderTurnLeaderRefused` (the fake `PeerInspecting` returns a pid whose ancestry includes a recorded turn leader → connection closed with `refused`), `wrongUidRefused`, `statusNeedsNoProof`.
  - `CrashLoopGuardTests.fiveUncleanStartsInTenMinutesLoop`, `cleanExitsDoNotCount`, `oldStartsExpire` (injected clock).
  - `ServiceLogTests.rotatesOver20MBKeeps3`.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `run()` takes `service.lock` (exit 0 with a message if busy), then checks the crash loop (`crashLoop` state: IPC up, no orchestrator), then resolves the tool environment (login-shell PATH, `claude`), then runs the doctor, then takes `EngineLock`, then builds the Orchestrator and calls `start()`, then `runForever`.
  - The IPC server accepts on a thread and handles requests on a service actor. Nudge calls `orchestrator.tick()` coalesced (at most one pending).
  - Auth order follows spec §6.4.4 items 1–5.
- [ ] **Step 4:** Run the service tests and the full suite. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 16: Suspend/resume, upgrade drain, schema guard, kill switch

**Files:**
- Create: `Sources/BrahmaService/Suspension.swift`, `UpgradeDrain.swift`, `Tests/BrahmaServiceTests/{ServiceSuspendTests,ServiceUpgradeTests,ServiceKillSwitchTests}.swift`
- Modify:
  - the 6 lock-taking sites (Task 0 (e)): `Restore` ×2, `DevReleaseScenario`, `ProviderProbe`, `LabProvenance.engineLock`, `RepoImport`. Each wraps `EngineLock.acquire` with `EngineSuspension.withEngineSuspended(paths:reason:) { … }`.
  - `StopCommand.swift` (adds `nudge`).
  - `Store.init` (`StoreError.databaseNewer`, if Task 0 Step 5 found no refusal).

**Interfaces:**
- Produces:
  - `public enum EngineSuspension { public static func withEngineSuspended<T>(paths: BrahmaPaths, reason: String, ownerKey: () throws -> Data, _ body: () throws -> T) throws -> T }`. With no service answering, it runs `body` directly (today's path).
  - Server side:
    - `Suspend` holds admission, takes today's quit path, closes the Store, releases `EngineLock`, and watches `holderPid` (`kqueue NOTE_EXIT`).
    - `Resume`, or the holder's exit with the lock free, reopens the Store, re-takes the lock, and runs `recover`.
  - Server side, `RestartForUpgrade`:
    - sets an in-memory `upgradePending` hold;
    - waits until `TaskRegistry` has no turn, check, merge or release tasks, or 600 s awake have passed;
    - then shuts down with `now` and exits 75.
  - `StoreError.databaseNewer(known: Int, applied: Int)`. The service maps it to `failed("database is newer than this engine (build X)")`.

- [ ] **Step 1: Write the tests:**
  - `ServiceSuspendTests.restoreSuspendsAndResumes`: a running service, then `BackupService.restore` through the wrapper, then state `suspended`, the lock free during the body, then `running` again, with the restored DB's stop row carried (`RestoreCarry`).
  - `holderDeathResumes`: the holder pid is a child that exits.
  - `noServiceRunsBodyDirectly`.
  - `ServiceUpgradeTests.drainThenExit75`: one running fake turn, `RestartForUpgrade`, no new admission, the turn finishes, exit code 75.
  - `drainTimeoutInterrupts`: an awake clock advanced 601 s leaves the turn `interrupted`.
  - `olderEngineRefusesNewerSchema`.
  - `preMigrationSnapshotTaken` (existing behaviour, through the service).
  - `ServiceKillSwitchTests.stopWorksWithServiceWedged`: the service's tick is blocked by a test gate, then `StopCommand` logic (the core function, not the binary) writes the row and signals recorded groups, and the fake group sees SIGTERM.
  - `stopDuringUpgradeDrainHolds`: no admission after the restart, because the DB stop row still holds.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the tests and `RestoreTests`, `EmergencyStopTests`, `LabTaintTests` and `ProviderProbeTests`. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 17: Installer and the `brahma engine` CLI group

**Files:**
- Create: `Sources/BrahmaService/Install/{ServiceInstaller.swift,LaunchAgentPlist.swift,Launchctl.swift,UnmanagedLauncher.swift}`, `Sources/brahma/EngineCommands.swift`, `Tests/BrahmaServiceTests/{LaunchAgentPlistTests,ServiceInstallerTests}.swift`, `Tests/BrahmaGuardTests/ServiceGuardTests.swift`, `Tests/BrahmaCLITests/EngineRunCommandTests.swift`
- Move: `Sources/brahma/RunCommand.swift` → `EngineRunCommand.swift` (`brahma run` stays as an alias). Move `SecretTests`' file-read assertions accordingly.
- Modify: `DoctorCommand.swift` (four service lines), `StatusCommand.swift` (one engine line), `Brahma.swift` (registers `engine`)

**Interfaces:**
- Produces:
  - `public protocol Launchctl: Sendable { func bootstrap(plist: URL) throws; func bootout(label: String) throws; func kickstart(label: String, kill: Bool) throws; func isLoaded(label: String) -> Bool; func kill(label: String, signal: Int32) throws }`.
    - `SystemLaunchctl` (Darwin) runs `ToolPaths.launchctl` (`/bin/launchctl`, added to S's `ToolPaths`, verified like the other tools) through S's `Spawn`, with fixed argv.
    - `FakeLaunchctl` lives in the support target.
  - `public enum LaunchAgentPlist { static func label(paths: BrahmaPaths) -> String; static func render(program: URL, paths: BrahmaPaths, autostart: Bool) -> Data }`, an XML plist with the Global Constraint keys.
  - `public struct ServiceInstaller { func install(program: URL) throws -> InstallerStatus; func uninstall() throws; func status() -> InstallerStatus; func ensureCurrent(program: URL) throws }`. `ensureCurrent` rewrites and re-bootstraps when `ProgramArguments[0]` differs.
  - `public enum InstallerStatus: Codable { notInstalled, installed, loaded, disabledByUser, unmanaged }`
  - `UnmanagedLauncher.spawn(program: URL, paths: BrahmaPaths) throws -> pid_t` uses S's `Spawn` with a new session, and its stdout and stderr go to the log descriptor. If `Spawn` has no new-session option, add one in `BrahmaSafety` under the same security review as Task 14's `LocalSocket`.
  - CLI: `brahma engine status|start|stop|restart|kill|logs [-f] [--lines N]|install|uninstall|autostart on|off|run [--hard-cap N] [--profile P]`. All except `status`, `logs` and `run` call `requireOwnerShell()`. `kill` = SIGKILL the pid from `service.lock`, `bootout`, then `EmergencyStop.signalGroups(recordedGroups)`.

- [ ] **Step 1: Write the tests:**
  - `LaunchAgentPlistTests.defaultHomeLabel` (`dev.brahma.engine`).
  - `otherHomeLabelIsHashed`.
  - `renderHasExactKeys`: parse back with `PropertyListSerialization` and assert every key and value of the Global Constraint table, `BRAHMA_HOME` only for a non-default home, and `ProgramArguments == [program, "engine", "serve"]`.
  - `ServiceInstallerTests.installWritesAndBootstraps` (`FakeLaunchctl` records calls).
  - `ensureCurrentRebootstrapsWhenMoved`.
  - `disabledByUserFallsBackToUnmanaged`.
  - `ServiceGuardTests.launchctlOnlyInInstall`.
  - `EngineRunCommandTests.refusesWhileServiceRuns` (a service in-process holding the lock; the `engine run` core reports "engine service is running … brahma engine stop").
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement.
  - The plist is written through `EngineFiles` (atomic temp, `fsync`, rename, 0644) under `~/Library/LaunchAgents`, a fixed owner path, as a `Place`.
  - `SafetyLintTests` must pass with an unchanged baseline.
- [ ] **Step 4:** Run the tests and the full suite. Expected: PASS.
- [ ] **Step 5:** Manual (controller, once): `scripts/make-app.sh debug`, then `Brahma.app/Contents/Helpers/brahma engine install` with a demo `BRAHMA_HOME`, then `brahma engine status` shows running, then `brahma engine uninstall`. Record the output in the task report.
- [ ] **Step 6: Commit.**

### Task 18: Socket deny rule and canary probe

**Files:**
- Modify: S's policy factory (`SandboxPolicyFactory`, path per Task 0 (f)) so it adds the two rules of spec D-R12 to every agent and helper policy. Also modify `CanaryProbes` (a new probe `engine-socket`) and the default probe file template.
- Test: `Tests/BrahmaSafetyTests/CanaryProbeTests.swift` (or S's test file for the factory)

**Interfaces:**
- Produces:
  - `SandboxPolicy.denyUnixSocketPaths: [String]`, set by the factory to `[paths.serviceSocket.path]` with subpath `paths.runDir.path`, and rendered by `SeatbeltProfile.render` as `(deny network-outbound (remote unix-socket (path-literal …)))` and `(… (subpath …)))`.
  - Probe `engine-socket`: inside the turn, `/usr/bin/nc -U <sock> </dev/null`. The expected outcome is **denied**.

- [ ] **Step 1: Write the tests:**
  - `SeatbeltProfileTests.rendersSocketDeny` (exact strings).
  - `PolicyFactoryTests.everyPurposeDeniesEngineSocket` (iterates every factory purpose).
  - `CanaryProbeTests.engineSocketDenied` (`.enabled(if: Toolchain.seatbeltAvailable)`; a real `sandbox-exec` with the rendered profile cannot connect to a listening socket bound in a temp run dir).
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement. Changing the profile changes the canary's settings shape, so the canary re-runs on first start, which is expected. Note it in the README.
- [ ] **Step 4:** Run the tests plus `BRAHMA_LIVE=1 … --filter LiveSandboxProbeTests` once. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 19: App becomes a client

**Files:**
- Create: `Sources/BrahmaAppModel/Engine/EngineConnection.swift`, `Sources/BrahmaApp/Views/EngineSettingsPanel.swift`, `Tests/BrahmaAppModelTests/EngineConnectionTests.swift`
- Delete: `Sources/BrahmaAppModel/Engine/EngineHost.swift` and its tests (`AppModelEngineTests` takeover cases, which are replaced by `EngineConnectionTests`). Delete the `BRAHMA_ENGINE_MODE=embedded` switch.
- Modify: `AppModel.swift`, which removes `ticksSinceTakeoverCheck` and `retryTakeover`. `engine: EngineHost?` → `engine: EngineConnection?`. `restore` uses `EngineSuspension`. `restartEngine` is removed.
  - `AppModel+Secrets.swift`: `loadSecrets` → IPC `LoadSecrets(interactive: true)`, and `secretsBanner` comes from `status.secretsHeldNames`.
  - `AppModel+Work.swift`: `retryEngine` → IPC `Recheck`, and it uses `clock()`.
  - `MenuBar/MenuBarSummary.swift`.
  - `BrahmaApp/AppDelegate.swift`: boot = install or ensureCurrent, then connect. Quit closes the app per RQ1. ⌥ Quit sends `Shutdown(now)` bounded by 15 s.
  - `Views/EngineBanner.swift`, `Views/MenuBarContent.swift` (Stop engine / Start engine), `Harness.swift` (`engine=service`; starts an unmanaged service under the smoke home).

**Interfaces:**
- Consumes: Tasks 14–17.
- Produces:
  - `@MainActor @Observable public final class EngineConnection { public private(set) var status: EngineStatus; public private(set) var report: EngineStatusReport?; public init(paths: BrahmaPaths, client: EngineClientProtocol, installer: ServiceInstalling?); public func start() async; public func recheck() async -> DoctorReport?; public func loadSecrets(ownerKey: Data) async throws; public func shutdown(timeout: Duration) async; public func nudge() }`
  - `public enum EngineStatus { starting, service, suspended(String), stopping, stopped, updatePending, crashLoop, failed(String) }`, mapped from `ServiceState` by a table in `EngineConnection.swift` that `EngineConnectionTests.mapsEveryState` covers.
  - `EngineClientProtocol` lets tests inject `FakeEngineClient`.

- [ ] **Step 1: Write `EngineConnectionTests`:**
  - `mapsEveryState`.
  - `reconnectsWithBackoff` (a fake client fails twice; `ManualClock` steps of 0.1 s then 0.2 s).
  - `buildMismatchShowsUpdatePendingAndRequestsRestart`.
  - `secretsBannerFromServiceStatus`.
  - `recheckUsesService`.
  - `quitLeavesServiceRunning`: the quit path sends no `Shutdown`.
  - `optionQuitShutsDownBounded`: a fake that never answers is still released after 15 s on `ManualClock`.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement. Map each old banner text through the state table. The copy stays the same where the state is the same, for example "Claude Code check failed: … Run brahma doctor in Terminal for details.".
- [ ] **Step 4:** Run the full suite, then `scripts/make-app.sh debug && scripts/smoke-app.sh`. Expected: `SMOKE OK … engine=service`.
- [ ] **Step 5: Commit.**

### Task 20: Docs, measurements, cleanup

**Files:**
- Modify: `README.md` ("Running the engine": the service, `brahma engine …`, Quit vs ⌥ Quit, Login Items, logs, Keychain prompts for the helper, the canary re-run after the socket rule). Append an "After Plan R" note under v2 §3.1 in `docs/superpowers/specs/2026-10-21-brahma-design-v2.md`, without rewriting the original diagram. Update `scripts/smoke-app.sh`.
- Delete: `LaunchAgentSpikeTests.swift` (Task 0)

- [ ] **Step 1:** Record in the commit body:
  - cold `swift build` time, before (Task 0) and after;
  - one-file-touch rebuild time;
  - test count per target and full-suite time;
  - `wc -l` of `Orchestrator.swift`, and the Store core line count.
- [ ] **Step 2:** Run `GuardAllowlistTests`, `PublicSurfaceTests` and `ModuleGraphTests`, then the full suite twice. Expected: green both times.
- [ ] **Step 3:** Final review (Opus, per the owner's model policy for final reviews) of the whole branch against spec §5 anti-goals and §7 parity checklist.
- [ ] **Step 4: Commit.**

---

## Self-review notes (done inline)

- **Spec coverage.** Each spec section maps to tasks:
  - §6.1 targets: Tasks 1–6, 12, 13.
  - §6.2 participants: Tasks 9–11.
  - §6.3 Store: Tasks 4, 7, 8.
  - §6.4.1 processes: Task 15.
  - §6.4.2 install: Task 17.
  - §6.4.3 locks: Tasks 15, 17.
  - §6.4.4 IPC: Tasks 14, 15.
  - §6.4.5 lifecycle: Task 15.
  - §6.4.6 suspend: Task 16.
  - §6.4.7 upgrade: Task 16.
  - §6.4.8 crash loop: Task 15.
  - §6.4.9 sleep/network: no new code. It is covered by `ServiceLifecycleTests` (no wall clock) plus the reconnect test in Task 19.
  - §6.4.10 kill switch: Tasks 16, 17, 18.
  - §6.4.11 secrets: Tasks 0, 19.
  - §6.4.12 logs: Task 15.
  - §6.4.13 CLI: Task 17.
  - §6.4.14 app: Task 19.
  - §7 parity: Tasks 1, 9–11, 15, 16, 20.
  - §9 migration: Tasks 1, 4, 12, 17, 19, 20.
- **Consistent names across tasks:** `EngineLock`, `TickParticipant`, `TaskRegistry`, `EngineClient`, `EngineService`, `EngineSuspension`, `ServiceInstaller`, `EngineConnection`, `EngineStatusReport`.
- **Estimated build effort:** 21 tasks. Tasks 2, 6 and 12 are large mechanical moves. Tasks 10, 11 and 15–19 are the review-heavy ones. That is about 9–12 implementer-days under subagent-driven execution, plus review rounds, so roughly 2–2.5 calendar weeks at the owner's Max/Ultra pacing.
