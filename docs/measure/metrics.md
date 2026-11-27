# What `brahma measure` measures, exactly

`brahma measure <company> [--since <YYYY-MM-DD|all>] [--format md|json]` prints, for one company and one window, the metrics of
the design spec (§8.6.1 of `docs/superpowers/specs/2026-11-21-any-product-and-hedges-design.md`) plus the owner's additions of
2026-11-24. Every number is read from the engine's own records (the database and the company's workspace repository). Nothing
is estimated, sampled or inferred from text. This page is the definition of record; `measure --format md` links to it.

**Where every name below lives** (table, column, file and line on the current tree): `docs/measure/x6a-inventory.md`.

## Reading a number

- **A number is never shown without its denominator.** A ratio prints as `97.4% (38/39)`; a per-item value as
  `$1.20 per landed item (24.00/20)`; a duration as `median 4m 10s · p95 31m (n=38)`.
- **Status vocabulary.** Each metric carries exactly one:
  - `ok` — measured; the value and its denominator are shown.
  - `insufficient data (n=<n>)` — a **rate** whose denominator has fewer than 20 events. The count is shown, the percentage is
    not. Counts (safety counts, owner minutes) are never "insufficient": a count of 0 prints `0`.
  - `not applicable: <reason>` — the **source does not exist** on this build (a column, table or feature not merged, or a
    company setting that is off, such as no main check). Nothing could have been recorded.
  - `not measured: <reason>` — the source exists but **no data was recorded** (no owner-time log, no baseline company, no
    landing yet in the window, a recorder that was not running).
- **Basis.** Every metric states what it counted and what it left out (for example `basis: landings since vX6a-measure;
  2 landings before links existed excluded`). Rows from before a record existed are excluded with the basis stated, never
  counted as zero.
- **Window.** `--since <date>` is midnight in the owner's time zone (`ownerSettings.timeZone`); the default window is the
  last 28 days and `--since all` starts at `company.createdAt` (both plan X6a pinned numbers: `MeasureWindow.defaultDays`
  = 28; `all` = since the company was created). A metric is windowed on the time its *event* happened: landings
  on the landing time, asks on the decision time, messages on `createdAt`, counters on their day.
- **Scope.** Every query is `WHERE companyId = ?`; git-derived metrics read only the company's own workspace repository
  (`company.workspacePath`). Two companies sharing a history never see each other's rows.

## The vocabulary the metrics share

| Term | Definition (**controller's call**) | Source |
|---|---|---|
| **landing** | one move of `main` by the merge queue: a `mergeBatch` row with `landCommit` set **and** `step` in `landed`, `recorded`, `cleaned`, `done` (a batch at `landing` counts only when git confirms `landCommit` is an ancestor of `main`; one at `checked` has not moved `main` yet). | `mergeBatch.landCommit`, `mergeBatch.step` |
| **landed item** | an item whose merge request is in that batch's `landedIds`: `mergeRequest.itemId` for each id in `landedIds` (`landedIds` hold merge-request ids). The item's own merged commit is `mergeBatch.candidates[requestId]` = `mergeRequest.mergedCommit`. | `mergeBatch.landedIds`, `mergeRequest.itemId`, `mergeRequest.mergedCommit` |
| **landing time** | the landed requests' `mergeRequest.finishedAt` (stamped when the landing is recorded), else `mergeBatch.updatedAt` **(Task 0 proposal, not a controller's call)**. | `mergeRequest.finishedAt`, `mergeBatch.updatedAt` |
| **approval time** | `mergeRequest.enqueuedAt`: an item is queued the moment its review approves it. | `mergeRequest.enqueuedAt` |
| **caught in review** | a `changesRequested` event followed by a later `submitted` event on the same item (a resubmission is a code change: an unchanged worktree commits nothing). Spec §8.6.1's "follow-up changed code covered by the finding" needs path-level findings that reviews do not record yet; until they do, this is the definition. The owner's addition (2026-11-24) narrows the headline to **confirmed** catches, below. | `workItemEvent.kind` = `changesRequested`, `submitted` |
| **confirmed catch** (owner, 11/24) | a caught-in-review sequence whose resubmission was then confirmed by a later passing check on that item: a `verificationRun` for that `itemId` (`purpose` `submit` or `merge`) with `status = 'passed'` finishing after the `submitted` event, **or** a `mergeRun` with `kind = 'item'` and that `itemId` and `status = 'passed'` finishing after it, **or** — when `company.mainCheck` is set — the `mergeRun` with `kind = 'main'` and `status = 'passed'` of the batch that landed the item (`mergeRun.batchId = mergeRequest.batchId`, `mergeRequest.status = 'merged'`) finishing after it. A change request with no later confirmed resubmission is not counted. | `verificationRun.itemId/purpose/status/finishedAt`, `mergeRun.kind/itemId/status/batchId/finishedAt`, `mergeRequest.batchId/status`, `company.mainCheck` |
| **escaped** | a defect found after landing, **keyed to the target item's landing time**: a `regressionOf` link to an item that landed in the window (the link may be created at any time up to now), **plus** a failed audit of an item that landed in the window (`reviewAudit.verdict = 'failed'` — the stored value; auto-merged items that escaped review), **deduplicated by the landed (target) item**: the audit's follow-up item carries a `regressionOf` link to the same item, so one defect counts once. The detail lists the source of each. | `workItemLink.kind = regressionOf` (migration `vX6a-measure`), `reviewAudit.verdict`, `reviewAudit.auditedAt` |
| **revert** | a `revertOf` link to a landed item, **or** an engine-detected exact inverse: the stable patch-id of `git diff <merged> <base>` for landed item L equals the patch-id of `git diff <base'> <merged'>` of a later landed item within the lookback. `base` is the landed commit's first parent (in a batch of several items, the previous candidate), not `mergeRequest.baseCommit`, which is the batch's base. Partial reverts are found only through links. | `workItemLink.kind = revertOf`; git `patch-id --stable` over `mergeRequest.mergedCommit` |
| **owner touch** | an ask the owner decided in the window (`ask.ownerDecidedAt` in the window **and** `ask.decidedBy = 'owner'` — an access preset also stamps `ownerDecidedAt`) **plus** an owner-authored message in the company in the window (`message.senderId = 'owner'`, `message.kind <> 'system'`). | `ask.ownerDecidedAt`, `ask.decidedBy`, `message.senderId`, `message.createdAt` |
| **idle while actionable** | company-active seconds during which the company had no running turn **and** at least one agent was blocked by `usageLimit` or a cap closure, or was ready but held by `paceClosed` / `paceStrict`. Recorded per tick by the measure recorder (there is no such record today). | `measureCounter.idleActionableSeconds` (Task 5), ÷ company-active seconds |
| **company-active seconds** | the engine's awake clock for the company: seconds it was `running` with no engine hold and no emergency stop, at most 60 s per tick gap (`Store.accrueActiveTime`). The database keeps only a running total, so the windowed value is a daily counter the recorder keeps with the same rule; `--since all` reads the total. | `companyActivity.activeSeconds`; `measureCounter.activeSeconds` (Task 5) |

---

## The metrics

### 1. Green-main rate (spec §8.6.1)

| | |
|---|---|
| **Definition** | landings after which the main check passed on the first run ÷ all landings. **Controller's call:** a landing is green when the `main`-kind `mergeRun` for the landed candidate passed at `attempt = 1` and was not flaky, **and** the `mainSmokeRun` with `reason = 'merge'` for `landCommit` (when the company has a main smoke) did not fail. |
| **Numerator** | landings in the window with a `mergeRun` where `batchId = mergeBatch.id`, `kind = 'main'`, `candidateCommit = landCommit`, `attempt = 1`, `status = 'passed'`, `flaky = 0`, and no `mainSmokeRun` with `reason = 'merge'`, `commit = landCommit`, `status = 'failed'`. |
| **Denominator** | landings in the window for which a `main`-kind `mergeRun` exists. A `main` run is recorded only when `company.mainCheck` is set; with no main check configured the metric is `not applicable: no main check configured` and the landings are listed in the detail. A `mainSmokeRun` at `error` (superseded, could not run) says nothing and does not fail the landing. |
| **Source** | `mergeBatch.landCommit/step`, `mergeRun.batchId/kind/candidateCommit/attempt/status/flaky`, `mainSmokeRun.reason/commit/status`, `company.mainCheck`, `company.smokeCheck` |

### 2. Revert rate (spec §8.6.1; owner addition 11/24: 7, 14 and 30 days)

| | |
|---|---|
| **Definition** | landed items whose change was reverted within N days of landing ÷ landed items that have had N days to be reverted. **Headline: 14 days** (spec). **Detail rows: 7 days, 14 days, 30 days, each with its own n.** |
| **Population (N)** | the items landed in the window whose landing time is at least N days before `now`. Numerator and denominator are both taken over this set: an item landed 3 days ago is in neither the 7-day numerator nor the 7-day denominator (it cannot yet have passed the test); the basis states how many were excluded. |
| **Numerator (N)** | items of the population with a `revertOf` link pointing at them whose linked item landed within N days of the landing, or whose landed range is the exact inverse (patch-id) of a later landing within N days. |
| **Denominator (N)** | the population. |
| **Source** | `workItemLink` (`revertOf`), `mergeRequest.mergedCommit`, git `diff`/`patch-id --stable` in the company workspace. Bounded: ≤ 2000 landed items per run, each git call ≤ 10 s. |
| **Status** | `insufficient data (n=…)` below 20 in the denominator; `not measured: no landings old enough` when the denominator is empty. |

### 3. Review catch rate (spec §8.6.1; owner addition 11/24: confirmed catches only)

| | |
|---|---|
| **Definition** | confirmed catches ÷ (confirmed catches + escaped). Spec: "defects caught in review ÷ (caught + escaped)". **Controller's call** on what "caught" means and **owner's call** that only confirmed catches count are in the vocabulary above. |
| **Numerator** | items with at least one confirmed catch whose confirming check finished in the window. One item with three rounds counts once (an item is a defect caught, not a round). |
| **Denominator** | numerator + escaped defects whose **target item landed in the window** (the `regressionOf` link or failed audit may have been recorded at any time up to now; deduplicated by target item). Basis: `escapes found so far`. |
| **Detail** | unconfirmed change requests (a `changesRequested` with no later `submitted` + passing check) are listed with their count and are **not** in the rate; the basis says so. |
| **Source** | `workItemEvent.kind/itemId/createdAt` (`changesRequested`, `submitted`), `verificationRun.itemId/purpose/status/finishedAt`, `mergeRun.kind/itemId/status/finishedAt/batchId`, `mergeRequest.batchId/status`, `company.mainCheck`, `workItemLink`, `reviewAudit.verdict/auditedAt` |
| **Status** | `insufficient data (n=…)` below 20. Catches and escapes from before `vX6a-measure` have no links; the basis states the start of link history. |
| **Basis (clocks)** | the two legs are windowed on different clocks and the basis says so: a **catch** is in the window when its confirming check finished in the window; an **escape** is in the window when its target item landed in the window (whenever the link or failed audit was recorded). |

### 4. Escape rate (spec §8.6.1)

| | |
|---|---|
| **Definition** | escaped defects ÷ landed items. |
| **Numerator** | escaped defects (vocabulary) keyed to the **target item's landing time**: `regressionOf` links and failed audits, whenever recorded up to now, whose target item landed in the window. Basis: `escapes found so far` (an item landed yesterday has had one day to escape; the number can only grow as the window ages). |
| **Denominator** | landed items in the window. |
| **Source** | `workItemLink` (`regressionOf`), `reviewAudit.verdict = 'failed'`, `reviewAudit.auditedAt`, landings |

### 5. Usage per landed item (spec §8.6.1)

| | |
|---|---|
| **Definition** | spend and effort per landed item: `$LE (subscription)` and `$ (gateway)` per landed item, with turns, tokens and awake time. |
| **Denominator (all legs)** | one denominator for the whole metric: landed items in the window that have an `itemFact` row. Items without a fact row (containers, items done before facts existed) are excluded from every leg with the basis stated. |
| **`$LE (subscription)`** | Σ `itemFact.costLE` of those items ÷ the denominator. `itemFact.reviewCostLE` is shown beside it (review turns are not in `costLE`). |
| **`$ (gateway)`** | `not applicable: X1 gateway columns absent` (ruling R4). When X1 lands this leg reads `itemFact.meteredUSD` / `turn.meteredUSD`. |
| **turns** | Σ `itemFact.turnsUsed` ÷ the denominator (work turns: `turn.kind = 'work'`, not infra, not session resets, outcome succeeded or failed). |
| **tokens** | Σ `itemFact.tokensUsed` ÷ the denominator (input + output + cache creation; ultra turns excluded, cache reads excluded). |
| **awake time** | Σ `itemFact.cycleActiveSeconds` ÷ the denominator: **company-active seconds** from first claim to completion, the engine's awake clock, never wall-clock. A never-claimed item has a null value and contributes 0; the basis names how many. |
| **Source** | `itemFact.costLE/reviewCostLE/turnsUsed/tokensUsed/cycleActiveSeconds/completedAt`; landings |

### 6. Owner touches per landed item (spec §8.6.1)

| | |
|---|---|
| **Definition** | Inbox decisions plus owner messages ÷ landed items. |
| **Numerator** | asks with `ownerDecidedAt` in the window and `decidedBy = 'owner'` + messages with `senderId = 'owner'` and `kind <> 'system'` created in the window. The two legs are shown separately in the detail. |
| **Denominator** | landed items in the window. |
| **Source** | `ask.ownerDecidedAt/decidedBy/companyId`, `message.senderId/kind/createdAt/companyId` |
| **Not counted** | policy and preset decisions (`decidedBy` = `policy:…`, `preset:…`), internal approvals (`@handle`), engine-alert acknowledgements (`acknowledgedAt`), owner comments on items (`workItemEvent.actorId = 'owner'` — listed in the detail, not in the rate). |

### 7. First-pass rate (spec §8.6.1)

| | |
|---|---|
| **Definition** | items landed with no check failure and no review rejection ÷ landed. |
| **Numerator** | landed items in the window whose `itemFact.firstPass = 1` (the first conclusive submit check passed without a re-run and no `changesRequested` event). |
| **Denominator** | landed items in the window that have an `itemFact` row. |
| **Source** | `itemFact.firstPass`, `itemFact.failedRuns`, `itemFact.reviewRejections` (shown in the detail) |

### 8. Queue health (spec §8.6.1)

| | |
|---|---|
| **approval → land** | median and p95 (nearest rank) of `mergeRequest.finishedAt − mergeRequest.enqueuedAt` over requests with `status = 'merged'` whose `finishedAt` is in the window; n = that count. **Controller's call:** approval time is `enqueuedAt`. `enqueuedAt` is the merge request's: an owner retry (`brahma merge retry`) leaves the old request as it is (its status unchanged, `retryRequestedAt` stamped) and inserts a fresh request with `enqueuedAt` = the retry time, so approval → land measures the latest enqueue of the item, not its first approval; only requests that reached `merged` are in the sample. |
| **bisect isolations** | batches in the window whose `landedIds` count is smaller than `requestIds` count because a member bounced (`mergeRequest.status = 'bounced'`, `failure` in `itemCheckFailed`, `mainCheckFailed`), ÷ batches in the window. |
| **flake rate** | `mergeRun` rows with `flaky = 1` ÷ finished `mergeRun` rows (`status` in `passed`, `failed`, `timedOut`) with `kind` in `main`, `item`, finishing in the window. |
| **Source** | `mergeRequest.enqueuedAt/finishedAt/status/failure`, `mergeBatch.requestIds/landedIds`, `mergeRun.kind/status/flaky/finishedAt` |

### 9. Safety (spec §8.6.1) — counts with targets, never rates

| Row | Count in the window | Source | Status today |
|---|---|---|---|
| taint refusals | turns whose session was forced fresh after a refused high-risk call under taint: `turn.freshSessionReason = 'tainted'` (**one per refused turn, not per call** — the basis says so) | `turn.freshSessionReason`, `turn.startedAt` | `ok` with basis |
| channel refusals | — | X4 channels not merged | `not applicable: channels (X4) absent` |
| DLP hits | merge requests bounced for a secret: `mergeRequest.failure = 'secretFound'` | `mergeRequest.failure/finishedAt` | `ok` |
| canary passes | `sandboxCanary` rows with `passedAt` in the window — **owner-wide** (the table has no `companyId`; a re-pass overwrites the earlier row for the same key) | `sandboxCanary.passedAt` | `ok`, basis `owner-wide` |
| reserve breaches (target 0) | ticks where the company's weekly utilization reached the owner's reserve (`sevenDayUtilization ≥ 1 − reserve`, the `paceStrict` condition), counted as transitions into that state by the measure recorder | `measureCounter.reserveBreaches` (Task 5) | `not measured: recorder not running` until recorded |
| cap overruns (target 0) | running turns above the company's mode cap at any tick | no record exists; nothing today over-admits by design | `not applicable: no cap-overrun record` unless Task 5 records one |
| access refusals | refused `request_access` calls | `accessRefusal.createdAt/kind` | `ok` (detail row) |

### 10. Non-code acceptance (spec §8.6.1)

| | |
|---|---|
| **Definition (spec)** | owner sign-off rate on `landGate: owner` items; rubric pass rate. |
| **Status** | `not applicable: landGate items and rubric checks absent` — neither exists on this tree (no `landGate` column or setting, no rubric record). |
| **Detail (available, no rate)** | owner-decided gate asks by kind (`ask.kind` in `prd`, `architecture`, `sprintPlan`, `release`; `decidedBy = 'owner'`): approved ÷ decided, as a count pair. Shown as detail, not as the metric. |

### 11. Model ranking per role (spec §8.6.1, decision 20)

| | |
|---|---|
| **Definition** | for each (role, model): first-pass rate, confirmed review catch rate, rework rounds and `$LE` per landed item, each with its denominator. |
| **Attribution** | the landed item's assignee (`itemFact.ownerId` → `agent.role`, `agent.model`); the item's work turns' `turn.modelsUsed` is shown when it names a different model family than `agent.model` (the owner may have changed the agent's model since; `modelsUsed` is cumulative over resumed sessions, so it is shown, not used to split cost). **Routed model and provider: `not applicable: X1 gateway columns absent`.** |
| **Rows** | per (role, model): landed items (n); first-pass (`itemFact.firstPass`); catches confirmed where the agent was the **reviewer** — the landed item's `itemFact.reviewerId` (the item's reviewer at completion; it exists), falling back to the `workItemEvent.actorId` of the item's `reviewApproved` / `changesRequested` events when `reviewerId` is null — ÷ (caught + escaped) for items it reviewed; rework rounds Σ `itemFact.reworkRounds` ÷ n; `$LE` Σ `itemFact.costLE` ÷ n. |
| **Status** | each row carries its own `insufficient data (n=…)` below 20 landed items. |
| **Source** | `itemFact.ownerId/reviewerId/firstPass/reworkRounds/costLE`, `agent.role/model`, `turn.modelsUsed`, `workItemEvent.actorId` |

### 12. Idle while actionable (plan X6a, controller's call)

| | |
|---|---|
| **Definition** | company-active seconds during which the company had no running turn and at least one agent was blocked by `usageLimit` or a cap closure, or ready but held by `paceClosed` / `paceStrict`, ÷ company-active seconds in the window. |
| **Numerator** | Σ `measureCounter.idleActionableSeconds` over days in the window (accrued per tick by the recorder with the engine's own gap rule, ≤ 60 s per tick). |
| **Denominator** | Σ `measureCounter.activeSeconds` over the same days (`companyActivity.activeSeconds` for `--since all`). |
| **Status** | `not measured: recorder not running` when no counter rows exist for the window (the recorder ships with Task 5; days before it are stated in the basis). |
| **Detail** | the share of idle seconds by cause: five-hour gate (`usageLimit`), weekly pace (`paceClosed`), reserve (`paceStrict`). |

### 13. Merged items per dollar and per plan-hour (owner addition 11/24)

| | |
|---|---|
| **items per dollar** | landed items in the window ÷ Σ `itemFact.costLE` of those items, labelled **`$LE (subscription)`**. `$ (gateway)`: `not applicable: X1 gateway columns absent`. With Σ cost = 0 (no fact rows, or facts without cost): `not measured: no cost recorded for the landed items`. Printed as `<n> items per $LE 100 (n/Σ)`. |
| **items per plan-hour** | landed items in the window ÷ company-active hours in the window (`measureCounter.activeSeconds` ÷ 3600; `companyActivity.activeSeconds` for `--since all`). "Plan-hour" is an hour the company was awake under the owner's plan, never wall-clock. With no active-time record for the window: `not measured: no company-active time recorded for the window`. |
| **Source** | landings, `itemFact.costLE`, `measureCounter.activeSeconds`, `companyActivity.activeSeconds` |

### 14. Owner intervention minutes per item (owner addition 11/24)

| | |
|---|---|
| **Definition** | Σ `measureCounter.ownerInterventionSeconds` in the window ÷ 60 ÷ landed items in the window. |
| **Source** | **the owner's own log only**: `brahma measure <co> --log-owner-minutes <n> [--day YYYY-MM-DD]` adds `n × 60` to that day's counter (today in the owner's time zone when `--day` is omitted). |
| **Status** | with no rows in the window: `not measured: no owner-time records`. |
| **Plainly** | Brahma records no owner time on its own and never estimates it. Inbox decisions and messages are counted in metric 6 as touches, not as minutes. If the owner logs nothing, this row says so. |

### 15. Single-agent baseline (owner addition 11/24; spec §8.6.4 "Baselines" is the authority)

`brahma measure <co> --compare <baseline-co>` prints both companies' reports side by side, metric by metric, each with its own
denominator and status. Nothing is normalised or extrapolated; a difference is shown only where both sides are `ok`.

**The owner's procedure** (no script spends usage on the owner's behalf):

1. Create a one-agent company on the same pack and the same repository (`brahma company create … --import <repo>` or the
   app's New company sheet; staff it with one agent).
2. Import the same backlog into it (the same items, same acceptance criteria and checks), so both companies start from the
   same work.
3. Run it under the same pacing preset and billing mode for the same budget or wall-clock span.
4. `brahma measure <co> --compare <baseline-co> --since <the start date>`.

**Status:** a missing baseline company, or one with no landings in the window, prints `not measured: baseline <name> has no
landings in the window` (or `not measured: no company named <name>`). Spec §8.6.4 also names a *single Claude Code session*
baseline; Brahma has no record of such a session, so that comparison is an owner step outside `brahma measure` and is
`not applicable` here.

---

## What is not measured, and why

| Spec item | Status | Why |
|---|---|---|
| `$ (gateway)`, per-provider split, routed-model attribution | `not applicable: X1 gateway columns absent` | `turn.meteredUSD`, `itemFact.meteredUSD`, `turn.routedModel`, `turn.provider`, `turn.authRoute`, `gatewayCharge`, `providerCap` are X1's, not merged (ruling R4). |
| channel refusals | `not applicable` | X4 channels are not merged. |
| non-code acceptance (`landGate: owner`, rubric) | `not applicable` | no such items or checks on this tree. |
| cap overruns | `not applicable` unless recorded | no record; the scheduler never admits above the cap. |
| reserve breaches, idle while actionable, plan-hours in a window | `not measured` until the recorder runs | the database holds only the current usage state and a running active-time total; the measure recorder (Task 5) keeps the daily counters. |
| owner minutes | `not measured` until the owner logs them | Brahma never estimates owner time. |
| single Claude Code session baseline | `not applicable` | no engine record of a session outside Brahma. |
| anything before `vX6a-measure` that needs links | excluded, basis stated | links did not exist; nothing is back-filled or guessed. |
