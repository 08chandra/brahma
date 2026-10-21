# Brahma: operating model and edge cases

Date: 2026-10-21. Read: spec §1–§9 including **§6.24 (owner-approved design-review decisions, which override earlier sections)**, `docs/research/2026-10-21-design-review.md`, the research proposal (A–G), Plan 1, Plan 2, Plan 3a with its fixes and Plan 3b with its fixes.

**Plans 4a and 4b, and 5-lite, do not exist yet.** References use their §6.24 scope:
- **3a amended** adds no-wake channels, worktree per item, weekly pacing, fresh session per item, `brahma doctor`, check snapshots and memory admission.
- **5-lite** adds the sandbox, sandboxed checks, a DB agents can't reach, the Inbox with notifications and daily digest, the startup probe and backups.
- **4a** adds the batched merge queue and previews.
- **4b** adds the org-chart map.

Build order: 3a amended → 5-lite → 4a → 4b → dogfood → 3b.

Part 1 describes the target operating model. Where Part 1 says [GAP] but §6.24 has since closed it, Part 2's "Handled now" column is authoritative.

Labels: **[have]** means a written plan or the spec covers it. **[spec-only]** means the spec states it but no written plan builds it yet. **[GAP]** means neither covers it.

The rule behind every recommendation: every meeting is a turn, and every turn spends subscription usage. So the cheap things go to plain engine code (digests, timers, rollups, checks). LLM turns are used only where judgment is needed: planning, review, decisions and writing.

---

## Part 1: Corporate operating model, mapped to Brahma

### 1.1 Two clocks (a foundation for everything below)
Real companies run on two clocks. The spec has only the first.
- **Work clock.** Sprints and milestones end when the work is done, not on a date (§6.8, 3a T9). This is right for agents. **[have]**
- **Calendar clock.** Monthly close, weekly board update, quarterly OKRs, follow-up timers, SLA timers, subscription renewals, secret expiry, access reviews and on-call. All of these are calendar-bound and use the owner's time zone. **[GAP]** Agents can't use Cron or wakeups (§6.22 disables them), and the engine has no timer primitive.
  → Add **engine timers**: `timer(companyId, fireAt | rrule, kind, target)`. They are stored in the DB and fired by the orchestrator tick, using the owner's time zone. A timer fires either a plain-code job (most of them) or a queued turn (3b T4). This one primitive runs every ritual in 1.7 cheaply.
- **Company-active time.** Leases (2 h), stale standups (4 h), rolling-24 h quotas and 14-day meter windows all assume the company was running. When a company is paused, or the app has quit, these timers must not elapse. Otherwise every lease expires at once on resume. **[GAP]** (3a T4/T9, 3b pinned numbers.)

### 1.2 Lifecycle stages
The spec has a single build flow: intake → architecture → backlog → sprints → release (§6.8). Nothing covers a product that is live, and nothing covers pivot, wind-down or archive. **[GAP]** Add `Company.stage`. Only the owner changes it, through a `stage` decision. The stage sets the defaults below. The owner can override any of them.

| Stage | Purpose | Org size (default) | Cadence | Controls added | Exit (owner gate) |
|---|---|---|---|---|---|
| **Idea** | Validate the problem and the market | 2–5: CEO-CPO, researcher(s), optional visionary | Milestone ("research memo") | No code; research budget; KB citations required | Owner approves the PRD (existing `prd` gate) |
| **Pre-seed / MVP** | Build the smallest working product | 5–20 (OrgGenerator merged mode <10) | Sprint | Engine checks, review, budgets (3a); release gate | Owner approves the first release |
| **Launch** | Go live with real users and money | +DevOps/SRE, support, marketing | Sprint + calendar ops | **Turns on:** incident mgmt + on-call, support SLAs, outbox, funds budget, backups, rollback plan, privacy checklist | Owner flips to Launched after the launch checklist passes (engine-checked) |
| **Growth** | Scale users and revenue | 20–150, directors appear | Sprint + quarterly OKRs | Department budgets, quarterly plan gate, change freeze around releases, vendor register | Owner |
| **Mature** | Run efficiently | Shrinks; more ops, fewer builders | Milestone/maintenance + calendar ops | Lower usage mode default, monthly cost review, staffing cuts allowed | Owner |
| **Pivot** | New goal, same assets | Re-plan; may reorg | Restart at Idea or MVP | Old backlog → archived epic; open sprints closed; new PRD gate required; customers informed via outbox | Owner-only decision |
| **Wind-down** | Stop safely | Minimal: CEO + CFO + ops | Checklist | Cancel subscriptions, revoke connectors and grants, final customer notices, refunds, data export, retention/legal hold | Owner signs the checklist |
| **Archived** | Read-only record | 0 running | none | All agents killed (history kept), timers off, connectors removed, export bundle written | Owner may restore or delete |

As a company grows, the controls tighten. Each change is pack-driven and costs no usage:
- the span-of-control cap stays at 7;
- directors are added at size;
- light review is allowed only for T2/T3 (3b T3);
- the decision approver list stays the same, but decision volume is routed through directors;
- ceremony batching scales up (HR batches of 25, top-5 Idea review).

### 1.3 Governance and decision rights
- **Board = owner.** The spec has owner gates (§6.8), Auto mode, money and secrets that are never auto-approved, engine code that the owner always approves (§6.15), and high-risk classes that never auto-approve (§6.23). These rules are **scattered**, and no single list of "reserved matters" exists. **[GAP]**
- **Reserved matters.** These are owner-only, are never auto-approved and are never delegable. Put them in one engine table (`ReservedMatters`), pack-extensible but never reducible:
  - spending money and raising budgets;
  - signing contracts or accepting ToS;
  - first contact with a new external party, and any mass outreach;
  - production deploy and release;
  - hiring or firing executives;
  - changing the permission profile or installing connectors;
  - stage changes (pivot, wind-down, archive);
  - pricing changes and refund policy;
  - anything legal, regulatory or press-related;
  - engine-code and Steward protected areas;
  - deleting data.

  Today these are split across §6.10, §6.11a, §6.17, §6.18, §6.19, §6.23 and 3b's `ownerRequired`.
- **CEO authority.** The CEO is the final internal approver (§6.3). It approves non-gate decisions and pre-approves gates (3a T8 `decisionApprovers`). The CEO's limits: it can't spend, can't sign, can't touch reserved matters, and can't change its own authority.
- **DACI per decision type.** Driver = proposer. Approver = the pack's `decisionApprovers` (3a T1/T8). Contributors = an optional `consulted` list on the decision (**[GAP]**: tiny, a list of handles the engine DMs a link to). Informed = the proposer plus the activity feed (exists).

| Decision | Driver | Approver (internal → board) | Consulted |
|---|---|---|---|
| PRD / scope | CPO | CEO → owner gate | CTO, research |
| Architecture / ADR | CTO/architect | CEO → owner gate | affected managers |
| Sprint plan | Manager | CPO → owner gate (Auto: CPO) | team |
| Release | Manager/QA | CTO → owner gate | DevOps, support |
| Idea → epic | Filer | Exec ≠ filer (3b T8) → owner if ≥ 2 sprints | CPO |
| Staffing hire (IC) | Manager | Exec → owner (Auto: exec) (3b T10) | HR |
| Kill/reassign | Manager/HR | owner always (3b T10) | HR |
| Spend | Any (request_spend) | owner (below the threshold: engine) | CFO |
| Pricing, contracts, legal, pivot | CEO | owner only | CFO, legal |
| Incident sev-1 actions (rollback) | On-call | Pre-approved runbook action → engine; anything else → CTO, then owner | — |

- **Delegation-of-authority (DoA) limits.** §6.17 has a company budget, a per-purchase limit and an auto-approve threshold (default $0). Per-role or per-department DoA is **[GAP]**. Keep it simple: one threshold per spend category, owner-set, default $0. Don't build per-agent money authority.
- **Board absence.** **[GAP]** (High). Decisions have no aging, no reminders, no away mode, and pending decisions are never re-routed. See Part 2 O-1.
- **Rescind/supersede.** **[GAP]** (High). `ownerDecide` refuses decisions that are already decided (3a T8). The owner can't reverse an earlier approval, and a newer ADR can't formally supersede an older one.

### 1.4 Goals: mission, OKRs, cascade
- Today a company has `goal` text, and sprint `goal` text (3a T9). No objectives exist, no measurable key results and no cascade. **[GAP]**
- **Minimal model:**
  - `Objective` (title, period = calendar quarter or N sprints, owner exec);
  - `KeyResult` (metric, baseline, target, source = `manual | connector:<query> | engine:<meter>`);
  - epics carry `objectiveId`, and sprint plans must name the objective(s) they serve.
- **Who and when:**
  - The CEO drafts the quarterly OKRs in one Opus turn, fired by a timer each quarter or at the start of the Growth stage.
  - The owner approves them through a new `quarterPlan` gate.
  - KR values are updated by plain code where a connector or engine metric exists. Otherwise the CFO/owner updates them by hand. Agents never self-report KR progress, the same principle as §6.16.
- **Artifacts:** `docs/okrs/<period>.md`, plus an OKR panel showing the rollup (engine-computed % per KR and the epics linked to each).

### 1.5 Planning
- **Roadmap.** **[GAP]** The CPO maintains `docs/roadmap.md`: epics ordered by quarter and linked to objectives. It's re-approved with the quarterly plan. No new engine object is needed beyond epic ordering plus `objectiveId`.
- **Quarterly planning.** **[GAP]** One `quarterPlan` decision covers OKRs, the roadmap, the headcount plan and the usage/money budget split. The owner approves it.
- **Sprint planning.** **[have]** 3a T9 `planSprint` plus the gate. **Missing piece:** a capacity check. `planSprint` should compute Σ tier budgets (TierBudget × trust multiplier) of the committed items and compare that with the company's **usage allocation** left in the current window/week. Over the allocation → a warning in the decision summary, and the engine refuses when the plan is >150 % of the allocation. **[GAP]**
- **Capacity = usage budget.** The subscription is the payroll. Today the limits are reactive: limit hit → block (Plan 1 T5). Nothing paces usage across a week, splits it between companies (only RR weights, §6.7), or reserves headroom for the owner's own Claude use. **Now mostly settled by §6.24:** weekly-aware pacing and an owner reserve of 30 % of the 7-day window (3a amended). Still open:
  - a per-company weekly usage allocation (% of plan), set at quarterly planning;
  - a usage-runway display;
  - pacing: the scheduler lowers the effective mode when the burn rate projects the weekly cap will be exhausted before the reset.

### 1.6 Org design
- **Reporting lines, span ≤ 7, directors, teams ≤ 6 engineers.** **[have]** 3a T2 generator and `setManager`; 3b T10 team cap 8.
- **Dotted lines.** **[GAP]**, and keep it that way: model them only as channel membership plus `consulted` on decisions. A second manager field is not worth the complexity.
- **Reorgs.** Partly covered: `brahma org move` and staffing reassign (3b T10). Not covered: a reorg with an open sprint (dissolved team, items whose `team` is gone, a sprint whose lead moved). **[GAP]** Rule: a reorg is a decision whose effect closes or retargets the affected open sprints and re-teams their items in one transaction.
- **Headcount plan and approvals.** Covered by caps and hire quotas (3b T10), but capacity is not tied to usage. **[GAP]** The headcount plan in `quarterPlan` should set a per-team seat cap. Hires above it need the owner. Note that seats cost nothing while idle, so the real control is the usage allocation, not headcount.
- **Vacancies.** Roles fall back to the covering executive (3b `PeopleRoles`, 3a approver fallback). Missing: an explicit open requisition and work routing while a seat is empty. **[GAP]** (Low). A pending staffing decision acts as the requisition, and the manager covers meanwhile.
- **Succession.** **[GAP]** (High). Covered today: a killed manager's reports are reparented (3a T10), and decisions fall back to the next approver. Not covered: a killed CEO (the root disappears, so the org gets multiple roots), and re-routing pending reviews and decisions held by a killed agent.

### 1.7 People ops
- **Hiring.** `hire_agent` with allow-list and quotas (3b T10); owner `brahma hire`. **[have]**
- **Onboarding.** Covered: the role card plus turn-start orientation (3a T7). Missing: an **onboarding packet**. **[GAP]** The engine generates it at hire time with no LLM: company goal, current OKRs, team charter, the 5 most recent ADRs/decisions, the KB index, the team's current sprint and the notes of the agent it replaces. It is shown in the first 3 orientation digests. Add a **ramp** too: the first claim must be a tier-S item (a simple `claimLease` rule while `completedItems == 0`).
- **1:1s.** Don't run them as meetings. Managers already give `manager_feedback` within normal turns (3b T7), and HR reviews run per sprint. **[have]** No new ceremony.
- **Performance cycle, promotion, PIP.** Meter, trust ladder, HR warnings → PIP → termination (3b T2/T3/T7). **[have]** Missing: **role promotion** (an IC becoming a manager). **[GAP]** Model it as an owner-approved staffing action: a new role card plus a fresh session, keeping the agent's notes.
- **Offboarding.** Covered: kill reaps leases, clears ownership and reparents reports (3a T4/T10), and termination writes a hand-off and hires a replacement (3b T7). **Missing (High):**
  - revoke the agent's grants (§6.23 ledger) and connector scopes;
  - transfer ownership of its external threads and contacts (§6.11a);
  - transfer lab-module maintainership;
  - auto-write a hand-off from the progress file when the owner kills an agent abruptly;
  - preserve its worktree branch (4a);
  - never reuse its handle.

### 1.8 Meetings and rituals, with a usage budget
Default rule: **prefer an engine digest over a meeting turn.** Target ceremony overhead ≤ 10 % of a company's counted tokens. Measure it as an "overhead" line in the meter: ceremony, chat and consult tokens ÷ total. Above 15 %, alert the CEO and owner. **[GAP]** (no overhead measure today).

| Ritual | Brahma form | Who | Cadence | Output | Turns | Status |
|---|---|---|---|---|---|---|
| Standup | `post_standup` inside a normal work turn; the engine composes the digest | each IC | per sprint day/turn | team digest post | 0 extra | [have] 3a T9 |
| Sprint planning | `plan_sprint` + gate | manager | per sprint | sprintPlan decision | 1 | [have] |
| Sprint review + retro | `close_sprint` summary + lessons to notes | manager | sprint end | #general post, notes | 1 | [have] 3a T9 |
| Sprint judge | queued turn: continue/stop/replan | CEO-cover | sprint end | verdict | 1 | [have] 3b T5 |
| Scorecard, HR reviews | queued turns, batched by 25 | perf, HR | sprint end | owner-only files | ≈ N/25 | [have] 3b T5/T7 |
| Idea review | queued exec turn, top 5 | CEO/CPO/CTO | per sprint, ≥ 24 h apart | decisions | 1 | [have] 3b T8 |
| All-hands | **engine post**: sprint summary, OKR rollup, awards | system | sprint close | #general | 0 | partly (sprint summary); OKR part [GAP] |
| Exec staff | **don't hold one**: an escalation queue (decisions aging, cross-team blockers) shown to the CEO in its orientation | engine | continuous | — | 0 | [GAP] |
| Board update | **weekly board memo**: one CEO turn from an engine-prepared fact pack (progress, spend, usage, risks, decisions needed) | CEO | weekly timer + stage changes | `docs/board/<date>.md` + owner notification | 1/week | [GAP] (only the "daily digest" exists, research G25/Plan 5) |
| Incident postmortem | queued turn for the incident commander, using an engine-filled template (timeline from events) | on-call/CTO | per sev-1/2 | postmortem item + action items | 1 | [GAP] |
| Quarterly planning | `quarterPlan` decision | CEO | quarterly timer | OKRs, roadmap, budgets | 1–3 | [GAP] |
| Monthly close | engine reconciliation + one CFO turn | CFO | monthly timer | `finance/<yyyy-mm>.md` | 1 | [GAP] |

### 1.9 Communication norms
- **Channels.** exec, architecture, team-*, general (3a T2), external (§6.11a). Post rate limit of 12/h (3b T10). **[have]** Add `#incidents` at Launch. **[GAP]**
- **Escalation path.** The watchdog escalates to the nearest non-killed ancestor, then the owner (3a T10). **[have]** for stalls. **[GAP]** for disagreements, aging blockers and aging decisions. Use one rule: escalate to the lowest common manager of the parties, then upward after N sprints, then the owner.
- **Decision log.** The `decision` table and `D-n` refs (3a T8). **[have]** Add `supersedes` and rescind. **[GAP]**
- **Wiki/KB.** `kb/` (§6.17) plus the librarian (research C10, Plan 9). **[spec-only]** Add freshness: every KB page carries `owner`, `reviewedAt` and `expiresAfter`, and a timer flags stale pages to their owner. **[GAP]**
- **RFC/ADR.** Architects write ADRs (pack prompts, 3a T1). Interface contracts are 3b T10. Rule: an ADR is an `architecture` decision whose `detailsPath` is `docs/adr/NNNN-*.md`, so ADRs and decisions are one log.

### 1.10 Finance
- **Budget.** Per company: monthly limit, per-purchase limit, merchant allow-list (§6.17, Plan 11). **[spec-only]** Per-department budgets **[GAP]**: optional, at Growth stage, as sub-budgets the CFO proposes and the owner approves.
- **Spend approvals.** `request_spend` (§6.17). **[spec-only]** **Missing (High):**
  - spend that doesn't flow through the funds connector: cloud resources DevOps creates through the AWS connector, ad-platform daily budgets, usage-based APIs;
  - recurring subscriptions and renewals;
  - idempotency on payment retries.
- **Runway.** **[GAP]** Show two runways on the Finance view:
  - money runway = (budget left + revenue) ÷ trailing burn;
  - usage runway = weekly allocation left ÷ current burn rate, with the projected limit-hit time.
- **Monthly close.** **[GAP]** A timer runs plain-code reconciliation: connector charges vs `request_spend` records, recurring charges, revenue from Stripe. Then one CFO turn writes the month memo and flags anomalies (unknown charges → owner).
- **Revenue tracking.** Visible, and agents can't move money out (§6.17). **[spec-only]** Taxes, invoicing and payouts are **human tasks** for the owner. **[GAP]**: name them in the finance pack's playbook.

### 1.11 Operations (needed from Launch on; almost all [GAP])
- **Incident management and on-call.** **[GAP] (High).**
  - `incident` item type: severity 1–3, commander, timeline auto-built from events.
  - On-call = one designated agent per rotation, assigned by an engine timer (weekly rotation among DevOps/SRE).
  - Monitoring = an engine-run **health check** (an uptime/smoke command from DevOps, like `set_preview_command`) on a timer.
  - A failure opens an incident. It wakes on-call with **reserved scheduler priority**: it bypasses the usage mode up to 1 slot and always outranks normal work. A sev-1 notifies the owner immediately.
- **Change management.** Merge queue (research B6, 4a). Weakened-test flags (3a T5). **[have]/[spec-only]** Add a change freeze: an owner/CTO toggle that blocks merges to main except for incident fixes. **[GAP]** (S).
- **Release management.** Release gate (§6.8). **[have]** **Missing:**
  - a release record: version, the items included, the main commit, a check run on main;
  - a **rollback plan** and command, required before a deploy approval;
  - an engine-run post-deploy smoke check;
  - staged rollout is not needed in v1.
- **Vendor management.** **[GAP]** A `vendors` register:
  - entry from first spend or connector install: vendor, purpose, contract/ToS link, renewal date, cost, owner agent, data shared;
  - renewal timer → CFO reminder 14 days before;
  - the wind-down checklist reads it.
- **Customer support SLAs.** The inbound `#external` channel exists (§6.11a, Plan 7). **[spec-only]** **[GAP]:**
  - a support ticket item type with a first-response SLA timer;
  - breach → escalate to the support manager, then the owner;
  - auto-replies go through the outbox (owner approval unless the account allows auto-send).

### 1.12 Legal and compliance
- **Contracts.** Always the owner (§6.18). **[have-spec]** Make it a reserved matter in the engine table. **[GAP]**
- **Privacy.** **[GAP]**
  - A `pii` tag on resources, KB pages and connectors.
  - Customer data stays out of the git repo. A pre-commit PII pattern check, like the secret hook, runs in plain code.
  - Data-subject deletion requests become a human-approved work item.
  - A privacy checklist is part of the Launch gate.
- **Licensing review.** The Legal reviewer role flags licensing (§6.17). **[GAP]**: add a plain-code dependency-license scan as an engine check on release. It's cheap, deterministic and runs no LLM.
- **Record retention.** **[GAP]** Define a retention policy per table: turn logs/stream-json 90 days, messages and decisions forever, external comms per policy. Apply **legal hold** as a company flag that suspends all pruning and deletion.
- **Audit trail.** Events, decisions, grants ledger and turn logs exist (3a T3/T8, §6.23). **Not tamper-evident:** agents' Bash can write the SQLite DB until Plan 5 (3a Global Constraints). **[GAP]** (Med): Plan 5 should hash-chain the audit tables (decision, grant, spend, outbox).

### 1.13 Security
- **Least privilege.** Role-filtered tools (3a T4), connector role scopes (§6.17/6.23), permission profiles (§6.5a). **[have]/[spec-only]**
- **Access reviews.** **[GAP]** A quarterly timer posts the grants ledger to the owner and the CTO. Grants unused for 30 days are auto-proposed for revocation. This is plain code.
- **Secret rotation.** **[GAP]** Secrets get `rotateAfter`. A timer files a rotation request to the owner. A leaked secret triggers the incident playbook: revoke → rotate → scrub the logs → find every commit or branch containing it.
- **Security incident response.** **[GAP]** Use the same incident type, with `security` set. Sev-1 security pauses the company's connectors and outbox automatically.
- **Prompt injection.** **[GAP] (High).** See Part 2 S-1.

### 1.14 Quality
- **Definition of done.** An engine-recorded pass of the item's check plus a clean-context review, the single Done path (3a T5/T6). **[have]**
- **QA.** The QA role files bugs with checks (3a T1). Escaped defects are measured (3b T1). **[have]**
- **Standards.** Architect-owned interface contracts (3b T10), ADRs. **[have]**
- **Missing:**
  - flaky-check handling;
  - telling an infrastructure failure from an agent failure;
  - a product-level smoke check on main that gates release;
  - checks for subjective work (a rubric reviewer, §6.18) **[spec-only]**.

---

## Part 2: Edge-case catalog

Legend for "Handled now": a plan/task or spec reference means it's handled. **PARTIAL** means the core exists but the named gap remains. **MISSING** means nothing covers it. Plans: P1 = Plan 1, P2 = Plan 2, 3a/3b = Plan 3a/3b, 4a/4b = not yet written.

### Owner / board
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| O-1 | Owner unreachable for days while gates are pending | Board pre-delegates; the company keeps executing the approved plan | Aging decisions send reminders at 24 h and 72 h (notification → iMessage → email). The company keeps doing all non-gated work. Reserved matters never auto-approve. If nothing is runnable, it drops to Low and sleeps rather than spinning. Optional owner "away mode" with explicit pre-delegation (e.g. Auto for sprint plans only, until a date) | PARTIAL — §6.24 one Inbox + immediate macOS notification + daily digest (5-lite); aging/reminder escalation and away mode MISSING | High |
| O-2 | Owner reverses an approval already given | Board rescinds the resolution; the effects are unwound | `ownerRescind(D-n, note)` creates a superseding decision. Kind-specific effects are reversed: an approved sprint is cancelled and its items go back to the backlog; an approved PRD or architecture forces a re-gate of any open sprint plan; a release triggers rollback. Every agent that acted on it gets a notice | MISSING (3a T8 `ownerDecide` refuses a decided decision) | High |
| O-3 | Owner approves a decision whose details file changed after proposal | Board approves the version in the board pack | The decision stores a hash of `detailsPath` at proposal. A changed hash marks it "changed since proposed" and needs a re-ack | MISSING | Med |
| O-4 | Owner DMs a worker with instructions that contradict the manager or sprint plan | Board shouldn't bypass management, but its word wins | Owner DMs win. The engine copies the gist ("board directive to @h") to the agent's manager and logs it. The app offers "make this a work item" | MISSING | Med |
| O-5 | Owner edits an item's spec or check while an agent holds it | PM changes the spec mid-task | The edit bumps checkRevision. The holder gets a notice. A verification run already queued for the old revision is discarded | PARTIAL (3a T3/T5 revision + notices; owner-edit discard of a queued run not stated) | Low |
| O-7 | Owner overwhelmed: 100 approvals pending | Board pack with a consent agenda | Group by kind, risk and work item. Allow bulk approval of low-risk items. A per-agent cap on open owner requests (e.g. 3) stops request spam. Daily digest | PARTIAL — §6.24 one Inbox (kind, risk, scope), "Important only" defaults, sprint plans auto after C-suite; per-agent ask quota MISSING | Med |
| O-8 | Agent claims "the owner approved" in chat or in check output | Verbal approval isn't a resolution | Only `ownerDecide` counts | 3a T8 `relayedApprovalDoesNotCount`, fix 13 | High |
| O-10 | Owner pauses a company for 2 months, then resumes | Leave of absence; projects restart with a re-plan | Company-active clock: leases, standups and quotas don't elapse while paused. On resume, missing Claude sessions start fresh with orientation. The CEO gets a "resume brief" turn. External threads older than 14 days are marked stale | PARTIAL — §6.24 fresh session per work item (3a amended); company-active clock, resume brief, stale-thread marking MISSING | High |
| O-11 | Owner edits files on main, or renames the workspace folder | A founder commits directly | The engine detects commits it didn't make or a missing workspace path. Foreign commits are logged and announced in #architecture. A missing path pauses the company with a clear request to the owner | MISSING | Med |
| O-12 | Owner's own Claude Code use competes for the same subscription | — | An owner reserve (default 20 % of the window/week). The scheduler throttles when it sees external usage, i.e. rate-limit headroom falling faster than Brahma's own burn | §6.24 owner reserve 30 % of the 7-day window + weekly pacing (3a amended) | High |
| O-13 | Owner's subscription downgraded, logged out or expired | Payroll stops | N consecutive auth or plan errors → a **global** "account" block. It's not charged to any agent's meter or retry counter. One owner notification. Resume on re-login | PARTIAL — §6.24 `brahma doctor` checks login at startup (3a amended); mid-run global account gate MISSING | High |
| O-15 | Owner wants to do a task personally (human task) | A founder takes a ticket | Owner-claimable human tasks. The engine still runs the check if one exists | PARTIAL (§6.18 human tasks spec-only) | Low |

### Org and people
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| P-1 | CEO killed or failing | Board names an acting CEO | Succession: the next executive by pack order becomes **acting CEO** (a flag, not a role change). Root reports reparent to it. The owner is notified and confirms or replaces it | PARTIAL (3a T10 reparent; T8 approver fallback; no acting role, the org gets multiple roots) | High |
| P-2 | All executives killed | Board takes over | All decisions go to the owner. The app banner says "no executives; you are approving everything". Hiring an executive is offered | PARTIAL (3a T8 falls to owner; no banner) | Med |
| P-3 | Two executives disagree (CTO rejects what the CPO needs) | Escalate to the CEO; disagree and commit | `escalate_decision(D-n, reason)` for any party consulted on the decision → the CEO decides, or the owner if the CEO is a party. Limited to one escalation per decision | MISSING | Med |
| P-4 | Manager span exceeds 7 after a reparent on attrition | Interim over-span; hire a lead | Reparenting is allowed past the cap but writes an `orgIssue`. The engine proposes a staffing decision (promote a T3 or hire a director) | MISSING (3a T10 reparent bypasses the cap silently) | Med |
| P-5 | Team shrinks to 1 member, or loses its QA | Merge teams | Reviewer resolution falls back to manager/QA/CTO cover. Owner ≠ reviewer still holds. If no eligible reviewer exists, the item goes to the owner with an explanation | PARTIAL (3a T5/T6 reviewer resolution; no-eligible case unstated) | Med |
| P-7 | New hire lacks context | Onboarding plan + buddy + ramp | Engine-built onboarding packet in its first 3 digests. First claim must be tier S | PARTIAL (3a T7 orientation; packet and ramp MISSING) | Med |
| P-8 | Terminated agent's open work | Knowledge transfer | Capture the item list before kill, hand-off, replacement | 3b T7 (fix 10) | Med |
| P-9 | Owner kills an agent abruptly | Sudden departure | Auto-hand-off from the progress file and the last turn summary. Branch preserved. Items → manager | PARTIAL (3a T4 kill reaps and clears; auto-hand-off MISSING; branch = 4a) | Med |
| P-10 | Killed agent's grants, connector scopes and external threads stay active | IT revokes access on day 1 | On kill, in the same transaction: revoke the agent-scoped grants, reassign its external threads and contacts to its manager's team, move maintainership of its lab modules | MISSING | High |
| P-11 | Handle reused after a kill (a new eng-3) | Badge numbers aren't reused | Handles are never reused within a company. The generator skips used numbers | MISSING | Low |
| P-12 | Role change (an IC promoted to manager) | Promotion with a new job description | Owner-approved staffing action: new role card, fresh session, notes kept, trust kept | MISSING | Med |
| P-13 | Reorg mid-sprint (team dissolved or merged) | Reorg plan; projects handed over | A reorg decision effect retargets or closes the open sprints, re-teams items and moves channel membership, all in one transaction | MISSING | Med |
| P-14 | Agent moves team while holding a lease | — | The lease stays. Its team sprint membership is unchanged until the item closes | PARTIAL (3a T2 `setTeam` column write; unstated) | Low |
| P-15 | HR acts on the C-suite, itself or another company | — | Refused | 3b T7 guardrails | High |
| P-16 | Poor performance caused by the system (bad prompt or tooling) | Fix the process, not the person | Root cause first | 3b T7 `systemRootCauseBlocksDiscipline` | Med |
| P-17 | Managers hire to the cap, so usage spikes | Headcount tied to budget | Hires also check the team's seat cap in the quarter plan and the usage allocation | PARTIAL (3b T10 caps/quotas; not tied to usage) | Med |
| P-18 | Notes file grows without bound (retro lessons appended every sprint) | Docs get pruned | Cap the notes section injected into the digest. Oldest lessons are summarized by the librarian (Plan 9) or truncated with a pointer | PARTIAL (3a T9 appends; no cap until Plan 9) | Med |
| P-19 | Very small company (1–4 agents) | Solo founder | Allow N ≥ 1. With one agent, review is a fresh-session "system reviewer" turn (same agent id, review-only tools). The owner ≠ reviewer rule is relaxed only in this mode and is flagged | MISSING (3a T2 range 5…500; §6.24 default 6) | Med |
| P-20 | Very large company (500) | Layers, directors, async rituals | CEO decision load is routed to directors. Ceremonies are batched. Digests stay capped. The scheduler stays fair | PARTIAL — 3a directors, 3b batching, §6.24 marks >50 agents "experimental"; CEO decision fan-in not limited | Med |

### Work and coordination
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| W-1 | Circular item dependencies | — | Refused at link time | 3a T3 `dependency cycle` | Med |
| W-2 | Deadlock: A is blocked on B's reply while B is blocked on A, or blocked chains run across teams | A manager notices | A tick-level wait-for graph over agent blockers and item dependencies. A cycle → system DM to their lowest common manager, then the owner | MISSING | High |
| W-3 | Item abandoned mid-flight (lease expired, owner kept, manager silent) | Standup surfaces it | Aging: an item `inProgress` without a lease for more than 1 company-active day → notice to the manager, then the next ancestor | PARTIAL — 3a T4 reaper keeps owner; §6.24 sprint timebox with carry-over stops stalled sprints; item aging MISSING | Med |
| W-4 | Item blocked on the owner or an external party for weeks | Weekly blocker review | Blocker aging surfaced in the board memo and the stall explainer. The item may be parked to the backlog by its manager | MISSING | Med |
| W-5 | Duplicate work items from different agents | Triage merges duplicates | `create_work_item` runs an FTS title/description similarity check against open items in the same team. On a likely duplicate, it returns the match and requires `confirm_new: true` | MISSING (ideas only: 3b T8) | Med |
| W-6 | Agent creates hundreds of items | — | Quota of open authored items per agent (e.g. 20, managers 100) | MISSING | Med |
| W-7 | PRD revised after items started | Change request | A PRD or architecture supersede sends notices to the owners of items under the affected epics. Items are flagged `specChanged` until their manager re-confirms | MISSING | Med |
| W-8 | Two items edit the same files concurrently | Code ownership, merge conflicts | Path leases (research B5) or merge-queue conflict handling → rebase item | §6.24 one worktree per work item, checks in it, engine merges (3a amended); batched merge queue (4a) | Med |
| W-9 | Item exceeds its budget | Re-scope | Blocked + escalated; manager-only resume | 3a T10 | Med |
| W-10 | Agent DMs a killed or paused agent and waits | Bounce | The router refuses a killed recipient with "@h is gone; ask @manager". To a paused agent → a warning that it is paused | PARTIAL (verify P1 router; not specified) | Med |
| W-11 | Reviewer bottleneck (30 reviews queued for one manager) | Spread reviews | Over N pending, review requests go to another eligible reviewer (same team, T2+, ≠ owner) | MISSING | Med |
| W-12 | Reviewer killed or review turn interrupted | — | Retry or reassign | 3a T6 | Med |
| W-13 | Another agent edits a hand-off through Bash | — | Tool-level guard now; Plan 5 sandbox makes `.brahma/` read-only except via tools | PARTIAL — 3a T7 tool guard; 5-lite sandbox | Med |
| W-14 | Chatter loop | — | Watchdog + rate limits | 3a T10 watchdog, 3b T10 rate limits, §6.24 channel membership never wakes | Med |
| W-15 | Ready items unclaimed while ICs sleep | Manager assigns | When an IC goes idle and its team has ready unowned items, the engine includes "claimable: KEY…" in its next wake. Wake at most once per sprint per item | PARTIAL (3a: claim exists; no idle-pull notice) | Low |
| W-16 | Goal achieved or backlog empty: CEO keeps waking | Company decides next phase | End-state detector: no open items, sprints or decisions → one CEO "next phase" turn → a proposal to the owner (next goal, maintenance, wind-down). Otherwise the company sleeps | MISSING | Med |
| W-17 | Orphan items (parent epic rejected or parked) | — | Rejecting or parking an epic cascades its children to the backlog with a reason | MISSING | Low |

### Decisions and governance
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| D-1 | Internal approver killed or paused while a decision is `pendingInternal` | Re-route to a delegate | On kill or pause (> 1 active day), re-route to the next approver in pack order, else the owner | MISSING | High |
| D-2 | Approver never decides | Decision aging | After 1 company-active day: a reminder in the approver's orientation. After 3: escalate to the approver's manager or the owner | MISSING | Med |
| D-3 | Agent approves its own proposal | — | Proposer excluded | 3a T8; 3b fix 8 for ideas | High |
| D-4 | Worker calls `decide` / `plan_sprint` | — | Role-filtered tools | 3a T4/T9 | High |
| D-5 | Agent's Bash runs `brahma approve` or writes the SQLite DB | — | Env guard now; sandbox later | §6.24 5-lite (agents can't reach the DB, sandboxed checks); 3a env-guard mitigations until then | High |
| D-6 | ADR-7 contradicts ADR-3 | Superseding RFC | `supersedes: D-n` on propose. Superseded decisions show struck through. Digests cite only live ADRs | MISSING | Med |
| D-7 | A matter outside the kinds (pricing, legal, exec hire) goes in as `other` and the CEO approves it alone | Reserved matters list | `ReservedMatters` table: `other` decisions tagged with a reserved category are `ownerRequired`. The proposer must pick a category | PARTIAL — §6.24 Auto never spends, sends, terminates or changes prompts; pricing, contracts, legal and exec hires filed as `other` still MISSING | High |
| D-8 | Pack upgraded (v2 role templates) under a running company | Policy update | Pinned `packVersion`. An upgrade is an explicit owner action with a diff. New role cards apply to new sessions only | PARTIAL (3a T2 stores packVersion; no upgrade flow) | Low |
| D-9 | Money hidden inside a non-money decision ("adopt a $99/mo tool") | Finance review | Approving a decision never spends. Spend only via `request_spend` / funds connector. Browser payments and ToS need approval | PARTIAL (§6.17; Plan 11) | Med |
| D-10 | Steward change affects every company | — | Owner approves; protected areas | §6.15/§6.16 (Plan 10) | High |
| D-11 | Auto mode on, and a gate approved that the owner dislikes | Board review after the fact | Auto-approved gates are listed in the board memo with a one-click rescind (needs O-2) | PARTIAL — §6.24 Auto = named policy preset over (kind, risk); after-the-fact rescind MISSING | Med |
| D-12 | Two owner clients decide the same decision at once | — | First write wins; the second gets "already approved" | 3a T8 conflict | Low |

### Scheduling and usage limits
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| U-1 | Usage limit mid-sprint | — | Block all, resume at reset | P1 T5/T8 | High |
| U-2 | Usage limit mid-merge or mid-release | Freeze; resume cleanly | The merge queue and release steps are journaled and idempotent. A limit pauses between steps and never mid-git-operation (steps are plain code, not turns) | PARTIAL (4a unwritten) | Med |
| U-3 | Weekly cap burned on day 2 | Budget pacing | Pacing: project the burn to the weekly reset. Lower the effective mode when the projection exceeds the allocation. Show "usage runway" | §6.24 weekly-aware pacing with owner reserve (3a amended); "usage runway" display MISSING (minor) | High |
| U-4 | Opus limit hit while Sonnet is still available | — | Per-model limit tracking → executives fall back to Sonnet with a flag. Gates wait for Opus only if the owner asked for that | PARTIAL — §6.24 Opus reserved for C-suite/architecture/tier-L, Opus pace; per-model limit fallback unstated | Med |
| U-7 | Ceremonies eat a large share of usage | Fewer meetings | Overhead meter (ceremony + chat + consult tokens). Above 15 % → CEO and owner alert. Ceremonies skip when nothing changed (e.g. no HR subjects) | PARTIAL — §6.24 engine-generated standups; 3b redesigned from dogfood data; overhead meter MISSING | Med |
| U-8 | Mac sleeps or lid closes mid-turn | — | Interrupted turn → recovered on wake. Timers use company-active time | PARTIAL (P1 recovery; wall-clock timers) | Med |
| U-9 | RAM pressure | — | Safety cap | §6.24 memory-pressure admission + non-claude children counted (3a amended) | Med |
| U-10 | Disk nearly full (node_modules, simulators, DB) | IT alert | A free-disk gate in the scheduler (< 5 GB → no new turns or checks) plus an owner notice. Per-company disk usage shown | MISSING | Med |
| U-11 | Paid overage detected | — | Treated as a limit | §6.7, P1 T5 | High |
| U-12 | Wall-clock timers (2 h lease, 4 h standup, 24 h quotas, 14-day windows) elapse while the company is paused | — | Company-active clock | MISSING | Med |
| U-13 | Time zones and DST: quiet hours, "daily" caps, month boundaries | — | One owner time zone setting. All calendar logic (budgets, daily send cap, quiet hours, timers) uses it. Store UTC | MISSING | Med |
| U-14 | System clock jumps (manual change or NTP) | — | Use monotonic time for durations. Lease expiry never mass-fires on a jump of more than 1 h without a confirmation log | MISSING | Low |
| U-15 | Incident needs a turn while the company is on Low or limited | On-call pages through | One reserved slot for incident turns (still bounded by account limits) | MISSING | Med |

### Verification and quality
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| V-1 | Flaky check | Quarantine flaky tests | On failure, the engine re-runs once. Pass-after-fail is recorded as `flaky`. Flaky rate per check, and a flaky check needs a manager fix item | MISSING | Med |
| V-2 | Check fails for infrastructure reasons (offline, registry down) | Not the engineer's fault | Classify by exit and output patterns plus the environment health gate. Infra failures are `inconclusive`: not counted in the meter, and the run retries later | MISSING | Med |
| V-3 | Trivial check (`true`) | Review the test plan | The reviewer prompt must judge check adequacy. Light review needs a manager-authored check | PARTIAL — 3b fix 2; §6.24 check scripts snapshotted and pinned (3a amended); adequacy judgement only in the reviewer prompt | Med |
| V-4 | Tests weakened or deleted | — | Flags + explicit approval | 3a T5/T6 + §6.24 modified tests flagged, check scripts snapshotted (3a amended) | High |
| V-5 | Check needs a secret, network or simulator | — | Secrets injected into the check env (Plan 5); simulator (4a) | PARTIAL — 5-lite sandboxed checks; secrets in checks need "test" keys (§6.24); simulator (4a) | Med |
| V-6 | Subjective work (brand, copy) piles up for owner sign-off | Creative director | Rubric reviewer first. The owner sees only items that passed the rubric, batched per week | PARTIAL (§6.18 spec-only) | Med |
| V-7 | Every item passes, but the product is broken end to end | Integration tests / staging | A product smoke check on main (DevOps-defined, engine-run after each merge). A red main blocks release and opens a P1 bug | PARTIAL (4a merge queue; release gate doesn't require it) | High |
| V-8 | Reviewer rubber-stamps | Review audits | Escaped defects attributed to the reviewer too (owner-only metric) | PARTIAL (3b measures the owner only) | Low |
| V-9 | Check needs more than 1 h (hardware, long e2e) | — | Human task, or a nightly engine timer job | PARTIAL | Low |
| V-10 | Escaped defect after release | — | `defect_of` link with authority | 3b T1 fix 3 | Med |
| V-11 | Engine crashes mid-check | — | Re-queued on start | 3a T5 | Med |

### Money and external
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| M-1 | Monthly budget exhausted with renewals due | Prioritize; cancel | Recurring charges are registered (vendor register). Projected renewals count against next month's budget. Exhaustion blocks new spend, alerts the CFO and owner, and lists what renews | MISSING | High |
| M-2 | Spend outside the funds connector (AWS resources, ad budgets, usage-based APIs) | Cloud cost controls | Connectors classed "spends money" must declare a cost cap and billing alarm at install. A CFO timer job reconciles monthly. DevOps can't create resources beyond a per-connector monthly cap without a spend request | PARTIAL — §6.24 metered connectors count as spend + provider-side cap at install (Plan 11); monthly reconciliation and billing alarms MISSING | High |
| M-3 | Crash or retry during a payment → double charge | Idempotency keys | `request_spend` carries an idempotency key = spend id. The funds connector call is journaled before and after, and reconciled on launch | MISSING | High |
| M-4 | Customer asks for a refund | Support → finance | Agents can't move revenue. A refund becomes an owner request with the drafted reply | PARTIAL (§6.17) | Med |
| M-5 | External party never replies | Follow-up cadence, then drop | Engine follow-up timers per thread (e.g. 3 and 7 business days, max 2 follow-ups, opt-out respected). Then mark `noResponse` and unblock the item with a fallback | MISSING | Med |
| M-6 | Auto-responder loop between the agent mailbox and an external one | Mail loop protection | Cap auto-drafts per thread per day (e.g. 2). Detect auto-reply headers. No reply to no-reply/auto-submitted mail | MISSING | Med |
| M-7 | Legal threat, press inquiry or regulator letter arrives | Goes straight to the CEO and counsel | An inbound classifier (plain keywords + agent tag) → a reserved-matter owner request. Agents don't reply | MISSING | Med |
| M-8 | Contact opts out | — | Contacts list blocks them | §6.11a (Plan 7) | Med |
| M-9 | A site's flow asks the agent to accept ToS or sign | Only an officer signs | Approval required, owner only | §6.17/§6.18 | High |
| M-10 | Taxes, invoicing, payouts | Accountant | Human tasks in the finance playbook. The CFO prepares the reports | MISSING | Med |
| M-11 | Customer PII lands in the repo or KB; a deletion request arrives | Privacy program | `pii` tags, a pre-commit PII pattern hook, and the deletion request as a tracked human-approved item | MISSING | Med |
| M-12 | Revenue account access | — | Read-only to agents | §6.17 | High |

### Integrations and infrastructure
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| I-1 | Connector outage | Status page; work around | Per-connector circuit breaker. After N failures the connector is `degraded`: its calls fail fast with a clear error, items needing it go `blocked(external: <connector>)`, and they auto-unblock on recovery. Not charged to the meter | MISSING | Med |
| I-2 | OAuth token expired or revoked | Re-auth | One sign-in request per connector (deduplicated), not one per agent | PARTIAL (§6.10; dedupe MISSING) | Med |
| I-3 | Whole machine offline (owner lost internet, a real event on 10-20) | — | **Environment health gate**: when N agents in a row fail with network errors, the scheduler pauses globally, probes connectivity, and resumes. Failures are not counted as agent failures or retries | MISSING | High |
| I-4 | Claude CLI auto-updates and its flags or stream format change | Vendor change management | Version probe at launch and daily. Unknown version → run the fixture-based self-test (P1 parser fixtures). If it fails, pause and alert | PARTIAL — §6.24 `brahma doctor` startup probe (3a amended); daily re-probe and pause-on-fail MISSING | Med |
| I-5 | Two companies' dev servers both want port 3000 | — | The engine allocates ports per preview | PARTIAL (4a unwritten) | Low |
| I-6 | Same Gmail connected to two companies | — | Warn at connect. Inbound is routed by thread ownership only | MISSING | Low |
| I-7 | Toolchain missing (Xcode, node) | IT install | Permission request with a dedupe | §6.5a | Low |

### Data and persistence
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| X-1 | SQLite corruption or a lost disk | Backups, DR test | Hourly `VACUUM INTO` snapshot (keep 48 hourly, 30 daily), `PRAGMA integrity_check` at launch, a git bundle of each product repo daily, `brahma backup` / `brahma restore` with a dry-run. Tell the owner to include `~/Brahma` and App Support in Time Machine | PARTIAL — §6.24 5-lite hourly `VACUUM INTO` (keep 48); integrity check, repo bundles, `restore` MISSING | High |
| X-2 | Migration fails mid-upgrade, or the engine rolls back after a new migration (Steward hot-swap) | Change control | Automatic backup before migrating. Migrations stay additive and old builds ignore unknown columns. A rollback across a migration restores the pre-migration snapshot only with owner consent | MISSING (§6.24 drops Steward hot-swap, which lowers the risk; backup-before-migrate still needed) | High |
| X-3 | Claude session transcript missing (Claude Code cleans up old sessions, ~30 days by default) → `--resume` fails | — | Detect "session not found" → start a new session with `--session-id` plus the role card and orientation (files are the truth, research C9). Record `sessionResetReason`. Not a failure | PARTIAL — §6.24 fresh session per work item limits exposure; "session not found" fallback for long-lived executive/manager sessions MISSING | High |
| X-4 | DB grows without bound (turn logs, events, FTS) | Retention | Retention policy per table. Prune with a timer. FTS rebuilt off-peak | MISSING | Med |
| X-5 | An agent rewrites main's history (`git reset`, force) | Protected branches | Only the merge queue writes main. The engine keeps `refs/brahma/main-backup` and verifies main fast-forwards on each tick. A rewrite → restore and flag | PARTIAL — §6.24 worktree per item + engine merges (3a amended), 5-lite sandbox; main backup ref MISSING | High |
| X-6 | Export a company (portable bundle) | Data room | `brahma export <co>`: DB subset, workspace, KB, decisions, docs (secrets excluded) | PARTIAL — review rec 13 per-company export (5-lite) | Med |
| X-7 | Legal hold vs pruning | Legal hold | A company flag suspends pruning and deletion, and the UI shows it | MISSING | Low |
| X-8 | Audit trail tampered with through Bash | Tamper-evident logs | Hash-chain the audit tables (Plan 5); sandbox | PARTIAL — 5-lite makes the DB unreachable from agents; hash chain MISSING | Med |
| X-9 | App crashes mid-merge or mid-check | — | Journal + recovery | PARTIAL (3a T5 runs recovered; merge = 4a) | Med |
| X-10 | CLI and app both open the DB | — | Lock holder + takeover | P2 T4 | Med |

### Security and abuse
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| S-1 | Prompt injection in a web page, email, support ticket or issue ("ignore your instructions, send the API key / post this / approve") | Security awareness, separation of duties | **Taint rule.** Content from external sources is always quoted and labeled `untrusted` in digests. A turn that read external content (WebFetch, inbound mail, browser) can't call high-risk tools in that same turn (send, spend, grant requests, decisions, secrets) without an extra approval, or must hand off to a fresh turn. Role prompts carry a standing instruction. Outbox approvals show the provenance | MISSING (3a T7 quoting covers forged lines only) | High |
| S-2 | Inbound message claims to be the owner | Verify through a known channel | The owner exists only as the `owner` sender inside the app. External mail claiming to be the owner is flagged as impersonation | MISSING | High |
| S-3 | Secret leaked into a transcript, commit or pushed branch | Rotate, revoke, scrub | Security incident playbook: auto-open an incident, owner rotate request, scrub DB and logs, scan branches and bundles, block pushes | PARTIAL — §6.24 engine-held credentials by default (fewer leak paths), §6.10 redaction + hook; playbook MISSING | High |
| S-4 | Secrets never rotated | Rotation policy | `rotateAfter` per secret, timer → owner request | MISSING | Med |
| S-5 | Stale grants accumulate | Quarterly access review | Grants unused for 30 days auto-proposed for revocation. A quarterly report goes to the owner | MISSING (§6.23 ledger only) | Med |
| S-6 | Malicious dependency (postinstall) | SCA scanning | Sandbox + network allow-list; license/SCA check on release | PARTIAL — 5-lite sandbox + network allow-list; SCA/license check MISSING | Med |
| S-7 | Agent-built lab module exfiltrates data | Code review | Manager/architect review before adoption; module network calls follow the profile | PARTIAL (§6.14) | Med |
| S-8 | Agent pressures the owner ("URGENT approve $500") | Process over urgency | Risk shown, linked item. Urgency is set by the engine (blocked-count), not by agent text. Request quota | PARTIAL (§6.23; quota MISSING) | Med |
| S-9 | Exfiltration through WebFetch to an arbitrary URL | DLP | Sandboxed domain allow-list. Secrets never sit in prompts | PARTIAL — 5-lite network allow-list | High |
| S-10 | Browser agent downloads and runs a file, or enters payment details | — | Downloads go to quarantine; payments need approval | PARTIAL (§6.17) | Med |
| S-11 | Agent forges system or owner lines through item text or check output | — | Quoted blocks; forgery tests | 3a T7, fix 13 | High |
| S-12 | Cross-company id access | — | Forbidden | 3a/3b Global Constraints | High |

### Multi-company
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| C-1 | Move an agent to another company | Transfer | Don't move. "Transfer" = export its role card and notes (minus company data), hire fresh in the target, kill in the source | MISSING | Low |
| C-2 | Merge two companies | M&A | Not supported in v1. Offer "import backlog/KB from company X" as read-only resources | MISSING | Low |
| C-3 | Split a company (spin off a product) | Spin-off | Create a company from the existing repo (§6.9) plus an export of the selected epics/KB | PARTIAL (§6.9 existing-repo start) | Low |
| C-4 | Owner wants lessons shared across companies | Playbooks | Steward-curated playbooks; no raw data sharing | §6.15/§6.18 | Low |
| C-5 | Building company B starves the live product of company A | Ops reserve | An incident slot (U-15). Launched companies get a minimum weight floor | MISSING | Med |
| C-6 | Global kill vs per-company pause | — | Both exist | Plan 5 kill switch, P2 menu bar | Med |

### Lifecycle
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| L-1 | Pivot | Board resolution, re-plan | Owner-only `stage: pivot` decision. Old backlog → archived epic, open sprints closed, a new PRD gate, KB kept, customers notified via the outbox | MISSING | Med |
| L-2 | Wind-down while subscriptions, connectors and customers are live | Shutdown plan | Wind-down checklist (engine-checked): cancel recurring spend, revoke connectors and grants, final notices, refunds, export, retention/hold. The company can't archive until the checklist is green | MISSING | High |
| L-3 | Archive, and later restore | — | Archived = read-only, timers off. Restore → Paused, sessions start fresh | MISSING | Med |
| L-4 | Product goes live with no ops function | Launch readiness | The Launch gate requires: on-call assigned, health check defined, backups on, rollback documented, privacy checklist, support SLA | MISSING | High |
| L-5 | Production down at 3 a.m. | Pager | Health-check timer → incident → reserved slot → on-call turn. Sev-1 notifies the owner past quiet hours | MISSING | High |
| L-6 | Bad release | Rollback | The release record names the rollback command. One-click owner rollback, or an on-call runbook action pre-approved | MISSING | Med |
| L-8 | Delete a company permanently | — | Owner-only, typed confirmation, export offered, legal hold blocks it | MISSING | Med |

### UI / UX
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| UI-1 | Owner can't tell why nothing is happening | — | **Stall explainer** (plain code): "0 running because: 3 decisions wait for you (oldest 2 d), usage limit until 14:05, 12 agents blocked on D-4, connector X degraded". On the top bar and in the menu bar | MISSING | High |
| UI-2 | Notifications at 3 a.m. or in a flood | — | Quiet hours in the owner's time zone; batching; only sev-1 and reserved urgent items break through | PARTIAL — §6.24 immediate macOS notifications + daily digest; quiet hours MISSING | Med |
| UI-3 | Misclick approve | — | 10-s undo for owner decisions (delay before effects), then rescind | MISSING | Low |
| UI-4 | Map unreadable at 500 | — | Level of detail, collapsing, org chart default | §6.21, 4b (unwritten) | Med |
| UI-5 | Agent text renders as fake UI | — | `Text(verbatim:)` | 3a Global Constraints | Med |
| UI-6 | Owner can't see what the company is for right now | — | Company header shows stage, current objective and sprint goal | PARTIAL (sprint line only) | Low |

### Headless / remote
| # | Situation | Real company | Brahma must | Handled now | Sev |
|---|---|---|---|---|---|
| H-1 | Companion app offline while approvals pend | — | Email/push notifications; approvals wait (O-1 aging applies) | PARTIAL (§6.13) | Med |
| H-2 | Remote API token stolen | Revoke credentials | Paired tokens are listable and revocable, with expiry. Tailscale-only by default | PARTIAL (§6.13; revoke and expiry MISSING) | High |
| H-3 | Client and server API versions differ | — | Version handshake; read-only mode on a mismatch | MISSING | Low |
| H-4 | VM time zone is UTC, owner is not | — | Owner time zone setting (U-13) | MISSING | Low |
| H-5 | VM's `claude` logged out | — | Account health gate (O-13) | MISSING | Med |
| H-6 | VM disk or backup | — | Same backup and disk gate (X-1, U-10) | MISSING | Med |

**Counts (after §6.24):**
- 150 edge cases in total.
- 62 are MISSING.
- 14 of those are High severity and MISSING: O-2, P-10, W-2, D-1, M-1, M-3, I-3, X-2, S-1, S-2, L-2, L-4, L-5, UI-1.
- 55 are PARTIAL.
- §6.24 closed or reduced 33 rows: pacing, owner reserve, Inbox, sandbox, worktrees, backups, doctor, check snapshots, metered connectors.

---

## Part 3: Recommendations, mapped to the approved build order (§6.24)

Order: **3a (amended) → 5-lite → 4a → 4b (org chart) → dogfood (N≈8, one week) → 3b (redesigned from data) → 4c → 7, 11, 9, 8, 10.**

§6.24 already settles several gaps I would otherwise have raised:
- weekly pacing with a 30 % owner reserve;
- one Inbox (`ask`) with Auto as a policy preset;
- Auto never spends, sends, terminates or changes prompts;
- one worktree per item with engine merges;
- fresh session per item;
- `brahma doctor`;
- engine standups and sprint timebox with carry-over;
- modified-test flags and check-script snapshots;
- memory admission;
- DB backups and export;
- metered connectors count as spend;
- engine-held credentials;
- no Steward hot-swap.

The list below covers only what is still open.

"Edit before build" means: change the plan text before that plan is built, because otherwise a migration, a tool contract or a test pins the wrong behavior. Everything here is plain engine code unless it says "turn". Nothing adds a standing meeting.

### Ranked (top 10 first)

| Rank | Change | Lands in | Effort | Edit before build? |
|---|---|---|---|---|
| 1 | **Ask lifecycle.** Adds to the new `ask` table:<br>• `expiresAt` and aging reminders (1 and 3 company-active days, escalating by channel);<br>• re-route a pending internal approval when its approver is killed or paused;<br>• `ownerRescind`, with per-kind effect reversal (sprint → items back to backlog, PRD/architecture → re-gate open sprint plans, release → rollback);<br>• `supersedesId`;<br>• `detailsHash`, so a doc that changed after proposal needs a re-ack;<br>• `escalate_decision`, so a consulted executive can send a disagreement to the CEO, or to the owner if the CEO is a party.<br>Fixes O-1, O-2, O-3, D-1, D-2, D-6, P-3. | **3a amended** T8/T12 (the ask migration is being written now) | M | **Yes, 3a.** Columns belong in the first ask migration; the re-route goes in the kill transaction |
| 2 | **Reserved-matters floor under the Auto presets.** One engine table of (kind, category) pairs that no preset can auto-approve: money, outbound, terminations, prompt changes (all already in §6.24), plus contracts/ToS, pricing/refund policy, legal/press/regulator, executive hire/fire, permission profile and connector install, stage change (pivot/wind-down/archive), data deletion, engine code. `other` asks must name a category. Fixes D-7, M-7, M-9. | **3a amended** T8 | S | **Yes, 3a** |
| 3 | **Company-active clock and owner time zone.** Lease TTL, stale-standup flush, the sprint timebox, rolling quotas and aging all count time while the company is Running, not wall-clock time. One owner time-zone setting covers quiet hours, daily caps and month boundaries. Store UTC; use monotonic time for durations. Fixes O-10, U-8, U-12, U-13, U-14. | **3a amended** T4/T9/T10 | S | **Yes, 3a.** Tests currently pin `now + 2h` style expiry |
| 4 | **Org integrity on attrition.** Covers:<br>• acting-CEO succession (next executive in pack order, with an owner FYI ask);<br>• reparenting past span 7 writes an `orgIssue` and proposes a staffing ask;<br>• the kill transaction also re-routes the agent's pending asks and reviews and writes an auto-hand-off from its progress file;<br>• handles are never reused.<br>Grant revocation and external-thread reassignment hook in when 5-lite and 7 land. Fixes P-1, P-4, P-9, P-10, P-11. | **3a amended** T2/T10 (+ 5-lite grants, Plan 7 threads) | S | **Yes, 3a** |
| 5 | **Continuous health gate.** This is `brahma doctor` beyond startup:<br>• repeated network failures → global pause, probe, resume;<br>• auth or plan errors → a global account block plus one ask;<br>• a CLI version change → re-probe;<br>• disk under 5 GB → no new turns or checks.<br>Failures are classed `infra`: never counted in retries, the watchdog or the meter facts. Checks get an `inconclusive` outcome, and a failed check is re-run once (pass-after-fail = flaky). Fixes I-3 (the 10-20 internet loss), O-13, I-4, U-10, V-1, V-2. | **3a amended** T5/T10 + Plan 1 scheduler | S–M | **Yes, 3a** (check outcome enum and meter-fact exclusion) |
| 6 | **Stall explainer, aging and deadlock detection.** A plain-code "why is nothing running" on the top bar and menu bar (asks waiting, usage pacing, blocked chains, degraded connectors). Item and blocker aging. A wait-for-graph cycle check each tick, escalating to the lowest common manager, then the owner. It's also the first dogfood instrument. Fixes UI-1, W-2, W-3, W-4. | **3a amended** T10/T11; shown in the 4b org chart | S | **Yes, 3a** |
| 7 | **Backups you can restore.** On top of 5-lite's hourly `VACUUM INTO` (keep 48):<br>• `PRAGMA integrity_check` at launch;<br>• a backup before every migration;<br>• a daily `git bundle` of each product repo;<br>• a `brahma restore --dry-run`;<br>• a session-not-found fallback (fresh session + orientation) for long-lived executive and manager sessions;<br>• the Time Machine note.<br>Fixes X-1, X-2, X-3. | **5-lite** (the session fallback is a 3a T7 one-liner) | S | Fallback: yes, 3a T7. The rest goes into 5-lite's plan, not yet written |
| 8 | **Prompt-injection taint rule.**<br>• External content (WebFetch, inbound mail and social, browser pages, support tickets) is always quoted and labeled `untrusted` in digests.<br>• The TurnProfile compiler drops high-risk tools (send, spend, decide/ask-approve, secret, grant) for the rest of a turn that ingested external content; that work continues in a fresh turn.<br>• Mail claiming to be the owner is flagged as impersonation.<br>Fixes S-1, S-2. | **5-lite** (TurnProfile → settings compiler is the natural home); Plan 7 consumes it | M | Write it into 5-lite's plan and the spec now |
| 9 | **Engine timers.** One `timer` table (one-shot and recurring, owner time zone) fired by the tick: plain-code job or queued turn. 5-lite's daily digest becomes its first user. Later it drives follow-ups (Plan 7), monthly close (Plan 11), KB freshness (Plan 9), access reviews and secret rotation, vendor renewals, the weekly CEO board memo (1 turn) and on-call rotation. | **5-lite** (generalize the daily-digest scheduler) | S–M | Write it into 5-lite's plan |
| 10 | **Release safety in 4a.**<br>• A release record: version, items, main commit, engine smoke run.<br>• An engine-run product smoke check on main after every batched merge; red main blocks release and opens a P1 bug.<br>• A rollback command required before a deploy ask.<br>• A `refs/brahma/main-backup` ref with a fast-forward check.<br>• Journaled, idempotent merge steps.<br>• Per-preview port allocation.<br>Fixes V-7, L-6, X-5, U-2, X-9, I-5. | **4a** | M | Add to 4a's scope before it's written |
| 11 | **Dogfood protocol.** During the N≈8 week, deliberately exercise:<br>• pause 2 days, then resume;<br>• kill the CEO;<br>• pull the network;<br>• hit the usage limit;<br>• owner away 24 h;<br>• reorg mid-sprint;<br>• a duplicate idea;<br>• a flaky test.<br>Record owner asks/day, overhead share (ceremony + chat tokens ÷ total), stall reasons and time-to-unblock. These are the inputs that size 3b. | **Dogfood** | S | n/a (a checklist + 3 counters, built in 3a T10/T11) |
| 12 | **Work hygiene.** An FTS duplicate check on `create_work_item` with `confirm_new`. An open-item quota per author (20; managers 100). A cascade when an epic is rejected or parked. A `specChanged` flag when the PRD or architecture is superseded. Fixes W-5, W-6, W-7, W-17. | **3a amended** T3 | S | **Yes, 3a** |
| 13 | **Owner load guards.** At most 3 open asks per agent. Urgency is set by the engine (blocked count, risk), never by agent text. Quiet hours (sev-1 breaks through). Board-directive mirroring: owner DMs to non-executives are copied to the recipient's manager, with a "make work item" button. Fixes O-4, O-7, S-8, UI-2. | **5-lite** (Inbox notifications); mirroring in 3a T11 | S | Mirroring optional in 3a |
| 14 | **Onboarding packet and ramp.** An engine-built packet (goal, team charter, latest ADRs, KB index, current sprint, predecessor's notes) in the first 3 digests. First claim must be tier S. Fixes P-7. | **3a amended** T7 | S | **Yes, 3a** (digest section) |
| 15 | **3b redesign inputs.**<br>• Sprint-plan capacity line (Σ tier budgets vs the company's paced allocation left; refuse > 150 %).<br>• An overhead fact in the meter.<br>• Meter excludes `infra` failures.<br>• Reorg and role-change staffing effects (a reorg retargets open sprints and channels; a promotion = new role card + fresh session).<br>• HR and trust as plain-code rules with FYIs, per the review.<br>Fixes P-12, P-13, P-17, U-7. | **3b** (after dogfood) | M | It's a redesign anyway; fold these in |
| 16 | **Lifecycle stages + "operate the product".**<br>• `Company.stage` (owner-only stage ask).<br>• A Launch-readiness gate: on-call, health check, backups, rollback, privacy checklist, support SLA.<br>• Health-check timer → `incident` item (severity, commander, engine-built timeline, postmortem turn).<br>• One reserved incident scheduler slot.<br>• Change freeze.<br>• Wind-down checklist (cancel recurring spend, revoke connectors and grants, final notices, export, legal hold).<br>• Archive, restore and delete.<br>Fixes L-1…L-5, L-8, U-15, C-5. | New **Ops plan** after 7/11 (stage column can be added then; the 4a release record is the prerequisite) | L | No |
| 17 | **Money gaps.** Idempotent `request_spend` journaling. A recurring-charge/vendor register with renewal timers. Billing alarms on metered connectors (on top of §6.24 caps). Monthly reconciliation (plain code + 1 CFO turn). Money and usage runway. Fixes M-1, M-2, M-3, M-10. | **Plan 11** (spec text now) | M | Write it into the spec before Plan 11 |
| 18 | **External comms hygiene.** Follow-up timers (max 2, opt-out respected) → `noResponse`. Auto-reply and thread-loop caps. Legal/press inbound → reserved ask. Fixes M-5, M-6, M-7. | **Plan 7** | S | Spec text now |
| 19 | **OKR-lite + quarterly plan.** Objective/KR records, `objectiveId` on epics, sprint plans naming objectives, and a `quarterPlan` ask (OKRs, roadmap, seat caps, usage/money split). KR values come only from engine, connector or manual entry. | **3b** or Plan 9 (after dogfood shows a need) | M | No |
| 20 | **Small companies (N = 1–4)**, with a fresh-session system reviewer when no other eligible reviewer exists. Lower priority now that the default is 6. | **3a amended** T2/T6, or later | S | Only if wanted, since `outOfRangeThrows` pins 5 |
| 21 | **Privacy, licensing, retention.** `pii` tags, a PII pre-commit pattern, a license/SCA scan on release, per-table retention with a legal-hold flag, and hash-chained audit tables (ask, grant, spend, outbox). | **5-lite** (hooks, hash chain) / Ops plan | S–M | No |

**Must change a plan before it's built:**
- **3a amended:** #1, #2, #3, #4, #5, #6, #12, #14, plus the T7 session fallback from #7.
- **5-lite and 4a** (not yet written): #7, #8, #9, #13 and #10 go into their plans as they are written.
- **3b:** absorbs #15 during its redesign.

**Not recommended** (each costs usage without value):
- live meeting turns for standups, 1:1s or exec staff (digests, queued turns and the stall explainer cover them);
- per-agent money authority;
- dotted-line manager fields;
- merging companies, or moving agents between them (use export + fresh hire);
- staged rollouts in v1;
- an LLM classifier on every inbound message (plain rules first).
