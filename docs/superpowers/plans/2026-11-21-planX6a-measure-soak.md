# Plan X6a — `brahma measure` and the minimal 72-hour soak harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Execution:** subagent-driven, on a branch cut from `main` after Plans S, R and P are merged. It runs as its own lane beside X1 and X8a (spec §13.4). **Merge order: X1 first.** Tasks 0–4 and 6–8 do not need X1; Task 5 reads X1's columns (`turn.authRoute`, `turn.provider`, `turn.routedModel`, `turn.meteredUSD`, `itemFact.meteredUSD`, `gatewayCharge`, `providerCap`), so it runs after X1 is on `main` and this branch is rebased. Model policy: Fable for implementers and reviews; Opus for the final review. Never Sonnet or Haiku.

**Goal:** Make dogfood #1 measured. `brahma measure <co>` prints the spec's metrics with their denominators from engine records only; `--verify-landings` proves every `main` commit was verified; a soak harness (`--soak-checkpoint`, `--soak-verify`, `--mission`, plus an owner-run 72-hour script) proves an engine `kill -9` and a reboot lose nothing. The app shows the same numbers in a MEASURE panel.

**Architecture:**
- A read-only `Measure` component in `BrahmaDomain` (`Measure/`): one pure function per metric over a `MeasureWindow`, reading through `Store` with `WHERE companyId = ?`, returning `MetricValue`s that always carry numerator, denominator and basis. Git-derived metrics (reverts, the landing audit) use 3a's hardened `GitCommand` through S's `GitHardening`/`ToolPaths` on the engine-owned repository, with `cwd` = the common dir.
- Two small engine-side recorders in a new `MeasureStep` tick participant (R's `TickParticipant`): idle-while-actionable seconds and reserve breaches, which no existing record holds.
- One migration, `"vX6a-measure"`: item links (`regressionOf`, `revertOf`) and daily measure counters.
- The soak harness is a checkpoint/verify pair over engine records and git, run by `brahma measure`, plus an owner script that simulates a crash (SIGKILL of the engine service's pid only, so launchd restarts it) and a reboot.

**Tech Stack:** Swift 6.2 toolchain (manifest `swift-tools-version: 6.0`, `.macOS(.v14)`), SwiftPM, GRDB.swift 7.x, swift-argument-parser 1.5+, Swift Testing, git ≥ 2.43 (`ToolPaths.git`), bash for the owner script.

**Spec:** `docs/superpowers/specs/2026-11-21-any-product-and-hedges-design.md` — decisions 5 and 13, §8.6.1 (metric definitions), §8.6.2 (`brahma measure`), §8.6.5 (`LiveSoak/72h`), §10 rows 1–3, 5 and 12, §12 (Insights › MEASURE), §13.1–§13.3.

**Builds on (merged first), with the names consumed:**
- **Plan S:** `GitHardening`, `ToolPaths.git`, `Spawn` (S3, S5); `safe()` for CLI output; `SafetyLintTests` (no new baseline entry).
- **Plan R:** `BrahmaDomain`, `BrahmaEngine` targets; `TickParticipant`, `TickStepID`, `TickContext`, `TickOrderTests`, `TickGatesTests`; `UsageStep`'s `UsageDecisions`; `EngineService`; `brahma engine serve --unmanaged`, `brahma engine kill`, `brahma engine status` (R Task 17); `BrahmaTestSupport`.
- **Plan P:** `.processTier`/`.liveTier`, `UnitTierHygieneTests`, `TemplateRepo`; `ChangeTopics` (`everyTableMapped`); the CLI tests (`CLITreeFrozenTests`, `CLIHelpTests`, `CLIErrorStyleTests`, `CLIHintTests`); `ScreenInventoryTests`, `ThemeLintTests`, the shared state components; `ScriptedTurnRunner`, `scripts/fake-claude.sh` with `scripts/fake-claude-roles/*`, `scripts/golden-path.sh`.
- **4a / L / 3a records:** `mergeRequest`, `mergeRun` (`kind` main | item | mainAtBase, `attempt`, `flaky`), `mergeBatch` (`landCommit`, `landedIds`), `mainSmokeRun` (`reason` merge), `verificationRun`, `itemFact` (`firstPass`, `reviewRejections`, `costLE`, `cycleActiveSeconds`, `autoMerged`, `auditVerdict`), `workItemEvent` (`changesRequested`, `submitted`, `merged`), `ask` (`ownerDecidedAt`, `decidedBy`), `message`, `turn`, `usageState`, `sandboxCanary`, `accessRefusal`, `release`, `reviewAudit`, `companyActivity`.
- **X1 (Task 5 only):** the columns listed in the header note.

Task 0 records any drift in these names; later tasks use Task 0's names.

## Global Constraints

- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Swift 6, SwiftPM, GRDB, Swift Testing; one `@Suite struct <FileName>` per new test file.
- Core code stays Linux-portable. Child processes only through `Spawn`/`ToolPaths`; engine files only through `EngineFiles`/`Place`; no new `SafetyLintTests` baseline entry; no `try?`/`?? true`/`?? false`/empty `catch` in `Sources/BrahmaDomain/Measure` (added to the `failOpen` zero scope).
- **`measure` is read-only** except the two recorders (Task 5) and the soak checkpoint file the owner names. It changes no scheduling, trust, prompt or decision (like outcome facts).
- **A number is never shown without its denominator.** A rate with fewer than 20 events in its denominator prints `insufficient data (n=<n>)` (spec §8.6.2). A metric whose source does not exist yet prints `not applicable: <reason>` (for example channels before X4).
- Every query is company-scoped. Agent-controlled text (titles, handles) printed by the CLI goes through `safe()`; the app uses `Text(verbatim:)`.
- **Existing CLI commands are unchanged.** New: `brahma measure` (top-level) and `brahma items link` (a new subcommand of the existing items group). Each satisfies P's CLI tests and appends rows to `cli-tree.tsv`. The MCP tool `create_work_item` gains two optional arguments; its existing arguments and outputs are unchanged.
- New tables are mapped in `ChangeTopics.map`. New public names are appended to `public-surface.txt`. App changes use P's components; the inventory baseline changes by additions only, in a commit tagged `approved Plan X spec §12`.
- Tests never touch the Keychain, launchd, the network or a model API. Unit tests spawn no process and bind no port; the soak process test is `.processTier`; `LiveSoak/72h` is owner-run (`.liveTier`).
- Never `pkill`; the harness kills only the engine pid it started, and the owner script only the service pid named in R's `<home>/run/service.lock`. **It does not use `brahma engine kill`**: R defines that as SIGKILL, then `bootout`, then signalling every recorded turn group, which is an owner kill switch, not a crash (launchd would not restart the engine and the turns would die with it).
- Every task ends with `swift build` green and `scripts/test.sh unit` green (Task 7 also `scripts/test.sh process`).
- Every commit message ends with:
  `Co-Authored-By: Claude <your actual model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`

**Pinned numbers:**

| Constant | Value | Owner |
|---|---|---|
| Minimum denominator for a rate | 20 | `MetricValue.minEvents` |
| Default window | last 28 days; `--since all` = since the company was created | `MeasureWindow.defaultDays` |
| Revert lookback | 14 days after landing | `RevertDetector.window` |
| Revert scan bound | ≤ 2000 landed items per run; each git call ≤ 10 s, output ≤ 8 MiB | `RevertDetector.limits` |
| Landing audit bound | ≤ 50 000 first-parent commits | `LandingAudit.maxCommits` |
| Soak verify settle time | the engine must have been running ≥ 300 s awake since its last start | `SoakVerify.settle` |
| Soak stuck-merge threshold | a merge batch in a non-terminal step > 600 s awake | `SoakVerify.stuckMerge` |
| Soak lease recovery | no `inProgress` item without a lease, and no lease held by a killed agent | `SoakVerify` |

## Review Focus

1. **Small or empty denominators**: a company with no landings, a window with 3 items, a metric whose denominator is 0. Expected: `insufficient data (n=…)`, never a percentage, never a crash or NaN. → Task 1 `MetricValueTests.neverDividesByZero`, `insufficientBelowTwenty`.
2. **History from before X6a**: items landed before links existed, turns without X1's columns, merge rows from before 4a's fields. Expected: such rows are excluded with the basis stated (`basis: since vX6a-measure` or `X1 columns absent`), never counted as zero. → Task 4 `ReviewMetricsTests.preLinkHistoryStated`; Task 5 `UsageMetricsTests.preGatewayTurnsExcludedWithBasis`.
3. **A `main` history the audit cannot explain cleanly**: an owner `brahma main accept`, the import commit, a restore from backup that moved `main` back, a merge made outside Brahma. Expected: accept and import are classified as such, a restore is reported as a history change, and only genuinely unverified commits are listed — never a false "100%". → Task 6 `LandingAuditTests` cases.
4. **A `kill -9` in the middle of a merge, a release or a turn.** Expected: after restart and settle, verify passes (journal recovered, release executed once, interrupted turn recorded) or names the exact failed check. → Task 7 `SoakVerifyTests.midMergeKillRecovers`, `duplicateDeployFlagged`; `SoakHarnessProcessTests.killNineThenRecover`.
5. **Cross-company leakage**: `measure acme` counting another company's asks, charges or commits (two companies sharing a repository import). Expected: only `acme`'s rows and `acme`'s workspace repository. → Task 1 `MeasureScopeTests.otherCompanyNeverCounted` (two companies with identical histories, one doubled).

---

## File Structure

```
Sources/BrahmaDomain/Measure/MetricValue.swift        MetricValue, MetricId, MeasureWindow, MeasureReport, rendering (md, json)
Sources/BrahmaDomain/Measure/Measure.swift            Measure.report(store:git:company:window:) — composes the metric functions
Sources/BrahmaDomain/Measure/LandingMetrics.swift     green-main, first-pass, queue health
Sources/BrahmaDomain/Measure/ReviewMetrics.swift      review catch, escape, revert (with RevertDetector)
Sources/BrahmaDomain/Measure/RevertDetector.swift
Sources/BrahmaDomain/Measure/UsageMetrics.swift       usage per landed item, owner touches, safety, non-code, model ranking per role
Sources/BrahmaDomain/Measure/LandingAudit.swift
Sources/BrahmaDomain/Measure/Soak.swift               SoakCheckpoint, SoakVerify, MissionReport
Sources/BrahmaDomain/Work/ItemLinks.swift              workItemLink store API
Sources/BrahmaStore/Migrations.swift                  "vX6a-measure"
Sources/BrahmaEngine/Tick/MeasureStep.swift           idle-while-actionable and reserve-breach recorders
Sources/BrahmaAgentTools/MCP/WorkTools.swift          create_work_item: regression_of, revert_of
Sources/brahma/MeasureCommand.swift, ItemLinkCommand.swift
Sources/BrahmaAppModel/Measure/MeasureModel.swift; Sources/BrahmaApp/Views/MeasurePanel.swift
scripts/soak/run-72h.sh
docs/measure/metrics.md                               exact definitions and sources (owner-facing)
Tests/BrahmaDomainTests/Measure/*Tests.swift, Tests/BrahmaEngineTests/{MeasureStepTests,SoakHarnessProcessTests}.swift, Tests/BrahmaCLITests/{MeasureCommandTests,ItemLinkCommandTests}.swift
Tests/BrahmaTestSupport/MeasureFixtures.swift         builders for landed items, batches, runs, asks, charges
```

---

### Task 0: Re-read S, R and P (and X1 if merged) and write the metric source map

**Files:**
- Create: `.superpowers/sdd/planX6a/inventory.md`, `docs/measure/metrics.md`

**Interfaces:**
- Produces:
  - the inventory: every "Builds on" name marked "as named" or "renamed to …"; where R put the record types; R's `TickOrderTests` list and the proposed `measure` position (after `dispatch`, last); whether X1 and X8a are merged;
  - `docs/measure/metrics.md`: for each metric of spec §8.6.1, its exact definition, numerator, denominator and source tables and columns on merged `main`, with every **controller's call** this plan makes marked (below). This file is the owner-facing definition `measure --format md` links to.
- The controller's calls to record there:
  - **landing** = one move of `main` by the merge queue: a `mergeBatch` row with `landCommit` set; a landed item = an item in that batch's `landedIds`;
  - **green-main** = a landing whose `main`-kind `mergeRun` for the landed candidate passed at `attempt = 1` and not flaky, and whose `mainSmokeRun` with `reason = 'merge'` for `landCommit` (when the company has a main smoke) did not fail;
  - **caught in review** = a `changesRequested` event followed by a later `submitted` event on the same item (a resubmission is a code change: an unchanged worktree commits nothing). Spec §8.6.1's "follow-up changed code covered by the finding" needs path-level findings that reviews do not record yet; the definition says so;
  - **escaped** = a `regressionOf` link to a landed item, created in the window, plus failed audits of landed items (`reviewAudit.verdict = 'fail'`, auto-merged items that escaped verification), **deduplicated by the landed (target) item**: the audit follow-up carries a `regressionOf` link to the same item (Task 2), so one defect counts once. The detail lists the source of each;
  - **approval time** for queue health = `mergeRequest.enqueuedAt` (an item is queued when its review approves it);
  - **revert** = a `revertOf` link, or an engine-detected exact inverse: the stable patch-id of `git diff <merged> <base>` for item L equals that of a later landed item's `git diff <base> <merged>` within 14 days. Partial reverts are found only through links;
  - **owner touch** = an ask with `ownerDecidedAt` in the window plus an owner-authored message in the company in the window;
  - **idle-while-actionable** = company-active seconds during which the company had no running turn and at least one agent blocked by `usageLimit` or a cap closure, or ready but held by `paceClosed`/`paceStrict`, ÷ company-active seconds.

- [ ] **Step 1:** Generate the inventory and the source map on merged `main`. For every source column, run one query on a seeded demo home (`scripts/seed-demo.sh`) and record a row count, so a misnamed column is found now.
- [ ] **Step 2: Commit:** `docs(measure): metric definitions and sources on merged main; X6a inventory`.

---

### Task 1: The metric framework and `brahma measure`

**Files:**
- Create: `Sources/BrahmaDomain/Measure/{MetricValue,Measure}.swift`, `Sources/brahma/MeasureCommand.swift`, `Tests/BrahmaDomainTests/Measure/{MetricValueTests,MeasureScopeTests}.swift`, `Tests/BrahmaCLITests/MeasureCommandTests.swift`, `Tests/BrahmaTestSupport/MeasureFixtures.swift`

**Interfaces:**
- Produces:
  - `public struct MeasureWindow: Codable, Equatable, Sendable { public var since: Date; public var until: Date; public static func parse(_ since: String?, now: Date, companyCreated: Date, tz: TimeZone) throws -> MeasureWindow }` (`YYYY-MM-DD` in the owner's time zone, or `all`).
  - `public struct MetricId: RawRepresentable, Hashable, Codable, Sendable` — the ids `greenMain`, `revertRate`, `reviewCatch`, `escapeRate`, `usagePerLanded`, `ownerTouches`, `firstPass`, `queueHealth`, `safety`, `nonCode`, `modelRanking`, `idleActionable`.
  - `public struct MetricValue: Codable, Equatable, Sendable { public var id: MetricId; public var label: String; public var numerator: Double; public var denominator: Double; public var unit: MetricUnit /* ratio, usd, count, seconds */; public var basis: String; public var detail: [MetricValue]; public var status: MetricStatus /* ok, insufficient(n), notApplicable(reason) */; public static let minEvents = 20; public var display: String { get } }` — `display` is `97.4% (38/39)` for a ratio, `$1.20 per landed item (24.00/20)` for usage, `insufficient data (n=7)`, or `not applicable: <reason>`.
  - `public struct MeasureReport: Codable, Equatable, Sendable { public var companyId: String; public var company: String; public var window: MeasureWindow; public var metrics: [MetricValue]; public var generatedAt: Date; public var brahmaBuild: String; public func markdown() -> String; public func json() throws -> Data }`.
  - `public enum Measure { public static func report(store: Store, git: GitWorkspace, companyId: String, window: MeasureWindow, now: Date) throws -> MeasureReport }` — calls each metric function; Task 1 ships the frame with every metric `notApplicable("not built yet")`, and Tasks 3–5 fill them.
  - CLI: `brahma measure <co> [--since <date|all>] [--format md|json]` (owner shell or any shell: read-only; refuses inside an agent turn because it reads every agent's records).

- [ ] **Step 1: Write the failing tests:**
  - `MetricValueTests.neverDividesByZero` (denominator 0 → `insufficient(0)`), `insufficientBelowTwenty` (19 → insufficient, 20 → ratio), `displayShowsDenominator` (every `ok` ratio display contains `(<num>/<den>)`), `notApplicableHasReason`;
  - `MeasureScopeTests.otherCompanyNeverCounted` (unit tier, store-only fixture with git-derived metrics stubbed: companies `acme` and `zeta` with the same items; `zeta` has twice as many; every metric of `acme` equals the single-company run); its git leg `MeasureScopeGitTests.otherWorkspaceNeverRead` is `.processTier`;
  - `MetricValueTests.countsAreNeverInsufficient` (a count such as cap overruns = 0 displays `0` with its target, never `insufficient data`: `minEvents` applies to rates only);
  - `MeasureCommandTests.markdownAndJSON` (JSON decodes back to the same `MeasureReport`), `sinceParses`, `refusedInsideAgentTurn`, `unknownCompanyIsActionable` (P's error shape).
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement; append the `cli-tree.tsv` row. **Step 4:** Run them and P's CLI tests. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(measure): metric values with denominators, the report frame, brahma measure`.

---

### Task 2: Item links and daily counters (migration `"vX6a-measure"`)

**Files:**
- Modify: `Sources/BrahmaStore/Migrations.swift`, `ChangeTopics.map` (`workItemLink` → `.work`, `measureCounter` → `.usage`), `Sources/BrahmaAgentTools/MCP/WorkTools.swift` (`create_work_item`), the audit follow-up in `Store+Audit` (auto-link)
- Create: `Sources/BrahmaDomain/Work/ItemLinks.swift`, `Sources/brahma/ItemLinkCommand.swift`, `Tests/BrahmaDomainTests/ItemLinksTests.swift`, `Tests/BrahmaCLITests/ItemLinkCommandTests.swift`

**Interfaces:**
- Produces:
  - tables `workItemLink(companyId, itemId, kind TEXT /* regressionOf | revertOf */, targetId, createdBy TEXT, createdAt, PK(itemId, kind, targetId))` and `measureCounter(companyId, name TEXT, day TEXT /* owner-calendar YYYY-MM-DD */, value REAL, PK(companyId, name, day))`;
  - `public enum ItemLinkKind: String, Codable, Sendable { case regressionOf, revertOf }`; `public struct ItemLink: Codable, Equatable, Sendable { itemId, kind: ItemLinkKind, targetId, createdBy: String; createdAt: Date }`;
  - `extension Store { public func linkItem(companyId: String, itemKey: String, kind: ItemLinkKind, targetKey: String, by actor: String, now: Date) throws; public func itemLinks(companyId: String, kind: ItemLinkKind, in window: MeasureWindow) throws -> [ItemLink]; public func addCounter(companyId: String, name: String, day: String, delta: Double) throws; public func counters(companyId: String, name: String, in window: MeasureWindow) throws -> Double }` — `linkItem` refuses a target in another company (not found), a target that never landed (`<KEY> has not landed; only landed items can regress or be reverted`), and a self-link.
  - `create_work_item` gains optional `regression_of` and `revert_of` (item keys); the tool output reports the link in a `Trusted` line; a refused link fails the whole call with the refusal text (nothing created).
  - The audit follow-up item (`openAuditFollowUp`) gets `regressionOf` the audited item, `createdBy = "system"`.
  - CLI: `brahma items link <co> <KEY> regression-of|revert-of <TARGET>` (owner).

- [ ] **Step 1: Write the failing tests:** `ItemLinksTests.linkRoundTrip`, `crossCompanyTargetNotFound`, `unlandedTargetRefused`, `selfLinkRefused`, `auditFollowUpLinksRegression`, `countersSumByWindow`; `WorkToolsTests.createWithRegressionOf` and `refusedLinkCreatesNothing`; `ItemLinkCommandTests.linksAndRefusesInsideAgentTurn`.
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run them, `ChangeTopicsTests`, `StoreMigrationTests`, `ToolOutputTests` (S14) and the unit tier. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(work): regressionOf/revertOf item links and daily measure counters (vX6a-measure)`.

---

### Task 3: Landing metrics — green-main, first-pass, queue health

**Files:**
- Create: `Sources/BrahmaDomain/Measure/LandingMetrics.swift`, `Tests/BrahmaDomainTests/Measure/LandingMetricsTests.swift`

**Interfaces:**
- Produces: `enum LandingMetrics { static func greenMain(_ db: Database, companyId: String, window: MeasureWindow) throws -> MetricValue; static func firstPass(...) -> MetricValue; static func queueHealth(...) -> MetricValue }`.
  - `greenMain`: Task 0's definition; `detail` lists the non-green landings' numbers (`M-<n>` of the batch and why: main run failed, flaky, smoke failed).
  - `firstPass`: `itemFact.firstPass` over items landed in the window.
  - `queueHealth`: `detail` holds median and p95 seconds from `mergeRequest.enqueuedAt` to the batch's `finishedAt` for merged requests (company-active seconds where `companyActivity` allows, else wall seconds with the basis stated), bisect isolations (requests isolated as failing from a batch of ≥ 2), and flake rate (flaky ÷ finished runs over `mergeRun` and `verificationRun`).

- [ ] **Step 1: Write the failing tests** with `MeasureFixtures`: `greenMainCountsFirstAttemptOnly` (a landing whose main run passed at attempt 2 is not green), `flakyMainIsNotGreen`, `failedMergeSmokeIsNotGreen`, `noSmokeConfiguredUsesMainRunOnly`, `firstPassFromFacts`, `queueMedianAndP95` (known durations 1…40 s → median 20.5, p95 38), `bisectIsolationsCounted`, `flakeRateAcrossBothRunTables`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit tier.
- [ ] **Step 5: Commit:** `feat(measure): green-main, first-pass and queue health`.

---

### Task 4: Review, escape and revert metrics

**Files:**
- Create: `Sources/BrahmaDomain/Measure/{ReviewMetrics,RevertDetector}.swift`, `Tests/BrahmaDomainTests/Measure/{ReviewMetricsTests,RevertDetectorTests}.swift`

**Interfaces:**
- Produces:
  - `enum ReviewMetrics { static func reviewCatch(...) -> MetricValue; static func escapeRate(...) -> MetricValue; static func revertRate(..., detector: RevertDetector) -> MetricValue }` — definitions from Task 0; `detail` names each escaped item (`A-12 regressionOf A-7`) and each revert (`A-20 reverts A-9 (exact inverse)` or `(linked)`).
  - `struct RevertDetector { init(git: GitWorkspace, limits: RevertDetector.Limits); func inversePairs(_ landed: [LandedRange]) throws -> [(reverted: String, by: String)] }` with `LandedRange { itemId; base: String; merged: String; landedAt: Date }`. It computes stable patch-ids with `git diff <a> <b> | git patch-id --stable` through `GitCommand` (hardened, `cwd` = the common dir, absolute `ToolPaths.git`), caches them for the run only, and stops at the bounds with `basis: "revert scan stopped at <bound>"`.
  - Basis rule: links count only from the `vX6a-measure` migration date; earlier windows state `basis: links since <date>`.

- [ ] **Step 1: Write the failing tests.** Every test that runs git spawns a process, so it is `.processTier` (`TemplateRepo` fixtures); each has a unit-tier sibling over pure inputs (patch-ids and ranges given as values):
  - `RevertDetectorTests.exactInverseFound`, `partialRevertNotClaimed`, `outsideFourteenDaysIgnored` (`.processTier`); `PatchIdPairingTests.pairsByInverseWithinWindow`, `boundsStopWithBasis` (unit);
  - `ReviewMetricsTests.caughtNeedsResubmission`, `escapedFromLinksAndAudits`, `catchRateFormula` (8 caught, 2 escaped → 80% (8/10) only when n ≥ 20; else insufficient), `preLinkHistoryStated`, `revertLinkedAndDetectedNotDoubleCounted`, `auditAndLinkCountOnce` (a failed audit plus its follow-up's `regressionOf` link → one escape) (unit).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit (and process) tier.
- [ ] **Step 5: Commit:** `feat(measure): review catch, escape and revert rates (links plus exact-inverse detection)`.

---

### Task 5: Usage, owner touches, safety, non-code, model ranking and the `MeasureStep` recorders

**Depends on X1 being merged** (rebase first). If X8a is merged too, its `turn.backend` column is read for the isolation row; otherwise X8a adds that row (see the outline file).

**Files:**
- Create: `Sources/BrahmaDomain/Measure/UsageMetrics.swift`, `Sources/BrahmaEngine/Tick/MeasureStep.swift`, `Tests/BrahmaDomainTests/Measure/UsageMetricsTests.swift`, `Tests/BrahmaEngineTests/MeasureStepTests.swift`
- Modify: R's `TickOrderTests`/`TickGatesTests` literals (`measure` after `dispatch`, gates `[]`: it records even under a stop, because stopped time is not actionable-idle — it only adds when the company is running), `Orchestrator.participants`

**Interfaces:**
- Produces:
  - `enum UsageMetrics { static func usagePerLanded(...) -> MetricValue; static func ownerTouches(...) -> MetricValue; static func safety(...) -> MetricValue; static func nonCode(...) -> MetricValue; static func modelRanking(...) -> MetricValue; static func idleActionable(...) -> MetricValue }`.
    - `usagePerLanded` detail: `$LE (subscription)` = Σ `itemFact.costLE` ÷ landed; `$ (gateway)` = Σ `itemFact.meteredUSD` ÷ landed, split by provider from `gatewayCharge`; turns, tokens and `cycleActiveSeconds` per landed item.
    - `ownerTouches`: (owner-decided asks + owner messages) ÷ landed items.
    - `safety` detail (counts, each with its target): taint refusals (`accessRefusal` plus taint refusal events per Task 0), canary passes and failures (`sandboxCanary`), reserve breaches (counter, target 0), cap overruns (target 0: a (company, provider, day) or (company, provider, month) whose spend exceeded its daily or monthly cap by more than the largest single charge of that period; also `capExceeded` periods), reserve breaches are **owner-wide** (the usage snapshot is the owner's account, not a company's) and shown with that basis in every company's report, wasted turns on rate limits (turns whose stop reason is a rate-limit rejection, target 0), channel refusals and DLP hits `not applicable: no Approved channels (X4)`.
    - `nonCode`: `not applicable: no owner-gated item types (pack schema v2, X3)` until X3; the function is written against `ask.kind`/item type so X3 only adds the source.
    - `modelRanking` (decision 20): per (role, model) where model = `turn.routedModel` with `turn.provider`, or the subscription family from `turn.modelsUsed`: an item is attributed to its owner's role and to the model that ran most of its work turns; per pair, first-pass rate, review catch rate, rework turns per item (`itemFact.reworkRounds` and turns after the first submit), review rejections per item and $ (gateway) or $LE per landed item, each with n (spec §8.6.1); pairs with n < 20 are listed as insufficient.
    - `idleActionable`: counter `idleActionableSeconds` ÷ company-active seconds in the window (`companyActivity`).
  - `final class MeasureStep: TickParticipant` — `id = .measure`; each tick, for each running company: if no turn is running for it and (`UsageDecisions` closed it, or any agent is blocked with `usageLimit`/a cap closure, or a ready agent is in `paceClosed`/`paceStrict`), add the tick's company-active delta to `idleActionableSeconds`; when the latest `usageState` snapshot is new (by `observedAt`) and `sevenDayUtilization ≥ 1 − effective reserve`, add 1 to the owner-wide counter `reserveBreaches` (company id `""`).

- [ ] **Step 1: Write the failing tests:** `UsageMetricsTests.splitsSubscriptionAndGateway`, `ownerTouchesCountsDecisionsAndMessages`, `capOverrunBeyondOneChargeOnly` (a day at cap + one charge's worth is `capExceeded`, not an overrun), `rateLimitWastedTurnsCounted`, `channelsNotApplicable`, `modelRankingAttributesByMajority`, `preGatewayTurnsExcludedWithBasis`; `MeasureStepTests.accruesOnlyWhenActionable` (gate closed with a blocked agent → accrues; gate closed with nobody waiting → does not), `breachCountedOncePerSnapshot`, `stoppedCompanyDoesNotAccrue`, R's `TickOrderTests.orderIsPinned` updated (ruling in the commit).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit tier.
- [ ] **Step 5: Commit:** `feat(measure): usage per landed item, owner touches, safety, model ranking per role; idle-while-actionable and reserve-breach recorders`.

---

### Task 6: The landing audit — `brahma measure <co> --verify-landings`

**Files:**
- Create: `Sources/BrahmaDomain/Measure/LandingAudit.swift`, `Tests/BrahmaDomainTests/Measure/LandingAuditTests.swift`
- Modify: `MeasureCommand.swift` (`--verify-landings`; exit 0 when every commit is classified as verified, accepted or imported; exit 1 otherwise)

**Interfaces:**
- Produces:
  - `public struct LandingAudit { public static func run(store: Store, git: GitWorkspace, companyId: String, since: Date?) throws -> LandingAuditResult }`.
  - `public struct LandingAuditResult: Codable, Equatable, Sendable { public var commits: Int; public var verified: Int /* a commit the merge queue landed: any request candidate in a landed batch's candidates[landedIds] (4a fast-forwards main through each of them) or its landCommit, with a passed run for that batch */; public var ownerAccepted: [String] /* main accept records */; public var imported: [String] /* the import or initial commit */; public var unverified: [String]; public var historyChanged: [String] /* restore markers that moved main back */; public var truncatedAt: Int? }`.
  - Walk: `git rev-list --first-parent <main tip>` back to the company's first `main` commit (Task 0 names the record), at most `LandingAudit.maxCommits`.
  - Output: `landings verified: 100% (412/412); owner-accepted 2; imported 1` or the list of unverified commits (short sha and subject through `safe()`).

- [ ] **Step 1: Write the failing tests** (`TemplateRepo` fixtures driven through the store builders): `allQueueLandingsVerified`, `ownerAcceptClassified`, `importCommitClassified`, `outsideCommitIsUnverified` (a commit made directly on `main` in the fixture repo), `restoreReported`, `boundStated`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. `LandingAuditTests` run git, so they are `.processTier`; `LandingClassificationTests` (unit) classifies given commit lists against store records, including `batchOfThreeAllVerified` (every intermediate candidate of a three-item batch is verified).
- [ ] **Step 5: Commit:** `feat(measure): landing audit (--verify-landings) over first-parent main`.

---

### Task 7: The soak harness — checkpoint, verify, mission report and the 72-hour script

**Files:**
- Create: `Sources/BrahmaDomain/Measure/Soak.swift`, `scripts/soak/run-72h.sh`, `Tests/BrahmaDomainTests/Measure/SoakVerifyTests.swift`, `Tests/BrahmaEngineTests/SoakHarnessProcessTests.swift` (`.processTier`)
- Modify: `MeasureCommand.swift` (`--soak-checkpoint <file>`, `--soak-verify <file>`, `--mission`)

**Interfaces:**
- Produces:
  - `public struct SoakCheckpoint: Codable, Equatable, Sendable { public var companyId: String; public var takenAt: Date; public var mainTip: String; public var itemHeads: [String: String] /* item key → branch head */; public var verifiedCommits: [String: String] /* item key → verifiedCommit */; public var leases: [String: String] /* item key → agent id */; public var releaseExecutions: [String: Int] /* release id → times executed */; public var openBatches: [String]; public var engineStartedAt: Date? }` with `static func take(store:git:companyId:now:) throws -> SoakCheckpoint`. The file is written 0600 through `EngineFiles` rooted at the `Place` of the owner-named directory (as R writes the LaunchAgent plist).
  - `public struct SoakVerify { public static func run(_ before: SoakCheckpoint, store: Store, git: GitWorkspace, now: Date, engineStartedAt: Date?) throws -> SoakVerdict }` — the CLI reads `engineStartedAt` from R's `EngineStatusReport.startedAt` through `EngineClient.status()`; with no service answering, the verdict is `wait`. Settle is measured as wall seconds since that start (the owner script keeps the Mac awake with `caffeinate -i` for the run) with `SoakVerdict { checks: [SoakCheck]; passed: Bool }` and these checks, each pass/fail with a detail:
    1. `settled`: the engine has run ≥ 300 s awake since its last start (else the verdict is `wait`, not fail);
    2. `noLostCommits`: every commit in `mainTip`, `itemHeads` and `verifiedCommits` still exists (`git cat-file -e`), and `main` contains the old `mainTip` (not rewound) unless a restore marker explains it;
    3. `leasesRecovered`: no `inProgress` item without a lease; no lease held by a killed agent; every lease of the checkpoint is either still held by the same live agent or released with the item back to `ready`;
    4. `noStuckMerges`: no `mergeBatch` in a non-terminal step longer than 600 s awake;
    5. `noDuplicateOutsideActions`: no release executed more than once (from L's release records); channel actions `not applicable` until X4;
    6. `interruptedTurnsRecorded`: every turn that was running at the kill has an end row (`interrupted` or `failed`) and no agent is stuck `running` without a live process record;
    7. `companyRunning`: the company is `running` and has started at least one turn since the restart, with no new owner ask about recovery (an engine hold or a restore prompt) — "no owner touch beyond login".
  - `public struct MissionReport { public static func make(store: Store, companyId: String, window: MeasureWindow) throws -> MeasureReport }` — the mission subset: items landed, owner touches, usage per landed item, green-main, wasted rate-limit turns, reserve breaches, idle-while-actionable (spec §10 row 5 (2)).
  - `scripts/soak/run-72h.sh <co> [--hours 72] [--kill-at <h>] [--state <file>]` (owner-run; never run by tests): checks `brahma engine status` is the launchd service; takes an hourly `--soak-checkpoint`; at `--kill-at` (default 24) sends SIGKILL to the pid in `<home>/run/service.lock` only (a crash: launchd's `KeepAlive {SuccessfulExit false}` restarts the service; turn processes in their own sessions are reaped by R's recovery) and, after settle, `--soak-verify`; at hour 48 prints "Reboot the Mac now, log in, and run: scripts/soak/run-72h.sh <co> --resume --state <file>" and exits; on `--resume` verifies against the last checkpoint and continues; at the end prints `--mission` and every verdict. It writes only under the `--state` directory and kills nothing except that one pid, after checking it is the `brahma engine serve` process.

- [ ] **Step 1: Write the failing tests:**
  - `SoakVerifyTests` (store fixtures; the `noLostCommits` cases run git and are `.processTier`, the rest are unit tier with the git answers given as values): `cleanRestartPasses`, `missingCommitFails`, `rewoundMainFails`, `restoreExplainsRewind`, `orphanInProgressFails`, `killedHolderLeaseFails`, `midMergeKillRecovers` (batch journaled at `prepared`, then terminal after recovery → pass), `stuckBatchFails`, `duplicateDeployFlagged`, `notSettledIsWait`.
  - `SoakHarnessProcessTests.killNineThenRecover` (`.processTier`): a temp home under a short root with `BRAHMA_OWNER_KEY_STORE=file`, `BRAHMA_SECRET_STORE=memory`; P's fake-claude role scripts; start `brahma engine serve --unmanaged` through `Spawn` and record its pid; wait until A-1 is `inProgress` with a lease and a commit on its branch; `--soak-checkpoint`; send SIGKILL to **that pid only**; start `serve --unmanaged` again; advance until settle (the test lowers `SoakVerify.settle` through an environment override available only in DEBUG builds); `--soak-verify` → every check passes; stop the engine with `brahma engine stop`.
  - `MeasureCommandTests.missionPrintsSubset`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement; run `shellcheck scripts/soak/run-72h.sh` if installed. **Step 4:** PASS with the unit and process tiers.
- [ ] **Step 5: Commit:** `feat(measure): soak checkpoint/verify, mission report and the owner-run 72-hour script`.

---

### Task 8: App MEASURE panel and docs

**Files:**
- Create: `Sources/BrahmaAppModel/Measure/MeasureModel.swift`, `Sources/BrahmaApp/Views/MeasurePanel.swift`, `Tests/BrahmaAppModelTests/MeasureModelTests.swift`
- Modify: the Work › Budget screen (MEASURE panel after the existing panels; there is no Insights screen yet, and P froze the sidebar — **controller's call, flagged for a ruling**: spec §5 places measurement under Insights, which does not exist; the panel lives on Budget, the nearest read-only numbers screen, until an Insights screen is approved), P's inventory fixtures (additions only), `README.md` ("Measuring a company": `brahma measure`, `--verify-landings`, the soak script)

**Interfaces:**
- Produces: `@MainActor @Observable final class MeasureModel { var report: MeasureReport?; var window: MeasureWindow; func load() async; var errorMessage: String? }` — the report is computed off the main actor with the same `Measure.report`; refreshed on P's `work` and `usage` change topics.
- The panel: a zebra table, one row per metric with its `display` string verbatim (so the denominator is always visible), detail rows expandable, a window picker (7 / 28 days / all), and "insufficient data" in `text2`. Uses `LoadingState`/`EmptyState`/`ErrorState`.

- [ ] **Step 1: Write `MeasureModelTests`:** `displaysDenominators`, `refreshesOnTopics`, `errorShowsCLIText`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement with P's components.
- [ ] **Step 4:** `scripts/make-app.sh debug`, `scripts/ui-inventory.sh` diff (only the new panel), baseline update in a commit tagged `approved Plan X spec §12`; UI snapshot of Budget, read it; `ThemeLintTests`, `ScreenInventoryTests`, the unit tier. Then the final review (Opus) of the branch against spec §8.6, the Review Focus and decisions 5 and 13.
- [ ] **Step 5: Commit:** `feat(app): MEASURE panel on Budget; docs for measure and the soak`.

---

## §10 rows delivered by X6a (final ids)

| Row | Criterion | Task |
|---|---|---|
| 1 (2)(3) | `measure` shows cap overruns = 0 and reserve breaches = 0 | X6a-T5 |
| 2 (2)(3) | green-main rate; `measure --verify-landings` 100% | X6a-T3, T6 |
| 3 (1)(2)(3) | idle-while-actionable ≤ 5%, cap overruns = 0, wasted rate-limit turns = 0 | X6a-T5 (recorders and metrics) |
| 5 (1)(2) | `LiveSoak/72h` (kill -9 and reboot) and the mission report | X6a-T7 |
| 5 (3) | share of turns in a VM and Seatbelt-fallback turns | X8a-T10 adds the row through `MetricValue` |
| 7 (2) | walkthrough coverage | X9 adds the row through `MetricValue` |
| 8 (3) | PR first-push CI pass rate | X5 adds the row |
| 12 (4) | model ranking per role | X6a-T5 |

## Self-review notes

- **Spec coverage:** §8.6.1 metrics: green-main T3; revert, review catch, escape T4; usage, owner touches, safety, non-code, model ranking T5; first-pass, queue health T3. §8.6.2 command, denominators, insufficient data: T1. `--verify-landings` (row 2 (3)): T6. Minimal 72-hour soak harness (§13.1 X6a): T7. Insights › MEASURE: T8 (on Budget, controller's call). Bench, adaptive batch, backlog mirror, comparison probes: X6b.
- **Type consistency:** `MetricValue`/`MeasureWindow`/`MeasureReport` (T1) are used by T3–T8; `ItemLinkKind` and `measureCounter` (T2) are read by T4 and T5; `LandedRange` (T4) comes from T3's landing query; `SoakCheckpoint`/`SoakVerdict` (T7) are what the CLI flags read and write.
- **Effort:** 9 tasks (T0–T8). M: T4, T5, T7. S: T0, T1, T2, T3, T6, T8. About 5–6 implementer-days subagent-driven; one calendar week. Larger than the spec's "~6" because the links, the recorders and the app panel are separate gates.
