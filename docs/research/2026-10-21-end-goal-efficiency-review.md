# Brahma: end-goal efficiency review

Date: 2026-10-21 · Reviewer: principal systems architect (read-only review) · Scope: spec §1–§9 (through §6.27), improvements-from-research, research docs (existing projects, failures, design review, operating model and 150 edge cases), visual brief, Plans 1–2 (built), 3a amended, 4a, 4b (upcoming), 3b (deferred), and the built code in `Sources/**` and `Tests/**`.
Not present, so not reviewed: the Plan 5-lite, Memory-lite and Plan M plan files, and `research-gstack-abilityai.md`.

End goal used as the yardstick: the owner states a goal, and a company of Claude Code agents researches, builds, launches, markets and operates the product, in any industry. The owner acts as a board. It runs on Max 20x plus optional services, on a Mac.

---

## 1. Verdict

Brahma's engine is sound and its verification-first core (engine-run checks, clean-context review, engine merges) is the right foundation. But the current design spends most of its subscription on coordination rather than shipped work, and it schedules the externally visible half of the end goal last. Three mechanisms drive the cost:
- long-lived `--resume` sessions that are resumed after the 1-hour prompt cache has expired;
- work-item notices that wake authors and reviewers on every event;
- org charts sized to headcount ambition instead of to backlog width and the weekly budget.

On this review's model, only about 30% of a 6-agent company's tokens, and about 15% of a 30-agent company's, end up in merged work or approved documents. A 30-agent company ships roughly the same per week as a 6-agent one, at about 2.5× the tokens. The binding constraints are the weekly Max 20x allowance (especially Opus) and the serial critical path, not concurrency, SQLite or process spawn. The build order also defers everything needed for "live product" and "first post" (deploy, domain, payments, posting) to Plans 7, 11 and M, behind maps, people management and memory. A small set of S-sized amendments to the not-yet-built 3a/5-lite text would roughly double useful output per token. One new thin "Live" plan would deliver an end-to-end goal → live URL → first launch post demo about six plans sooner.

---

## 2. Usage model

### 2.1 Units and assumptions (stated so they can be checked)

- **Unit: list-equivalent dollars ($LE).** This is what Claude Code reports as `total_cost_usd` on every `result` line. Brahma already stores it (`Turn.costUSD`, written in `Store.endTurn`, `Orchestrator.swift`). It weights output, cache writes, cache reads and the model correctly. On a subscription it is not a bill. It is the best available proxy for how fast a turn consumes the allowance.
- **Prices assumed (ratios matter more than absolutes):**

  | Model | Input $/M | Output $/M | 1-hour cache write $/M | Cache read $/M |
  |---|---|---|---|---|
  | Sonnet | 3 | 15 | 6 | 0.30 |
  | Opus | 5 | 25 | 10 | 0.50 |
  | Haiku | 1 | 5 | 2 | 0.10 |

- **Measured baseline (probe, `tmp/probe/out1.jsonl`, `out2.jsonl`).** A trivial first turn with the exact Plan 1 argv (Haiku) took 2.1–3.7 s wall time. Its token profile:
  - cache read 6.9–9.4k tokens, i.e. the Claude Code system prompt plus tools, shared across sessions;
  - cache write 4.1–5.2k tokens, i.e. the appended role prompt, environment and git status;
  - cache type `ephemeral_1h`, so the prompt cache lives 1 hour.

  With 3a's ~25 company tools, a 4,000-character role card and the orientation digest, the fixed prefix per turn becomes roughly 20–25k tokens.
- **Weekly allowance (assumption, ±2×).** Anthropic's 2025 guidance for Max 20x was about 240–480 Sonnet-hours and 24–40 Opus-hours per week. Heavy Claude Code use is about $6–12 LE per agent-hour. After the 30% owner reserve (§6.24), the planning figure is **≈ $1,500 LE/week usable** and **≈ 17–28 Opus-hours**. Calibrate this in week 1. The engine already parses `sevenDayUtilization` (`UsageGate`), so it can compute Δ7d% per turn (see improvement 5).

### 2.2 Turn archetypes (Sonnet unless noted)

| Archetype | Shape | $LE |
|---|---|---|
| **A. Work turn** (implement or fix, tier S/M) | 25 API iterations; context 25k→90k; reads ≈1.4M, writes ≈70k, output ≈12k | **≈ 1.00** |
| **B. Review turn** (fresh session, diff plus file reads) | 12 iterations; reads ≈540k, writes ≈55k, output 4k | **≈ 0.55** (Opus ≈ 0.92) |
| **C. Warm notice/FYI turn** (resume under 1 h, 40k session) | reads ≈135k, writes ≈6k | **≈ 0.10** |
| **D. Cold notice turn** (resume over 1 h, 120k base session) | rewrites the whole transcript into cache, ≈125k | **≈ 0.88** (Opus ≈ 1.47) |
| **E. Discovery turn** (`list_work`, `claim_lease`, "nothing new") | fresh prefix plus a few calls | **≈ 0.20** |
| **F. Planning document turn** (Opus: PRD, architecture, with web research) | 30 iterations, average context 70k | **≈ 2.45** |
| **G. Backlog turn** (Opus: about 20 `create_work_item` calls) | — | **≈ 1.90** |
| **H. Reflection turn** (Memory-lite, Haiku) | — | **≈ 0.04**, plus a process spawn and about 3 s |

**Key observation.** In long agentic turns, cache reads of the growing context are the largest single cost. In cold resumes, cache writes of the old transcript dominate. 3a's budget unit counts `input + output + cache_creation` (3a "Decisions this plan pins"). It ignores reads, so it misprices exactly these two cases. It also treats Opus tokens as equal to Sonnet tokens.

### 2.3 Per work item (one S/M task), as currently planned (3a amended, plus Memory-lite)

| Component | Count per item | $LE |
|---|---|---|
| Work turns (including 0.4 fix-after-failed-check and 0.15 conflict re-work) | 2.0 × A | 2.00 |
| Clean-context review (1.35 rounds) | 1.35 × B | 0.74 (Opus reviewer: 1.24) |
| Claim/discovery | 0.5 × E | 0.10 |
| Notice wakes (3a Task 6 `recordItemEvent` notifies author, reviewer and owner, waking the sleeping ones; ~7 events per item coalesce to ~2 effective wakes, half of them cold) | 2 × (C or D) | 0.98 |
| Memory-lite recall payload (~1.5k uncached tokens × ~5 turns) and one reflection turn | — | 0.09 |
| **Total** | | **≈ 3.9 (Sonnet reviewer) – 4.4 (Opus reviewer)** |
| Of which shippable (the merged attempt's work tokens) | | ≈ 1.6 → **36–41%** |

### 2.4 Week 1: 6-agent SaaS MVP

Composition: ceo-cpo (Opus), cto-architect (Opus, also the default reviewer under 3a Task 9 `resolveReviewer`), 3 engineers and 1 QA. Backlog of ~45 items, ~35 of them claimable.

| Bucket | Turns | $LE | Share |
|---|---|---|---|
| PRD with research (F × 3) | 3 | 7 | 3% |
| Architecture, ADRs and contracts (F × 4) | 4 | 10 | 4% |
| Backlog creation (G × 3) | 3 | 6 | 2% |
| Sprint plan, C-suite approval and close (× 2 sprints) | 6 | 4 | 2% |
| Executive coordination: DMs, asks, escalations, notices on long Opus base sessions (~10/day × 5, mostly cold) | 50 | 40 | 17% |
| Items, 35 × 4.4 | ~180 | 154 | 64% |
| QA seat (test items, bug filing; overlaps engine checks) | 15 | 12 | 5% |
| Idle and discovery turns ("no current item", welcome @mentions) | 20 | 4 | 2% |
| Memory reflection | 35 | 2 | 1% |
| **Total** | **~315** | **≈ $240** (≈ 16% of the weekly allowance) | |

- Shippable: merged work ≈ $56, plus approved PRD and architecture ≈ $17. That is about **30%**.
- The budget is not binding for a 6-agent company in week 1. Calendar time is set by the critical path and owner latency (§3). Waste still matters, because week 2+ (operate, market) adds standing load and the owner wants a reserve.
- Opus: about 11–17 Opus-hours, i.e. 40–100% of the usable Opus allowance. Opus, not total usage, is the first wall.

### 2.5 Week 1: 30-agent SaaS MVP

Composition: 3 executives (Opus), 4 managers, 2 architects, 2 designers, 1 devops, 1 security, ~17 engineers and QA. The MVP scope is the same; backlog width does not grow with headcount.

| Bucket | $LE |
|---|---|
| Planning (same as 6-agent) | 25 |
| Executive coordination (3 separate executives, more escalations, cold Opus resumes) | 120 |
| Managers (4 × ~12 wakes/day × 5 days, from notices and assigns) | 120 |
| Items, 45 × 4.9 (more conflicts, cross-team review, contract churn) | 220 |
| `@team` broadcasts, idle and discovery wakes (~300 × 0.2) | 60 |
| Onboarding first turns (30 × cold prefix) | 15 |
| Ceremonies (4 teams × 2 sprints × 3) | 15 |
| Architect contract reviews | 18 |
| **Total** | **≈ $590** (≈ 40% of the weekly allowance) |

- Shippable ≈ $72 + $17, i.e. **≈ 15%**.
- Output per week is about the same as the 6-agent company. After the walking skeleton, the parallel width of an MVP item graph is about 6–10 items. 3a's weekly pacing gate (`7d ≥ elapsedFraction × 0.7`) then caps average concurrency at about 2–3 agents anyway.
- Opus demand is about 25–35 h. **It exceeds the Opus allowance**, so the company falls back to Sonnet or blocks.

### 2.6 Week 1: CPG launch (6 seats, CPG pack)

Roles: ceo-cpo, brand/marketing, product development, sourcing, regulatory, finance.

- The work is mostly documents. Verification is a rubric review by a clean-context LLM, so there are about 2.0 review rounds per item, and the reviewer reads long documents.
- Research turns pull web pages of 5–20k tokens each into context, which multiplies cache reads.
- Estimate: ~25 document items × $4.6, plus 10 code items (landing page, waitlist) × $3.9, plus planning and coordination ≈ **$235**, with shippable ≈ 28%.
- The real limit is different. Supplier RFQs, samples, entity and regulatory filings are human tasks or outbox items, and their latency is days. Without a parked state, agents fill the wait with speculative documents, which is waste.

### 2.7 Where the tokens go (6-agent, planned design) and the cheapest fixes

| Waste | Share of total | Cheapest fix |
|---|---|---|
| Cold resumes of long base sessions (executives, managers) | 12–20% | Resume only while the cache is warm (improvement 1) |
| FYI notice wakes | 10–15% | Wake only on actionable events, debounced (improvement 2) |
| Review on every low-risk item | 8–12% | Risk-tiered review with sampled audits (improvement 7) |
| Opus on coordination and reviews | 6–10% | Model chosen by turn kind (improvement 6) |
| Discovery, idle and broadcast turns | 3–10% (grows with N) | Engine dispatch, never run an empty turn (improvement 3) |
| QA/designer seats before they are needed | 5% | Size seats from budget and backlog width (improvement 4) |
| Uncached volatile prefix (role card in the user digest, roster in the system prompt, per-role tool schemas) | 1–3% | Stable prefix (improvement 8) |

Applying improvements 1–4 and 6–8, the 6-agent week drops to about $150 with ≈ 55–60% shippable. The 30-agent company, sized down to the ~8–10 seats the backlog can use, lands near the same figure.

**When not to use an agent at all** (plain code is cheaper and deterministic):
- dispatching items;
- sprint planning for N ≤ 8, i.e. priority order within capacity;
- standups (already decided);
- sprint-close summaries;
- release notes from merged items;
- default checks per stack;
- secret, PII and license scans (gitleaks or license-checker as engine checks);
- uptime and smoke checks;
- deduplicating asks and items (FTS);
- reflection and lessons (extract the review "changes requested" notes verbatim);
- monthly reconciliation;
- QA's "run the tests" (the engine runs checks).

---

## 3. Critical path: goal → PRD → architecture → merged code → preview → deploy → first post

6-agent company, owner responsive but not watching. Times are agent wall time, plus owner latency (OL).

| Step | Agent time | Gate or serialization | Notes |
|---|---|---|---|
| Goal → PRD (CEO-CPO, 2–4 Opus turns, serial) | 30–60 min | **OL #1: PRD approval** (§6.8, §6.24) | Nothing else runs; the engineers sleep |
| PRD → architecture (CTO, 2–4 Opus turns) | 30–60 min | **OL #2: architecture approval** | Serial after OL #1 |
| Backlog (CPO plus items with checks) | 30–60 min | The check author must exist before an engineer can start (3a: an item "requiresCheck") | Each item that lacks a check is another hop |
| Sprint plan → C-suite approval → active | 10–20 min | Extra hop: a manager's turn, then an executive's turn | FYI to the owner (good) |
| Engineers claim (`list_work` → `claim_lease`) | 5–10 min | Pull model, no dispatch | |
| Walking skeleton (repo, framework, CI check) | 30–60 min | Parallel engineers before the skeleton cause conflicts | |
| Check (npm install in sandbox) → review turn → merge | 10–25 min | Review turn by an Opus cto-architect | **First merged code ≈ 3–5 h agent time + OL#1 + OL#2** (often 12–30 h of calendar time when a gate lands overnight) |
| First preview | +30 min after the merge | Needs 4a (after 5-lite and Memory-lite) plus DevOps `set_preview_command` | **Not buildable until 4a** |
| First deploy | — | Needs release gate, QA sign-off, CTO approval and owner approval, **plus a hosting connector (Plan 11)** | **Not reachable in the planned order before Plan 11** |
| First marketing post | — | Needs the outbox (Plan 7), connectors and funds (Plan 11) and Plan M (video) | **Not reachable until Plans 7, 11 and M** |

Where latency comes from:
1. **Two serial owner gates before any code.** With a typical owner, OL is hours to overnight, which is larger than all agent time combined.
2. **Pacing shape.** The gate closes when `sevenDayUtil ≥ elapsedWeekFraction × 0.7` (3a amendment 3). It is linear in time, so a company created early in a week window (or after heavy owner use) is held exactly during the serial, Opus-heavy planning burst. That burst is cheap in absolute terms but on the critical path.
3. **Hops that don't need an LLM:** check authoring before start, the assign/claim pull, C-suite approval of sprint plans in small companies, and the review turn for trivial items.
4. **A single reviewer.** In a 6-agent company every item funnels through one Opus cto-architect.
5. **Build order** (§6.24): 3a → 5-lite → Memory-lite → 4a → 4b → dogfood → 3b → 4c → 7, 11, 9, 8, 10, with Plan M after dogfood but dependent on 7 and 11. Deploy, domain, payments, outbound posting and support all sit in the last four plans or in no plan.

What parallelism helps and what hurts:
- **It helps:**
  - research fan-out, which is cheapest as Claude Code sub-agents inside one turn so page text stays out of the parent context;
  - a tech spike or walking skeleton concurrent with PRD drafting;
  - independent items after the skeleton;
  - checks and previews running concurrently.
- **It hurts:**
  - engineers in parallel before the skeleton exists;
  - more than one team on a 40-item MVP;
  - `@team` broadcasts;
  - parallel reviewers for the same diff;
  - a high Balanced/Max concurrency that only burns the 5-hour window faster and then sits in the pacing hold.

---

## 4. Owner time and cognitive load

**Setup before value appears (today and as planned):**
1. Install the app.
2. Confirm `claude` is logged in and extra usage is off.
3. Pass `brahma doctor`.
4. Create the company: goal, size, pack, preset.
5. Accept the sandbox profile (5-lite) and its network allow-list.
6. Wait for and read the PRD (10–20 min).
7. Wait for and read the architecture (10–20 min).

Nothing visible (preview) appears before 4a, and nothing live before Plan 11.

**Week-1 touches, 6-agent company, "Important only" preset:**

| Source | Touches |
|---|---|
| Setup | 6–10 (day 0, 20–40 min) |
| Gates: PRD, architecture, later release | 2–3 |
| Secrets and test keys (DB URL, Stripe test key, OAuth client) | 2–4 |
| Sandbox network or permission asks (registries, CDNs, docs, GitHub), **filed per agent with no cross-agent dedupe** | 4–12 |
| Human tasks (hosting account and token, domain, Stripe account) | 3–5 |
| Escalations (deadlock after 1 active day, stalled review, executive watchdog) | 1–3 |
| Ask reminders (1 and 3 active days) and FYIs (sprint start/close) | 4–8 notifications |
| **Total** | **≈ 25–45 touches/week, or 5–8 per active day** |

§6.24 notifies on every pending ask immediately. For 30 agents, permission and secret asks scale with headcount, giving 10–20 touches per day.

**Against the five-noun concept budget** (Company · People · Work · Inbox · Budget). As planned, the owner meets these concepts:
- **Budget:** usage mode (Low/Balanced/Max), hard cap, per-hour turn budget, weekly pace, owner reserve, tier budgets, and later funds. That is 5–7 knobs for one noun.
- **Inbox:** asks, kinds, risk, scope and duration grants, three presets, reserved matters, reminders, rescind, re-ack.
- **Work:** items, keys, tiers, checks, review flags, "lease until HH:mm" (3a TurnDigest/UI), sprints, cadence, timebox.
- **Company:** pack, profile, cadence, engine holds, doctor.

About 25 owner-visible concepts in total. Budget and Work leak engine internals most. The single biggest owner-load lever is to collapse Budget to one "weekly share" slider and to batch and dedupe asks (improvements 5 and 11).

---

## 5. Ranked inefficiencies

| # | What | Evidence | Impact estimate |
|---|---|---|---|
| 1 | **Long-lived base sessions resumed after the cache expires.** Executives and managers mostly work without an item, so their base session grows for the company's lifetime. Every wake after more than 1 hour rewrites the whole transcript into cache. | `Orchestrator.performTurn` resumes `agent.sessionId` forever; 3a Task 10: "Turns without an item use the base session… `--resume` after"; design review Medium "lifetime --resume session growth"; probe shows a 1-hour cache (`ephemeral_1h`) | A cold FYI turn costs ≈ $0.9 against $0.1–0.2 fresh. Executives and managers take 30–50% of turns. **12–20% of total usage** |
| 2 | **Notices wake on every item event.** | 3a Task 6 `recordItemEvent`: "notifies the owner, reviewer and author… waking sleeping recipients"; ~7 events per item | ~2 wakes per item. **10–15% of usage**, plus scheduler slots taken from work |
| 3 | **Pull-based work.** Agents run turns to discover and claim work, and empty digests still run a turn. | Plan 1 `InboxDigest.render`: "(nothing new — check your work and continue)"; 3a TurnDigest: "No current item. Use list_work and claim_lease" | 3–10% (grows with N), plus a manager `assign` hop |
| 4 | **Headcount sized to ambition, not to backlog width or budget.** Ratios add QA, designers, architects and security automatically. | §6.3 ratios; 3a Tasks 1–2 `OrgShape` and ratios; §6.24 default size 6 | A 30-agent company costs about 2.5× the tokens of a 6-agent one for about the same weekly output |
| 5 | **Budget unit misses cache reads and model weight; owner Budget knobs sprawl.** | 3a "Token budget counts `input + output + cache_creation`"; `SchedulerConfig.modeCap` and `turnBudgetPerHour`; `UsageGate.threshold`; 3a Task 5 pacing and reserve | Tier budgets, the watchdog and the facts (and later 3b and the Steward) optimize the wrong number. The owner faces 5+ knobs. Linear pacing throttles the planning burst |
| 6 | **Opus by role rather than by turn kind.** Executives are Opus for every turn, and the cto-architect is the default reviewer in small companies. | 3a Task 1 pack table (Opus ×3 for executives); Task 9 `resolveReviewer` | The Opus allowance is about 10× smaller than Sonnet's. A 30-agent company exceeds it; a 6-agent company uses 40–100% of it |
| 7 | **Full clean-context review turn for every item,** including tier-S items with an engine pass and no flags. | 3a Task 9 | 15–20% of per-item cost, plus one serial hop per item |
| 8 | **Cache-unfriendly and possibly role-losing prompt layout.** The role prompt goes only on the first turn, the role card is re-injected in the user digest, the roster sits in the system prompt, and tool schemas are filtered per role. | `ClaudeCommand.arguments`: `--append-system-prompt` only when `!sessionStarted`; 3a Global Constraints pin this; `RolePrompt.render` embeds the roster; 3a `CompanyToolNames` per role. The probe shows ~7k of prefix shared across sessions | Tokens 1–3%. **Correctness risk:** Claude Code rebuilds the system prompt per invocation, so resumed turns likely lack the role prompt. Verify in `brahma doctor` |
| 9 | **Two serial owner gates before any code,** with no speculative or reversible work allowed. | §6.8 flow; §6.24 "owner approves PRD, architecture" | Owner latency dominates time to first merge: 12–30 h calendar against 3–5 h of agent time |
| 10 | **Build order back-loads every external outcome.** | §6.24 order; §3 non-goal "deploying to paid production hosting"; §6.26 Plan M depends on 7/11; 4a has no deploy | No "goal → live" demo until about 8 more plans |
| 11 | **Owner ask flood.** Per-agent permission asks, no dedupe, immediate notification for everything, reminders. | §6.5a; §6.23; §6.24 "pending asks notify on macOS immediately"; 3a Task 11 reminders | 5–8 touches per day (6 agents), 10–20 (30 agents) |
| 12 | **Seven overlapping knowledge stores,** plus pushed recall and reflection turns. The stores are notes (3a Task 13), progress files, hand-offs, KB (§6.17), Company Memory (§6.25), personal memory with four types and reflection (§6.27), the experience store (research C11), lab notes (§6.14) and retro lessons. | Spec §6.14/§6.17/§6.25/§6.27; 3a Tasks 10/13 | Effort L before dogfood proves need; 1–3% of tokens per turn for top-k pushed into every orientation |
| 13 | **4a over-scoped for dogfood scale.** It adds a batched queue, bisect, a journaled crash-safe merge, a backup ref and six adapters (web, CLI, backend, iOS, macOS, artifacts). | 4a Tasks 1–3 and 6–8 | Effort L. At 10–20 merges/day, 3a's serial merge is enough |
| 14 | **4b is a SpriteKit org chart** with particles, replay, pop-out and a 300-agent bench, placed before the demo. | 4b Tasks 1–11 | Effort L for a low-value owner surface; the Inbox and preview matter more |
| 15 | **QA and designer seats duplicate engine checks or are premature.** | 3a Task 1 `teamSupport qa`; designer ratio | ~5% of usage |
| 16 | **Pacing throttles critical-path work as hard as background work.** | 3a amendment 3 | Adds latency to PRD, architecture and incident work |
| 17 | **Missing critical-path pieces have no plan or are last:** deploy/hosting, domain/DNS, payments (test → live), transactional email, analytics and uptime, ToS/privacy, entity formation, support inbox, incidents. | Operating model §1.10–1.12 ([GAP]); Plans 7, 11 and the Ops plan come last | The end goal ("launch, market, operate") is unreachable in the current order |
| 18 | **First marketing capability is short-form video.** It needs a video-generation connector, an ffmpeg pipeline, platform API approval (the TikTok Content Posting API needs an app audit) and spend. | §6.26 | Weeks of build before the first post; text launch posts would be on the critical path immediately |
| 19 | **No parked state for human-blocked critical paths** (CPG, vendors). | §6.18 human tasks; no "park" rule in 3a | Speculative document churn while waiting days on vendors |
| 20 | **Not a real bottleneck, so don't optimize yet:** the single SQLite writer, polling and spawn cost. Each turn also spawns a `brahma mcp` child that writes the DB under a 5 s busy timeout. | Store `DatabasePool` WAL, `busy_timeout 5000`; `Orchestrator.runForever` 1 s tick with O(N) reads; app polls every 500 ms; probe shows 2–4 s per spawn | The usage allowance binds at about 2–3 average concurrent agents long before 16–50 writers matter. Spawn overhead only matters for FYI turns, which improvement 2 removes |

---

## 6. Ranked improvements

Effort: S = under a day of plan and build work, M = a few days, L = a plan. Savings are against the planned design.

| # | Improvement | Where it lands | Effort | Expected effect | Change unbuilt plan now? |
|---|---|---|---|---|---|
| 1 | **Resume only while warm.** Resume a session only if its last turn ended less than ~50 min ago and its transcript is under ~60k tokens. Otherwise start a fresh session with orientation plus an engine "continuity note" (last 3 turn summaries and open asks). This applies to base sessions too. | 3a Task 10 (session selection), Task 4 (TurnProfile); spec §6.5 | S | −12–20% total usage; bounded context; ends unbounded session growth | **Yes, 3a** |
| 2 | **Actionable-only, debounced wakes for work notices.** These wake: review requested (reviewer), changes requested or check failed (holder), dependency done (waiter), asks and escalations addressed to the agent. FYI events (claimed, submitted, passed, merged, comments not @-addressed) are delivered in the next turn without waking. Managers and executives have a 10 active-minute wake debounce unless the item is on the critical path (`blockingCount > 0`). | 3a Task 6 (`recordItemEvent` uses `WakePolicy`), Task 3 | S | −10–15% usage; frees slots; fewer cold turns | **Yes, 3a** |
| 3 | **Engine dispatch and no empty turns.** The engine leases the next Ready, dependency-free, role-matching item to an idle IC (priority, then age) and starts the turn already claimed. A turn whose digest has nothing actionable is skipped and the agent stays asleep. Manager `assign` remains an override only. | 3a Task 7 (lease on dispatch), Task 10 (digest); Plan 1 `Orchestrator.performTurn` guard | S–M | −3–10% usage (more at scale); removes the claim and assign hops (−10–20 min to first work) | **Yes, 3a** |
| 4 | **Size seats from budget and backlog width.** The org generator proposes `min(N, ready-graph width + 2 leads, weekly budget ÷ agent burn)` agents. The rest are vacancies (4b's `opening` table) that executives fill when width grows. No QA, designer or security seats until a stage or pack trigger. Default 4–6 seats. | 3a Task 2 (`OrgGenerator`); spec §6.3, §6.24 defaults | S | 30-agent company: about −55% tokens for the same output; fewer asks and broadcasts | **Yes, 3a** |
| 5 | **One budget unit and one owner knob.** Budget in `total_cost_usd` (already stored), calibrated to Δ`sevenDayUtilization` per turn and shown as "% of week". TierBudget, the watchdog, facts and the Inbox all use it. The owner sees one "weekly share" slider (default 70%) and a steady/sprint toggle; mode, cap and turn budget are derived. Pacing gets burst headroom (elapsed fraction + 15%) and critical-path or incident exemption. | 3a Tasks 5 and 14; spec §6.7, §6.24; Plan 1 `SchedulerConfig` and `UsageGate` | S | Correct cost signals for the watchdog and the future 3b/Steward; Budget noun drops from 5–7 knobs to 1; planning burst unthrottled | **Yes, 3a** |
| 6 | **Model by turn kind, not by role.** Opus only for PRD, architecture and tier-L work. Executive coordination, reviews and notices run on Sonnet. FYI, triage and format turns run on Haiku. The default reviewer model is Sonnet; Opus reviews only for L, flagged or sensitive items. | 3a Task 1 pack table plus `ModelPolicy`, Task 9 | S | Keeps Opus under its allowance; −30–40% of executive and review cost | **Yes, 3a** |
| 7 | **Risk-tiered review.** A tier-S item with an engine pass, no flags, a diff under ~150 lines and no sensitive paths auto-merges. 1 in 4 such merges is sampled into a daily batched audit turn, and a bad audit demotes the author to full review. M, L, flagged and sensitive items keep the full clean-context review. | 3a Task 9 (review policy), Task 14 (facts record audits) | S–M | −8–12% usage; removes one hop per small item | **Yes, 3a** |
| 8 | **Cache-friendly stable prefix.** Pass the role card via `--append-system-prompt` on every turn, byte-stable: no roster, no timestamps. Use one identical company tool schema for all roles, with authorization enforced in `CompanyTools`. Keep a stable workspace CLAUDE.md (conventions, commands, ADR index) injected as system text if `--setting-sources ""` suppresses it. The digest carries only the volatile tail. The doctor asserts the role prompt is present after `--resume`. | 3a Task 4 (compiler), Task 10 (TurnDigest), Task 1 (`CompanyToolNames`) | S | Fixes likely role loss on resume; 1–3% tokens; better cross-agent cache sharing | **Yes, 3a** |
| 9 | **New thin "Plan L — Live" right after 3a and minimal 5-lite.** Web preview only; a `deploy` ask kind that runs a pack-defined hosting command (Vercel, Cloudflare Pages or Fly CLI) with an engine-held token; release record plus post-deploy smoke check plus rollback by redeploying the previous release; a universal `humanTask` ask with prefilled links and paste-back fields (domain, DNS, Stripe test keys, launch post via web intent URL). Defer 4b, Memory-lite, 3b, 4c, the batched queue and non-web adapters until after the demo. | Spec §6.24 build order; new plan; takes 4a Tasks 3–5 and 7 | M | Goal → live URL → first post moves from about 8 plans to about 2; the first real end-to-end test of the end goal | **Yes: reorder; cut 4a/4b/Memory-lite before writing them** |
| 10 | **Speculative parallel kickoff and one combined gate for small companies.** At intake, PRD drafting runs in parallel with a tech spike or walking skeleton (repo, CI check, preview command) on a reversible branch. For N ≤ 8 there is one combined "brief + architecture" owner gate. Gates block only irreversible work (spend, outbound, deploy, data deletion). | Spec §6.8; 3a Task 11 (gate effects), Task 13 (sprint prerequisite) | S | −1 owner latency (hours to overnight) and −1–2 h of serial agent time to first merge | **Yes, 3a** |
| 11 | **Ask dedupe and batched notification.** Company-wide dedupe by (kind, target), so one domain request covers every agent. Notify immediately only for asks blocking the critical path, reserved matters with expiry, or sev-1. Everything else goes in two daily digests. Per-pack starter network allow-list (npm, PyPI, crates, GitHub, common CDNs and docs). | 5-lite (Inbox notifications, sandbox allow-list); 3a Task 11 dedupe key | S | −50–70% owner pings; most first-week permission asks disappear | **Yes, 5-lite (unwritten)** |
| 12 | **Shrink Memory-lite to pull-only.** `search_memory` over existing FTS (messages, items, ADRs and docs, hand-offs) plus `remember` appending to the capped notes file. No auto top-k push into orientation, no reflection turns. Lessons are plain-code extracts of review notes. Revisit after dogfood with measured recall misses. | Spec §6.25, §6.27; Memory-lite plan; move after Plan L | S (saves L) | −1–3% tokens per turn; effort L saved; one knowledge model (git docs + item files + notes + FTS) | **Yes, before writing it** |
| 13 | **Cut 4a** to serial merge (already in 3a), main smoke check, release record, web and artifact adapters. Defer batching, bisect, journaling, the backup ref (beyond a cheap fast-forward check) and the CLI, backend, iOS and macOS adapters. | 4a Tasks 1–3, 6, 8 | Saves L | Effort L saved; nothing on the critical path lost | **Yes, 4a** |
| 14 | **Replace 4b with a SwiftUI tree or list** in mission control (state chips, current item, blocked reason). The SpriteKit chart, particles and replay come after dogfood. | 4b; spec §6.21 | Saves L | Effort L saved | **Yes, 4b** |
| 15 | **Research through Claude Code sub-agents.** Research and web turns use the Task tool, so fetched pages stay in sub-agent contexts and only cited summaries return to the parent, which then writes the `kb/` report. | Pack prompts (3a Task 1), §6.17, §6.22 (enable Task per role) | S | −30–50% on research-heavy turns; matters most for CPG | Yes, 3a pack text |
| 16 | **Reuse existing tools instead of building:** gitleaks or trufflehog for secret scanning; license-checker on release; Claude Code PreToolUse hooks via `--settings` to deny the DB path, `git` on main and edits to check snapshots (defense in depth with 5-lite); a company skill library seeded with review, QA, ship and deploy skills (check licenses); hosting CLIs and existing MCP servers (Vercel, Cloudflare, GitHub, Stripe); ntfy or Pushover for phone alerts instead of AppleScript iMessage plus Gmail SMTP. | 5-lite, Plan L, Plan 11, spec §6.10 | S–M | Weeks of bespoke code saved; better-tested mechanisms | Yes, 5-lite text |
| 17 | **Marketing text-first.** Plan M v1 is the landing page and waitlist, launch post drafts (X, LinkedIn, HN, Product Hunt, Reddit) posted by the owner through a human task, and analytics pull. Short-form video becomes Plan M2. | Spec §6.26; Plan M | S (saves M–L) | First post on day 1 of the demo instead of after Plans 7 and 11 | **Yes, Plan M scope** |
| 18 | **Parked state.** When every critical-path item is blocked on owner, human or vendor, the company sleeps, except "prepare the next human task" work and inbound wakes. The Inbox shows "waiting on you: k". | 3a Task 12 (stall explainer and deadlock), spec §6.18 | S | Stops speculative churn in CPG and services companies | Yes, 3a |
| 19 | **Engine-owned default checks per stack** in the pack (`npm test && npm run build`, `swift test`, `pytest -q`, document validators), so an item can start without a check-author hop. Custom checks stay editable by the author or reviewer. | 3a Task 1 (pack), Task 8 | S | −1 hop per item; faster skeleton | Yes, 3a |
| 20 | **Ops-lite right after the demo, before 3b:** engine timers; an uptime check on the deployed URL leading to an incident item and a reserved scheduler slot; a weekly CEO board memo (one turn from an engine fact pack); a support email mapped to `#external` plus a ticket item type. | New Ops-lite plan (from operating model #9 and #16) | M | Makes "operate the company" real; the board gets one weekly read instead of a stream | New plan |

**Plan-by-plan summary:**
- **3a** (being written or built): apply 1, 2, 3, 4, 5, 6, 7, 8, 10, 15, 18 and 19. All are S except 3 and 7 (S–M). Most are small edits to Tasks 1, 2, 5, 6, 7, 9, 10, 11 and 14, and they change pinned constants or tool contracts, so they must go in before build.
- **5-lite** (unwritten): keep it minimal. Include the Claude Code sandbox via `--settings`, Keychain secrets for engine-run commands only, hooks, ask dedupe and digest batching, starter allow-lists, and `VACUUM INTO` backups. Defer timers and the taint rule to Ops-lite and Plan 7.
- **Memory-lite:** shrink to pull-only and move after Plan L.
- **4a:** split. The preview, release and deploy parts go to Plan L; the rest is deferred.
- **4b:** defer; use a SwiftUI tree for now.
- **Plan M:** text-first.
- **3b:** stays deferred until dogfood data, and adopts the cost unit from improvement 5.

---

## 7. Fastest path to an end-to-end demo: "goal → live product → first launch post"

**Order:**
1. 3a with the S amendments above.
2. 5-lite-min: sandbox settings, engine-held secrets, ask dedupe and digests, backups.
3. **Plan L.**
4. Demo and dogfood week.
5. Ops-lite.
6. Plan 7 and Plan 11 (connector catalog, funds).
7. Plan M text-first, then M2 video.
8. Memory-lite (pull-only).
9. 3b, redesigned from data.
10. 4b and 4c skins.
11. Plans 9, 8 and 10.

**Plan L, about 7 tasks:**
1. **Web preview from `main`.** Run command, port allocation and `WKWebView`, rebuilt on merge. Taken from 4a Tasks 4–5.
2. **Artifact preview.** Markdown, HTML, images and PDF, so the PRD, architecture and mockups are visible before code. Taken from 4a Task 7.
3. **Deploy as an ask kind** (reserved, always owner-approved). The pack defines the hosting command: Vercel, Cloudflare Pages or Fly, chosen at setup. The engine runs it in the sandboxed runner with the token from Keychain and records the URL as a release. A plain-code smoke check (curl plus a page assertion) follows. Rollback redeploys the previous release.
4. **`humanTask` ask kind:** a checklist, prefilled links and paste-back fields that go to Keychain when secret. Examples: buy domain, point DNS, create Stripe account and paste test keys, post a launch thread through a web-intent link, create a support mailbox.
5. **"SaaS launch kit" playbook** in the software pack. Its items: walking skeleton (with default checks), landing page plus waitlist, ToS and privacy drafts (owner-approved document asks), launch post drafts, a README for operating the product.
6. **Critical-path instrumentation:** timestamps for goal, PRD, architecture, first merge, first preview, first deploy and first post; $LE and Δ7d% per phase; owner touches. This becomes the dogfood scorecard.
7. **Live end-to-end test** on a toy goal, using Haiku and Sonnet only.

**Expected demo (6 seats, owner responsive):**

| Milestone | Time from goal |
|---|---|
| Combined brief and architecture ask | ~1 h |
| First merged skeleton and preview | ~2–3 h |
| First deploy | ~3–5 h |
| Landing page, waitlist and approved launch post via human task | same day |

Total usage is about $60–120 LE, or 4–8% of the weekly allowance. About 8–12 owner touches.

**What the demo deliberately does without:**
- the outbox APIs: the owner posts through human tasks;
- funds: the owner buys the domain through a human task;
- the connector catalog: one hosting CLI, configured at setup;
- memory, maps, people management and video.

Each of these is added afterwards, against measured gaps from the demo and dogfood week.
