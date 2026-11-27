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
| **landing** | one move of `main` by the merge queue: a `mergeBatch` row with `landCommit` set **and** `step` in `landed`, `recorded`, `cleaned`, `done` **and** at least one landed item. A batch at `landing` or any earlier step is **not** a landing, even when `main` already holds its `landCommit` (`checked` has not moved `main` yet; at `landing` the move may not have been recorded): recovery (`repairUnrecordedLandings`, run when the owner resumes the merge queue, or the engine's own journal recovery finishing the batch) records it as `landed`, and from then it is a landing. **Ruling R24:** a **landed item** is a `landedIds` request with `mergeRequest.status = 'merged'` **and** `mergeRequest.batchId` = that batch. `landCommit`/`landedIds` are written at `checked`, and the abort paths after it (stopped, main moved, blocked, off main, a git error, recovery abandoning the batch) finish the batch to `done` with both still set and requeue its requests (same ids); such a batch has no merged request of its own and is not a landing, and a requeued request lands once, in the batch that merged it. `mergeBatch.error IS NULL` is not used as a filter (an inconclusive result sets it after a real landing). | `mergeBatch.landCommit`, `mergeBatch.step`, `mergeBatch.landedIds`, `mergeRequest.status/batchId` |
| **landed item** | an item whose merge request is in that batch's `landedIds` **and** that the batch merged (ruling R24): `mergeRequest.itemId` for each id in `landedIds` (`landedIds` hold merge-request ids) whose request has `mergeRequest.status = 'merged'` **and** `mergeRequest.batchId` = that batch. A request in `landedIds` that was requeued from an aborted batch is not that batch's landed item. The item's own merged commit is `mergeBatch.candidates[requestId]` = `mergeRequest.mergedCommit`. | `mergeBatch.landedIds`, `mergeRequest.itemId`, `mergeRequest.status/batchId`, `mergeRequest.mergedCommit` |
| **landing time** | the landed requests' `mergeRequest.finishedAt` (stamped when the landing is recorded), else `mergeBatch.updatedAt` **(Task 0 proposal, not a controller's call)**. | `mergeRequest.finishedAt`, `mergeBatch.updatedAt` |
| **approval time** | `mergeRequest.enqueuedAt`: an item is queued the moment its review approves it. | `mergeRequest.enqueuedAt` |
| **caught in review** | a `changesRequested` event followed by a later `submitted` event on the same item (a resubmission is a code change: an unchanged worktree commits nothing). Spec §8.6.1's "follow-up changed code covered by the finding" needs path-level findings that reviews do not record yet; until they do, this is the definition. The owner's addition (2026-11-24) narrows the headline to **confirmed** catches, below. | `workItemEvent.kind` = `changesRequested`, `submitted` |
| **confirmed catch** (owner, 11/24) | a caught-in-review sequence whose resubmission was then confirmed by a later passing check on that item: a `verificationRun` for that `itemId` (`purpose` `submit` or `merge`) with `status = 'passed'` finishing after the `submitted` event, **or** a `mergeRun` with `kind = 'item'` and that `itemId` and `status = 'passed'` finishing after it, **or** a passed `main`-kind `mergeRun` of the batch that merged the item, at that batch's `landCommit` (`mergeRun.batchId = mergeRequest.batchId`, `mergeRequest.status = 'merged'`, `mergeRun.candidateCommit = mergeBatch.landCommit`, `status = 'passed'`) finishing after it. That main run confirms the catch **whether or not `company.mainCheck` is set now**: main runs exist only while it was set, so the runs are the record, not the current setting (rulings R23, R26). A change request with no later confirmed resubmission is not counted. | `verificationRun.itemId/purpose/status/finishedAt`, `mergeRun.kind/itemId/status/batchId/candidateCommit/finishedAt`, `mergeRequest.batchId/status`, `mergeBatch.landCommit` |
| **escaped** | a defect found after landing, **keyed to the target item's landing time**: a `regressionOf` link to an item that landed in the window (the link may be created at any time up to now), **plus** a failed audit of an item that landed in the window (`reviewAudit.verdict = 'failed'` — the stored value; auto-merged items that escaped review), **deduplicated by the landed (target) item**: the audit's follow-up item carries a `regressionOf` link to the same item, so one defect counts once. The detail lists the source of each. | `workItemLink.kind = regressionOf` (migration `vX6a-measure`), `reviewAudit.verdict`, `reviewAudit.auditedAt` |
| **revert** | a `revertOf` link to a landed item, **or** an engine-detected exact inverse: the stable patch-id of `git diff <merged> <base>` for landed item L equals the patch-id of `git diff <base'> <merged'>` of a later landed item within the lookback. `base` is the landed commit's first parent (in a batch of several items, the previous candidate), not `mergeRequest.baseCommit`, which is the batch's base. Partial reverts are found only through links. | `workItemLink.kind = revertOf`; git `patch-id --stable` over `mergeRequest.mergedCommit` |
| **owner touch** | an ask the owner decided in the window (`ask.ownerDecidedAt` in the window **and** `ask.decidedBy = 'owner'` — an access preset also stamps `ownerDecidedAt`) **plus** an owner-authored message in the company in the window (`message.senderId = 'owner'`, `message.kind <> 'system'`). | `ask.ownerDecidedAt`, `ask.decidedBy`, `message.senderId`, `message.createdAt` |
| **idle while actionable** | company-active seconds during which the company had no running turn **and** at least one awake (not paused) agent waited on usage: blocked by `usageLimit` (the five-hour gate), ready while that gate is closed, or ready but held by `paceClosed` (weekly pace) / `paceStrict` (owner reserve). Cap closures are X1's and absent. The hourly `turnBudget` blocker is **not** usage-waiting and is not counted (ruling R31). Recorded per tick by the measure recorder. | `measureCounter.idleActionableSeconds` (Task 5), ÷ company-active seconds |
| **company-active seconds** | the engine's awake clock for the company: seconds it was `running` with no engine hold and no emergency stop, at most 60 s per tick gap (`Store.accrueActiveTime`). The database keeps only a running total, so the windowed value is a daily counter the recorder keeps with the same rule; every window, `--since all` included, reads the daily counters only (ruling R31), so time from before the recorder first ran is never counted. | `measureCounter.activeSeconds` (Task 5); `companyActivity.activeSeconds` is the engine's running total, not read by `measure` |

---

## The metrics

### 1. Green-main rate (spec §8.6.1)

| | |
|---|---|
| **Definition** | landings after which the main check passed on the first run ÷ landings judged. **Controller's call (rulings R17, R23):** a landing is judged by the runs **at its land commit** (`candidateCommit = landCommit`; a bisected batch's runs at other candidates never judge it): (1) when the batch has `main`-kind `mergeRun`s (recorded only while `company.mainCheck` is set), by the `main` run at the land commit; (2) else by the batch's own verification — the `item`-kind `mergeRun`s at the land commit for the landed requests (a landed item with no check of its own is not evidence). Either way a run is green only when `attempt = 1` passed, was not flaky, and no later attempt passed (the merge queue records every passing re-run flagged flaky); **and** no `mainSmokeRun` with `reason = 'merge'` for `landCommit` failed. `mainAtBase` runs never judge a landing. |
| **Numerator** | judged landings in the window whose runs at the land commit (main, else item) all passed at `attempt = 1`, un-flaky, with no passing re-run, and with no `mainSmokeRun` where `reason = 'merge'`, `commit = landCommit`, `status = 'failed'`. |
| **Denominator** | landings in the window with a `main`-kind `mergeRun`, else at least one `item`-kind `mergeRun` at the land commit. A landing with neither is excluded and counted in the basis; with no landing judged the metric is `not measured: no check run recorded …`. A batch with main runs but none at the land commit is judged not green and named in the detail. The basis names the source (`main check runs`, `no main check run recorded; verification runs (item checks at the land commit)`, or the split) — from the runs, never from the company's current `mainCheck` setting. A `mainSmokeRun` at `error` (superseded, could not run) says nothing and does not fail the landing. Detail: one row per non-green landing, value 1, labelled `M-<n>: <why>`. |
| **Source** | `mergeBatch.landCommit/step/landedIds`, `mergeRequest.status/batchId`, `mergeRun.batchId/requestId/kind/candidateCommit/attempt/status/flaky`, `mainSmokeRun.reason/commit/status` |

### 2. Revert rate (spec §8.6.1; owner addition 11/24: 7, 14 and 30 days)

| | |
|---|---|
| **Definition** | landed items whose change was reverted within N days of landing ÷ landed items that have had N days to be reverted. **Headline: 14 days** (spec). **Detail rows: 7 days, 14 days, 30 days, each with its own n.** |
| **Population (N)** | the items landed in the window whose landing time is at least N days before `now`. Numerator and denominator are both taken over this set: an item landed 3 days ago is in neither the 7-day numerator nor the 7-day denominator (it cannot yet have passed the test); the basis states how many were excluded. |
| **Numerator (N)** | items of the population with a `revertOf` link pointing at them whose linked item landed within N days of the landing, or whose landed range is the exact inverse (patch-id) of a later landing within N days. |
| **Denominator (N)** | the population. |
| **Source** | `workItemLink` (`revertOf`), `mergeRequest.mergedCommit`, git `diff`/`patch-id --stable` in the company workspace. Bounded: ≤ 2000 landed items per run, each git call ≤ 10 s. |
| **Status** | `insufficient data (n=…)` below 20 in the denominator. With no landing in the window: `not measured: no landings in the window`. A row whose population is empty says why (ruling R28): `not measured: no landings at least <N> d old in the window (window starts <date>)`, or `not measured: no readable landings at least <N> d old (<k> excluded)` when git could not read them. **The 30-day row needs a window of at least 30 days** (`--since` a date 30 or more days back, or `--since all`): with the default 28-day window no landing in it can be 30 days old, so the 30 d row is always `not measured` and says so. Items whose commits git could not read, without a merged commit, or past the scan bound are left out of every row with the basis saying how many. |

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
| **approval → land** | median and p95 (nearest rank) of `mergeRequest.finishedAt − mergeRequest.enqueuedAt` over the landed items (requests `merged` by that batch, ruling R24) of the landings in the window — the landing is windowed on the batch's `finishedAt` (else `updatedAt`), the duration ends at the request's `finishedAt` (else the batch's); n = that count, less any request enqueued after its landing (excluded and counted, never clamped). **Controller's call:** approval time is `enqueuedAt`. `enqueuedAt` is the merge request's: an owner retry (`brahma merge retry`) leaves the old request as it is (its status unchanged, `retryRequestedAt` stamped) and inserts a fresh request with `enqueuedAt` = the retry time, so approval → land measures the latest enqueue of the item, not its first approval; only requests that reached `merged` are in the sample. |
| **bisect isolations** | a count: requests bounced (`mergeRequest.status = 'bounced'`, `failure` in `itemCheckFailed`, `mainCheckFailed`) with `finishedAt` (the bounce time) in the window, from a batch of **≥ 2 checked candidates** (`mergeBatch.candidates`, written at `rebased` for the members that rebased cleanly — not `requestIds`, which also holds requests bounced on a conflict before any check). A request bounced from a batch of one checked candidate is not an isolation and is counted in the basis. |
| **flake rate** | flaky ÷ finished runs (`status` in `passed`, `failed`, `timedOut`) finishing in the window, over **both** run tables: `mergeRun` with `kind` in `main`, `item` (never `mainAtBase`) **plus** `verificationRun`; the basis shows each table's flaky/finished pair. |
| **Headline and windowing** | the headline is the count of merged requests of the landings in the window. Landings are windowed on the batch's `finishedAt` (else `updatedAt`); the approval → land durations end at each request's own `finishedAt` (else the batch's). Wall seconds, with the basis saying why (ruling R22). |
| **Source** | `mergeRequest.enqueuedAt/finishedAt/status/failure/batchId`, `mergeBatch.candidates/landedIds/finishedAt`, `mergeRun.kind/status/flaky/finishedAt`, `verificationRun.status/flaky/finishedAt` |

### 9. Safety (spec §8.6.1) — counts with targets, never rates

| Row | Count in the window | Source | Status today |
|---|---|---|---|
| taint refusals | turns whose session was forced fresh after a refused high-risk call under taint: `turn.freshSessionReason = 'tainted'` (**one per refused turn, not per call** — the basis says so) | `turn.freshSessionReason`, `turn.startedAt` | `ok` with basis |
| channel refusals | — | X4 channels not merged | `not applicable: channels (X4) absent` |
| DLP hits | merge requests bounced for a secret: `mergeRequest.failure = 'secretFound'` | `mergeRequest.failure/finishedAt` | `ok` |
| canary passes | `sandboxCanary` rows with `passedAt` in the window — **owner-wide** (the table has no `companyId`; a re-pass overwrites the earlier row for the same key) | `sandboxCanary.passedAt` | `ok`, basis `owner-wide` |
| reserve breaches (target 0) | **one per new usage snapshot** of the owner's account observed at or over the owner reserve line (`sevenDayUtilization ≥ 1 − reserve`, the `paceStrict` condition), judged once per snapshot by the measure recorder on the day the snapshot was observed (ruling R30). The reserve is the **owner-wide** one (`SchedulerConfig.ownerReserve`), not a company's override, and the count is **owner-wide** (the usage snapshot is the owner's account): every company's report shows the same number, basis `owner-wide`. Snapshots observed before the recorder first ran are not counted. The count scales with how often usage is observed; the target is 0 either way. | `measureCounter.reserveBreaches` under company id `""` (Task 5), `measureEpoch` (`recorder`, `usageSnapshotJudged`) | `ok` once the recorder has run; `not measured: recorder not running` before |
| cap overruns (target 0) | running turns above the company's mode cap at any tick | no record exists; nothing today over-admits by design | `not applicable: no cap-overrun record` unless Task 5 records one |
| access refusals | refused `request_access` calls | `accessRefusal.createdAt/kind` | `ok` (detail row) |
| turns wasted on rate limits (target 0) | turns that ended `usageLimited` | `turn.outcome`, `turn.startedAt` | `ok` |

The headline of Safety is the sum of the measured target-0 rows (turns wasted on rate limits + reserve breaches), shown as a count with target 0; the other rows are counts without a target.

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
| **Attribution** | **role:** the landed item's assignee's role (`itemFact.ownerId` → `agent.role`; an item with no assignee recorded is excluded with the basis saying how many). **Model:** the **majority family** (`haiku`, `sonnet`, `opus`) of the item's counted work turns' `turn.modelsUsed` — one family per turn (a background `haiku` beside another family is not counted; a turn naming several main families, cumulative over `--resume`, names none). Two families tied for most turns, or turns that named models but no single family: **no majority**, the item is **excluded** and the basis says how many. **Only when no turn names any model** is the agent's current `agent.model` used (the basis counts these); an `auto` agent then has no model and the item is excluded with a basis. A review is attributed the same way from the reviewer's own turns on the item. **Routed model and provider: `not applicable: X1 gateway columns absent`** (ruling R4). |
| **Rows** | per (role, model): landed items (n); first-pass (`itemFact.firstPass`); rework rounds Σ `itemFact.reworkRounds` ÷ n; **review rejections per item** Σ `itemFact.reviewRejections` ÷ n; **turns after first submit** — counted work turns started after the item's first `submitted` event ÷ n; `$LE (subscription)` Σ `itemFact.costLE` ÷ n; and, for the pair as **reviewer**, confirmed catches ÷ (caught + escaped) over the items it reviewed — the landed item's `itemFact.reviewerId` (the item's reviewer at completion), falling back to the `workItemEvent.actorId` of the item's `reviewApproved` / `changesRequested` events when `reviewerId` is null. |
| **Status** | each row carries its own `insufficient data (n=…)` below 20 landed items. |
| **Source** | `itemFact.ownerId/reviewerId/firstPass/reworkRounds/reviewRejections/costLE`, `agent.role/model`, `turn.modelsUsed/kind/startedAt`, `workItemEvent.actorId/kind` |

### 12. Idle while actionable (plan X6a, controller's call)

| | |
|---|---|
| **Definition** | company-active seconds during which the company had no running turn and at least one awake agent waited on usage (blocked by `usageLimit`, ready while the five-hour gate is closed, or ready but held by `paceClosed` / `paceStrict`), ÷ company-active seconds in the window. The hourly `turnBudget` blocker is not usage-waiting and is not counted; cap closures are X1's and absent (ruling R31). |
| **Numerator** | Σ `measureCounter.idleActionableSeconds` over days in the window (accrued per tick by the recorder with the engine's own gap rule, ≤ 60 s per tick). |
| **Denominator** | Σ `measureCounter.activeSeconds` over the same days — for every window, `--since all` included: the daily counters only, never `companyActivity`'s running total (ruling R31). |
| **Events (n)** | the **days** with an active-seconds record in the window, not the seconds (ruling R32): below 20 such days the metric is `insufficient data (n=<days>)`, and the basis says n counts days. |
| **Status** | `not measured: no active-seconds records in window` when no day of the window has a counter row; days before the recorder first ran are stated in the basis (`recorded since <day>`). |
| **Detail** | the share of idle seconds by cause: five-hour gate (`usageLimit`), weekly pace (`paceClosed`), reserve (`paceStrict`). |

### 13. Merged items per dollar and per plan-hour (owner addition 11/24)

| | |
|---|---|
| **items per dollar** | landed items in the window ÷ Σ `itemFact.costLE` of those items, labelled **`$LE (subscription)`**. `$ (gateway)`: `not applicable: X1 gateway columns absent`. With Σ cost = 0 (no fact rows, or facts without cost): `not measured: no cost recorded for the landed items`. Printed as `<n> items per $LE 100 (n/Σ)`. |
| **items per plan-hour** | landed items in the window ÷ company-active hours in the window (Σ `measureCounter.activeSeconds` ÷ 3600, the daily counters only, `--since all` included — ruling R31). "Plan-hour" is an hour the company was awake under the owner's plan, never wall-clock. Items that landed **before the first day with an active-seconds record** are left out of the numerator (their hours were never counted) and the basis says how many. With no active-time record for the window: `not measured: no active-seconds records in window`. The 20-event rule counts the landed items (the numerator, ruling R19). |
| **Source** | landings, `itemFact.costLE`, `measureCounter.activeSeconds` |

### 14. Owner intervention minutes per item (owner addition 11/24)

| | |
|---|---|
| **Definition** | Σ `measureCounter.ownerInterventionSeconds` in the window ÷ 60 ÷ landed items in the window. |
| **Source** | **the owner's own log only**: `brahma measure <co> --log-owner-minutes <n> [--day YYYY-MM-DD]` adds `n × 60` to that day's counter (today in the owner's time zone when `--day` is omitted; `n` is 1–1440 per log; a day that has not begun is refused). **Owner-only:** it runs only from the owner's shell (refused inside an agent turn) and the store write takes the owner principal (`Store.logOwnerMinutes(…owner:)`); the generic counter path refuses this counter (ruling R32), so no agent can write owner minutes. It prints one line and no report. |
| **Status** | with no rows in the window: `not measured: no owner-time records`. Otherwise a count (never `insufficient`) ÷ landed items. |
| **Plainly** | Brahma records no owner time on its own and never estimates it. Inbox decisions and messages are counted in metric 6 as touches, not as minutes. If the owner logs nothing, this row says so. |

### 15. Single-agent baseline (owner addition 11/24; spec §8.6.4 "Baselines" is the authority)

`brahma measure <co> --compare <baseline-co>` prints both companies' reports side by side over **the same window** (the first
company's: `--since` applies to both) and **the same metric ids**, row by row: `| metric | <co> | <baseline> (baseline) |`.
Each cell is exactly what that company's own report shows, with its own denominator and status (`97.4% (38/39)` beside
`insufficient data (n=4)`). Nothing is normalised, subtracted or extrapolated. A detail row only one side has reads
`not measured: no '<label>' row in <company>'s report` on the other. `--mission --compare` compares the mission subset the same way. `--format json` carries both reports in full
(`report`, `baseline`, `baselineName`, `baselineNotMeasured`). Comparing a company with itself is refused (exit 2).

**Status of the baseline column:** a company that does not exist prints `not measured: no company named '<name>'` in every
baseline cell; a baseline with no landing in the window prints `not measured: <name> has no landings in the window` in every
baseline cell. In both cases the JSON's `baseline` is null and `baselineNotMeasured` holds the reason (ruling R42(c)). Nothing
is ever estimated.

**The owner's procedure** (no script runs the baseline and nothing here spends usage on the owner's behalf):

1. Create a one-agent company on the same pack and the same repository: `brahma company create Solo --goal "<the same goal>"
   --agents 0 --from-repo <the same repo>` (or the app's New company sheet), then hire its one agent:
   `brahma hire Solo solo --role engineer --model auto`.
2. Give it the same backlog: the same items with the same acceptance criteria and checks (`brahma items add Solo …` for each),
   so both companies start from the same work.
3. Run it (`brahma run`, or the app) under the same pacing preset and billing mode for the same budget or wall-clock span.
4. `brahma measure <co> --compare Solo --since <the day both started>` (add `--mission` for the mission subset, `--format json`
   for both reports in full).

Spec §8.6.4 also names a *single Claude Code session* baseline; Brahma has no record of such a session, so that comparison is
an owner step outside `brahma measure` and is `not applicable` here.

### 16. The mission subset and the soak harness (Plan X6a Task 7; spec §10 row 5 (2))

`brahma measure <co> --mission [--since …] [--format md|json]` prints only what a long run is judged on, in this order: **Items
landed** (a count of the window's landed items, rulings R13/R24, with the number of landings in its basis), **Owner touches per
landed item** (§6), **Usage per landed item** (§5), **Green-main rate** (§1), **Turns wasted on rate limits** and **Reserve
breaches** (the two target-0 rows of Safety, §9, taken as they are), **Idle while actionable** (§12). Each row is the full
report's own measurement over the same window; the header reads `# mission <co>` and the JSON carries `"subset": "mission"`.

The soak harness checks that a company survives a crash, a restart and a reboot without losing work or asking the owner for
more than a login. There is no engine service on this tree (ruling R8): the engine is `brahma run` (or the app); it is running
while something holds the `flock` on `<home>/orchestrator.lock`, and it started at the modification time of
`<home>/run/.sentinel`, which every engine start writes anew (rulings R16, R40).

- `--soak-checkpoint <file>` writes, 0600 and into a directory that must exist, the company's `main` tip, every item branch head,
  every `verifiedCommit`, every lease (item → agent), every release's deploy-started count, the merge batches short of `done`,
  the turns in progress and the engine's start (null with no engine running). It prints one line.
- `--soak-verify <file> [--format json]` judges the company now against that checkpoint. Exit **0** pass, **1** fail, **3** wait,
  **2** could not verify (no such file, another company's checkpoint, a store or git error). The seven checks:
  1. `settled` — the engine restarted after the checkpoint (its start is later than the checkpoint and not the start the
     checkpoint recorded) and has run at least 300 s since; no engine running, no restart since the checkpoint, or not yet
     300 s: **wait**, never fail (ruling R42(a)). Turns are counted only from such a restart;
  2. `noLostCommits` — every checkpoint commit is still an object of the repository (`git cat-file --batch-check`), and `main`
     still contains the checkpoint's tip, unless a restore recorded after the checkpoint (`restoreMain`/`restoreEvent`,
     `restoreEpoch`) explains the rewind — and `main` must still contain the commit that restore put it at, when one is
     recorded. A git error is exit 2, never a rewind;
  3. `leasesRecovered` — no item `inProgress` without a lease, no lease held by a killed or missing agent, and every lease of the
     checkpoint still held by the same agent or released with its item no longer `inProgress`;
  4. `noStuckMerges` — no merge batch short of `done` for more than 600 s since the later of its last step and the engine's
     start (a batch the kill left at `prepared` that recovery finished passes);
  5. `noDuplicateOutsideActions` — no release's deploy step started again after the checkpoint, and no two non-rolled-back
     releases of one commit to one project started deploying with one of them after the checkpoint (L's release records; there
     is no execution counter). Channel actions: `not applicable` (X4 absent);
  6. `interruptedTurnsRecorded` — every turn running at the checkpoint has ended (the restart records `interrupted`), no turn
     started before the engine's start is still in progress, no agent is `running` without a turn in progress;
  7. `companyRunning` — the company is `running`, no engine alert was filed for it since the checkpoint, the engine is not on
     hold (owner-wide), and it has started a turn since the engine's restart. The pause, alert and hold checks come first and
     fail it whether or not the engine restarted; with no restart since the checkpoint there is nothing to count turns from, so
     a check with no problem is **wait**, never pass.
- `--mission`, `--compare`, `--verify-landings`, `--log-owner-minutes`, `--soak-checkpoint` and `--soak-verify` are exclusive
  (`--mission --compare` excepted); a combination is refused with exit 2.

`scripts/soak/run-72h.sh <co> [--hours 72] [--kill-at 24] [--state <dir>] [--resume]` is the owner's 72-hour run. It refuses
to start without `BRAHMA_LIVE=1` (a real company run spends usage). It starts `brahma run` itself, in a process group of its own
(`perl -e 'setpgrp(0, 0); exec …'`, so the recorded pid is the engine's and a Ctrl-C at the terminal never reaches it), and
records its pid and start time (a process is that engine only while both match and its command line is `brahma run`), keeps the
Mac awake with `caffeinate -i` for its own lifetime, takes a checkpoint every hour, at `--kill-at` checks the recorded pid's
command line is `brahma run` and sends SIGKILL to that pid only, starts `brahma run` again and asks for the verdict after the
settle time; at hour 48 it prints the reboot instruction and exits, and `--resume` (after the reboot and login) verifies against
the last checkpoint and continues (with the run's saved `--hours` and `--kill-at`, each checked to be a whole number; the
pre-reboot pid is discarded). Ctrl-C stops the script, never the engine, and says how to stop it (`kill -TERM <pid>`) or resume. At the end it stops its engine with SIGTERM (after the
same check), prints `--mission` over the soak's days (from its local start day) and every verdict. It writes only under
`--state` (default `~/.brahma-soak/<co>`; the company must be a plain name, no `/` or `..`).

### 17. The landing audit (`--verify-landings`; spec §10 row 2 (3))

`brahma measure <co> --verify-landings [--since <YYYY-MM-DD|all>] [--format md|json]` walks `main`'s first-parent history from
its tip back to the company's first commit (at most 10,000 commits) and classifies every commit once (ruling R38):

- **verified** — the merge queue landed it: a landing (as defined above) whose batch has a passed `main` or `item` check at its
  land commit verifies each candidate it merged and the rebased chain between that candidate and the one below it (the previous
  candidate or the batch's base) on first-parent history (ruling R35);
- **owner-accepted** — a `mainAccept` record: one row per owner acceptance of `main` (`brahma main accept`, `brahma merge
  adopt-main`, a quarantine accept), written in the same transaction as the recorded head moves, holding the full commit and
  the head Brahma recorded before it (`previousHead`). It covers that commit and the first-parent run below it down to
  `previousHead` (exclusive), stopping at any commit the store records (a batch base, candidate or land commit, another accept,
  the imported commit, a restore). A store-recorded commit is never owner-accepted (rulings R38, R38a);
- **imported** — the company's first commit: `company.importedCommit`, else the root of first-parent history;
- **unverified** — everything else, each listed by its short id and subject (sanitized).

It prints `landings verified: <p>% (<verified>/<verified + unverified>); owner-accepted <n>; imported <n>` — a census of every
commit, shown at any n, rounded down so 100% means every one (ruling R37) — then any history changes (restores; listed, not a
failure) and the unverified commits. With `--since <date>` the walk stops below the land commit of the newest landing that
finished before that day (landing time, not author dates).

**Acceptances from before `mainAccept` existed** (before the migration's `measureEpoch('mainAccept')`) are known only from the
engine's activity text (`main adopted at <sha7> by the owner`, or `the owner accepted refs/brahma/quarantine/… into main at
<sha7>`). Such a legacy accept covers **one** commit: the single walked commit
with that seven-digit prefix, committed before the acceptance (rulings R38, R39). A legacy adopt that brought several commits
into `main` therefore leaves the others **unverified**. Nothing guesses them in. The remedy is
`--verify-landings --since <a day after the first queue landing that followed the legacy adopt>` (the walk stops below the
newest landing that finished before that day, so a landing must lie between the adopt and that day).

**Exit codes:** **0** every audited commit is verified, owner-accepted or imported and the walk reached the first commit; **1**
unverified commits, or the walk stopped at its bound; **2** could not audit — no `main` (or no repository), an unknown company, a
git failure, a planted `shallow` or `info/grafts` file, a cut history, a bad `--since`, a refusal outside the owner's shell, or a
merge batch moving `main` (`a merge batch is open; run again after it finishes`). Read-only: nothing is written.

---

## What is not measured, and why

| Spec item | Status | Why |
|---|---|---|
| `$ (gateway)`, per-provider split, routed-model attribution | `not applicable: X1 gateway columns absent` | `turn.meteredUSD`, `itemFact.meteredUSD`, `turn.routedModel`, `turn.provider`, `turn.authRoute`, `gatewayCharge`, `providerCap` are X1's, not merged (ruling R4). |
| channel refusals | `not applicable` | X4 channels are not merged. |
| non-code acceptance (`landGate: owner`, rubric) | `not applicable` | no such items or checks on this tree. |
| cap overruns | `not applicable` unless recorded | no record; the scheduler never admits above the cap. |
| reserve breaches, idle while actionable, plan-hours in a window | `not measured` until the recorder runs | the database holds only the current usage state and a running active-time total; the measure recorder (Task 5) keeps the daily counters, and every window (`--since all` too) reads only those (ruling R31). |
| owner minutes | `not measured` until the owner logs them | Brahma never estimates owner time. |
| single Claude Code session baseline | `not applicable` | no engine record of a session outside Brahma. |
| anything before `vX6a-measure` that needs links | excluded, basis stated | links did not exist; nothing is back-filled or guessed. |
