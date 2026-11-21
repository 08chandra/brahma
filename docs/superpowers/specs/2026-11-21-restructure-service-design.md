# Plan R — Restructure and engine service (design)

**Status:** design, 2026-11-21. Owner approved the scope (design analysis items 4 and 5). Build order: 4a → C → 4b leftovers → **S** → **R** → P → first dogfood run.
**Plan:** `docs/superpowers/plans/2026-11-21-planR-restructure-service.md`.
**Inputs:** `2026-11-21-design-analysis-input.md` (cited as *analysis §n*), `2026-10-21-brahma-design-v2.md` (§3.1 architecture, §1.3 concept budget, §1.6 anti-goals), Plan S spec/plan (`plan-engine-safety` branch), code on `main` f55cf21, `plan4a-previews` ce18541 and `planC-collab` 91e84e9.

R is a **refactor plus a hosting change**. Nothing the owner or an agent does changes, except one deliberate thing: the engine keeps running when the app quits.

---

## Owner questions (recommended defaults; the plan builds the defaults unless you say otherwise)

| # | Question | Recommended default | Why |
|---|---|---|---|
| RQ1 | When you quit the Brahma app, do agents keep working? | **Yes.** Quit closes the window and menu bar only. The engine keeps running as a background service. The menu bar and Settings › Engine get **Stop engine**, and **⌥ Quit** ("Quit and stop agents") does what Quit does today. Desktop notifications pause until you reopen the app. Phone alerts (`brahma prefs set push`) keep coming from the engine. | This is the point of item 5 (*analysis §3 Engine lifetime*). Keeping the old behaviour on ⌥ Quit costs one menu item. |
| RQ2 | Does the engine start at login? | **Yes, on by default.** Toggle in Settings › Engine (and `brahma engine autostart on|off`). Paused companies cost nothing, and an idle engine ticks once a second. | Agents survive a reboot without you opening the app. |
| RQ3 | What happens to running turns when a new Brahma build is installed? | **Drain, then restart.** New work is held. The engine waits up to **10 minutes** (awake time) for running turns, checks and merges to finish, then restarts on the new build. Anything still running is interrupted exactly as Quit interrupts it today (agents go back to ready). The banner has a **Restart now** button. | No work is lost, and no turn runs for long on an old binary. |
| RQ4 | Keep a foreground terminal engine (`brahma run`)? | **Keep it** as `brahma engine run`, for development. `brahma run` stays as an alias. It refuses while the service runs and tells you to `brahma engine stop` first. | Developers and the live tests use it. It is the same code as the service. |

None of these change safety. Each one is a switch in `EngineServiceConfig`, so a different answer is a one-line change in the plan.

---

## 1. Why

**Structure** (*analysis §1.4, §3, §5, §8 #9 #12 #14, §9*):
- `BrahmaCore` is one module: 242 files and 67,103 lines on `main`, 269 files and 75,282 lines on `planC-collab`. Swift access control cannot express a boundary inside it, a one-line edit recompiles everything, and the single core test target holds about 3,000 tests.
- `Orchestrator` is one actor: `Orchestrator.swift` (1,916 lines) plus 16 `Orchestrator+*.swift` files and `OrchestratorLock.swift`, 4,424 lines in all. It has about 98 stored members, about 45 of them mutable per-subsystem maps, and a `schedule(now:)` of about 30 ordered steps. Every plan appends a step and a map.
- `Store` is a god object: 49 `Store+*.swift` files on `main` (16,035 lines), 52 with 4a's `Store+Artifacts`, `Store+MergeQueue` and `Store+MergeSettings`, 324 `public func`s in `Store/`, and 81 `extension Store` blocks (26 of them in files outside `Store/`). Domain rules (merge state, ask lifecycle, release, taint) sit beside SQL. 55 files outside `Store/` call `writer.read`/`writer.write` directly.

**Hosting** (*analysis §3 Engine lifetime, §6, §8 #10*):
- The engine lives in the app (`EngineHost`, `BrahmaAppModel/Engine/EngineHost.swift`) or in `brahma run`, behind `OrchestratorLock` (`flock` on `<home>/orchestrator.lock`).
- The app polls for takeover every 10 polls (`AppModel.swift:264-270`). Quitting the app stops every agent (`AppDelegate.applicationShouldTerminate`).
- That suits building Brahma. It does not suit operating the product, and the dogfood run is a week of operation.

## 2. Goals

1. **G1 Modules.** `BrahmaCore` becomes a set of SwiftPM targets with a one-way dependency graph that a test enforces. `BrahmaCore` remains as an umbrella module, so the app, the CLI and most tests compile unchanged.
2. **G2 Orchestrator.** The tick becomes an ordered list of `TickParticipant`s, each owning its own state and declaring its own gates (stop, hold, secrets, pressure). The `Orchestrator` keeps admission, ordering, fair share and the turn lifecycle. The tick order is identical and pinned by a test.
3. **G3 Store.** There is a thin persistence core. Each feature's `Store` extension lives in that feature's module. Company-owned writes go through a `CompanyScope` handle. The ask lifecycle becomes a service type over thin Store methods (*analysis §8 #14*: "merge first, then asks" — see D-R7 for why merge is moved but not extracted).
4. **G4 Service.** The engine runs as a per-user background service (`brahma engine serve`, supervised by launchd). It survives an app quit, logout/login and crashes. The app and the CLI are clients over a local control socket, with defined lifecycle, upgrade, crash recovery, single instance, sleep/wake and network-loss behaviour.
5. **G5 Parity.** Every existing test passes unchanged, except for import lines, moved file paths and the `EngineHost` tests that are replaced. Safety allowlists in static tests are renamed 1:1 and never widened.

## 3. Non-goals

- Running agents as a separate macOS user (the owner rejected *analysis §8 #11*).
- Moving tick DB reads off the actor, or changing tick timing (*analysis §3*). R makes this possible later but does not do it, because "behaviour identical" includes timing.
- New owner features. Sidebar, CLI and polling changes are Plan P. R gives P the IPC that P's change notifications ride on.
- Splitting Release or Merge state machines into services (D-R7), and splitting `Migrations.swift` (it stays append-only in the store core).
- A signed/notarized distribution, `SMAppService` login items, or a Linux systemd unit. R leaves room for each.
- The safety work in Plan S. R assumes it (§4) and does not redo it.

## 4. What R assumes Plan S delivered

This section was checked against Plan S as written: `plan-engine-safety` branch, `specs/2026-11-21-engine-safety-design.md` (*S §n*) and `plans/2026-11-21-planS-engine-safety.md` (Tasks S1–S16), read 2026-11-21. S's own non-goals (S §3) name R's scope: the launchd agent (#10), the Orchestrator decomposition (#9), the Store `CompanyScope` (#6's Store half) and the general module split (#12). The two plans therefore do not overlap. **R Task 0 re-reads S as merged and records any drift.** Where S changed during its build, S wins and R adapts.

| What S delivers (S task) | What R does with it |
|---|---|
| **`BrahmaSafety` target** (S3, S §6.8.1). Contents: the path layer (`EngineFiles`, `SafeFS`, `SandboxPath`, `SafeRead`, `Place`, plus `AwakeTime`, `SHA256` and `SHA1`, which S moves into it); process spawning (`ProcessGroup`/`GroupRun`, `ProcessTable`, `ChildEnvironment`, `Spawn`, `ToolPaths`); the sandbox runtime and renderer; `GitHardening`; `Principal`/`Purpose`/`PolicyDecision`/`SandboxPolicyFactory`/`Decision`; `PromptBuilder`/`RenderedPrompt`/`ToolOutput`; and the helper protocol, client and server. Its only dependency is `CSandboxCheck`. It imports no GRDB and no `Store` (S's static test enforces both). `BrahmaCore` `@_exported import`s it. | **`BrahmaSafety` is R's bottom layer**, below `BrahmaFoundation` and `BrahmaModel` (§6.1). R does not move its files. R keeps S's no-GRDB/no-Store test and adds the target to `ModuleGraphTests`. |
| **`brahma-helper`** executable, which depends only on `BrahmaSafety` and is built next to `brahma` (S8) | The service spawns helpers exactly as the in-app engine did. `make-app.sh` already builds the binary. The plist does not mention it. |
| **`PrincipalResolver`**, which stays in `BrahmaCore` because it reads `Store` (S §6.2.3) | It moves to `BrahmaDomain/Principal/`. S's `failOpen` **zero** rule for `Principal/` follows it through the lint-root change below. |
| **`Decision` and the required `AlertScope { .company(id), .allCompanies(GlobalAlert) }`** (S4, S §6.7) | **R does not touch alerts.** R adds only the Store `CompanyScope` (§6.3), which S excludes. |
| **`SafetyLintTests`** with a shrink-only baseline (`Fixtures/safety-lint-baseline.json`: rule → file → count). It scans **`Sources/BrahmaCore` and `Sources/brahma`** only. | **The largest R/S interaction.** R moves most code out of `Sources/BrahmaCore`, and a root-limited lint would then pass vacuously. R Task 1 does three things: it widens the lint roots to every Brahma source target except the app/UI targets; it re-keys the baseline through `MovedPaths`, with identical counts; and it adds `SafetyLintRootsTests.coversEveryCoreTarget`. R's new code adds **no** baseline entries: process launches use S's `Spawn` with `ToolPaths` (`launchctl` is added to `ToolPaths`), files in the data home use S's `Place`/`EngineFiles` APIs, and socket bind/connect lives in `BrahmaSafety` as `LocalSocket` (D-R13, R Task 14, security-reviewed). |
| **`SandboxPolicyFactory`** as the only policy constructor (S7), and the canary re-run with helper probes (S16) | R's socket-deny rule (D-R12) is added **inside the factory**, and its canary probe joins S's probe set. |
| **Helper ops** that replace the in-engine `WebAdapter`/`BackendAdapter` loopback probes, `DeploySmoke`, `worktreeDiff`/`worktreeStatus`, `TextExtract` and the 3a submit staging (S9–S12, S10b) | R's `GitWorkspace` file split (Task 5) splits whatever S left in `GitWorkspace.swift` and moves nothing back. P's flaky-test fixes re-read the S-changed tests (P Task 3). |

## 5. Anti-goals (binding)

- **No behaviour regressions.** The same tick order, the same admission decisions, the same DB rows, the same CLI output, and the same agent prompts and argv. `brahma mcp` and `brahma hook pre-tool|post-tool` keep their exact argv, because canary keys include the settings shape (`SandboxCanaryKey`).
- **No weakened safety.**
  - Every fail-closed hold (emergency stop, engine hold, secrets held, health hold) still gates admission first, in the same tick position.
  - The sandbox canary still gates sandboxed turns per launch of the engine process.
  - The emergency stop still works when the engine is wedged or absent (`brahma stop` signals recorded process groups itself, `StopCommand.swift`).
  - Static guard allowlists (`EngineGitGuardTests.gitCommandFiles`, `MainGuardTests` paths, `EmergencyStopTests` MCP dir, `NoKeychainTests` roots, `SecretTests` file reads, `AwakeTimeTests` roots, S's lint baseline) are renamed 1:1 and never grow.
  - The service adds **no capability** an agent could not already get: the control socket is a control plane, not a data plane (D-R10).
- **No data loss on upgrade.**
  - Pending migrations still take the verified pre-migration snapshot (`Store.init(backupsDir:)`).
  - A service on a newer schema than its binary refuses to run rather than writing rows it does not understand.
  - An upgrade restart never kills a turn without recording it (it uses the Quit path).

---

## 6. Architecture

### 6.1 Target graph (architect's call)

The dependency analysis (a source scan of type references between directories, `planC-collab`) shows a near-mesh. `Store` references 30 of 32 directories. `Model` references 8 feature directories (Access 3, Release 2, Merge 2, Org, Resources, Work, Turns, Modes). `Org` references Extensions, Handbook and Release. Some features reference each other (Release → Hosting 21 and Preview 17; Refs → Memory 18 and Resources 13). One module per feature would therefore need dozens of cycle cuts before anything compiles. R uses **coarse layers first**, with an enforced graph, and splits further only where the scan shows the cut is cheap.

```
                    ┌──────────────────────────────────────────────┐
 executables        │ BrahmaApp      brahma (CLI + `engine serve`) │
                    └───────┬─────────────────┬────────────────────┘
                    ┌───────▼───────┐ ┌───────▼────────┐
 app libs           │ BrahmaAppModel│ │ BrahmaService  │  service host, IPC server, launchd installer (Darwin-only bits)
                    │ BrahmaMapKit  │ └───────┬────────┘
                    └───────┬───────┘         │
                    ┌───────▼─────────────────▼──┐
 client             │ BrahmaEngineClient         │  wire protocol (Codable), EngineClient, EngineStatus  (Foundation only)
                    └────────────┬───────────────┘
                    ┌────────────▼───────────────┐
 umbrella           │ BrahmaCore  (@_exported)   │  re-exports everything below; holds no code but the default composition
                    └────────────┬───────────────┘
                    ┌────────────▼───────────────┐
 engine             │ BrahmaEngine               │  Orchestrator, TickParticipants, TurnLauncher, Scheduler, Engine/* (Doctor, health, alerts), Verify
                    └────────────┬───────────────┘
                    ┌────────────▼───────────────┐
 agent I/O          │ BrahmaAgentTools           │  MCP/* (company tools served by `brahma mcp`)
                    └────────────┬───────────────┘
                    ┌────────────▼───────────────┐
 domain             │ BrahmaDomain               │  Work, Org, Modes, Lifecycle, Messaging, Access, Owner, Timers, Turns (prompts/digest),
                    │                            │  Memory, Handbook, Resources, Refs/Collab/Show/Changes (C), Extensions,
                    │                            │  Preview, Release, Hosting, Backup  + their Store extensions
                    └────────────┬───────────────┘
                    ┌────────────▼───────────────┐
 git                │ BrahmaGit                  │  Git/GitWorkspace (split in 4 files), Merge/* (4a) + Store+Merge*, Store+MainGuard
                    └────────────┬───────────────┘
                    ┌────────────▼───────────────┐
 persistence        │ BrahmaStore                │  Store (class), Migrations, core tables, CompanyScope, ChangeTopics hook (P)
                    └────────────┬───────────────┘
                    ┌────────────▼───────────────┐
 values             │ BrahmaModel                │  Model/* + value types pulled down from features (enums, ids, records)
                    └────────────┬───────────────┘
                    ┌────────────▼───────────────┐
 base               │ BrahmaFoundation           │  rest of Util (Blocking, StableHash, DirectoryListing, EngineGitGuard), Paths, TerminalText, Platform, OwnerKey, EngineLock
                    └────────────┬───────────────┘
                    ┌────────────▼───────────────┐
 kernel (Plan S)    │ BrahmaSafety               │  as S delivered it (path layer incl. AwakeTime/SHA*, Spawn, sandbox, policy, principal, prompt, helper); deps: CSandboxCheck only
                    └────────────────────────────┘     brahma-helper (S) depends on BrahmaSafety only
 (unchanged)  CSandboxCheck, BrahmaKeychain (→ depends on BrahmaFoundation + BrahmaModel instead of BrahmaCore)
```

Rules:
- **R-L1 Downward only.** A target imports only targets below it. `ModuleGraphTests` parses `Package.swift` and fails on any upward or sideways edge not in the table above.
- **R-L2 `package`, never `public`, for cross-module internals.** A symbol that was `internal` and is now needed in another Brahma module becomes `package` (SE-0386; tools 6.0 supports it). The `public` surface of the umbrella stays the same set of names. `PublicSurfaceTests` diffs `swift package dump-symbol-graph`-derived names against a checked-in list made in Task 1.
- **R-L3 Store extensions follow their feature.** `extension Store` files move to the module that owns the feature. Call sites keep `store.foo()` syntax, so the app and CLI do not change.
- **R-L4 The umbrella stays.** `BrahmaCore` becomes `@_exported import` of every core target, plus the default composition (`Store.standard(path:)`, which wires the default observers). App, CLI and test sources keep `import BrahmaCore`. Tests change only `@testable import` lines (§9).
- **R-L5 Portability.** Every core target stays Linux-portable (Global Constraint of every plan). `BrahmaService` keeps launchd, `flock` and the peer-credential calls behind `#if canImport(Darwin)`. Linux builds a service host without an installer.
- **Optional split (R Task 13):** `BrahmaDomain` splits into `BrahmaWork` (Work, Org, Modes, Lifecycle, Messaging, Access, Owner, Timers, Turns), `BrahmaKnowledge` (Memory, Handbook, Resources, Refs/Collab/Show/Changes) and `BrahmaShip` (Preview, Release, Hosting, Backup, Extensions). It happens only if, after Tasks 2–12, the scan shows ≤ 10 back-edges between those groups that can be cut by moving value types to `BrahmaModel`. Otherwise it is deferred and recorded. This is the one place where R decides by measurement and not up front.

Why this shape:
- It gives the build parallelism and the access-control boundaries that matter today: values, safety, persistence, git, domain, engine, service.
- No step needs a cross-feature redesign.
- The analysis says to split "after C" and to do it "as subsystems are touched", and the layer cut is the part that can be done mechanically.

**Cycle cuts needed** (scan counts, each a type reference that must move down or become a protocol):
- `Model → {Access, Release, Merge, Org, Resources, Work, Turns, Modes}`: 12 references. Move the referenced value types into `BrahmaModel`.
- `Util → {Owner 2, Verify 1}`: 3.
- `Store` core → features: the default observers `OutcomeFactsObserver`, `EpisodeObserver` and `TaintedCommitObserver` become injected (R-L4).
- `Safety → {Turns 12, Store 5, Engine 4, Merge 3, Orchestrator 3}`: **handled by S.** S3 extracts `BrahmaSafety` with no Store or GRDB dependency. The `Safety/` files S leaves in `BrahmaCore` (`Taint`, `Secrets`, `EmergencyStop`, `OwnerShellGuard`, `SandboxCanary`, `SleepGuard`) go to `BrahmaDomain`/`BrahmaEngine` with their users. R Task 3 only verifies.
- `Git → {Org 2, Scheduler 1, Merge 1, Extensions 1, Owner 1, Turns 1, Platform 1}`: 8.
- `Domain → Engine` (`Orchestrator` referenced from Access, Extensions, Hosting, Modes, Release, Safety): 9. These are static helpers such as `Orchestrator.checkBaseline`, and they move into `BrahmaDomain` as free types (`CheckBaseline`).
- `OrchestratorLock` users in the domain (`Restore`, `DevReleaseScenario`, `ProviderProbe`, `LabProvenance.engineLock`, `RepoImport`): the lock moves to `BrahmaFoundation` as `EngineLock` (a typealias keeps the old name).

### 6.2 Orchestrator decomposition (architect's call)

```swift
/// One step of the engine tick. Non-Sendable on purpose: a participant is owned by the Orchestrator and only ever runs on
/// the Orchestrator's executor, through an `isolated` parameter. There are no new suspension points, so ticks still never
/// interleave (today's invariant: "Synchronous on the actor (no suspension points)").
package protocol TickParticipant: AnyObject {
    /// Stable id, e.g. "merge". Used by TickOrderTests and log lines.
    var id: TickStepID { get }
    /// What stops this step. The Orchestrator checks the gates before calling `tick`; a participant never re-derives them.
    var gates: TickGates { get }
    /// Called once per engine start, before the first tick, in participant order (today's `start()` recovery steps).
    func recover(_ ctx: RecoveryContext, on engine: isolated Orchestrator) async throws
    /// One tick. Synchronous: it may start child Tasks (registered in `ctx.tasks`) but never awaits.
    func tick(_ ctx: TickContext, on engine: isolated Orchestrator) throws
    /// Engine shutdown (runForever's tail): cancel its tasks; the Orchestrator awaits them with the rest.
    func shutdown(on engine: isolated Orchestrator)
}

package struct TickGates: OptionSet { stop, hold, secrets, pressure, companyRunning }   // declared, not re-derived
package struct TickContext {           // computed once per tick, today's schedule() locals
    let now: Date; let stopped: EngineStopRow?; let held: Bool; let secretsPending: Bool
    let pressure: MemoryPressure; let config: SchedulerConfig; let companies: [Company]
    let tasks: TaskRegistry            // replaces the 12 `didSet { resumeIdleWaitersIfIdle() }` maps
}
```

- **Gates are declared per participant** (*analysis §8 #9*: "stop, hold and secrets gating declared once"). Each participant keeps its **current** gating exactly. For example, memory ingest is gated by `stop` and `secrets`, and the handbook refresh by `stop` and `secrets` via `HandbookRefresh.isHeld`. `TickGatesTests` asserts the declared gates of each participant against a table copied from today's code. Where today's code gates inside the step (for example, `leaseMaintenance(… held:)` takes `held` as a parameter instead of skipping), the participant gets `gates: []` and keeps the parameter. Identical behaviour wins over uniformity.
- **`TaskRegistry`** owns every in-flight child task keyed by `(participant, key)`. It provides `waitUntilIdle`, `idle` waiters and `inFlight` for `runForever`'s tail. This removes the 12 task maps from the actor and makes `awakeWork` (SleepGuard) a registry query.
- **Ordering** is the `[TickParticipant]` array built in `Orchestrator.init`. `TickOrderTests` runs one tick with spy participants wrapping the real ones and compares the id list to the pinned list below.

| # | Participant (new file in `BrahmaEngine/Tick/`) | From today | State it takes off the actor |
|---|---|---|---|
| 1 | `StopStep` | `Orchestrator+Stop`, schedule head | `engineStoppedNow`, `stopObserved`, `stopObserverTask`, `stopObservers` |
| 2 | `SecretsStep` | `reloadSecretsIfDue` | `secretsTask` |
| 3 | `HealthStep` (incl. active-time accrual) | `Orchestrator+Health` | `health`, `healthTasks`, `lastPressure` |
| 4 | `UltraReservationStep` | `Orchestrator+Ultra` (orphan release) | — |
| 5 | `LeaseStep` | `Orchestrator+Leases` (reap, KB leases, maintenance, secret uses) | `lastSweep`, `worktreeFailures`, `gitTasks` |
| 6 | `RestoreMarkerStep` | `Orchestrator+Restore` | `ignoredRestoreMarker`, `staleRestoreEventsExpired` |
| 7 | `SweepStep` (notices, reviews, asks, timeboxes, standups, liveness) | schedule body, `Orchestrator+Review` | `lastLiveness` |
| 8 | `KnowledgeStep` (memory ingest, handbook skeleton, refresh) | schedule body | `handbookSkeletons`, `lastHandbookRefresh` |
| 9 | `AuditStep` | schedule body | — |
| 10 | `BlockerExpiryStep` | step 1 | — |
| 11 | `TimerStep` | `Orchestrator+Timers` | `timerTasks`, `ensuredTimerCompanies` |
| 12 | `PushStep` | `pushTick` | `pushDispatcher`, `pushTask` |
| 13 | `UsageStep` (5-hour gate, pace, turn budget) | steps 2–4, `Orchestrator+Budget` | `loggedPaceClosed` → produces `UsageDecisions` for admission |
| 14 | `CheckStep` | `Orchestrator+Checks` | `checkTasks` |
| 15 | `MainGuardStep` | `mainGuardTick` (4a) | `mainBlocked` |
| 16 | `MergeStep` | `Orchestrator+Merge`, `MergeQueue` | `mergeTasks`, `mergeBackoff`, `mergeFaults`, `mergeCheckDeferrals` |
| 17 | `PreviewStep` | `Orchestrator+Preview` | `previewRunner`, `previewTask` |
| 18 | `SmokeStep` | `smokeTick` | `smokeChecks`, `smokeSlots`, `smokeTasks`, `smokeBackoff` |
| 19 | `ReleaseStep` | `Orchestrator+Release` | `releaseExecutor`, `releaseTasks` |
| 20 | `CanaryStep` | `Orchestrator+Canary` | `canaryWaiting`, `canaryLogged`, `canaryFailedAt`, `canaryFailures`, `canarySettings`, `fingerprintCache`, `probesDigestCache` |
| — | **Admission** (stays in `Orchestrator`) | select + launch, step 5 tail | `runningByCompany`, `infraCooldown` |
| — | **Dispatch** (stays in `Orchestrator`) | step 6 | `dispatching`, `dispatchBackoff`, `lastDispatch` |
| — | `WALStep` (not per tick; start/stop) | `startWALShipping` | `walShipper` |

The turn path (`launch`, `performTurn`, `beginTurn`, `endTurn`, `Orchestrator+Modes`, `Orchestrator+Sandbox`) moves to a `TurnLauncher` component in `BrahmaEngine/Turns/` that the Orchestrator owns. Its signatures and its isolation are unchanged: `performTurn` stays `nonisolated` and hops back through `turnEnded`. Whatever 4a/C/4b/S add to `schedule` by the time R starts becomes a participant at the same position, and Task 4 Step 1 lists it from the merged code.

### 6.3 Store decomposition (architect's call)

- **`BrahmaStore` core** keeps:
  - the `Store` class: connections, `busyTimeout`, migrator, pre-migration snapshot, redactor, `lifecycleObservers`/`observers` (injected);
  - `Migrations.swift`;
  - the core-table extensions every layer needs: company, agent, turn, activity events, channels/messages, sessions, usage/rate limits, owner prefs, engine stop/hold, secrets metadata, notices, and transcripts.
  - It no longer constructs feature observers. `Store.standard(path:catalog:backupsDir:)` in the umbrella does.
- **Feature extensions move** (R-L3), with their files renamed only by directory:
  - Store+Merge, +MergeQueue, +MergeSettings, +MainGuard → `BrahmaGit`.
  - Store+Asks, +AskLifecycle, +Grants, +HumanTasks, +Release, +Preview, +Hosting, +Memory*, +Handbook, +Resources, +ResourcePurge, +Taint*, +Sprints, +WorkItems, +Leases, +Review, +Audit, +Verification, +Extensions, +Modes, +ModeRequests, +UltraApprovals, +Attrition, +Liveness, +Vacancies, +Org, +Timers, +Push, +Digest, +StallReport, +MapFeed, +OwnerView, +OwnerWork, +OwnerGuard, +Sandbox, +MCPAuth, +Artifacts → `BrahmaDomain`.
  - The 26 `extension Store` files outside `Store/` go with their directories.
- **`CompanyScope`** (*analysis §3 Store, §8 #6*; S §3 leaves this Store half to R):
  - `store.scope(companyId) -> CompanyScope` is a non-escapable-by-convention value holding the id. Company-owned writes in moved repositories take a `CompanyScope` instead of a `companyId: String`.
  - The SQL is unchanged: the scope supplies the same `WHERE companyId = ?`.
  - R converts the write paths of the repositories the analysis names as cross-tenant bug sources: merge batch writes, asks and release. Main-head alerts are already scoped by S4's `AlertScope`. The remaining repositories are a follow-up list in the plan, because converting all of them is a large diff with no behaviour change.
- **`AlertScope`** is delivered by S4, with named `GlobalAlert` reasons. R does nothing to it.
- **`AskService`**:
  - The ask state machine (open → decided/answered/rescinded/expired, rerouting, reminders) moves from `Store+Asks` (733 lines) and `Store+AskLifecycle` (307) into `BrahmaDomain/Inbox/AskService.swift`, as pure transition functions plus thin Store reads and writes.
  - `Store.ownerDecide`, `ownerAnswer`, `ownerRescind` and `acknowledge` keep their signatures and stay the only owner-decision entry points (the Global Constraint). They delegate to the service.

### 6.4 The engine service

#### 6.4.1 Processes

```
 launchd (gui/<uid>)                                   Brahma.app (client)          brahma CLI (client)
   └─ brahma engine serve   ◄─── <home>/run/engine.sock ───►  EngineConnection  ◄──►  EngineClient
        ├─ Orchestrator (tick 1 s)                          reads/writes SQLite directly, as today
        ├─ claude -p …  (turns; own sessions)                   ▲
        │    └─ brahma mcp / brahma hook                        │ every process opens the same DB (WAL)
        ├─ S agent-data helper(s) (Seatbelt children)           │
        ├─ checks, previews, smokes, releases, caffeinate, litestream
        └─ SQLite ◄──────────────────────────────────────────────┘
```

- **One binary** (architect's call): the service is `Brahma.app/Contents/Helpers/brahma engine serve`.
  - That executable is already the app's sibling on every Keychain item's trusted-application list (`KeychainVault` doc comment, `KeychainTrust`), so the service reads secrets non-interactively exactly as `brahma run` does today.
  - It is also already what turns call for `brahma mcp`.
  - A separate daemon binary would be a third Keychain identity and a third build to sign.
- **The DB stays the message bus** (v2 §3.1). Clients keep reading and writing the database directly. The socket carries **control and notifications only** (D-R10).

#### 6.4.2 Installation (architect's call)

- **Mechanism: a per-home LaunchAgent plist plus `launchctl`**, not `SMAppService`.
  - `scripts/make-app.sh` builds ad-hoc-signed bundles that change identity on every build. Dev/demo data homes (`BRAHMA_HOME`) each need their own job. A plist we generate is testable as text.
  - `SMAppService` can replace the installer behind the same `ServiceInstaller` protocol once there is a signed release.
- Label: `dev.brahma.engine` for the default home, else `dev.brahma.engine.<fnv1a64(canonicalHomePath) hex8>`.
- Plist at `~/Library/LaunchAgents/<label>.plist`, written 0644 through an atomic rename:

```xml
Label <label>
ProgramArguments [<abs path>/Brahma.app/Contents/Helpers/brahma, engine, serve]
EnvironmentVariables { BRAHMA_HOME: <home> (only for a non-default home) }
RunAtLoad <RQ2: true>
KeepAlive { SuccessfulExit: false }      ← restart after a crash or the upgrade exit (75); not after a clean stop (0)
ThrottleInterval 10
ExitTimeOut 30                            ← > EngineHost's 15 s stop bound + margin
ProcessType Standard
LimitLoadToSessionType Aqua               ← GUI session: Keychain prompts, caffeinate
StandardOutPath / StandardErrorPath <home>/logs/engine.log
WorkingDirectory <home>
```

- `brahma engine install` writes the plist and runs `launchctl bootstrap gui/<uid> <plist>`. `uninstall` runs `bootout` and deletes the plist. `start` runs `kickstart -k` (or `bootstrap` if not loaded), and `stop` sends `shutdown` over IPC (falling back to `launchctl kill SIGTERM`).
- The app runs `install` on first launch and whenever the plist's `ProgramArguments[0]` differs from its own helper path (the app was moved or rebuilt elsewhere).
- **Background Items.** macOS 13+ lists the job in Login Items and lets the owner disable it. `ServiceInstaller.status()` reports `.disabledByUser` when `bootstrap` fails with that cause, using the `launchctl print` exit status and `SMAppService.statusForLegacyPlist(at:)` where available. Then:
- **Fallback: unmanaged child.** When launchd is unavailable or disabled, the app spawns `brahma engine serve --unmanaged` itself (`posix_spawn`, new session, stdout to the log). The process is the same and so is the lock. Only crash restart differs: the app relaunches it on its next failed connect while the app is open. Settings › Engine shows "Running without login service (disabled in System Settings › Login Items)".
- **Tests never touch launchd.** `ServiceInstaller` takes a `Launchctl` protocol. `ServiceGuardTests` (static) bans the strings `launchctl`, `SMAppService` and `bootstrap gui/` outside `BrahmaService/Install/`. Every test runs the service **in-process** (`EngineService` is a library type) or as `--unmanaged` under a temp home.

#### 6.4.3 Single instance and locks

There are two locks, both `flock` in the data home:
- `<home>/run/service.lock` means one service process per home, held for the process's life. A second `serve` exits 0 with "already running (pid N)". Exiting 0 means launchd does not restart it.
- `<home>/orchestrator.lock` (today's `OrchestratorLock`, unchanged) means one **engine** per home. The service holds it while running and releases it while suspended (§6.4.6). `brahma engine run` (foreground) and the lock-taking owner commands (restore, `lab clear-taint`, repo import, the hosting probe, `dev release-scenario`) use it exactly as today.
- The app no longer takes either lock. The takeover machinery is deleted: `EngineHost`, `EngineStatus.external`, `retryTakeover`, `ticksSinceTakeoverCheck`, and the "auto-takeover within ~5 s" policy of v2 §3.1.

#### 6.4.4 IPC (architect's call)

- **Transport:** a Unix-domain stream socket at `<home>/run/engine.sock`, mode 0600, in the 0700 run dir that `DataHomeGuard.lockDown` already tightens.
  - The service binds after unlinking a stale socket only if `service.lock` is held, so it can never steal a live service's socket.
  - **D-R13 (`LocalSocket` in the kernel):** bind and connect live in `BrahmaSafety` as `LocalSocket`, because S's lint bans raw descriptor APIs outside the kernel. They open the run directory `O_DIRECTORY|O_NOFOLLOW`, verify that it is owned by the uid and is 0700, then bind relative to that descriptor and `fchmod` the socket to 0600. R adds this one small kernel API under a security review.
  - `sun_path` is 104 bytes. The socket is opened relative to the run directory's descriptor (`bindat`/`connectat`, Darwin) when available. Otherwise the absolute path must be ≤ 103 bytes or the service refuses with a clear error. **R Task 0 verifies `bindat`/`connectat` on macOS 14.**
  - Test homes live under short roots.
- **Framing:** a 4-byte big-endian length, then one UTF-8 JSON `Envelope { v: 1, id: UInt64, kind: request|response|event, type: String, body }`. The maximum frame is 1 MiB. Oversize or malformed frames close the connection. Strings shown to the owner from the wire go through `safe()` / `Text(verbatim:)`.
- **Handshake:** the client sends `hello { protocol: 1, role: app|cli, build: BuildStamp, pid }`. The server answers `welcome { protocol: 1, build, schemaVersion, engineId, state, nonce }`.
  - A different protocol major closes the connection with a message.
  - A different build is allowed. The app then starts the upgrade flow (§6.4.7).
- **Requests (R):**

| Request | Owner proof | Does |
|---|---|---|
| `status` | no | `EngineStatusReport`: state, pid, build, startedAt, last tick, running turns per company, holds (stop/engine/secrets/health/canary/upgrade/crash-loop), secrets-held names, canary state, Doctor summary, installer status |
| `subscribe {streams}` | no | Server-push `event`s on this connection: `status` (on change), `alert`, `log` (tail, opt-in). **P adds `changed {topics, seqs, epoch}`.** |
| `nudge` | no | Run the next tick now instead of ≤ 1 s later (a hint; coalesced; same tick code) |
| `recheck` | no | Re-run the Doctor (the app's Retry button; today `EngineHost.recheck`) |
| `loadSecrets {interactive: true}` | **yes** | The service performs the owner's interactive Keychain load (today `AppModel.loadSecrets` does it in-process on the shared `Store`, which no longer exists across processes) |
| `suspend {reason, holderPid}` / `resume` | **yes** | §6.4.6 |
| `shutdown {mode: drain|now}` | **yes** | Graceful stop. `now` = today's Quit (interrupt, record, exit 0). `drain` = §6.4.7 |
| `restartForUpgrade` | **yes** | Drain, then exit 75 (launchd restarts on the new binary) |

- **D-R10: control plane only.**
  - No request reads or writes company data (items, asks, messages, secrets values) or starts a turn.
  - Owner decisions still go through `Store.ownerDecide`/`ownerAnswer`/… from the app or CLI, as now.
  - The emergency stop is **not** an IPC request. It stays a DB row plus direct group signalling by the caller (`StopCommand`, the app's stop), so it works with the service wedged. Callers then send `nudge` to shorten the reaction time.
- **Authentication and authorization** (D-R11):
  1. Filesystem: the socket is in the data home, which every sandboxed turn's Seatbelt profile denies (Task 1a of 5-lite; `Sentinel`).
  2. **D-R12:** R adds, through S's policy factory, an explicit `(deny network-outbound (remote unix-socket (path-literal "<sock>")))` and `(deny network-outbound (remote unix-socket (subpath "<home>/run")))` to every agent and helper profile. A new canary probe ("connect to the engine socket") must be **denied**, so a future denylist regression is caught live, as the other probes catch theirs.
  3. The peer uid (`getpeereid`) must equal the service's uid.
  4. The peer pid (`LOCAL_PEERPID`) goes through `OwnerShellGuard.refusal(ancestors:runningTurnPids:)`. A peer descending from a recorded turn leader is refused. This is the same deterrent as owner CLI commands today ("a deterrent there, not a wall", `OwnerShellGuard.swift:8-11`).
  5. **Owner proof** for mutating requests: `HMAC-SHA256(ownerKey, nonce ‖ requestType ‖ requestId)`. The client reads the owner key file as owner CLI commands do. The service verifies it with the same key and `OwnerKey.verify` against the Keychain-held hash.
  - **Net effect:** an agent that cannot run `brahma resume` today cannot make the service resume, suspend or shut down. An agent on the Full profile can do both today and still can. No new capability.

#### 6.4.5 Lifecycle state machine

```
 launch ─► starting ──(service.lock)──► doctoring ──ok──► recovering ──► running ⇄ held(reasons)
              │ lock busy → exit 0          │ fail → failed(doctor)        │            │
              │                              └─(recheck ok)───────────────┘            │ suspend → suspended(reason, holder) → resume → recovering
              └ crash-loop guard → crashLoop (IPC up, no ticks until owner "Try again")  │ shutdown(drain) → draining → stopped(exit 0 | 75)
                                                                                          │ SIGTERM (logout, `launchctl kill`) → stopping → stopped(0)
```

- `doctoring` runs what `EngineHost.start` runs today (`Doctor.ensure`), moved into the service. The app's "Claude Code check failed … Run brahma doctor" banner and the Retry button (`recheck`) read it from `status`.
- `recovering` is `Orchestrator.start()`, unchanged: turn leftovers reaped, interrupted turns recovered, checks/smokes/releases/merges/merge journal recovered, hooks installed, extensions materialized, timers ensured, WAL shipping started.
- `held` is not a new state. It is the existing holds reported in `status`. Admission is decided in the tick exactly as today.
- **PATH and environment:** launchd gives a bare `PATH`. The service computes the login-shell `PATH` at start with `ToolLocator.mergePath(login:current:)`, which moves from `BrahmaAppModel` to `BrahmaService`, and resolves `claude` with `EngineSetup.resolveTools()` (which moves too). Today the app does both before `EngineHost.start` (`AppDelegate.swift`). `BRAHMA_CLAUDE` still wins.

#### 6.4.6 Suspend (lock-taking owner commands)

Restore, `lab clear-taint`, repo trust-import, the hosting probe and `dev release-scenario` need the engine lock. Today they say "quit the app first".
- With a resident service, they call `EngineClient.suspend(reason:holderPid:)` first when a service answers.
- The service holds admission and stops exactly as Quit does (turns interrupted and recorded). It closes its `Store` connections (restore's `DBOpeners` check needs that), releases `orchestrator.lock` and answers.
- The command takes the lock, works, releases it, and sends `resume`.
- If the command dies, the service watches `holderPid` (`kqueue EVFILT_PROC NOTE_EXIT`) and resumes when the lock is free.
- The app's own restore (`AppModel.restore`) does the same through `EngineConnection` instead of `engine?.stop` / `restartEngine`.
- With no service running, each command behaves exactly as today.
- CLI restore with the **app** open is still refused by the `DBOpeners` check, as today. R does not add app-side store hand-off (non-goal; P may).

#### 6.4.7 Upgrade and restart

- **`BuildStamp`:** the app version plus a build id compiled into both binaries (`git describe` plus a dirty flag, written by `make-app.sh` into a generated `BuildInfo.swift`; `"dev"` for `swift build`).
- On `welcome`, if `build != app.build`, the app shows "Engine update pending" and sends `restartForUpgrade` (RQ3):
  - admission is held with a new in-memory hold `upgradePending` (reported, never persisted);
  - the service waits up to `EngineServiceConfig.upgradeDrain` (600 s, awake time) for `TaskRegistry` to empty of turns, checks, merges and releases;
  - it then runs the `shutdown(now)` path and exits **75**;
  - launchd restarts it from the plist path, which `make-app.sh` replaced in place;
  - the new binary opens the Store, and pending migrations take the verified pre-migration snapshot (`Store.init`, existing).
- **Schema guard:** a service whose migrator does not know every applied migration refuses to run (`state failed("database is newer than this engine (build X)")`). R Task 0 checks whether `Store.init` already refuses. If not, R adds the check in the store core.
- A CLI from a different build (for example `swift run brahma` against the app's home) may use read-only IPC. Mutating IPC is refused with "engine build X ≠ this CLI build Y". Direct DB commands behave as today.

#### 6.4.8 Crash recovery and crash loops

- A crash or kill is restarted by launchd (`KeepAlive.SuccessfulExit=false`, `ThrottleInterval 10`). Recovery is today's `start()`.
- **Crash-loop guard:** `<home>/run/service-starts` keeps the last 10 starts with a clean/unclean flag. A clean exit writes a marker first. Five unclean starts within 10 minutes means the next start enters `crashLoop`: IPC is up, no `Orchestrator` is created, and the app shows "The engine keeps crashing — Open log · Try again". The window uses the injected clock, not `Date()`.
- An unmanaged child (fallback) gets the same guard. The app relaunches it at most once per failed connect.

#### 6.4.9 Sleep, wake, network loss, logout

- **Sleep/wake:** no new mechanism. Timers already run on awake time (`AwakeTime`) and company-active time, so a sleep is not counted as elapsed time. `SleepGuard` (caffeinate while work runs) moves with the Orchestrator into the service. The socket survives sleep. Clients reconnect on EOF with backoff (0.1 s doubling to 5 s, reset on success). The service does not subscribe to power notifications.
- **Network loss:** the socket is local and unaffected. The engine's existing HTTPS connectivity probe raises its health hold. Turn failures go to infra cooldown, unchanged. The service never exits because the network is down, and the plist has no `NetworkState` key.
- **Logout/shutdown:** launchd sends SIGTERM, which takes today's `brahma run` SIGTERM path: `runForever` is cancelled, turns are interrupted and recorded, and previews stop. `ExitTimeOut 30` covers the 15 s bound. Turns run in their own sessions, and leftovers are reaped by `TurnRecords` at the next start (existing).
- **Disk full / DB locked:** unchanged (Store busy timeout, health disk checks).

#### 6.4.10 Kill switch, emergency stop, canary

1. **Emergency stop** (`brahma stop`, app Stop, menu bar Stop): DB row first, then direct SIGTERM/SIGKILL of every recorded turn group by the caller (`EmergencyStop.signalGroups`), then `nudge`. This works with the service wedged, absent or crash-looping. The service's `StopStep` still runs stop observers (previews, deploys, merge queues, browsers, connectors) on its next tick, as today.
2. **`brahma engine stop`**: graceful `shutdown(now)`. Without IPC it falls back to `launchctl kill SIGTERM`, or SIGTERM to the pid in `service.lock`.
3. **`brahma engine kill`** (owner only): SIGKILL the service pid, `bootout` the job (so launchd does not restart it), then `EmergencyStop.signalGroups` on the recorded leaders. This is for a wedged service. `brahma engine start` brings it back.
4. **Sandbox canary:** unchanged and still per engine process (`SandboxCanaryGate`), gating sandboxed turns until it passes for the CLI fingerprint, settings shape and macOS version.
   - A long-lived service re-reads the fingerprint every `SandboxCanaryGate.fingerprintCacheSeconds`, so a `claude` update mid-run re-gates.
   - A macOS update reboots, which restarts the service.
   - The new socket-deny probe (D-R12) joins the probe set.

#### 6.4.11 Secrets and Keychain

- The service reads through `PlatformSecretVault` non-interactively, as `brahma run` does today.
- The app's "Load secrets" becomes IPC `loadSecrets(interactive: true)`, so the Keychain dialog appears for the helper binary, which is the one that needs access.
- The app's secrets banner reads `secretsHeld` names from `status` instead of its own redactor. The app keeps its own non-interactive vault for display-side redaction (live map, `mapVault`).
- **R Task 0 verifies** that a LaunchAgent in the Aqua session can (a) raise the Keychain dialog and (b) run `claude -p` with the owner's Claude Code login (its credentials are in the owner's login Keychain under the `claude` binary's own ACL). If (b) fails, R stops and asks the owner. That would block item 5 as designed.

#### 6.4.12 Logs

- The service logs to `<home>/logs/engine.log` (0600, in a 0700 dir added to `DataHomeGuard.lockDown`).
- The log rotates at start when over 20 MB (keeping 3) and is capped at 100 MB in total.
- `brahma engine logs [-f] [--lines N]`.
- Orchestrator `log()` lines are unchanged in text.

#### 6.4.13 CLI `engine` group (new, visible)

`brahma engine status | start | stop | restart | kill | logs | install | uninstall | autostart on|off | run` (`run` = foreground, = today's `brahma run`). `brahma doctor` gains four service lines: installed, running (pid, build), socket reachable, lock holder. `brahma status` gains one line: `engine: running (service, build …, up 3h)`.

#### 6.4.14 App changes

- `EngineHost` is replaced by `EngineConnection` (`@Observable`, in `BrahmaAppModel/Engine/`). It connects, subscribes to `status`, and exposes `EngineStatus`, which gains a `.service` case and loses `.embedded`/`.external`. Every banner and menu bar line maps old states to new ones in a table in the plan.
- `AppDelegate`:
  - no longer builds an `Orchestrator`;
  - on launch, installs the service if needed and connects;
  - on Quit (RQ1), closes and leaves the service running;
  - on ⌥ Quit, sends `shutdown(now)` and waits up to 15 s, as `applicationShouldTerminate` does today.
- `Harness` `--smoke-test` checks `engine=service` instead of `embedded`. The harness starts an **unmanaged** service under the smoke home, never a launchd job.

---

## 7. Behaviour parity checklist (each line is a test or a review item)

| Today | After R | Pinned by |
|---|---|---|
| Tick order of ~30 steps | Same order (participant list) | `TickOrderTests` |
| Each step's hold gating | Same gating, declared | `TickGatesTests` |
| `waitUntilIdle`, idle waiters | `TaskRegistry` | existing `OrchestratorTests` unchanged |
| Crash recovery on start | Same `recover` order | existing recovery tests, `RecoveryOrderTests` |
| Quit interrupts turns | ⌥ Quit / `engine stop` / upgrade drain timeout | `ServiceLifecycleTests.shutdownNowInterruptsLikeQuit` |
| `brahma stop` without engine | Unchanged | `EmergencyStopTests` + `ServiceKillSwitchTests.stopWorksWithServiceWedged` |
| Sandboxed turns gated by canary | Unchanged + socket probe | `SandboxCanaryTests`, `CanaryProbeTests.engineSocketDenied` |
| Owner-only commands | Unchanged; IPC mutations need owner proof | `ServiceAuthTests` |
| Pre-migration snapshot | Unchanged; schema-newer refusal | `StoreMigrationTests`, `ServiceUpgradeTests` |
| Public API | Same names | `PublicSurfaceTests` |
| Static guards | Renamed allowlists, never larger | `GuardAllowlistTests` (counts pinned) |

## 8. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `claude -p` under launchd lacks the owner's login or PATH | Medium | Task 0 spike first. The service resolves the login-shell PATH. If it fails, stop and ask the owner. |
| Keychain prompts appear for the helper after a rebuild | High (ad-hoc signing; documented today) | Same as `brahma run` today. "Load secrets" in the app triggers the helper's prompt over IPC. README note. |
| `@testable` and `internal` breakage across ~190 test files | High, mechanical | Task 12 adds `@testable import` of every module to every test file by script, and fixes `internal` → `package` only where needed. |
| Tick ordering subtly changes in the participant extraction | Medium | One participant per commit. `TickOrderTests` lands before the first extraction. The full suite runs per task. |
| 4a/C/4b/S land more `schedule` steps or Store files than listed | Certain | Task 0 inventories the merged code. Tables in the plan are re-generated, not trusted. |
| Owner disables the Login Item | Low | Unmanaged-child fallback with a visible note. |
| Long temp-home paths exceed `sun_path` | Medium (tests) | `bindat`/`connectat`, else short test roots. Task 0 verifies. |
| Two services on one home (dev `--unmanaged` and launchd) | Low | `service.lock` makes the second exit 0 with a message. |
| Build gets slower, not faster, with `@_exported` umbrella | Low | Measure `swift build` cold and one-file-touch times before and after (Task 14 records them). |

## 9. Migration strategy (counts from `planC-collab` unless marked)

- **M1 File moves.**
  - 269 core files move into 9 directories under `Sources/`, by `git mv` only, one module per commit, so blame follows.
  - Counts per target come from the scan: Foundation ≈ 12, Model ≈ 12, Store core ≈ 16 (`Store.swift`, `Migrations.swift`, ~14 core extensions), Git ≈ 13, Domain ≈ 170, AgentTools ≈ 16, Engine ≈ 30.
- **M2 Access fixes.** Compile, then change `internal` → `package` where a new boundary needs it. No `public` additions (`PublicSurfaceTests`).
- **M3 Guard allowlists.**
  - 8 test files pin `Sources/BrahmaCore/...` paths: EngineGitGuardTests, MainGuardTests, EmergencyStopTests, NoKeychainTests, ExtensionImporterTests, SecretTests, AwakeTimeTests, and S's lint.
  - **S's `SafetyLintTests` scans only `Sources/BrahmaCore` and `Sources/brahma`** (S §6.8.2). R widens its roots to every Brahma source target except BrahmaApp, BrahmaAppModel and BrahmaMapKit, which the lint never covered. R re-keys `safety-lint-baseline.json` through `MovedPaths` with identical counts. `SafetyLintRootsTests.coversEveryCoreTarget` fails when a new non-UI target is missing from the roots, so a later split cannot exempt code by moving it.
  - Each path is rewritten through one `MovedPaths` table in `Tests/Support`, and `GuardAllowlistTests` pins each allowlist's **count**.
  - `SecretTests` reads `Sources/brahma/RunCommand.swift`, which R changes. Its assertions move with the code to `EngineRunCommand.swift`, with the same strings.
- **M4 Tests.**
  - `BrahmaCoreTests` (189 files) splits into `BrahmaStoreTests`, `BrahmaGitTests`, `BrahmaDomainTests`, `BrahmaEngineTests`, `BrahmaServiceTests`, `BrahmaCLITests` (the 19 files that spawn the CLI) and `BrahmaGuardTests` (static scans).
  - A `BrahmaTestSupport` library target holds `TestSupport.swift`, `GitFixture`, fake tools and `Fixtures/`.
  - Test bodies do not change.
- **M5 Engine hosting.**
  - 1 `EngineHost` (230 lines) and its users: `AppModel` (5 sites), `AppDelegate` (6), `EngineBanner`, `MenuBarSummary`, `Harness` (2), `AppModel+Work` (`recheck`).
  - 6 `OrchestratorLock.acquire` sites get the `suspend` wrapper: `Restore` ×2, `DevReleaseScenario`, `ProviderProbe`, `Store+Taint.engineLock`, `RepoImport`.
- **M6 Docs.** README's "Running the engine" section, v2 §3.1 diagram (append an "after R" note, never rewrite history), and `scripts/smoke-app.sh` (3 CLI uses).
- **Rollback:**
  - Each module move is its own commit and revertible.
  - The service is one feature flag until Task 19: `BRAHMA_ENGINE_MODE=embedded` keeps the old `EngineHost` path compiled until R's final task deletes it.
  - After that, rollback is `git revert` of the hosting tasks.
  - The DB schema is untouched by R. P adds the change-topic migration.
