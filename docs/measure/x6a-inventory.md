# X6a inventory — the tree `brahma measure` is built on

Task 0 of Plan X6a (`docs/superpowers/plans/2026-11-21-planX6a-measure-soak.md`), written on branch `planX6a-build`
(base `6bdea2c`, 2026-11-27). Every row cites the file and line that defines it on this tree. Later tasks use these names
instead of the plan's. File paths are relative to the repository root. Line numbers are those of this commit; a later
commit may move them, the names will not.

Controller rulings this inventory follows: R1 (S, R, P, X1 not merged; build additive on BrahmaCore), R2 (static
verification, no demo seed), R4 (X1 gateway columns absent), R7 (owner additions), R8 (no launchd; engine start record and
first-`main` record named below), R9 (item keys `ACME-12`).

---

## 1. Drift table — every "Builds on" name of the plan

Status words: **as named** · **renamed to …** · **absent (not merged: S/R/P/X1/X8a)** → what the tree uses instead.

### Plan S

| Plan name | Status | What the tree uses |
|---|---|---|
| `GitHardening` | absent (not merged: S) | `GitWorkspace` / `GitCommand` (`Sources/BrahmaCore/Git/GitWorkspace.swift`; `ensureRepo` at :1016, `importRepository` at :3625). All git runs through `GitWorkspace`; `git.withMainLock` guards `main` (`Store+MainGuard.swift:97`). |
| `ToolPaths.git` | absent (not merged: S) | `GitCommand` resolves git itself (`Sources/BrahmaCore/Git/GitWorkspace.swift`, `GitCommand.resolveGit`). Measure code calls `GitWorkspace`, never a path. |
| `Spawn` (S3, S5) | absent (not merged: S) | `ProcessGroup.spawn` (`Sources/BrahmaCore/Verify/ProcessGroup.swift`). |
| `safe()` for CLI output | as named | `Sources/brahma/CLISupport.swift:7` — `func safe(_ text: String) -> String { TerminalText.sanitize(text) }`. |
| `SafetyLintTests` (no new baseline entry) | absent (not merged: S) | No lint test; the zero-tolerance rule for `Sources/BrahmaCore/Measure/` (no `try?`, `?? true/false`, empty `catch`) is a review lens (ruling R12). |

### Plan R

| Plan name | Status | What the tree uses |
|---|---|---|
| `BrahmaDomain`, `BrahmaEngine` targets | absent (not merged: R) | One `BrahmaCore` target. Measure code lives in `Sources/BrahmaCore/Measure/` (R1 file map). |
| `BrahmaStore` / `BrahmaStore/Migrations.swift` | renamed to `Sources/BrahmaCore/Store/Migrations.swift` | `enum Migrations { static func migrator() }`, blocks `m.registerMigration("…")` (`:6` onward; Plan 5 blocks from `:823`). New X6a migration `"vX6a-measure"` is appended at the end of `registerPlan5` (after `"vC-changes-quote"`, `:2021`). |
| `TickParticipant`, `TickStepID`, `TickContext` | absent (not merged: R) | `Orchestrator.schedule(now:)` (`Sources/BrahmaCore/Orchestrator.swift:546`), called from `tick()` (`:536`). Steps are inline; the last step is `dispatchTick` (`:775`). The measure recorder is called once per tick after it (ruling R5: `Orchestrator+Measure.swift`). |
| `TickOrderTests`, `TickGatesTests` | absent (not merged: R) | None. Proposed `measure` position: after `dispatchTick` (`Orchestrator.swift:775`), last in `schedule(now:)`, gated only on `company.status == .running`. |
| `UsageStep`'s `UsageDecisions` | absent (not merged: R) | Inline in `schedule(now:)`: `decisions: [String: UsageDecision]` (`:676`), `paceClosed` (`:677`), `paceStrict` (`:678`); see §4. `UsageDecision` is `Sources/BrahmaCore/Scheduler/UsageGate.swift:3–5` (`.open`, `.closed(until:)`). |
| `EngineService`, `brahma engine serve --unmanaged`, `brahma engine kill`, `brahma engine status` | absent (not merged: R) | `brahma run` (`Sources/brahma/RunCommand.swift:25`): `requireOwnerShell`, integrity check, `openStore`, `Doctor.ensure`, `OrchestratorLock.acquire` (`:45–49`), `Orchestrator.start()` then `runForever()`. Stop = SIGTERM/SIGINT/SIGHUP to that pid (`:66–75`); `brahma stop` is the owner's emergency stop, not a crash. No `engine status`: liveness/start record in §5. |
| `EngineClient.status()` | absent (not merged: R) | See §5: the `flock` on `<home>/orchestrator.lock` (`Sources/BrahmaCore/OrchestratorLock.swift:17–28`) for liveness; the mtime of `<home>/run/.sentinel` (`Sentinel.write`, `Sources/BrahmaCore/Sandbox/ClaudeSettings.swift:317–323`, written at `Orchestrator.start()`, `Orchestrator.swift:297–299`) for "engine started at". |
| `BrahmaTestSupport` | absent (not merged: R) | `Tests/BrahmaCoreTests/TestSupport.swift` (§10). Fixtures for X6a go in `Tests/BrahmaCoreTests/Measure/MeasureFixtures.swift`. |
| `<home>/run/service.lock` (R's launchd service) | absent (not merged: R) | `<home>/orchestrator.lock` (flock; `OrchestratorLock.swift:19`). No service, no launchd (ruling R8). |

### Plan P

| Plan name | Status | What the tree uses |
|---|---|---|
| `.processTier` / `.liveTier`, `UnitTierHygieneTests` | absent (not merged: P) | Plain tests; quota-spending suites use `.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1")` (ruling R3). |
| `TemplateRepo` | absent (not merged: P) | `GitFixture` (`Tests/BrahmaCoreTests/GitFixture.swift:6`): temp workspace + `ws.ensureRepo()`. |
| `ChangeTopics` (`everyTableMapped`) | absent (not merged: P) | None; new tables need no mapping. |
| `CLITreeFrozenTests`, `CLIHelpTests`, `CLIErrorStyleTests`, `CLIHintTests`, `cli-tree.tsv` | absent (not merged: P) | CLI tests spawn the built binary (`Tests/BrahmaCoreTests/CanaryCLITests.swift:5–21`, §10). Error shape: `fail(_:)` in `CLISupport.swift`. |
| `ScreenInventoryTests`, `ThemeLintTests`, shared state components, `scripts/ui-inventory.sh` | absent (not merged: P) | `Panel`, `MonoEmptyState`, `BrahmaTheme` in `Sources/BrahmaApp/Views/` (`BudgetView.swift:14, 21, 35`). Ruling R10. |
| `ScriptedTurnRunner`, `scripts/fake-claude.sh`, `scripts/fake-claude-roles/*`, `scripts/golden-path.sh`, `scripts/test.sh`, `scripts/seed-demo.sh` | absent (not merged: P) | `swift test --filter '<Suite>'`; store-level fixtures. No demo seed (ruling R2). |
| `public-surface.txt` | absent (not merged: P) | None. |

### 4a / L / 3a / 5-lite / C records (all present; exact columns in §2)

| Plan name | Status | Where |
|---|---|---|
| `mergeRequest` | as named | `Migrations.swift:1508–1532`; `MergeRequest` `Sources/BrahmaCore/Merge/Merge.swift:60` |
| `mergeRun` (`kind` main \| item \| mainAtBase, `attempt`, `flaky`) | as named | `Migrations.swift:1534–1554`; `MergeRun` `Merge.swift:129`, `MergeRun.Kind` `:132` |
| `mergeBatch` (`landCommit`, `landedIds`) | as named — **but `landedIds` are `mergeRequest.id`s, not item ids** (§2.1) | `Migrations.swift:1559–1575`; `MergeBatch` `Sources/BrahmaCore/Merge/MergeJournal.swift:19` |
| `mainSmokeRun` (`reason` merge) | as named | `Migrations.swift:716–733`; `MainSmokeRun` `Sources/BrahmaCore/Release/Release.swift:22`, `MainSmokeReason` `:5` |
| `verificationRun` | as named | `Migrations.swift:290–312`; `VerificationRun` `Sources/BrahmaCore/Store/Store+Verification.swift:14` |
| `itemFact` (`firstPass`, `reviewRejections`, `costLE`, `cycleActiveSeconds`, `autoMerged`, `auditVerdict`) | as named | `Migrations.swift:605–630`; `ItemFact` `Sources/BrahmaCore/Work/OutcomeFacts.swift:8` |
| `workItemEvent` (`changesRequested`, `submitted`, `merged`) | as named | `Migrations.swift:254–263`; `WorkItemEvent` `Sources/BrahmaCore/Model/WorkItem.swift:335`; `WorkEventKind` `:299–320` |
| `ask` (`ownerDecidedAt`, `decidedBy`) | as named | `Migrations.swift:456–495`; `Ask` `Sources/BrahmaCore/Model/Ask.swift:162` |
| `message` | as named | `Migrations.swift:70–78` (+`:1112`, `:1133`, `:1642–1646`, `:1815`, `:1979`); `Message` `Sources/BrahmaCore/Model/Messaging.swift:40` |
| `turn` | as named | `Migrations.swift:35–44` + later blocks (§2.9); `Turn` `Sources/BrahmaCore/Model/Turn.swift:18` |
| `usageState` | as named | `Migrations.swift:86–97`; private `UsageStateRow` `Sources/BrahmaCore/Store/Store+Usage.swift:4–16`, read as `RateLimitInfo` via `Store.latestRateLimit()` `:32` |
| `sandboxCanary` | as named — **owner-wide, no `companyId`** | `Migrations.swift:840–848`; raw SQL in `Sources/BrahmaCore/Store/Store+OwnerGuard.swift:61–82` (no record type) |
| `accessRefusal` | as named | `Migrations.swift:1086–1096`; `AccessRefusal` `Sources/BrahmaCore/Access/Grants.swift:311` |
| `release` | as named | `Migrations.swift:735–772` + `:791–796`; `Release` `Release.swift:91` |
| `reviewAudit` (`verdict`) | as named — **values are `ok` / `failed`, not `fail`** | `Migrations.swift:371–385` + `:403–410`; `ReviewAudit` `Sources/BrahmaCore/Store/Store+Audit.swift:6`; verdict written `:488` |
| `companyActivity` | as named — **a running total, no history** | `Migrations.swift:166–170`; private `CompanyActivity` `Sources/BrahmaCore/Engine/CompanyClock.swift:66`; `Store.accrueActiveTime` `:78` |
| `openAuditFollowUp` | as named (`private`) | `Store+Audit.swift:527` |

### X1 (Task 5) and X8a

| Plan name | Status | What the tree uses |
|---|---|---|
| `turn.meteredUSD`, `turn.routedModel`, `turn.provider`, `turn.authRoute`, `itemFact.meteredUSD`, `gatewayCharge`, `providerCap` | absent (not merged: X1) | Subscription leg only: `itemFact.costLE` (`Migrations.swift:620`), `turn.costLE` (`:591`), `turn.costUSD` (`:43`). Model attribution: `agent.model` (`:23`; `Agent.model` `Sources/BrahmaCore/Model/Agent.swift:25`) and `turn.modelsUsed` (`:599`; written `Sources/BrahmaCore/Orchestrator+Budget.swift:70`, the result's `modelUsage` keys comma-joined, **cumulative over `--resume`**). Ruling R4: gateway legs print `not applicable: X1 gateway columns absent`. |
| X8a (`linux-vm`, isolation backend, VM canary) | absent (not merged: X8a) | No `linux-vm`/`Containerization`/`IsolationBackend` name in `Sources/`. Sandbox = Seatbelt (`Sources/BrahmaCore/Sandbox/`). Nothing in X6a reads it. |

---

## 2. Source column table

Format: table → every column (type) with the `Migrations.swift` line that creates it; then the Swift record and the
property that reads it. "NOT FOUND" marks a name the plan or the brief uses that does not exist.

### 2.1 `mergeBatch` — the landing journal (`Migrations.swift:1559–1575`, migration `v4a-merge-journal`)

| Column | Created | Record property (`MergeBatch`, `Merge/MergeJournal.swift:19–71`) | Notes |
|---|---|---|---|
| `id` TEXT PK | :1560 | `id` | |
| `companyId` TEXT NOT NULL → company | :1561 | `companyId` | |
| `number` INTEGER NOT NULL | :1562 | `number` | per company, claim order; ref `B-<n>` |
| `base` TEXT | :1563 | `base: String?` | `main` when the batch was built |
| `step` TEXT NOT NULL | :1564 | `step: MergeStep` | `MergeStep` (`MergeJournal.swift:10–15`): `claimed, preparing, prepared, rebased, checked, backedUp, landing, landed, recorded, cleaned, done`; `order` = index (`:14`) |
| `requestIds` TEXT NOT NULL (JSON `[String]`) | :1565 | `requestIds: [String]` | `mergeRequest.id`s in the batch |
| `expectedParent` TEXT | :1566 | `expectedParent` | never written (S1) |
| `preparedCommit` TEXT | :1567 | `preparedCommit` | never written (S1) |
| `candidates` TEXT NOT NULL default `{}` (JSON `[String: String]`) | :1568 | `candidates: [String: String]` | request id → the candidate commit that carries it (the rebased chain) |
| `landCommit` TEXT | :1569 | `landCommit: String?` | the commit `main` is moved to. **Set at step `checked`** (`Merge/MergeQueue.swift:537`), before `main` moves |
| `landedIds` TEXT NOT NULL default `[]` (JSON `[String]`) | :1570 | `landedIds: [String]` | **`mergeRequest.id`s** that land with `landCommit`, in order (`MergeQueue.swift:537`: `landSet.map(\.request.id)`). Item = `mergeRequest.itemId`; per-request merged commit = `candidates[requestId]` (`Store+MergeSettings.swift:51`, `MergeQueue.swift:929`) |
| `error` TEXT | :1571 | `error` | redacted |
| `startedAt` DATETIME | :1572 | `startedAt: Date` | |
| `updatedAt` DATETIME | :1573 | `updatedAt: Date` | moves at every `advanceBatch` (`MergeJournal.swift:122`) |
| `finishedAt` DATETIME | :1574 | `finishedAt: Date?` | stamped at `done` only |

Index `mergeBatch_company (companyId, step, number)` `:1575`. Reads: `Store.openMergeBatches(companyId:)` (`MergeJournal.swift:97`,
step ≠ done), `Store.mergeBatches(companyId:limit:)` (`:104`, newest first, default limit 50 — Task 3 needs an unbounded,
window-filtered query). Writes: `advanceBatch(id:to:base:candidates:landCommit:landedIds:error:now:)` (`:122`), never backwards.
`repairUnrecordedLandings` (`Store/Store+MergeSettings.swift:35`) records a `landing`/`landed` batch whose `main` already holds
`landCommit`.

**Landing, as the tree records it (refines the brief):** a landing is a `mergeBatch` row with `landCommit` set **and `step` in
(`landed`, `recorded`, `cleaned`, `done`)** — `landCommit` alone is written one step before `main` moves. A batch at `landing`
or any earlier step is **not** a landing, even when git shows `main` holds `landCommit`: recovery (`repairUnrecordedLandings`,
run when the owner resumes the merge queue, or the engine's journal recovery finishing the batch) records it as `landed`, and
from then it is one. `measure` never asks git whether a batch landed. Landed items = `mergeRequest.itemId` for each id in `landedIds` **whose request is `merged` with `batchId` = that batch**,
and a batch with no such request is not a landing (ruling R24: the abort paths after `checked` — stopped, main moved, blocked, off
main, a git error, recovery abandoning the batch — finish the batch to `done` keeping `landCommit`/`landedIds` and requeue the
requests with the same ids; `mergeBatch.error IS NULL` is no filter, since an inconclusive result sets it after a real landing).
Landing time (Task 0 proposal for Task 3): the
landed requests' `mergeRequest.finishedAt` (all set to the same `now` in `recordLanded`, `Store+MergeQueue.swift:320`), falling
back to `mergeBatch.updatedAt`.

### 2.2 `mergeRequest` (`Migrations.swift:1508–1532`, `v4a-merge`)

| Column | Created | `MergeRequest` (`Merge/Merge.swift:60–125`) | Notes |
|---|---|---|---|
| `id` TEXT PK | :1509 | `id` | |
| `companyId` | :1510 | `companyId` | |
| `itemId` TEXT NOT NULL → workItem | :1511 | `itemId` | the landed item |
| `number` INTEGER NOT NULL | :1512 | `number` | ref `M-<n>` |
| `status` TEXT NOT NULL | :1513 | `status: MergeRequestStatus` | `queued, running, landing, merged, bounced, failed, cancelled` (`Merge.swift:30–31`); `isOpen` = queued/running/landing (`:46`) |
| `headCommit` TEXT NOT NULL | :1514 | `headCommit` | the item's verified commit at approval |
| `checkRevision` INTEGER | :1515 | `checkRevision` | |
| `baseCommit` TEXT | :1516 | `baseCommit` | **= the batch's `base` for every request of the batch** (`markLanding`, `Store+MergeQueue.swift:295`), not the request's own parent |
| `candidateCommit` TEXT | :1517 | `candidateCommit` | = `mergeBatch.candidates[id]` (`:296`) |
| `mergedCommit` TEXT | :1518 | `mergedCommit` | set with `status = merged` in `recordLanded` (`:318–319`); equals `candidateCommit` |
| `batchId` TEXT | :1519 | `batchId` | |
| `failure` TEXT | :1520 | `failure: MergeFailure?` | `conflict, itemCheckFailed, mainCheckFailed, secretFound, snapshotTampered, engineError, mainMoved` (`Merge.swift:53–55`) |
| `detail` TEXT | :1521 | `detail` | engine-written |
| `conflictFiles` TEXT NOT NULL default `[]` | :1522 | `conflictFiles: [String]` | agent-controlled text |
| `outputTail`, `outputPath` | :1523–1524 | same | |
| `attempts`, `requeues`, `inconclusive` INTEGER NOT NULL default 0 | :1525–1527 | same | |
| `retryRequestedAt` DATETIME | :1528 | `retryRequestedAt` | |
| `enqueuedAt` DATETIME | :1529 | `enqueuedAt: Date` | **approval time** (controller's call): set to `now` in `enqueueApproved` (`Store+MergeQueue.swift:131`), called from `approveForMerge` (`Store+Review.swift:247`; the `reviewApproved` event `:175`); also on an owner retry (`Store+MergeSettings.swift:163`) |
| `startedAt`, `finishedAt` DATETIME | :1530–1531 | same | `finishedAt` = landing recorded (`:320`) or bounce |

Index `mergeRequest_queue (companyId, status, number)` `:1532`. Reads: `Store.mergeRequests(companyId:statuses:limit:)`
(`Store+MergeQueue.swift:25`, default limit 200), `latestMergeRequest(itemId:)`, `mergeRuns(requestId:)` (`:54`).
Per-item diff range for a landed request: `mergedCommit` and its first parent (`<mergedCommit>^1`), or the previous
candidate in `landedIds` order (the first one's parent is `mergeBatch.base`). **Do not use `mergeRequest.baseCommit` as the
per-item base in a batch of size > 1.**

### 2.3 `mergeRun` (`Migrations.swift:1534–1554`, `v4a-merge`)

| Column | Created | `MergeRun` (`Merge/Merge.swift:129–165`) | Notes |
|---|---|---|---|
| `id` TEXT PK | :1535 | `id` | |
| `companyId` | :1536 | `companyId` | |
| `batchId` TEXT | :1537 | `batchId` | |
| `requestId` TEXT → mergeRequest | :1538 | `requestId` | nil for `main`/`mainAtBase` runs |
| `prefix` INTEGER | :1539 | `prefix` | how many requests the candidate carries |
| `candidateCommit` TEXT | :1540 | `candidateCommit` | join key to `mergeBatch.landCommit` |
| `kind` TEXT | :1541 | `kind: MergeRun.Kind?` | `main`, `item`, `mainAtBase` (`Merge.swift:132`). A `main` run exists **only when `company.mainCheck` is set** (`MergeQueue.swift:684`); `mainAtBase` tells a red main from a red candidate (`:481`, `:743`) |
| `itemId` TEXT | :1542 | `itemId` | set for `item` runs |
| `command`, `scriptHash` TEXT | :1543–1544 | same | |
| `status` TEXT | :1545 | `status: VerificationStatus?` | `queued, running, passed, failed, timedOut, inconclusive, error` (`Store+Verification.swift:4–6`) |
| `attempt` INTEGER NOT NULL default 1 | :1546 | `attempt` | a flake re-run is recorded as `attempt = 2` with `flaky = true` (`MergeQueue.swift:708–720`) |
| `flaky` BOOLEAN NOT NULL default 0 | :1547 | `flaky` | |
| `exitCode`, `outputPath`, `outputTail` | :1548–1550 | same | |
| `startedAt`, `finishedAt` DATETIME | :1551–1552 | same | |

Index `mergeRun_request (requestId)` `:1553`. Written by `Store.recordMergeRun` (`Store+MergeQueue.swift:274`) from
`MergeQueue.runCheck` (`MergeQueue.swift:1037–1049`).

### 2.4 `mainSmokeRun` (`Migrations.swift:716–733`, `vL-release`)

| Column | Created | `MainSmokeRun` (`Release/Release.swift:22–50`) | Notes |
|---|---|---|---|
| `id` TEXT PK | :717 | `id` | |
| `companyId` | :718 | `companyId` | |
| `commit` TEXT NOT NULL | :719 | `commit` | join key to `mergeBatch.landCommit` / `company.mainCommit` |
| `status` TEXT NOT NULL | :720 | `status: MainSmokeStatus` | `queued, running, passed, failed, error` (`Release.swift:11–15`); only `passed`/`failed` say anything (`error` = superseded or could not run) |
| `exitCode`, `outputPath`, `outputTail` | :721–723 | same | |
| `reason` TEXT NOT NULL | :724 | `reason: MainSmokeReason` | `merge`, `release`, `manual` (`Release.swift:5–7`) |
| `releaseId` TEXT | :725 | `releaseId` | |
| `createdAt`, `startedAt`, `finishedAt` | :726–728 | same | |

Unique partial index `mainSmokeRun_merge (companyId, commit) WHERE reason = 'merge'` `:731`. A `merge` run is queued only when
`company.smokeCheck` is set (`Store+Release.swift:97–106`, for `company.mainCommit`). Read: `Store.mainSmokeRuns(companyId:)`
(`Store+Release.swift:41`).

### 2.5 `verificationRun` (`Migrations.swift:290–312`, `v3-verify`)

| Column | Created | `VerificationRun` (`Store+Verification.swift:14–44`) |
|---|---|---|
| `id` TEXT PK | :291 | `id` |
| `companyId` | :292 | `companyId` |
| `itemId` TEXT NOT NULL → workItem | :293 | `itemId` |
| `checkRevision` INTEGER NOT NULL | :294 | `checkRevision` |
| `scriptHash` TEXT NOT NULL default `''` | :295 | `scriptHash` |
| `commit` TEXT NOT NULL | :296 | `commit` |
| `command` TEXT NOT NULL | :297 | `command` |
| `workingDirectory` TEXT NOT NULL default `''` | :298 | `workingDirectory` |
| `timeoutSeconds` INTEGER NOT NULL | :299 | `timeoutSeconds` |
| `purpose` TEXT NOT NULL | :300 | `purpose: VerificationPurpose` — `submit`, `merge` (`:8–10`) |
| `attempt` INTEGER NOT NULL default 1 | :301 | `attempt` |
| `status` TEXT NOT NULL | :302 | `status: VerificationStatus` — `queued, running, passed, failed, timedOut, inconclusive, error` (`:4–6`) |
| `flaky` BOOLEAN NOT NULL default 0 | :303 | `flaky` |
| `exitCode`, `outputPath`, `outputTail`, `requestedBy` | :304–307 | same |
| `notBeforeActive` DOUBLE | :308 | `notBeforeActive` |
| `createdAt` NOT NULL, `startedAt`, `finishedAt` | :309–311 | same |

Indexes `verificationRun_item (itemId)` `:313`, `verificationRun_status (status)` `:314`.

### 2.6 `itemFact` — every column (`Migrations.swift:605–630`, `v3-facts`)

Written once per completed non-container item inside the completing transaction (`OutcomeFactsObserver.itemCompleted`,
`Work/OutcomeFacts.swift:53–59`; the fact builder `:61`). `audited`/`auditVerdict` are updated later by
`Store.recordAuditFact` (`:135–137`).

| Column | Created | `ItemFact` property (`OutcomeFacts.swift:8–50`) | Meaning |
|---|---|---|---|
| `itemId` TEXT PK → workItem | :606 | `itemId` | |
| `companyId` NOT NULL | :607 | `companyId` | |
| `type` TEXT NOT NULL | :608 | `type` | |
| `tier` TEXT NOT NULL | :609 | `tier` | `s`/`m`/`l` |
| `ownerId` TEXT | :610 | `ownerId` | the assignee (agent id) |
| `reviewerId` TEXT | :611 | `reviewerId` | |
| `firstPass` BOOLEAN NOT NULL | :612 | `firstPass` | first non-inconclusive submit run passed un-flaky and `reviewRejections == 0` (`:69`) |
| `verificationRuns` INTEGER NOT NULL default 0 | :613–616 loop | `verificationRuns` | finished, non-inconclusive runs (submit + merge) |
| `failedRuns` | same | `failedRuns` | failed/timedOut/error |
| `flakyRuns` | same | `flakyRuns` | |
| `inconclusiveRuns` | same | `inconclusiveRuns` | |
| `reworkRounds` | same | `reworkRounds` | |
| `reviewRejections` | same | `reviewRejections` | count of `changesRequested` events (`:67`) |
| `turnsUsed` | same | `turnsUsed` | `Store.itemUsage` (`Work/Budget.swift:68–79`): `turn.kind = 'work' AND infra = 0 AND sessionResetReason IS NULL AND (stopReason IS NULL OR stopReason <> 'sessionReset')`, outcome in (succeeded, failed) |
| `tokensUsed` | same | `tokensUsed` | input + output + cacheCreation, ultra turns excluded (`Budget.swift:71`) |
| `tierMaxTurns`, `tierMaxTokens` | same | same | |
| `blockedActiveSeconds` | same | `blockedActiveSeconds` | |
| `mergeConflicts` | same | `mergeConflicts` | |
| `cycleActiveSeconds` INTEGER | :617 | `cycleActiveSeconds: Int?` | **company-active** seconds first claim → completion (nil if never claimed) |
| `checkAuthorId` TEXT | :618 | `checkAuthorId` | |
| `checkAuthorRole` TEXT | :619 | `checkAuthorRole` | `owner`, `system` or the agent's role |
| `costLE` DOUBLE NOT NULL default 0 | :620 | `costLE` | $LE of the item's counted work turns (subscription leg) |
| `tierMaxCostLE` DOUBLE NOT NULL default 0 | :621 | `tierMaxCostLE` | |
| `reviewCostLE` DOUBLE NOT NULL default 0 | :622 | `reviewCostLE` | Σ `turn.costLE` where `kind = 'review'` for the item (`OutcomeFacts.swift:73–75`) |
| `autoMerged` BOOLEAN NOT NULL default 0 | :623 | `autoMerged` | |
| `audited` BOOLEAN NOT NULL default 0 | :624 | `audited` | |
| `auditVerdict` TEXT | :625 | `auditVerdict: String?` | `ok` / `failed` (copied from `reviewAudit.verdict`) |
| `rungAtPass` INTEGER | :626 | `rungAtPass` | |
| `modesUsed` TEXT | :627 | `modesUsed` | comma-joined |
| `completedAt` DATETIME NOT NULL | :628 | `completedAt` | |

Index `itemFact_company (companyId, completedAt)` `:630`. Read: `Store.itemFacts(companyId:limit:)` (`OutcomeFacts.swift:123`,
default limit 50 — Task 5 needs a window query). `itemFact.meteredUSD`: **NOT FOUND (X1 absent)** → `not applicable`.

### 2.7 `workItemEvent` (`Migrations.swift:254–263`, `v3-work`; `:1134` `v5-taint-2`; `:1828` `vC-share`)

| Column | Created | `WorkItemEvent` (`Model/WorkItem.swift:335–350`) |
|---|---|---|
| `id` INTEGER PK autoincrement | :255 | `id: Int64?` |
| `companyId` NOT NULL | :256 | `companyId` |
| `itemId` NOT NULL → workItem | :257 | `itemId` |
| `actorId` TEXT NOT NULL | :258 | `actorId` — agent id, `"owner"` or `"system"` (`:341`) |
| `kind` TEXT NOT NULL | :259 | `kind: WorkEventKind` |
| `text` TEXT NOT NULL | :260 | `text` |
| `createdAt` DATETIME NOT NULL | :261 | `createdAt` |
| `createdActive` DOUBLE NOT NULL | :262 | `createdActive` (company-active seconds) |
| `taintedOrigin` BOOLEAN NOT NULL default 0 | :1134 | `taintedOrigin` |
| `sourceMessageId` TEXT | :1828 | `sourceMessageId` |

Index `workItemEvent_item (itemId, id)` `:264`. `WorkEventKind` raw values (`Model/WorkItem.swift:299–320`): `created,
statusChanged, edited, checkEdited, assigned, commented, dependencyAdded, dependencyDone, leaseClaimed, leaseReleased,
leaseExpired, submitted, verificationPassed, verificationFailed, reviewApproved, changesRequested, merged, mergeConflict,
handoffWritten, budgetExceeded, watchdog, aging, sprintChanged, branchBehind, mergeFailed, mergeQueued, planWritten,
planTurnWrote, modeEscalated, specConfirmed, humanTaskDone, humanTaskDeclined, referenced, reviewComment`.

Write sites the metrics rely on: `changesRequested` — `Store+Review.swift:258` (actor = reviewer agent id; the item goes back
to `inProgress`, `:256`); `submitted` — `Store+Verification.swift:244` (text `submitted for review (round <n>) at <sha7>`);
`reviewApproved` — `Store+Review.swift:175`; `mergeQueued` — `Store+MergeQueue.swift:143`; `merged` — `engineSetStatus(…, to: .done,
event: .merged)` from `finishMerge` (`Store+Merge.swift:253`, text `merged into main at <sha7>`); `verificationPassed` —
`Store+Verification.swift:432–470`; `verificationFailed` — `:504`, `Store+Merge.swift:348, 401`.

### 2.8 `ask` (`Migrations.swift:456–495`, `v3-asks`; `pushedAt` `:1017`)

| Column | Created | `Ask` (`Model/Ask.swift:162–200`) | Notes |
|---|---|---|---|
| `id` TEXT PK | :457 | `id` | |
| `companyId` | :458 | `companyId` | |
| `number` INTEGER NOT NULL | :459 | `number` | ref `A-<n>` |
| `kind` TEXT NOT NULL | :460 | `kind: AskKind` | raw values (`Ask.swift:13–30`): `prd, architecture, sprintPlan, release, other, info, engineAlert, boost, request, grant, deploy, humanTask, outbox, spend, staffing, stage, role, extension`; gates = `prd, architecture, sprintPlan, release` (`:37`) |
| `category` TEXT | :461 | `category` | |
| `risk` TEXT NOT NULL | :462 | `risk: AskRisk` | `low, medium, high` |
| `requesterId` TEXT NOT NULL | :463 | `requesterId` | agent id or `"system"` |
| `itemId` TEXT | :464 | `itemId` | |
| `title`, `summary`, `payload`, `detailsHash`, `proposedGrant` | :465–469 | same | |
| `status` TEXT NOT NULL | :470 | `status: AskStatus` | `pendingInternal, pendingOwner, approved, rejected, answered, expired, rescinded, superseded` (`Ask.swift:87–88`) |
| `internalApproverId`, `internalNote`, `internalDecidedAt` | :471–473 | same | |
| `ownerNote`, `ownerAnswer` | :474–475 | same | |
| `ownerDecidedAt` DATETIME | :476 | `ownerDecidedAt: Date?` | set only in `ownerDecide` (`Store+Asks.swift:619`), `ownerRescind` (`:641`), `ownerAnswer` (`:666`, `:685`) |
| `decidedBy` TEXT | :477 | `decidedBy: String?` | `"owner"`, `"@<handle>"` (internal approver, `:521`), `"policy:<preset>"` (`:538`), `"preset:<id>"` (an access preset through `ownerDecide`, `:587–589`), `"system"` (expiry, `Store+AskLifecycle.swift:48`) |
| `fyi` BOOLEAN NOT NULL default 0 | :478 | `fyi` | |
| `acknowledgedAt` DATETIME | :479 | `acknowledgedAt` | engine alerts |
| `subjectId`, `supersedesId`, `escalatedAt`, `rescindedAt` | :480–483 | same | |
| `createdActive`, `statusSinceActive`, `expiresActive` DOUBLE | :484–486 | same | |
| `remindCount`, `notifiedAt` | :487–488 | same | |
| `createdAt`, `updatedAt` NOT NULL | :489–490 | same | |
| `requestId` TEXT, `decisionClass` TEXT NOT NULL default `taste` | :492–493 | same | |

Index `ask_company_status (companyId, status)` `:496`. Read: `Store.asks(companyId:statuses:)` (`Store+Asks.swift:700`).
**Owner touch (ask leg):** `ownerDecidedAt` in window **and `decidedBy = 'owner'`** — an access preset also stamps
`ownerDecidedAt` with `decidedBy = 'preset:<id>'`, which is not an owner touch.

### 2.9 `message` (`Migrations.swift:70–78` `v1`; `:1112` `v5-taint`; `:1133` `v5-taint-2`; `:1642–1646` `vC-refs`; `:1815` `vC-threads`; `:1979` `vC-show`)

| Column | Created | `Message` (`Model/Messaging.swift:40–79`) |
|---|---|---|
| `id` TEXT PK | :71 | `id` |
| `companyId` | :72 | `companyId` |
| `channelId` NOT NULL → channel | :73 | `channelId` |
| `senderId` TEXT NOT NULL | :74 | `senderId` — agent id, `"owner"` or `"system"` (`Messaging.swift:32–34, 45`) |
| `text` NOT NULL | :75 | `text` |
| `createdAt` NOT NULL | :76 | `createdAt` |
| `flag` TEXT | :1112 | `flag` (`impersonation`) |
| `taintedOrigin` BOOLEAN NOT NULL default 0 | :1133 | `taintedOrigin` |
| `kind` TEXT NOT NULL default `text` | :1643 | `kind: MessageKind` — `text, share, showRequest, showAnswer, fileAsk, system` (`:83–85`) |
| `fromTaintedSession` BOOLEAN NOT NULL default 0 | :1644 | `fromTaintedSession` |
| `taintSource` TEXT | :1645 | `taintSource` |
| `parentId` TEXT | :1815 | `parentId` |
| `answerVerified` BOOLEAN | :1979 | `answerVerdict: Int?` / `answerVerified: Bool?` |

**An owner-authored message is `message.senderId = 'owner'`** (and `kind <> 'system'`; engine lines are `senderId = 'system'`).
Existing read is per channel (`Store.messages(channelId:limit:before:)`, `Store+Messaging.swift:65`); Task 5 counts with
`SELECT COUNT(*) FROM message WHERE companyId = ? AND senderId = 'owner' AND createdAt >= ? AND createdAt < ?`.

### 2.10 `turn` — every column

| Column | Created (migration) | `Turn` property (`Model/Turn.swift:18–81`) | Notes |
|---|---|---|---|
| `id` TEXT PK | :36 (v1) | `id` | |
| `agentId` → agent | :37 | `agentId` | |
| `companyId` → company | :38 | `companyId` | |
| `startedAt` NOT NULL | :39 | `startedAt` | |
| `endedAt` | :40 | `endedAt` | |
| `outcome` TEXT NOT NULL | :41 | `outcome: TurnOutcome` | `inProgress, succeeded, failed, usageLimited, interrupted` (`Turn.swift:4`) |
| `summary` TEXT | :42 | `summary` | |
| `costUSD` DOUBLE | :43 | `costUSD` | this turn's share of `total_cost_usd` |
| `infra` BOOLEAN NOT NULL default 0 | :189 (v3-clock) | `infra` | infrastructure failure, never counted |
| `kind` TEXT NOT NULL default `work` | :330 (v3-turn-context) | `kind: TurnKind` | `work, review, audit, notice, plan, show` (`Turn.swift:7–15`) |
| `itemId` TEXT | :331 | `itemId` | |
| `sessionResetReason` TEXT | :448 (v3-sessions) | `sessionResetReason` | set ⇒ the turn is ignored by budgets/facts |
| `reportedStatus` TEXT | :449 | `reportedStatus` | `DONE` / `DONE_WITH_CONCERNS` / `BLOCKED` / `NEEDS_CONTEXT` |
| `cacheBreak` TEXT | :450 | `cacheBreak` | |
| `sessionId` TEXT | :580 (v3-budgets) | `sessionId` | |
| `sessionTotalUSD` DOUBLE | :581 | `sessionTotalUSD` | |
| `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens` INTEGER NOT NULL default 0 | :582 | same | |
| `toolSignature` TEXT | :583 | `toolSignature` | |
| `mode` TEXT | :584 | `mode` | `ultra` turns excluded from token counts |
| `rung` INTEGER | :585 | `rung` | |
| `effort` TEXT | :586 | `effort` | |
| `modeReason` TEXT | :587 | `modeReason` | |
| `stopReason` TEXT | :588 | `stopReason` | `turnCap`, `budgetCap` or `sessionReset` (`Turn.swift:60`): the engine's own cap, **not** a rate limit |
| `subagentsSpawned`, `workflowAgents` INTEGER NOT NULL default 0 | :589–590 | same | |
| `costLE` DOUBLE | :591 | `costLE` | $LE (subscription leg) |
| `modelsUsed` TEXT | :599 (v3-budgets-models) | `modelsUsed` | result `modelUsage` keys, comma-joined, **cumulative over `--resume`** (`Orchestrator+Budget.swift:70`) |
| `pid` INTEGER | :839 (v5-owner-guard) | `pid: Int32?` | the CLI process of the turn |
| `freshSessionReason` TEXT | :954 (v5-extensions-2) | `freshSessionReason` | `"tainted"` after a refused high-risk call under taint (`Store+Taint.swift:149`) |
| `taintedAt` DATETIME, `taintSource` TEXT | :1102–1103 (v5-taint) | same | |

Indexes: `turn_agent_started (agentId, startedAt)` `:45`; `turn_item (itemId)` `:592`; `turn_session (sessionId)` `:593`.
**Rate-limit rejection representation:** `turn.outcome = 'usageLimited'` (`Orchestrator.swift:1655`, `:1667`, mapped `:1981`);
the agent is then `blocked` with `blocker = .usageLimit(until:)` (`:2171–2172`, `:2206`); the gate state is the single
`usageState` row saved with `status = "rejected"` when no rate-limit event named a reset (`noteUsageLimit`, `:1559–1568`).
There is **no per-rejection history row**: `usageState` is overwritten (§2.11). `turn.meteredUSD`, `routedModel`, `provider`,
`authRoute`: **NOT FOUND (X1 absent)**.

### 2.11 `usageState` — single row, `id = 1` (`Migrations.swift:86–97`, `v1`)

| Column | Created | `UsageStateRow` → `RateLimitInfo` (`Store+Usage.swift:4–16`, `:20–29`) |
|---|---|---|
| `id` INTEGER PK (always 1) | :87 | `id = 1` |
| `status` TEXT NOT NULL | :88 | `status` (e.g. `"rejected"`, `Orchestrator.swift:1564`) |
| `resetsAt` DATETIME | :89 | `resetsAt` |
| `rateLimitType` TEXT | :90 | `rateLimitType` |
| `isUsingOverage` BOOLEAN NOT NULL | :91 | `isUsingOverage` |
| `fiveHourUtilization` DOUBLE | :92 | `fiveHourUtilization` |
| `sevenDayUtilization` DOUBLE | :93 | `sevenDayUtilization` |
| `observedAt` DATETIME NOT NULL | :94 | `observedAt` |
| `fiveHourResetsAt`, `sevenDayResetsAt` DATETIME | :95–96 | same |

**Reserve:** not a column. `reserve = company.ownerReserve ?? SchedulerConfig.ownerReserve` (`Scheduler/Pacing.swift:69`;
`company.ownerReserve` `Migrations.swift:190`). A reserve breach is `sevenDayUtilization >= 1 - reserve`
(`Pace.reserveLine`, `Pacing.swift:18`; `criticalPathExempt` false at `:29`), the condition that puts a company in
`paceStrict` (`Orchestrator.swift:705`). **Owner-wide, not per company** (one `usageState` row). The row is overwritten on every
observation, so breaches have **no history** → Task 5's `reserveBreaches` counter. As built (ruling R30): the recorder judges
each **new** snapshot once (`measureEpoch('usageSnapshotJudged')`) against the **owner-wide** reserve (`SchedulerConfig.ownerReserve`,
not a company's `ownerReserve` override) and adds one breach per snapshot at or over `1 − reserve` to the owner-wide counter
(company id `""`) on the day it was observed.

### 2.12 `sandboxCanary` (`Migrations.swift:840–848`, `v5-owner-guard`) — no record type, raw SQL

| Column | Created | Read/written |
|---|---|---|
| `cliFingerprint` TEXT NOT NULL (PK part) | :841 | `Store.sandboxVerified` `Store+OwnerGuard.swift:61–66`; `recordCanary` `:73–82` (`INSERT OR REPLACE`) |
| `settingsShape` TEXT NOT NULL (PK part) | :842 | same |
| `osVersion` TEXT NOT NULL (PK part) | :843 | same |
| `cliVersion` TEXT | :844 | |
| `passedAt` DATETIME NOT NULL | :845 | the pass time |
| `detail` TEXT | :846 | |

**Owner-wide: no `companyId`.** `INSERT OR REPLACE` keeps one row per key, so "canary passes in the window" = rows with `passedAt`
in the window (a re-pass of the same key overwrites the earlier one). Not company-scoped → shown with basis `owner-wide`.

### 2.13 `accessRefusal` (`Migrations.swift:1086–1096`, `v5-grants`)

| Column | Created | `AccessRefusal` (`Access/Grants.swift:311–323`) |
|---|---|---|
| `id` INTEGER PK autoincrement | :1087 | `id` |
| `companyId` | :1088 | `companyId` |
| `agentId` TEXT NOT NULL | :1089 | `agentId` |
| `kind` TEXT NOT NULL | :1090 | `kind` — `GrantKind.rawValue` (`readPath`, `networkDomain`, `webDomain`, `extension`, …; written `Store+Grants.swift:73`) |
| `value` TEXT NOT NULL | :1091 | `value` (redacted, agent text) |
| `detail` TEXT NOT NULL | :1092 | `detail` |
| `createdActive` DOUBLE NOT NULL | :1093 | `createdActive` |
| `createdAt` DATETIME NOT NULL | :1094 | `createdAt` |

Index `accessRefusal_agent (agentId, createdActive)` `:1096`. Read: `Store.accessRefusals(companyId:limit:)` (`Store+Grants.swift:127`).

**Taint-refusal event:** NOT FOUND as a row. A refused high-risk call under taint calls `Store.requestFreshSession(agentId:)`
(`Store+Taint.swift:132`, sets `agent.freshSessionRequested`); at the turn's end `clearTaintIfRequested` forces a fresh session
with reason `"tainted"` (`:145`), which the agent's **next** turn carries as `turn.freshSessionReason = 'tainted'`. That column
is the only durable trace: one per refused turn, not per refused call. Share refusals are activity lines only
(`activityEvent.kind = 'access'`, text `…was refused…`, `Collab/Share.swift:462–467`). Channel refusals: X4 absent.
DLP hits: `mergeRequest.failure = 'secretFound'` (`Merge.swift:54`; bounced at enqueue `Store+MergeQueue.swift:134–140`, or in the
queue `MergeQueue.swift:524, 529`).

### 2.14 `release` (`Migrations.swift:735–772` `vL-release`; `:791–796` `vL-release-2`)

| Column | Created | `Release` (`Release/Release.swift:91–150`) |
|---|---|---|
| `id` TEXT PK | :736 | `id` |
| `companyId` | :737 | `companyId` |
| `number` INTEGER NOT NULL | :738 | `number` (ref `R-<n>`) |
| `version` TEXT NOT NULL | :739 | `version` |
| `status` TEXT NOT NULL | :740 | `status: ReleaseStatus` — `proposed, approved, building, deploying, smoking, deployed, failed, rejected, cancelled, interrupted, rolledBack` (`Release.swift:58–59`) |
| `provider`, `project` TEXT NOT NULL | :741–742 | same |
| `commit` TEXT NOT NULL | :743 | `commit` (the accepted `main` at propose time) |
| `previousReleaseId`, `build`, `outputDir` | :744–746 | same |
| `plan` TEXT NOT NULL, `commandsHash` TEXT NOT NULL, `rollbackPlan` TEXT NOT NULL | :747–749 | `plan: DeployPlan`, `commandsHash`, `rollbackPlan` |
| `notes`, `askId`, `proposedById` NOT NULL, `approvedBy` | :750–753 | same |
| `deployURL`, `productionURL`, `smokeStatus`, `smokeResults` NOT NULL default `[]`, `outputTail`, `failedReason`, `backupRef` | :754–760 | same |
| `rollbackStatus` TEXT | :761 | `rollbackStatus: RollbackStatus?` — `requested, running, succeeded, failed, interrupted` (`:86`) |
| `rollbackRequestedAt`, `rollbackStartedAt`, `rolledBackAt`, `rollbackOutputTail` | :762–765 | same |
| `createdAt` NOT NULL, `approvedAt`, `startedAt`, `deployedAt`, `finishedAt` | :766–770 | same |
| `deployStartedAt` DATETIME | :792 | `deployStartedAt` — when `deploying` was committed (`ReleaseExecutor.swift:401`) |
| `smokeCheck` TEXT, `siteSmoke` TEXT NOT NULL default `[]`, `siteExpectText` | :793–795 | same |

Unique `(companyId, number)`, `(companyId, version)` `:771–772`. **Execution count / idempotency:** there is no execution
counter. Exactly-once is by status compare-and-swap: `Store.claimRelease` claims the oldest `approved` release in one write,
each status change is committed before the next side effect (`Store.advanceRelease(id:from:to:)`, `Store+Release.swift:640`),
and `Store.recoverReleases` (`:910`) at engine start ends what an earlier engine left: `building`/`smoking` → `failed`,
`deploying` → `interrupted` (never run again), a running rollback → `interrupted` (`ReleaseExecutor.swift:29–62`). The soak
check "release executed once" = no release has `deployStartedAt` set twice (impossible by schema) and no `deployed`
release shares a `commit` + `version` with another non-rolledBack one; a `kill -9` mid-deploy must leave exactly one row at
`interrupted`.

### 2.15 `reviewAudit` (`Migrations.swift:371–385` `v3-review-audit`; `:403–410` `v3-review-audit-2`)

| Column | Created | `ReviewAudit` (`Store+Audit.swift:6–35`) |
|---|---|---|
| `itemId` TEXT PK → workItem | :372 | `itemId` |
| `companyId` | :373 | `companyId` |
| `sampledActive` DOUBLE NOT NULL | :374 | `sampledActive` (company-active seconds when the item landed) |
| `auditedAt` DATETIME | :375 | `auditedAt` |
| `verdict` TEXT | :376 | `verdict` — **`"ok"` or `"failed"`** (`:488`), never `fail` |
| `notes`, `authorId`, `baseCommit`, `mergedCommit`, `auditorId`, `auditTurnId`, `batchedActive` | :377–383 | same |
| `assigneeId`, `submitterId` | :404–405 | same |
| `attempts` INTEGER NOT NULL default 0 | :406 | `attempts` |
| `deferredUntilActive` DOUBLE | :407 | `deferredUntilActive` |
| `escalated` BOOLEAN NOT NULL default 0 | :408 | `escalated` |
| `followUpId` TEXT | :409 | `followUpId` — the item `openAuditFollowUp` created (set `:512`) |

Index `reviewAudit_company (companyId, auditedAt)` `:386`. Read: `Store.reviewAudits(companyId:)` (`:262`).

### 2.16 `companyActivity` (`Migrations.swift:166–170`, `v3-clock`)

| Column | Created | `CompanyActivity` (private, `Engine/CompanyClock.swift:66–70`) |
|---|---|---|
| `companyId` TEXT PK → company | :167 | `companyId` |
| `activeSeconds` DOUBLE NOT NULL default 0 | :168 | `activeSeconds` |
| `lastAccruedAt` DATETIME | :169 | `lastAccruedAt` |

**How active seconds accrue** (`Store.accrueActiveTime(now:)`, `CompanyClock.swift:78–94`, called first in every tick): for every
company, if `company.status == .running` and no `engineHold` row and no `engineStop` row, `activeSeconds += min(max(now −
lastAccruedAt, 0), CompanyClock.maxGap = 60)`; `lastAccruedAt = now` for every company regardless. Read:
`Store.activeNow(companyId:)` (`:96`), in-transaction `Store.activeNow(db:companyId:)` (`:101`).
**It is a running total with no history.** "Company-active seconds in the window" (idle-while-actionable denominator, R7(a)
plan-hours) is **NOT FOUND for a window** → Task 2's `measureCounter` must also carry a daily `activeSeconds` counter that Task 5's
recorder accrues per tick with the same gap rule. As built (ruling R31): every window, `--since all` included, reads only the
daily counters; `companyActivity.activeSeconds` is not read by `measure`.

### 2.17 `workLease` (`Migrations.swift:277–284` `v3-leases`; `:1648` `vC-refs`) and item status

| Column | Created | `WorkLease` (`Store+Leases.swift:7–26`) |
|---|---|---|
| `itemId` TEXT PK → workItem | :278 | `itemId` |
| `companyId` | :279 | `companyId` |
| `agentId` → agent | :280 | `agentId` (the holder) |
| `acquiredAt` DATETIME NOT NULL | :281 | `acquiredAt` |
| `expiresActive` DOUBLE NOT NULL | :282 | `expiresActive` (company-active seconds; ttl 7200, `:9`) |
| `claimHead` TEXT | :1648 | `claimHead` |

Read: `Store.leases(companyId:)` (`Store+Leases.swift:40`), `lease(itemId:)` (`:32`), `lease(agentId:)` (`:36`).
`workItem.status` values (`WorkItemStatus`, `Model/WorkItem.swift:36–37`): `backlog, ready, inProgress, inReview, done,
blocked`. Soak lease rule: no item `inProgress` without a `workLease` row; no lease whose `agentId` is an agent with
`state = 'killed'` (`AgentState`, `Model/Agent.swift:4`: `ready, running, blocked, sleeping, killed`). `workItem` columns of
interest: `baseCommit` (`:326`, `main` at first claim), `mergedCommit` (`:336`), `mergeState` (`:335`; `none, pending,
verifying`, `WorkItem.swift:197–199`), `doneAt` (`:237`), `key` (`:205`; `<PREFIX>-<n>`, prefix = up to 5 chars of the slug
uppercased, `Store+WorkItems.swift:116–120`, e.g. `ACME-12`).

### 2.18 Engine lock, liveness and restore records

| Record | Where | What it holds |
|---|---|---|
| `<home>/orchestrator.lock` | `OrchestratorLock.acquire(paths:)` `OrchestratorLock.swift:17–28`: `open(O_CREAT\|O_RDWR\|O_CLOEXEC, 0600)` + `flock(LOCK_EX\|LOCK_NB)`; released in `deinit` `:36–39`. Acquired by `brahma run` (`RunCommand.swift:45–49`) and the app. | **Liveness only**: a non-blocking `flock` attempt that gets `EWOULDBLOCK` means an engine holds it. No pid, no timestamp (the file is not truncated or rewritten on re-acquire). |
| `<home>/run/.sentinel` | `BrahmaPaths.sentinel` `Paths.swift:24`; written by `Sentinel.write(paths:)` `Sandbox/ClaudeSettings.swift:317–323` via `SettingsFile.writePrivate` (`:291–…`, a new temp file renamed over the name) in `Orchestrator.start()` `Orchestrator.swift:297–299`, unconditionally. | **"Engine started at" = this file's mtime** (rewritten at every `start()`). Content is the constant `"sentinel"`. |
| `engineProbe` (`Migrations.swift:147–152`): `id = 1`, `report` TEXT, `checkedAt` DATETIME | `Store.saveProbe` / `latestProbe` `Store+Engine.swift:6–20`; written by `Doctor.ensure` (`Engine/Doctor.swift:135`) at `brahma run` start unless `--skip-doctor` (`RunCommand.swift:35–37`), and by `brahma doctor`. | Not an engine-start record (the doctor also writes it). |
| `<home>/run/turns/<agentId>` (`TurnRecord`, `Turns/TurnProcess.swift:386–388`: `leader`, `leaderStart`) | `Store.recordedTurnLeaders(paths:)` `Store+OwnerGuard.swift:38–53` | Live turn leaders (pid + start time), what the owner-shell guard checks ancestry against. |
| `engineHold` (`:182–188`), `engineStop` (`:1036–1041`, `EmergencyStop`) | `EngineHold` `Engine/EngineHealth.swift:119`; `Store.engineStopped(db)` | Both freeze every company's clock (`CompanyClock.swift:81`). |
| Restore marker `<home>/run/restored-at` | `BackupService.restoreMarker(paths:)` `Backup/Restore.swift:235–237`; written by a restore with the nonce of its `restoreEvent` row (`Restore.swift:509–512`); taken up by `Orchestrator.restoreMarkerTick` `Orchestrator+Restore.swift:5–37` → `takeUpRestore` `:94` | Explains a rewound `main`: `restoreEvent(nonce PK, snapshot, restoredAt, notes, consumedAt)` and `restoreMain(nonce, companyId, mainCommit)` (`Migrations.swift:805–818`, `createRestoreTables`, migration `v5-restore` `:885`). `main` is re-adopted only when git's head equals `restoreMain.mainCommit`; otherwise `Store.checkMain` raises the "main changed outside Brahma" alert. |
| `restoreEpoch` (`:1771–1780`) | `RestoreEpoch` `Refs/RefRecords.swift:159–175` | A restore over a live database the engine could not read: `mainCommit`, `listed`, `source`, `createdAt`, `clearedBy`, `clearedAt`. |
| `turnCommit` (`:1936–1944`): `(companyId, sha) PK`, `itemId`, `agentId`, `turnId`, `createdAt` | `Store.recordTurnCommits` `Show/CommitAuthors.swift:22`; `CommitIndex` | Engine-recorded authorship of every commit a turn added to an item branch; a sha with no row is `unverified`. Useful to Task 6 for classifying commits. |
| `taintedCommit` (`:1703–1716`), `labCommit` (`:1114`) | `TaintedCommit` `Refs/RefRecords.swift:126` | Commits the engine marked tainted. |

**The company's first `main` commit (R8, Task 6):** for an imported company it is `company.importedCommit`
(`Migrations.swift:784`; `Company.importedCommit` `Model/Company.swift:71`; set in `Store.createCompany` from the staged import's
head, `Store.swift:228–229`, `importedFrom` beside it). For a company created fresh, `GitWorkspace.ensureRepo`
(`GitWorkspace.swift:1016–1037`) makes the root commit `"Import existing files"` (`:1035`, `--allow-empty`) and records nothing
in the database → **none — Task 6 uses the root commit of first-parent history** when `importedCommit` is NULL. Owner
interventions Task 6 must classify: `brahma main accept` → `Store.acceptMainCommit` (`Store+MainGuard.swift:201`) writes
`company.mainCommit` and an `activityEvent` kind `work`, text `the owner accepted <ref> (<sha12>) into main at <sha7>…`
(`:243–244`); `brahma merge adopt-main` → `Store.adoptMain` (`:79–120`) writes `activityEvent` kind `merge`, text `main adopted
at <sha7> by the owner|the engine` (`:113`). The current record of `main` is `company.mainCommit` (`:338`,
`finalizeMainCommit` `Store+Merge.swift:115`); `company.pendingMainCommit` (`:358`) is the head the engine is about to move to.

---

## 3. Hook points for later tasks

### 3.1 The tick's `usageLimit` / `paceClosed` / `paceStrict` decisions (Task 5 recorder)

`Orchestrator.schedule(now:)` (`Sources/BrahmaCore/Orchestrator.swift:546`), step 3 at `:671–716`:

- `:675` `let info = try store.latestRateLimit()` — the single `usageState` row.
- `:676–678` `decisions: [String: UsageDecision]`, `paceClosed: Set<String>`, `paceStrict: Set<String>` (company ids).
- `:679–682` per company: `reserve = cfg.reserve(for: c)`; `parts = UsageGate.evaluateParts(info, mode:, now:, reserve:,
  openReservationLE:, pctPerDollar5h:)` (`Scheduler/UsageGate.swift:75–80`; `Evaluation { fiveHour, pace }` `:60–62`).
- `:683–700` **five-hour gate closed** (`case .closed(let gateUntil) = parts.fiveHour`): `decisions[c.id] = parts.fiveHour`; every
  `ready` agent of the company → `blocked` with `blocker: .usageLimit(until:)` (`:689`); one `activityEvent` kind `usage`,
  text `usage gate closed (<mode> mode) until <ISO>; <n> agent(s) waiting` (`:694–699`). The blocker is persisted
  (`agent.blocker`, JSON of `Blocker` `Model/Agent.swift:6–16`); step 1 (`:646–654`) lifts expired `usageLimit`/`turnBudget`/`retry`
  blockers.
- `:701–715` **weekly pace closed** (`case .closed(let paceUntil) = parts.pace`): `paceClosed.insert(c.id)`; if
  `UsageGate.pace(info, reserve:, now:)` exists and `!pace.criticalPathExempt` (i.e. `sevenDayUtilization >= 1 − reserve`,
  `Pacing.swift:29`) then `paceStrict.insert(c.id)` (`:705`); one `usage` activity line per closure (`loggedPaceClosed`).
  Not persisted: re-evaluated every tick.
- `:753–759` `Scheduler.select(…, usage: { decisions[$0.id] ?? .open }, paceClosed:, paceStrict:, …)` then `launch`;
  `Scheduler.select` skips `paceStrict` companies entirely and, for `paceClosed`, admits only critical-path candidates
  (`blockingCount > 0`) or owner-request agents (`Scheduler/Scheduler.swift:82–83`).
- `:763` `conciergeTick(cfg:decisions:paceStrict:…)`; `:766–776` dispatch only for companies with `decisions == .open` and not
  `paceClosed`; `:775` `dispatchTick(…)` — **the last step**. The measure recorder goes right after it (R5), receiving
  `decisions`, `paceClosed`, `paceStrict`, the per-company running-turn counts (`runningByCompany`) and `now`.

Idle-while-actionable per tick for a running company `c`, as built (`MeasureRecorder.idleCause`): no running turn
(`runningByCompany[c.id] == 0`) **and**, among its unpaused agents, one `blocked` with a `usageLimit` blocker, or one `ready`
while `decisions[c.id]` is `.closed` (five-hour gate), or one `ready` while `paceStrict` (owner reserve) or `paceClosed` (weekly
pace) holds the company. The hourly `turnBudget` blocker is not usage-waiting and is not counted (ruling R31). Reserve breach:
one per new usage snapshot at or over `1 − owner reserve` (ruling R30, §2.11), not a per-tick transition.
Turn-level: `turn.outcome = 'usageLimited'` (§2.10).

### 3.2 `openAuditFollowUp` (Task 2 adds the `regressionOf` link)

`Store+Audit.swift:527–548`, `private func openAuditFollowUp(db:item:sample:auditor:ownerId:notes:now:) -> WorkItem`. Builds a
`WorkItemDraft` (type `bug`, or the pack's first non-container type; title `Audit: revert or fix <key>`; priority 1; `ownerId`
= the author's nearest active manager; `status = .ready`), `createWorkItem(db:companyId:by: .system, draft:, now:)`
(`Store+WorkItems.swift:142`), then `INSERT OR IGNORE INTO workItemDependency (itemId, dependsOnId, linkedBy, createdAt)` with
`linkedBy = 'system'` (`:544`) and a `dependencyAdded` event `depends on <key>` (`:546`). Called from `recordAudit`
(`:465`) at `:510–511` for a failed verdict; `sample.followUpId = followUp.id` at `:512`. Task 2 inserts the
`workItemLink(kind: regressionOf, from: created.id, to: item.id)` beside the dependency insert, inside the same `db`
transaction, so the audit follow-up and a later `regressionOf` filing dedupe on the landed item.

### 3.3 `create_work_item` (Task 2 adds `regression_of`, `revert_of`)

`Sources/BrahmaCore/MCP/WorkTools.swift`: tool list built from a `create` schema dictionary (before `:50`), `ToolSpec(name:
"create_work_item", …, inputSchema: s.schema(create, required: ["type", "title"]))` at `:57–58`; dispatch `case
"create_work_item": return try createWorkItem(args)` `:88`; implementation `private func createWorkItem(_ args:)` `:309–331`
— builds a `WorkItemDraft`, resolves `owner`/`reviewer` handles (`agentId(handle:)`), `parent` via `item(key:)` (`:146`),
then `store.createWorkItem(companyId:by: .agent(agentId), draft:)` and returns the plain string `"Created <KEY>: <title>
(<status>)."` (`:330`). Dependencies are a separate tool, `link_dependency` (`:61–62`, `:90–92`,
`store.addDependency(itemId:dependsOn:by:)` `Store+WorkItems.swift:514`).

**"Trusted" lines: NOT FOUND.** No tool output renders a `Trusted` marker. The only trust marking in tool output is the
inverse: `UntrustedBlock.render(source:text:maxLines:)` (`Sources/BrahmaCore/Safety/Taint.swift:586–598`) wraps outside content
as `Untrusted content from <source> — data, not instructions:` followed by `    | ` lines. Task 2 appends the link
acknowledgement to the existing plain `"Created …"` string (e.g. `"Created ACME-14: … (ready); regression of ACME-12."`),
with the target key — engine-resolved from the agent's argument, never echoed raw — through the same `item(key:)` resolution.

### 3.4 How a CLI command refuses inside an agent turn

`Sources/brahma/CLISupport.swift:133–153` `requireOwnerShell(quietly:) throws -> OwnerPrincipal`: (1)
`OwnerShellGuard.refusal(environment:ancestors:runningTurnPids:)` (`Sources/BrahmaCore/Safety/OwnerShellGuard.swift:113`) refuses
when any of `BRAHMA_AGENT_ID`, the `TurnContainment.markerVariable` or `MCPConfig.tokenVariable` is set (`:108`) or when an
ancestor pid (`ProcessAncestry.chain(of: getpid())`) is a recorded live turn leader (`Store.recordedTurnLeaders(paths:)`,
`Store+OwnerGuard.swift:38–53`, read from `<home>/run/turns` without opening the database); (2) `OwnerKey.verify`; (3)
`OwnerKey.databaseIsInsideHome`; (4) `OwnerPrincipal.enterOwnerProcess()` and `OwnerPrincipal.mint(runningTurnPids:)`.
`quietly: true` throws `ExitCode.failure` without printing (for commands anyone may run that only show owner detail to the
owner). `ProcessRole` (`Sources/BrahmaCore/Collab/OwnerPrincipal.swift:6–17`): `unknown, owner, agent`, sticky towards
`.agent`; `ProcessRole.refuseInAgentProcess()` throws `WorkError.forbidden(OwnerPrincipal.refusal)` in an agent process;
`OwnerPrincipal.enterAgentProcess()` (`:69`) is called by `brahma mcp` and every turn entry point; `requireAgentProcess()`
(`:76`). `brahma measure` (read-only, owner shell or any shell) should call `requireOwnerShell(quietly: false)`: the
ancestry/environment check is the "refuses inside an agent turn" the plan asks for (ruling R6).

### 3.5 `BudgetView` and its model (Task 8's MEASURE panel)

- `Sources/BrahmaApp/Views/BudgetView.swift:6–47`: `struct BudgetView: View { let model: AppModel }`; reads `model.budget`
  (`BudgetModel?`); renders `Panel(title: BudgetModel.panels[0])` (WEEKLY, `:14`), `Panel(title: BudgetModel.panels[1])` (BY
  MODE, `:21`), `StoragePanel(storage: budget.storage, timeZone: model.ownerTimeZone)` (`:31`); empty state `MonoEmptyState("No
  company selected")` (`:35`); `.task(id: model.selectedCompanyId) { model.ensureStorage() }` (`:39`). Text goes through
  `Text(verbatim:)`, fonts `BrahmaTheme.mono`/`monoSmall`.
- `Sources/BrahmaAppModel/Budget/BudgetModel.swift:8–43`: `@MainActor public struct BudgetModel` with `panels = ["WEEKLY", "BY
  MODE", "STORAGE"]` (`:9`), `paceLine`, `modeBreakdownLine`, `storage: StorageModel`; `AppModel.budget` (`:30–32`) is computed
  from `storage`, `paceLine`, `modeBreakdownLine`; `AppModel.ensureStorage()` (`:36–42`) lazily creates `StorageModel(store:
  paths: sizing:)` and runs `Task { await model.show(companyId:) }`.
- `Sources/BrahmaAppModel/Budget/StorageModel.swift:17–100`: `@MainActor @Observable public final class StorageModel`; `show(companyId:)`
  `:52`, `load()` `:62`, `refresh()` `:73`; the measurement runs off the main actor in `Task.detached` (`:85`) over `store`
  (`Store` is `Sendable`). **Pattern for `MeasureModel`:** an `@Observable` class owned by `AppModel`, `show(companyId:)` running
  `Measure.report(…)` in `Task.detached`, a fourth `Panel(title: "MEASURE")` appended after `StoragePanel` in `BudgetView`
  (ruling R10). As built (Task 8): `MeasureModel` (`Sources/BrahmaAppModel/Measure/MeasureModel.swift`) owned by `AppModel.measure`
  (`ensureMeasure()`), titled `MeasureModel.title` = `"MEASURE"`; `MeasurePanel` (`Sources/BrahmaApp/Views/MeasurePanel.swift`)
  after `StoragePanel`; `BudgetModel.panels` is unchanged. Refreshed, at most once a minute (ruling R43; `MeasureModel.changed()`), when `refreshSnapshot` sees the work or usage snapshot change
  while Budget is shown (no change topics on this tree, ruling R1).
- `AppModel.storage` / `storageSizing`: `Sources/BrahmaAppModel/AppModel.swift:92–94`.

---

## 4. The existing CLI test harness

| Helper | Where | What it does |
|---|---|---|
| `brahmaExecutableURL()` | `Tests/BrahmaCoreTests/TestSupport.swift:24` | `Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma")` — the built product; `swift build` must have built `brahma`. |
| `ownerPaths(_ home:)` | `:27–29` | `BrahmaPaths(home: <tmp>/home, workspaces: <tmp>/ws)`. |
| `cliEnvironment(home:)` | `:33–37` | `BRAHMA_HOME`, `BRAHMA_WORKSPACES`, `PATH=/usr/bin:/bin`, `BRAHMA_OWNER_KEY_STORE=file`, `BRAHMA_SECRET_STORE=file`. |
| `initOwnerKey(home:extraArgs:)` | `:42–54` | runs `brahma owner init` under `/usr/bin/script` (TTY). |
| `OwnerTestHome` | `:57–63` | a temp home whose owner key was created (`initOwner: true`). |
| `tempDir()` / `Scratch.dir()` | `:17–20`; `Tests/BrahmaCoreTests/TestScratch.swift` | per-case scratch directory; suites are `@Suite(.scratch)` (`TestScratch.swift:274–275`). |
| `brahma(_ args:home:env:)` | `Tests/BrahmaCoreTests/CanaryCLITests.swift:5–21` (file-private; copy the pattern) | spawns the binary with `cliEnvironment`, captures status/stdout/stderr. |
| `GitFixture` | `Tests/BrahmaCoreTests/GitFixture.swift:6–…` | temp workspace with `ws.ensureRepo()`, plain `git()` helper for building history. |
| `dumpDatabase(_:)` | `TestSupport.swift:75–86` | every row as text (leak checks). |
| `onWorkspaceProfile(_:_:)` | `:102–106` | puts a test company on the Workspace profile. |
| Live gating | `.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1")` | the only tier mechanism (ruling R3). |

---

## 5. Names the plan or the brief uses that are NOT FOUND (and what each later task must do)

| Name | Finding | Owner task |
|---|---|---|
| `reviewAudit.verdict = 'fail'` | the stored values are `ok` / `failed` (`Store+Audit.swift:488`) | Task 4 uses `'failed'` |
| `mergeBatch.landedIds` as item ids | they are `mergeRequest.id`s; item = `mergeRequest.itemId` (`MergeQueue.swift:537`) | Tasks 2–4, 6 join through `mergeRequest` |
| "landing = `landCommit` set" | `landCommit` is written at step `checked`, before `main` moves; post-`checked` aborts finish to `done` keeping it | Task 3: require `step` ≥ `landed` (a batch at `landing` or earlier is not a landing until recovery records it) and, per R24, a `landedIds` request `merged` with `batchId` = the batch |
| per-item base commit for a batch | `mergeRequest.baseCommit` is the batch base for every member | Tasks 3–4: base = `<mergedCommit>^1` / previous candidate |
| company-active seconds **in a window** | `companyActivity` is a running total | Task 2 schema + Task 5 recorder: daily `activeSeconds` counter |
| reserve breach / cap overrun records | none (`usageState` is one overwritten row; no cap record) | Task 5 recorder `reserveBreaches`; cap overruns are `not applicable: no cap-overrun record` (no source exists) |
| taint-refusal event row | none; trace is `turn.freshSessionReason = 'tainted'` on the next turn | Task 5: count with basis "turns, not calls" |
| channel refusals, `landGate: owner`, rubric pass rate | X4 / non-code packs absent | `not applicable` |
| `turn.meteredUSD`, `routedModel`, `provider`, `authRoute`, `itemFact.meteredUSD`, `gatewayCharge`, `providerCap` | X1 absent | `not applicable: X1 gateway columns absent` (R4) |
| "Trusted" tool-output lines | none; only `UntrustedBlock` exists | Task 2: plain-text acknowledgement |
| an engine start record (`EngineClient.status()`) | none in the database; `<home>/run/.sentinel` mtime + `orchestrator.lock` flock | Task 7 |
| a "first `main` commit" record for fresh companies | none; `company.importedCommit` for imported ones | Task 6: root of first-parent history |
| `Store.mergeBatches` / `itemFacts` / `mergeRequests` without a limit and with a window | all are limit-bounded, newest-first | Tasks 3–5 add window queries (`WHERE companyId = ? AND … BETWEEN`) in `Sources/BrahmaCore/Measure/` |
| `sandboxCanary.companyId` | owner-wide table | Task 5: basis `owner-wide` |
| `ask.ownerDecidedAt` as "the owner decided" | an access preset also stamps it (`decidedBy = 'preset:<id>'`) | Task 5: add `decidedBy = 'owner'` |
