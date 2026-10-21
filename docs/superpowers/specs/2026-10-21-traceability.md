# Brahma — Requirements traceability

Date: 2026-10-21 · Pairs with `2026-10-21-brahma-design-v2.md` (§ = section of v2).

**Plans:** P1, P2 (built, merged) · 3a (building in worktree `plan3a-work`; T1 committed) · 5L, 4a, 4b (written) · 3b (written, shelved/deferred) · L, ML, M, G, 4c, 7, 11, 9, 8, 10 (in the build order, not yet written).
**Status:** `built` · `building` (3a) · `planned` (written plan, not started) · `to-write` (plan in the order, unwritten) · `deferred` (owner deferred) · **`UNPLANNED`** (no plan in the order carries it).
**Task refs:** `3a T7` = Plan 3a Task 7; `5L T10`; `4a T2`; `L←4a T3` = moves from 4a Task 3 into Plan L.

| ID | Requirement | v2 § | Plan + task | Status |
|---|---|---|---|---|
| R-001 | Native macOS SwiftUI app plus `brahma` CLI | 1.1 | P1 T9, P2 T3 | built |
| R-002 | Agents are headless Claude Code sessions on the owner's subscription | 1.1 | P1 T6–T8 | built |
| R-003 | Owner can step in at any level (channel, DM, item edit) | 1.1 | P2 T5 (chat/DM); 3a T15–T16a (item edit) | built / building |
| R-004 | End-to-end demo: goal → live URL → first launch post | 1.2 | L (all tasks) | to-write |
| R-005 | Owner-facing concept budget of five nouns; internals under Insights | 1.3 | 3a T15–T16a; all UI plans | building |
| R-006 | Non-goal: no automation outside official APIs; browser only on owner accounts + product under test | 1.5 | 11 | to-write |
| R-007 | No secret in chat, logs, DB, engine-stored transcripts, commits | 1.6 | 5L T4, T13 | planned |
| R-008 | No money spent / payment details to agents without owner action | 1.6 | 3a T11a (reserved floor); 11 | building / to-write |
| R-009 | Owner reserve: Brahma never consumes the owner's own share (default 30%) | 1.6, 4.2.3 | 3a T5 | building |
| R-010 | Plan tier Max 5x default; `planTier` setting max5x/max20x | 1.7, 4.2.2 | 3a T5 | building |
| R-011 | Verify ToS/subscription/remote-login/distribution/AI-disclosure items before scaling | 1.7 | — (owner checklist) | **UNPLANNED** |
| R-012 | Brahma naming and data/workspace paths, env vars | 3.3 | P1 T1, P2 | built |
| R-013 | DB-as-bus: one shared WAL SQLite; MCP server = `brahma mcp` writing the DB | 3.1 | P1 T1, T7 | built |
| R-014 | One engine per data home (`OrchestratorLock`); app live client + auto-takeover | 3.1 | P2 T4 | built |
| R-015 | App polls DB every 500 ms; no `ValueObservation` | 3.4 | P2 T2 | built |
| R-016 | `BrahmaCore` Linux-portable; Mac-only behind protocols | 3.5 | all plans (global constraint) | built |
| R-017 | Slow work off the actor tick (detached tasks) | 3.4 | 3a T5, T9b (builder check 2 #11) | building |
| R-018 | Agent states exactly ready/running/blocked/sleeping/killed with recorded blockers | 4.1 | P1 T2 | built |
| R-019 | Crash recovery: running without live turn → ready, inbox kept | 4.1 | P1 T2, T8 | built |
| R-020 | Owner pause/wake/kill from roster, DM, map | 4.1 | P2 T8; 4b T10 (map) | built / planned |
| R-021 | Handles unique and never reused; `system` reserved | 4.1 | 3a T2, T12 | building |
| R-022 | Kill transaction: leases expired, items unassigned with auto-hand-off, asks/reviews re-routed, reports reparented | 4.1 | 3a T7, T12 | building |
| R-023 | Kill revokes agent-scoped grants | 4.1 | 5L T9 | planned |
| R-024 | Kill reassigns external threads; lab maintainership moves | 4.1 | 7; 9 | to-write |
| R-025 | Acting CEO succession; no-executives banner | 4.1 | 3a T12 | building |
| R-026 | Quit stops engine (turns interrupted, agents ready); relaunch resumes; close window keeps engine | 4.1 | P2 T4, T9 | built |
| R-027 | Global scheduler; caps and usage gate account-wide | 4.2.1 | P1 T5 | built |
| R-028 | Multiple companies; weighted round-robin; per-company weight | 4.2.1 | P1 T5; P2 rail | built |
| R-029 | Priority: critical path > role weight > sprint priority > wait | 4.2.1 | P1 T5 (role/wait); 3a T5/T7 (blockingCount) | built / building |
| R-030 | Admission refuses under memory pressure; checks/previews counted in safety cap | 4.2.1 | 3a T5; L/4a (previews) | building |
| R-031 | Sleep prevention while agents run (`caffeinate`) | 4.2.1 | 5L T7 | planned |
| R-032 | Usage modes Low/Balanced/Max per company; default Balanced | 4.2.2 | P1 T5; 3a T2 (default) | built / building |
| R-033 | Mode caps by planTier (1/3/8; 2/6/16) bounded by safety cap | 4.2.2 | 3a T5 | building |
| R-034 | Weekly share slider (default 70%); per-company reserve override | 4.2.3 | 3a T5 | building |
| R-035 | Weekly pacing with 15% burst headroom | 4.2.3 | 3a T5 | building |
| R-036 | Critical-path exemption from weekly pace | 4.2.3 | 3a T5 | building |
| R-037 | "On pace / ahead by N%" and "≈x% of week today" display | 4.2.3 | 3a T5, T15 | building |
| R-038 | Cost unit = per-turn `total_cost_usd` ($LE), calibrated to Δ7d% | 4.2.4 | 3a T5, T14 | building |
| R-039 | Usage limit → global block, resume at reset, top-bar display | 4.2.5 | P1 T5, T8; P2 T3 | built |
| R-040 | Never paid overage (overage closes the gate) | 4.2.5 | P1 T5 | built |
| R-041 | `--fallback-model` on every turn | 4.2.5 | P1 T6 | built |
| R-042 | Health gate: network/account/cli/disk holds, auto-lift, not counted against agents | 4.2.6 | 3a T5 | building |
| R-043 | Company-active clock for all durations | 4.2.7 | 3a T5 | building |
| R-044 | Owner time zone for calendar logic; UTC storage; monotonic durations | 4.2.7 | 3a T5 | building |
| R-045 | Short headless turns; prompt on stdin; stream-json to feed | 4.3.1 | P1 T6–T8 | built |
| R-046 | Agents act only via company tools; turn summary logged; `STATUS:` line parsed | 4.3.1 | P1 T8; 3a T10 | built / building |
| R-047 | No empty turns: skip and sleep when nothing actionable | 4.3.1 | 3a T10 | building |
| R-048 | Fresh session per work item; resume only within item | 4.3.2 | 3a T10 | building |
| R-049 | Warm-only resume (< 3000 s, < 60k tokens) with Continuity block | 4.3.2 | 3a T10, T14 | building |
| R-050 | Session-not-found → fresh session, not a failure | 4.3.2 | 3a T10 | building |
| R-051 | Role card + operating rules as byte-stable system prompt every turn; roster in digest | 4.3.3 | 3a T4, T10 | building |
| R-052 | Uniform tool list; authorization server-side | 4.3.3 | 3a T4, T7 | building |
| R-053 | Doctor asserts role prompt present after resume | 4.3.3 | 3a T4 | building |
| R-054 | Model by turn kind (opus: PRD/architecture/tier L; sonnet review; haiku notice) | 4.3.4 | 3a T2, T9a, T14 | building |
| R-055 | argv only from snapshot-tested `TurnProfileCompiler` | 4.3.5 | 3a T4 | building |
| R-056 | Isolation flags every turn (`--setting-sources ""`, strict MCP, never `--bare`) | 4.3.5 | P1 T6; 3a T4 | built |
| R-057 | Disallowed harness tools; `--restricted --tools` in Sandboxed | 4.3.5 | P1 T6; 5L T1 | built / planned |
| R-058 | Allowlisted child environment; `BRAHMA_AGENT_ID`; secret-like vars unset | 4.3.5 | 3a T4; 5L T1 | building |
| R-059 | `brahma doctor` probe gates scheduling | 4.3.5 | 3a T4 | building |
| R-060 | Per-turn guardrails (max turns, wall clock) | 4.3.5 | P1 T8; 3a T14 | built |
| R-061 | Messaging tools (post, DM, read channel, list, create channel, set_blocked) | 4.4 | P1 T7 | built |
| R-062 | Work, review, lead, Inbox tools as listed | 4.4 | 3a T6–T13 (T1 names built) | building |
| R-063 | Cross-company ids refused on every agent path | 4.4 | 3a (global constraint) | building |
| R-064 | `brahma mcp` refuses foreign `--agent`; owner CLI refuses inside a turn | 4.4, 4.7.2 | 3a T4; 5L T3 | building |
| R-065 | Company create: goal, size default 6 (5–500), pack, resources; >50 experimental | 4.5.1 | 3a T2, T16a | building |
| R-066 | Org preview and edit before start and any time | 4.5.1 | 3a T2, T15–T16a | building |
| R-067 | Start from an existing repo (clone, never commit to original) | 4.5.1 | — | **UNPLANNED** |
| R-068 | New companies: comms, funds, browser, connectors off by default | 4.5.1 | 7, 11 | to-write |
| R-069 | Org generation from pack ratios, ≤ 7 reports, ≤ 6 engineers/team, directors, merged small mode | 4.5.2 | 3a T2 | building |
| R-070 | Seats from backlog width and budget; vacancies; trigger-staffed roles | 4.5.2 | 3a T2 | building |
| R-071 | Owner fills vacancies (`org fill`) | 4.5.2 | 3a T2 | building |
| R-072 | Standard channels (exec, architecture, team-*, general) | 4.5.2 | 3a T2 | building |
| R-073 | Org edits: move, rename, add/remove; cycle and span checks | 4.5.2 | 3a T2 | building |
| R-074 | Role card v2 schema (sections, ≤ 5000 prompt, playbooks ≤ 2500, skills, connectors) | 4.5.3 | 3a T1 | building (T1 committed) |
| R-075 | Rendered card file ≤ 6000 chars re-read every turn | 4.5.3 | 3a T1, T10 | building |
| R-076 | Company operating rules block (≤ 1500 chars) every turn | 4.5.3 | 3a T10 | building |
| R-077 | Packs: Swift literal built-ins + versioned JSON overrides; company pins version | 4.5.4 | 3a T1, T2 | building |
| R-078 | Pack upgrade as explicit owner action with diff | 4.5.4 | G | to-write |
| R-079 | Software pack (roles, item types, check/deliverable templates, connectors field) | 4.5.4 | 3a T1 | building (T1 committed) |
| R-080 | `propose_role` with cited need | 4.5.5 | G | to-write |
| R-081 | Role generator output (card, toolkit, placement) | 4.5.5 | G | to-write |
| R-082 | Plain-code role validation (schema, authority lint, reserved tools, caps, connectors) | 4.5.5 | G | to-write |
| R-083 | New role = reserved prompt-change ask unless explicit owner policy; exec/HR/perf/security always owner | 4.5.5 | G; 3a T11a (floor) | to-write |
| R-084 | Approved role versioned into the company pack; `propose_role_change`; promote to shared library | 4.5.5 | G | to-write |
| R-085 | Hire from a description; new company from a description; save company as pack | 4.5.5 | G | to-write |
| R-086 | A/B evaluation of card versions on held-out scenarios | 4.5.5 | G | to-write |
| R-087 | Engine is the referee: only engine paths set inReview/done/merge | 4.6.1 | 3a T6–T9 | building |
| R-088 | Workers may change status fields only; never spec fields | 4.6.1 | 3a T6 | building |
| R-089 | Item types Epic/Story/Task/Bug/Spike with listed fields; dependency cycles refused | 4.6.2 | 3a T6 | building |
| R-090 | Item statuses exactly backlog/ready/inProgress/inReview/done/blocked | 4.6.2 | 3a T6 | building |
| R-091 | Item events fan out as work notices | 4.6.2 | 3a T6 | building |
| R-092 | Channel membership never wakes; wake only on DM, mention, blocker reply, rate-limited @here/@team | 4.6.2 | 3a T3 | building |
| R-093 | Wake test at N=300 (post wakes 0; mention wakes 1) | 4.6.2 | 3a T3 | building |
| R-094 | Actionable-only notices; FYIs delivered without waking | 4.6.2 | 3a T3, T6 | building |
| R-095 | Lead wake debounce 600 active s except blocking items | 4.6.2 | 3a T6 | building |
| R-096 | Tier-L split notice | 4.6.2 | 3a T9b | building |
| R-097 | Engine dispatch of Ready items to idle ICs; manager override | 4.6.3 | 3a T7 | building |
| R-098 | Single-writer lease (TTL 7200 active s, renewals, reaper) | 4.6.3 | 3a T7 | building |
| R-099 | Worktree per lease on `item/<KEY>`; claim-then-add; orphan sweep | 4.6.3 | 3a T7 | building |
| R-100 | Hardened engine git (explicit GIT_DIR, no fsmonitor/hooks/pager/ext) | 4.6.3 | 3a T7; 5L T1 reuse | building |
| R-101 | Path-overlap guard on claims and dispatch | 4.6.4 | 3a T7 | building |
| R-102 | Hot paths serialize company-wide | 4.6.4 | 3a T7 | building |
| R-103 | Early conflict detection after each merge (`merge-tree`) | 4.6.4 | 3a T9b | building |
| R-104 | Branch freshness notices (> 20 commits / > 2 active days) | 4.6.4 | 3a T9b | building |
| R-105 | Conflict-resolution brief + mandatory re-check | 4.6.4 | 3a T9b | building |
| R-106 | Architect-owned interface contracts | 4.6.4 | 3b T10 | deferred: 3b |
| R-107 | Executable check per claimable item; engine runs it on committed snapshot in detached worktree | 4.6.5 | 3a T8 | building |
| R-108 | Check pinned to checkRevision + script hash; scripts snapshotted at claim | 4.6.5 | 3a T8 | building |
| R-109 | Check process group, timeouts, output caps, ≤ 2 concurrent | 4.6.5 | 3a T8 | building |
| R-110 | Checks sandboxed under Seatbelt (Sandboxed/Workspace profiles) | 4.6.5 | 5L T2 | planned |
| R-111 | Review flags: deleted/modified tests, check-referenced files, check edits, post-pass changes, flaky | 4.6.5 | 3a T8, T9a | building |
| R-112 | Flake re-run; infra failures inconclusive, not counted | 4.6.5 | 3a T8 | building |
| R-113 | Check output only in quoted blocks | 4.6.5 | 3a T8 | building |
| R-114 | Clean-context reviewer with real diff; reviewer ≠ owner; review authority checks | 4.6.6 | 3a T9a | building |
| R-115 | Reviewer rigor (P1/P2, confidence, quoted line, scope drift) | 4.6.6 | 3a T9a | building |
| R-116 | Review attempts cap (3) → manager | 4.6.6 | 3a T9a | building |
| R-117 | Risk-tiered auto-merge with 1-in-4 sampled audits | 4.6.6 | 3a T9c | building |
| R-118 | Engine merge into main (ff or rebase + re-check); root-on-main guard | 4.6.7 | 3a T9b | building |
| R-119 | Done = merged; containers roll up | 4.6.7 | 3a T9b | building |
| R-120 | Batched merge queue with bisect, main check, journaled idempotent steps | 4.6.7 | 4a T1, T2 | planned |
| R-121 | `refs/brahma/main-backup` guard; outside writes restored and kept as branch | 4.6.7 | L←4a T3 | to-write |
| R-122 | Main smoke check after merges; red main blocks release and opens P1 bug | 4.6.7 | L←4a T3 | to-write |
| R-123 | Release records; rollback command required on deploy asks | 4.6.7 | L←4a T3 | to-write |
| R-124 | Tier budgets (turns/tokens/$LE); over budget → blocked, lead-only resume | 4.6.8 | 3a T14 | building |
| R-125 | Watchdog: no-progress, loops, 3 failed checks, escalation to non-killed ancestor | 4.6.8 | 3a T14 | building |
| R-126 | Outcome facts only (no scores); `brahma perf facts` | 4.6.8 | 3a T14 | building |
| R-127 | Pluggable cadence: sprint or milestone | 4.6.9 | 3a T13 | building |
| R-128 | Pack cadences beyond sprint/milestone (stage-gates, seasons, campaigns) | 4.6.9, 4.19 | G | to-write |
| R-129 | Sprint plans auto-approve after C-suite with FYI (`important`) | 4.6.9 | 3a T11a, T13 | building |
| R-130 | Gates block only irreversible work; pre-gate sprint plan needs owner | 4.6.9 | 3a T13 | building |
| R-131 | Combined Brief & architecture gate for ≤ 8 agents | 4.6.9 | 3a T11a | building |
| R-132 | Engine standups, no LLM turns, non-waking | 4.6.9 | 3a T13 | building |
| R-133 | Sprint timebox (5 active days / 200 turns) with carry-over | 4.6.9 | 3a T13 | building |
| R-134 | `close_sprint` summary; retro lessons to capped notes | 4.6.9 | 3a T13 | building |
| R-135 | Structured hand-offs on disk | 4.6.10 | 3a T10 | building |
| R-136 | Orientation digest (card, playbook, rules, item, progress, commits, notices, reviews, inbox, roster) with quoting | 4.6.10 | 3a T10 | building |
| R-137 | Notes file cap 8 KB | 4.6.10 | 3a T13 | building |
| R-138 | Stall explainer on top bar and menu bar | 4.6.11 | 3a T12, T15, T16a | building |
| R-139 | Deadlock (wait-for graph) detection and escalation | 4.6.11 | 3a T12 | building |
| R-140 | Item aging escalation | 4.6.11 | 3a T12 | building |
| R-141 | Org issues (over-span, no eligible reviewer) | 4.6.11 | 3a T12 | building |
| R-142 | One `ask` table for every owner-facing request | 4.7.1 | 3a T11a | building |
| R-143 | Ask kinds incl. later request/grant/deploy/humanTask/outbox/spend/staffing/stage/role | 4.7.1 | 3a T11a (reserved names); 5L T9; L; 7; 11; G | building / later |
| R-144 | Asks end the turn; resolution wakes requester | 4.7.1 | 3a T11a | building |
| R-145 | Decision brief payload (options, recommendation, stakes, reversible, proposal, request_id) | 4.7.1 | 3a T11a | building |
| R-146 | Decision classes mechanical/taste/goalChanging | 4.7.1 | 3a T11a | building |
| R-147 | Inline sanitized document on cards; changed-since-proposed re-ack | 4.7.1 | 3a T11a, T15 | building |
| R-148 | Routing to pack approvers; approver may raise, not lower, risk | 4.7.2 | 3a T11a | building |
| R-149 | Ask aging, reminders, reroute, expiry | 4.7.2 | 3a T11b | building |
| R-150 | Rescind with effect reversal; supersede; escalate_decision | 4.7.2 | 3a T11b, T13 | building |
| R-151 | Owner-only decision paths; relayed approvals never count | 4.7.2 | 3a T11a | building |
| R-152 | Autonomy presets everything / important (default) / auto | 4.7.3 | 3a T11a | building |
| R-153 | Explicit owner policies are the only auto-approval for reserved kinds | 4.7.3 | 5L T9 (grant presets); 7; 11 | planned / to-write |
| R-154 | Reserved-matters floor (14 categories; pack can only add) | 4.7.4 | 3a T11a | building |
| R-155 | Access asks with scope + duration; company-wide dedupe | 4.7.5 | 5L T9 | planned |
| R-156 | Exact-hostname presets; wildcard rules | 4.7.5 | 5L T9 | planned |
| R-157 | Grants compile into next turn; ledger with revoke | 4.7.5 | 5L T9, T11 | planned |
| R-158 | macOS notification for pending owner asks | 4.7.6 | 3a T16a; 5L T7 | building |
| R-159 | Quiet hours, batching, ask quota (3/agent), engine-set urgency, menu badge | 4.7.6 | 5L T7 | planned |
| R-160 | Daily digest (plain code) | 4.7.6 | 5L T8 | planned |
| R-161 | iMessage and email notifications (or a push service) | 4.7.6 | — | **UNPLANNED** |
| R-162 | Sandboxed profile default; Workspace and Full selectable; Full warning badge | 4.8.1 | 5L T1–T3, T11 | planned |
| R-163 | README states Workspace is not a sandbox until 5L | 4.8.1 | 3a T16b | building |
| R-164 | Profile change is reserved; applies next turn | 4.8.1 | 3a T11a (floor); 5L T11 | building / planned |
| R-165 | Per-agent HOME via shell prefix | 4.8.2 | 5L T1 | planned |
| R-166 | Narrow write scopes per turn kind; main/.git/config/hooks never writable | 4.8.2 | 5L T1 | planned |
| R-167 | Read denies: owner home, data home, credential dirs, backups, /Volumes, other companies | 4.8.2 | 5L T1, T3 | planned |
| R-168 | Network allowlist via egress proxy (no private/metadata, CONNECT 443) | 4.8.2 | 5L T2 | planned |
| R-169 | Seatbelt hardening for checks (signals, mach lookups, exec denies) | 4.8.2 | 5L T2 | planned |
| R-170 | Live canary gates sandboxed scheduling; per-command sentinel | 4.8.2 | 5L T3 | planned |
| R-171 | Company skill library and plugin dir per role; structural plugin allowlist | 4.8.2 | 5L T5 | planned |
| R-172 | Remove `--disable-slash-commands` when skills mount | 4.8.2 | 5L T5 | planned |
| R-173 | Sub-agents within a turn, counted against budget, capped | 4.8.2 | 5L T5 (tools); 3a T14 (budget) | planned |
| R-174 | Engine-owned hooks only (taint hook, pre-commit pattern scan) | 4.8.2 | 5L T4, T5, T10 | planned |
| R-175 | Compiled TurnProfile recorded per turn for audit | 4.8.2 | 5L T1, T13 | planned |
| R-176 | Permission layers 1–6, narrowing except grants; no self-granting | 4.8.3 | 5L T1, T9, T10; 3b (trust layer) | planned |
| R-177 | Taint rule: hook marks session before result; high-risk tools refused until fresh session | 4.8.4 | 5L T10 | planned |
| R-178 | Owner-impersonation flag on inbound | 4.8.4 | 5L T10; 7 | planned |
| R-179 | Secrets in Keychain, engine-held; only test keys to agents via `use_secret` | 4.8.5 | 5L T4 | planned |
| R-180 | Redaction at every write path and display; transcript redaction | 4.8.5 | 5L T4, T13 | planned |
| R-181 | Known-value leak scan at submit, enqueue and merge | 4.8.5 | 5L T4 | planned |
| R-182 | Sign-in asks completed by owner; one per connector | 4.8.5 | 11 | to-write |
| R-183 | Web preview from main (port allocation, WKWebView, rebuild on merge, sandboxed) | 4.9 | L←4a T4, T5 | to-write |
| R-184 | Artifact preview (MD, HTML, images, PDF, MP4/MOV 9:16) and `publish_artifact` | 4.9 | L←4a T7 | to-write |
| R-185 | `deploy` ask running one hosting CLI with engine-held token, smoke check, rollback | 4.9 | L | to-write |
| R-186 | `humanTask` asks with checklist, prefilled links, paste-back to Keychain | 4.9, 4.10.5 | L | to-write |
| R-187 | SaaS launch-kit playbook | 4.9 | L | to-write |
| R-188 | Critical-path instrumentation as dogfood scorecard | 4.9 | L | to-write |
| R-189 | CLI and backend preview adapters | 4.9 | 4a T6 | planned |
| R-190 | iOS Simulator and macOS app adapters; Screen Recording prompt on first use | 4.9 | 4a T8 | planned |
| R-191 | Sprint-review demos via adapters | 4.9 | 4a T8 | planned |
| R-192 | Preview pane shows latest artifact before anything runs | 4.9 | L←4a T7, 4a T10 | to-write |
| R-193 | Connector model (MCP/CLI + credential + role scope + risk + cost); install = reserved ask | 4.10.1 | 11 | to-write |
| R-194 | Integrations catalog with per-pack suggested bundles | 4.10.1 | 11; 3a T1 (pack field) | to-write |
| R-195 | Agents request connectors; connector calls logged and budgeted | 4.10.1 | 11 | to-write |
| R-196 | Metered connectors count as spend; provider-side cap at install | 4.10.1 | 11 | to-write |
| R-197 | Engine executes exactly the approved payload once | 4.10.1 | L (deploy); 7; 11; M | to-write |
| R-198 | WebSearch/WebFetch per role under allowlist | 4.10.2 | 5L T1, T9 | planned |
| R-199 | Research produces cited reports into the handbook | 4.10.2 | ML; pack prompts 3a T1 | to-write |
| R-200 | Browser (Playwright MCP), isolated profiles, owner sign-in hand-off, live view, quarantine | 4.10.3 | 11 | to-write |
| R-201 | Funds: budget, funds connector, `request_spend` → spend ask, threshold $0, Auto never spends | 4.10.4 | 11 | to-write |
| R-202 | CFO/Finance role and Finance view; revenue read-only | 4.10.4 | 11 | to-write |
| R-203 | Idempotent spend journaling, vendor register, billing alarms, monthly reconciliation, runway | 4.10.4 | 11 | to-write |
| R-204 | Business roles (research analyst, marketing, sales, support, CFO, legal reviewer, ops) | 4.10.4, 4.19 | G (packs); M (marketing); 11 (CFO) | to-write |
| R-205 | Resources drag-and-drop at company/channel/DM scope | 4.10.6 | — | **UNPLANNED** |
| R-206 | Company Memory: local scoped FTS, auto-ingest with provenance | 4.11.1 | ML | to-write |
| R-207 | Scope + sensitivity filtering before results reach agents | 4.11.1 | ML | to-write |
| R-208 | `search_memory`, `recall`, `remember` (key/type/confidence); orientation top-k | 4.11.1 | ML | to-write |
| R-209 | Memory hygiene (dedupe, TTL, owner browse/delete, retrieved text is data) | 4.11.1 | ML; 5L T10 (taint) | to-write |
| R-210 | Embeddings and external memory backends | 4.11.1 | 9 | to-write |
| R-211 | Personal memory: episodic + semantic, recall scoring, forgetting curve | 4.11.2 | ML | to-write |
| R-212 | End-of-item reflection (plain code + short Haiku turn) | 4.11.2 | ML | to-write |
| R-213 | Procedural memory and sprint-level reflection | 4.11.2 | 9 | to-write |
| R-214 | Memory privacy rules; replacement inherits procedural + semantic | 4.11.2 | ML; 3b (HR) | to-write |
| R-215 | Append-only work record of every message, hand-off, ask, review, decision, tool summary | 4.11.3 | P1 (messages, turns); 3a T6–T11; 5L T13 | building |
| R-216 | Per-turn transcript capture (redacted, compressed) | 4.11.3 | 5L T13 | planned |
| R-217 | Replay any agent's day or item history | 4.11.3 | ML | to-write |
| R-218 | Handbook in SQLite (kbPage, kbRevision, kbLink), FTS, Markdown export | 4.11.4 | ML | to-write |
| R-219 | `kb_read`/`kb_write`/`search_kb` with scope; orientation links 3–5 pages | 4.11.4 | ML | to-write |
| R-220 | Pack-defined handbook structure; engine-rendered auto pages | 4.11.4 | ML | to-write |
| R-221 | Doc-update check flag; review of significant pages; page lease | 4.11.4 | ML | to-write |
| R-222 | Librarian staleness jobs | 4.11.4 | 9 | to-write |
| R-223 | Handbook view (tree, search, backlinks, staleness, export) | 4.11.4 | ML | to-write |
| R-224 | Hot tier (~30 days) serves all live UI and recall | 4.11.5 | ML | to-write |
| R-225 | Warm tier monthly archives with FTS, cross-tier search, precomputed summaries | 4.11.5 | ML | to-write |
| R-226 | Hourly and pre-migration `VACUUM INTO`; integrity check at launch | 4.11.5 | 5L T12 | planned |
| R-227 | Daily git bundles; data-home snapshots; external/rclone-crypt targets; WAL shipping | 4.11.5 | 5L T12, T13 | planned |
| R-228 | `brahma restore` (dry-run, point in time, exclusive, atomic, adopt main) and `brahma export` | 4.11.5 | 5L T12, T13 | planned |
| R-229 | Retention keep-forever with archive-only cap; storage meter | 4.11.5 | ML (meter); 5L T12 | to-write |
| R-230 | Ops-console visual language and tokens (`BrahmaTheme`) for every UI | 4.12.1 | P2 T5b; all UI tasks | built |
| R-231 | Single color source `ThemeHex` for app and map | 4.12.1 | 4b T8 | planned |
| R-232 | Agent text verbatim; SafeMarkdown for documents | 4.12.1 | P2 T5; 3a T15 | built / building |
| R-233 | Company rail with status dot, badge, "+" | 4.12.2 | P2 T3 | built |
| R-234 | Sidebar: channels, DMs, Work, Inbox, People, Resources, Handbook, Insights | 4.12.2 | P2 T5 (channels/DMs); 3a T16a; ML; — (Resources) | built / building |
| R-235 | Top bar: mode control, autonomy, state chips, usage meter, pace, stall line, hold banner | 4.12.2 | P2 T3; 3a T15–T16a | built / building |
| R-236 | Mission control layout B; chat replaces top half; activity feed at bottom | 4.12.2 | P2 T7 | built |
| R-237 | Menu bar extra: totals, per-company pause/resume, stall line | 4.12.2 | P2 T9; 3a T16a | built / building |
| R-238 | Global kill switch / pause all (turns, browsers, connectors) | 4.12.2 | — | **UNPLANNED** |
| R-239 | Inbox view with card, options, scope/duration answers, re-plan, rescind | 4.12.2 | 3a T15–T16a; 5L T11 | building |
| R-240 | People: roster, detail, org editor, vacancies | 4.12.2 | P2 T8; 3a T16a | built / building |
| R-241 | Work: backlog, kanban, item editor, merge status, releases | 4.12.2 | 3a T16a; 4a T11; L | building |
| R-242 | Budget view: weekly share, pace, storage; later funds/runway | 4.12.2 | 3a T15; ML; 11 | building |
| R-243 | Search across messages (and items/memory) | 4.12.2 | P2 T6; ML | built |
| R-244 | Org-chart map default with live state, edges, particles, collapse, search, follow, vacancies, dotted review lines | 4.12.3 | 4b T1–T10 | planned |
| R-245 | Map replay (1 h), pop-out window, `--map-demo` 300 agents, 50 msg/s smooth | 4.12.3 | 4b T6, T10, T11 | planned |
| R-246 | Hive 3D skin | 4.12.3 | 4c | to-write |
| R-247 | Village 2D skin with original art | 4.12.3 | 4c | to-write |
| R-248 | Insights view of engine internals | 4.12.4 | 3a T16a (facts); 3b | building |
| R-249 | Marketing v1 text/image posts, landing page + waitlist, calendar, owner ask per post | 4.13 | M | to-write |
| R-250 | Marketing v1 publishing via humanTask or engine-executed connector payloads | 4.13 | M; L (humanTask) | to-write |
| R-251 | Engine-pulled analytics into Company Memory | 4.13 | M | to-write |
| R-252 | Marketing roles in packs | 4.13 | M; G | to-write |
| R-253 | M2 short-form video pipeline (generation connector, ffmpeg, check, review, publish, learn) | 4.13 | M (M2) | to-write |
| R-254 | Platform rules: TikTok per-post owner ask, no watermark, AI flags, licensed music, Sora excluded | 4.13 | M (M2) | to-write |
| R-255 | Content guardrails (AI labels, likeness rights, no fake reviews, FTC, approved claims) | 4.13 | M | to-write |
| R-256 | Generation credits are metered spend with caps | 4.13 | M; 11 | to-write |
| R-257 | Recurring work items with pre-check script | 4.13 | M | to-write |
| R-258 | Owner-connected mailbox and social accounts via official APIs | 4.14 | 7 | to-write |
| R-259 | Outbox asks; auto-send only under explicit per-account policy with caps | 4.14 | 7 | to-write |
| R-260 | Inbound into `#external` and contact threads, waking owner agent | 4.14 | 7 | to-write |
| R-261 | AI disclosure, no impersonation, rate limits, unsubscribe, consent/opt-out list | 4.14 | 7 | to-write |
| R-262 | Follow-up timers, loop caps, legal/press inbound → reserved ask | 4.14 | 7 (uses 5L T6 timers) | to-write |
| R-263 | Efficiency meter (engine-measured, many measures, no single score, FeedbackGuard) | 4.15 | 3b T1–T2 | deferred: 3b |
| R-264 | Trust ladder T0–T3 with effects and hysteresis | 4.15 | 3b T3 | deferred: 3b |
| R-265 | Cosmetic digital rewards and break room | 4.15 | 3b T6; 4c (Village display) | deferred: 3b |
| R-266 | HR partner: reviews, warning → PIP → termination + replacement, root cause first | 4.15 | 3b T7 | deferred: 3b |
| R-267 | Performance analyst scorecard and sprint judge | 4.15 | 3b T5 | deferred: 3b |
| R-268 | Ideas pipeline, visionary role, Idea review, quota, 💡 perk | 4.15 | 3b T8 | deferred: 3b |
| R-269 | Driver + navigator pairing; competing hypotheses | 4.15 | 3b T9 | deferred: 3b |
| R-270 | Smart-friend consult | 4.15 | 3b T4 | deferred: 3b |
| R-271 | Staffing tools (IC hires within caps; kill/reassign owner) and channel post limits | 4.15 | 3b T10 | deferred: 3b |
| R-272 | 3b redesign inputs (capacity check, overhead fact, reorg/promotion, owner rating) | 4.15 | 3b (rewrite) | deferred: 3b |
| R-273 | Per-agent lab folders with notes/modules/scratch, quota | 4.16 | 9 (5L T1 reserves the path) | to-write |
| R-274 | Modules as skill packages; promotion to Toolbox with tests and review | 4.16 | 9 | to-write |
| R-275 | Experience store (lessons by role + task type) | 4.16 | 9 | to-write |
| R-276 | Steward weekly report from telemetry | 4.17 | 10 | to-write |
| R-277 | Steward tuning proposals as Inbox asks; code changes as branches for owner merge | 4.17 | 10 | to-write |
| R-278 | Steward safety (immutable evaluator, held-out scenarios, auditor, lineage, one change at a time) | 4.17 | 10 | to-write |
| R-279 | "What changed" view with effect and revert | 4.17 | 10 | to-write |
| R-280 | `brahma serve` Linux daemon with Linux backends | 4.18 | 8 | to-write |
| R-281 | Authenticated HTTPS + WebSocket API; Mac app as remote client | 4.18 | 8 | to-write |
| R-282 | TLS, revocable expiring paired tokens, Tailscale default, version handshake | 4.18 | 8 | to-write |
| R-283 | Industry-neutral engine; packs define vocabulary, cadence, deliverables, verification, connectors, playbooks | 4.19 | 3a T1 (schema); G | building / to-write |
| R-284 | Non-software built-in packs (e-commerce, CPG, apparel, hard tech, services, media) | 4.19 | G | to-write |
| R-285 | Deliverable preview adapters for non-software packs (CAD, BOM, decks, spreadsheets) | 4.19 | L←4a T7 (documents); rest — | **UNPLANNED** |
| R-286 | Rubric review by clean-context reviewer for subjective work | 4.19 | G (check templates) | to-write |
| R-287 | Human tasks for physical/legal steps; contracts always owner | 4.10.5, 4.19 | L (humanTask); 3a T11a (reserved) | to-write |
| R-288 | Owner away mode / pre-delegation (O-1) | 4.20 | — | **UNPLANNED** |
| R-289 | Resume brief and stale external threads after long pause (O-10) | 4.20 | — | **UNPLANNED** |
| R-290 | Secret-leak incident playbook (S-3) | 4.20 | — | **UNPLANNED** |
| R-291 | Ops: incidents, on-call, health check on deployed URL, launch-readiness gate, change freeze (L-4, L-5) | 4.20, App. A | — | **UNPLANNED** |
| R-292 | Lifecycle stages, pivot, wind-down checklist, archive/restore/delete (L-1–L-3, L-8) | 4.20, App. A | — | **UNPLANNED** |
| R-293 | Dogfood protocol and counters | 4.20 | 3a T10/T11 (counters); dogfood week | building |
| R-294 | Scale: hundreds of agents exist, UI stays fast (old Plan 6) | 1.4, 5 | 3a T3 (N=300); 4b T11 (bench) | building / planned |
| R-295 | Engine timers (one-shot/recurring, owner TZ) | 4.6.9, 4.7.6 | 5L T6 | planned |

## Summary
- Requirements: **295**.
- Status counts (primary status of each row): built 23 · built/partly building or planned 11 · building (3a) 110 · building + later plan 5 · planned (5L/4a/4b) 40 · planned + to-write 1 · to-write 83 · deferred to 3b 11 · **UNPLANNED 11**.
- **UNPLANNED (11):** R-011 owner verify-before-scaling checklist · R-067 start a company from an existing repo · R-161 iMessage/email (or push) notifications · R-205 resources drag-and-drop · R-238 global kill switch · R-285 non-software deliverable previews (CAD, BOM, decks, spreadsheets) · R-288 owner away mode · R-289 resume brief after a long pause · R-290 secret-leak incident playbook · R-291 Ops (incidents, on-call, uptime check, launch-readiness gate, change freeze) · R-292 lifecycle stages, pivot, wind-down, archive/delete.
- Owner-originated among the UNPLANNED: R-161, R-205 (owner 2026-10-20), R-067 and R-285 (owner's "all product types / any industry" scope), R-238 (research proposal G25, owner-approved 2026-10-20). See v2 §7 Q1–Q2.
