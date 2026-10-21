# Brahma design review (architecture critic, 2026-10-21) — condensed by controller

Verdict: Plan 1 engine is sound; 3a's "engine is the referee" is right. Three
foundation gaps undermine what's planned next: (B1) channel membership wakes
every member (MessageRouter.swift:97-104; Store.hire adds all to #general) →
O(N) turns per post; (B2) no sandbox — Bash unrestricted (ClaudeCommand.swift
:51-53), checks run /bin/sh as owner → DB/approvals/meter forgeable,
credentials readable; (B3) one shared working tree (Orchestrator cwd =
workspace) → checks/deletion flags see other agents' edits.

High: H1 7-day window never gates (UsageGate.swift:35); H2 8+ approval
surfaces + 4 "please approve" verbs with contradictory auto-approve rules
(spec §6.8/§6.11a/§6.15/§6.17/§6.19/§6.23 vs 3b); H3 owner gate flood
(per-team sprint plans, ownerRequired HR warnings/prompt fixes) with no
notification until Plan 5; H4 sprints never close if one item stalls; H5 3b
uncalibrated (~40 concepts, 4 LLM ceremonies/sprint/team); H6 modified tests /
in-tree check scripts not flagged (reward-hacking path); H7 argv freeze +
`--disable-slash-commands` contradict §6.22.
Medium: PeopleCycle in one big write txn; SafetyCap ignores non-claude
children (checks, previews, sims); lifetime --resume session growth; CLI drift
(2.1.306 vs pinned 2.1.304) with no probe; no DB backup; app snapshot reloads
up to 5000 items per tick; approval details are a path not inline; notes/
coaching files uncapped; metered connectors (cloud) bypass funds budget.
Nits: spec §7 diagram/paths stale; Village/emoji vs ops brief (declare a
skin); no sleep prevention while agents run; ToS items to verify (sustained
automated subscription use; remote VM login; distribution requires API keys;
AI disclosure for outbound; browser automation ToS).

Owner mental model proposal (5 nouns): Company · People · Work · Inbox ·
Budget; everything else is an engine internal under "Insights".
Defaults: company size 6; Balanced; weekly owner reserve 30%; Opus only for
C-suite first turns, architecture, tier-L; autonomy "Important only" (owner
approves PRD, architecture, release, money, secrets, outbound, terminations;
sprint plans auto after C-suite with FYI; HR warnings/PIPs FYI); macOS
notifications + daily digest; comms/funds/browser/connectors off by default.

Ranked recommendations:
1 No-wake channel membership (wake only on @mention, DM, item notice, explicit @team/@here by manager+, rate-limited; system posts never wake) — S — change 3a + router.
2 Sandbox-lite before 3b: Claude Code sandbox via --settings (writes only workspace/worktrees/caches; deny data home, ~/.ssh and credential dirs; network allowlist); checks under sandbox-exec; replace "argv frozen" with a TurnProfile→argv/settings compiler — M — new plan "5-lite" before 3b.
3 Worktree per lease in 3a; checks in the worktree; reviewer gets real git diff; approve merges — M — 3a, 4a.
4 Weekly-aware pacing: close gate when sevenDayUtil ≥ elapsedWeekFraction × (1 − ownerReserve), default reserve 30%; Opus pace; top bar "on pace/ahead" — S — code + 3a ModelPolicy defaults.
5 One owner Inbox ("ask" table: kind, risk, requester, item, title, summary, payload, proposedGrant{scope,duration}, status, expiresAt); decisions/requests/grants/outbox/spend/human tasks/HR/staffing/systemFix are kinds; Auto mode = policy preset; fix spec contradictions C1–C5 — M — 3a Tasks 8/12, 3b.
6 Cut gate load/dead ends: sprint plans auto after C-suite (FYI); engine-generated standups (zero LLM turns); sprint timebox with carry-over; macOS notification for pending asks now; approval card renders doc inline (sanitized Markdown) — S–M — 3a Tasks 8/9/12.
7 Re-scope 3b after dogfooding (keep facts, perf table, perks, smart friend; one chief-of-staff ceremony per sprint; trust/HR as plain-code rules with FYI; defer PIP/termination, pairing, contracts, visionary) — saves L.
8 Fresh session per work item (resume only within an item) + startup probe `brahma doctor` (CLI version, flags, stream shapes, login, overage off); drop --disable-slash-commands when skills land — S — 3a Task 7.
9 Verification holes: flag modified test files and files referenced by the check; snapshot check scripts to engine-owned dir at claim; pin check to checkRevision + script hash — S — 3a Task 5.
10 PeopleCycle as an engine job in small transactions — S — 3b Task 5.
11 Memory-pressure admission; count non-claude children in the safety cap — S.
12 Metered connectors = spend; engine-held credentials behind connector proxies by default — M — spec now, Plan 11.
13 DB backups (VACUUM INTO hourly, keep 48) + per-company export — S — 5-lite.
14 Steward level 3 deferred; Steward = report + PRs — saves L.
15 One map first; others as skins — saves M–L.
16 Spec hygiene (Workspace text, browser vs non-goal, Village as skin, §7 diagram/paths/names) + a "Concept budget" section.

Recommended order: Plan 2 → 3a (amended) → 5-lite → 4a → dogfood N≈8 for a week → 3b(-lite) → 4b → 7, 11, 9, 8, 10.
