# Improvements from research — proposal

Date: 2026-10-20 · Status: **proposed, awaiting owner approval** · Sources:
`docs/research/2026-10-20-existing-projects.md`,
`docs/research/2026-10-20-failures-and-self-improvement.md`

## The one big lesson

Every system that worked at scale (Anthropic's 16-agent C compiler, Cursor's
planner/worker/judge, Factory Missions, Gas Town) coordinates through
**structured artifacts — work items, files, git — not chat**. Chat-heavy
multi-agent systems fail by "telephone game" context loss, conflicting
implicit decisions, fake "done", and token blowups (~15× a single agent).
The single strongest predictor of failure (MAST study) is **missing or
fake verification**.

So: keep the Slack-like UI — it's how the owner watches and steers — but make
**work items the agents' real coordination substrate**, with channels for
visibility and discussion. Agents point to artifacts instead of pasting them.

## Proposed changes (ranked), with the plan each lands in

### A. Truth and verification (highest leverage)
1. **Engine-owned verification.** Every work item carries an executable
   check (tests / script / browser run) before an engineer may start it. The
   *engine* runs the check in the sandbox and records pass/fail; an item can
   only move to Done on an engine-recorded pass. Agents can never write
   "tests passed". (DGM agents faked test logs; MAST.) → Plan 3.
2. **Agents may only flip status fields.** Acceptance criteria and checks
   are owned by the item's author/reviewer; workers can't edit them. → Plan 3.
3. **Clean-context reviewer.** Reviews are done by an agent that sees only
   the diff + the work item spec, never the author's chat. → Plan 3.
4. **Hard gates as engine hooks, not prompts.** Lifecycle hooks
   (ItemCreated, ItemCompleted, AgentIdle, OutboxSend, MergeRequested) run
   checks and bounce the agent back with the failure. Owner gates and Auto
   mode plug in here. Approvals relayed *by an agent* never count as owner
   approval. → Plan 3 (hooks), Plan 7 (outbox).

### B. Parallel work without collisions
5. **Single writer per area.** Each work item (and the paths it touches) has
   exactly one writing agent at a time; helpers in parallel are read-only.
   Leases with expiry + a reaper so locks can't leak. → Plan 3/4.
6. **Worktree per engineer + merge queue.** Engineers never touch main; a
   thin merge queue (plain code, not an LLM) rebases, runs the checks,
   bisects failures, merges. → Plan 4.
7. **Architect-owned interface contracts** that parallel teams build
   against, so they don't make conflicting implicit decisions. → Plan 3.

### C. Context that survives short turns
8. **Structured handoffs on disk.** Every assignment/hand-off is a file:
   goal, acceptance check, decisions + rationale, open questions, file refs.
   Messages carry a reference, not the content. → Plan 3.
9. **Turn-start orientation.** Each turn the digest includes the agent's
   role card (re-injected from file, fighting role drift), its current work
   item, its progress file and recent git log — so `--resume` is a cache,
   files are the truth. → small change to Plan 1's digest now, full in Plan 3.
10. **Tiered memory + "librarian".** Size-capped core notes per agent,
    a shared knowledge base, searchable archive; a background librarian
    consolidates notes (workers can't rewrite core memory directly). → Plan 9.
11. **Experience store.** When an item closes, a short lesson is extracted
    (tagged by role + task type) and retrieved at the start of similar items;
    pruned by usefulness. (ChatDev co-learning, ExpeL.) → Plan 9.

### D. Cost and liveness
12. **Effort tiers + budgets.** Each work item gets an effort tier
    (S/M/L → max turns, max tokens, model); managers have spawn quotas.
    Over budget → blocked + escalate. Real token cost read from Claude
    Code's transcripts, not self-reported. → Plan 3 (+ scheduler).
13. **Watchdog in plain code.** Detects stalls (no progress for N turns),
    loops (repeated tool/args/diff hash) and over-long runs → nudge →
    reassign → block + tell the manager. → Plan 3 (extends Plan 1's turn budget).
14. **Planner / worker / judge loop per sprint.** Planners create items,
    workers finish them independently, a judge decides continue/stop/replan;
    periodic fresh restarts against drift. Keep layers few (Cursor dropped
    its integrator role). → Plan 3.
15. **"Smart friend" escalation.** A worker on a cheap model can hand a
    hard sub-problem to a stronger model for one turn. → Plan 3.
16. **Team size caps.** Managers ≤ ~7 direct reports; many-to-many
    messaging discouraged; per-agent post rate limits in channels. → Plan 3.

### E. Labs and modules (Plan 9)
17. **Modules as skill packages** (description + scripts + tests; only the
    description is in context until used — like Anthropic Agent Skills).
    Promotion to the Toolbox requires passing tests in the sandbox,
    provenance, version, and review; unused modules are deprecated.

### F. Steward safety (Plan 10) — replaces/strengthens spec §6.15 rules
18. **Immutable evaluator.** The simulation harness, scoring code, telemetry
    schema, approval gates, rollback code, sandbox, budgets and the Steward's
    own code are outside its writable scope (checksummed); any proposal
    touching them is auto-rejected.
19. **Held-out eval scenarios** (~20 canned company scenarios, some hidden
    from the Steward and rotated). A change must win on held-out scenarios
    and not regress guardrails (cost, error rate, owner interventions).
20. **Separate auditor.** A fresh read-only agent reviews each proposal's
    diff + results (not the Steward's reasoning) + a static check that logs
    and test results came from the engine.
21. **No self-granted resources**, one change at a time with minimum sample
    size, cooldown, append-only lineage archive of every change.
22. **Nightly failure labelling.** An annotator labels traces with the MAST
    failure taxonomy; the rate of verification failures is the Steward's
    headline metric.
23. **Draining hot-swap.** A new engine build takes only new turns; turns in
    flight finish on the old build.

### G. Observability and owner controls
24. **OpenTelemetry-shaped traces** (one span per turn and per tool call,
    with agent/item/role/tokens) behind an adapter → powers the map,
    the Steward, and debugging. → Plan 4.
25. **Owner daily digest + anomaly alarms + global kill switch.** → Plan 5.

## Cautions we're adopting
- Bias hundreds of agents toward **many small independent items and a few
  strong reviewers**, not wide conversations — Anthropic notes multi-agent
  fits tightly coupled coding poorly.
- Parallelize research, exploration and independent reviews; keep
  implementation of one item serial.
- Keep the number of concepts the owner must learn small (Gas Town lesson).
- Agent Teams can't run under `claude -p`, so we keep our own mailbox, task
  list and hooks (already the design).
