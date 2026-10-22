# Brahma: work modes (final design)

How each agent turn's intensity is chosen, compiled, bounded and counted.

Final design, 2026-10-21. It replaces the earlier draft and folds in three adversarial reviews (cost/pacing, safety/self-escalation, feasibility). Every high fix is included, plus the medium fixes listed in §10.

Inputs:
- Spec v2: `/Users/chandra/agent-company/docs/superpowers/specs/2026-10-21-brahma-design-v2.md`
- Plan 3a, as amended: `/Users/chandra/agent-company/.claude/worktrees/plan3a-work/docs/superpowers/plans/2026-10-20-plan3a-work-system.md`. Tasks 1–4 are built. The worktree code was read: `Turns/TurnProfile.swift`, `Turns/TurnRunner.swift`, `Turns/ClaudeCommand.swift`, `Org/ModelPolicy.swift`, `Orchestrator.swift`.
- Plan 5-lite: `/Users/chandra/.claude/jobs/6d89b87c/tmp/2026-10-21-plan5lite-safety.md`
- The verified mode findings for Claude Code 2.1.306: flags, sub-agents/workflows and economics research.

Owner request: *"I want each agent to also be able to use ultra code or other modes based on the needs or priority etc."*

---

## 0. Decisions in brief

1. **Four intensity modes plus one modifier, all compiled by `TurnProfileCompiler`:**
   - **Quick**, **Standard**, **Deep** and **Ultra** are the intensity modes.
   - **Plan-first** is the modifier.
   - Each mode is a fixed bundle: model, `--effort`, `maxEffortLevel`, sub-agent policy, Workflow policy, `--max-turns`, `--max-budget-usd`, wall clock and MCP quotas.
2. **Rung ladder.** A rung is a (model, effort) pair: R0 sonnet/haiku low, R1 sonnet medium, R2 sonnet high, R3 opus medium, R4 opus high, R5 Ultra.
   - Escalation moves one rung, effort first.
   - **The model stays fixed for an (agent, item) session after its first work turn.** Effort changes keep the cache; model changes do not. The only model change is an explicit escalation to Opus, which is recorded as a `cacheBreak` and costed.
3. **The engine decides and agents can only ask.** `ModePolicy.select` is pure code with one reason string per step.
   - Spec fields count for intensity only when someone other than the lease holder set or confirmed them, and that someone is a manager, executive or the owner (`specConfirmedBy`).
   - An assignee's `request_mode` can raise its own item to R2 at most.
4. **"Ultra" is Claude Code's Workflow tool (the engine behind ultracode) under Brahma's caps.** It lands in 5-lite and runs only on the sandboxed profile, after its own probe gates pass (U-1, U-3, V-1, V-2, V-9).
   - Claude's standing `ultracode: true` is **never emitted in v1**.
   - Ultra that the engine proposes after repeated failures **always** needs an owner `boost` ask, whatever the preset.
5. **Sub-agents (`Task`) are off on the 3a workspace profile.** Today's 3a turns expose `Task` unforced: it is not in `ClaudeCommand.disallowedTools`, so built-in Explore runs on Opus and remote isolation is open. 3a closes this.
   - Sub-agents come back per CLI version only when the sub-agent gate passes (L-2, V-2, V-3, V-5, V-8). They are fully enabled on the sandboxed profile in 5-lite.
6. **The structural no-overage rule covers every mode, not just Ultra.**
   - When `overageStatus == "allowed"`, all modes clamp: rung ≤ R1, no Task, no Ultra, and no new admissions at `fiveHourUtil ≥ 0.85`.
   - If the CLI reports a plan tier other than the configured `planTier`, the engine uses the lower tier until the owner confirms. The CLI currently reports **Pro**.
   - Fast mode, Fable/`best`/`default`/`opusplan`/`[1m]`, ultrareview, agent teams and nested `claude` are excluded through the model allowlist, environment variables, deny rules, a pre-tool hook and a canary.
7. **A closed weekly pace really closes.** Admitted critical-path work runs at most R1, with no floor, no Task and no Plan-first. The critical-path exemption ends once `sevenDayUtil ≥ 1 − reserve`.
8. **No new owner noun.**
   - **Work** gets one item field, *Intensity* (Auto / Thorough / Ultra).
   - **Company**: the Low/Balanced/Max dial also bounds intensity.
   - **Inbox** gets a `boost` ask.
   - **Budget** shows spend by mode and the Ultra allowance.
9. **Where it lands.** 3a gets Quick/Standard/Deep/Plan-first as a new Task 14c, plus patch notes W1–W12. 5-lite gets Ultra as a new Task 14 and enables sub-agents, plus F1–F11.

---

## 1. Mechanisms

### 1.1 Verified headless on 2.1.306 (observed output)

| Mechanism | Exact control | Evidence |
|---|---|---|
| Effort | `--effort low\|medium\|high\|xhigh\|max` | `get_settings` `applied.effort` equals the flag. Init has `per_turn_effort_active: true`. Haiku low gave 0 thinking tokens; max gave 286. |
| Effort cap (main loop only) | settings `maxEffortLevel` | opus with `{"maxEffortLevel":"high"}` and `--effort max` gave applied `high` |
| Env override hazard | `CLAUDE_CODE_EFFORT_LEVEL` beats `--effort` | `=high` with `--effort low` gave applied `high` |
| Model | `--model haiku\|sonnet\|opus` | resolves to `claude-haiku-5-5` / `claude-sonnet-5-5` / `claude-opus-5-5`. `default` resolves to Opus 5.5; `best` resolves to Fable. |
| Turn cap | `--max-turns <n>` (hidden) | result `subtype:"error_max_turns"`, `terminal_reason:"max_turns"`, exit 1; the last tool call ran |
| Spend cap | `--max-budget-usd <x>` | result `subtype:"error_max_budget_usd"`, `terminal_reason:"budget_exhausted"`, exit 1; the requested tool did not run. Measured in list-price $LE, the same unit as `total_cost_usd`. Fresh sessions only. |
| Sub-agents | `Task` in tools (the model calls it `Agent`) | p8: `task_started` with `spawn_depth` 1 and 2; one MCP server pid; sub-agent Bash write gave "operation not permitted" |
| Workflow | settings `enableWorkflows:true` **and** `Workflow` in `--tools` (under `--restricted`) **and** `permissions.allow:["Workflow"]` | absent under `--setting-sources ""` until set (24 vs 25 tools). p9: 2-agent `parallel()` ran, `denyRead` was honoured, and the stream had **two `system/init` and two `result` events** (the first said "still running") with a cumulative `total_cost_usd` |
| Ultracode readback | `get_settings` `applied.ultracode/ultracodeRequested/ultracodeAvailable` | `ultracodeAvailable` reflects `enableWorkflows` plus model support. It was true even with `--tools ""`, so it is **not** proof that Workflow is usable. |
| Plan mode | `--permission-mode plan` | haiku in an empty dir: the plan was written via `Write` to `~/.claude/plans/…`, `subtype:"success"`, no `ExitPlanMode` in `-p`, no other file created |
| Fast mode default | (none) | `-p` init `fast_mode_state:"off"`, `fast_mode_disabled_reason:"sdk_opt_in_required"`, `usage.speed:"standard"` |
| Window telemetry | `rate_limit_event.unifiedWindows.five_hour/seven_day`; control requests `get_settings`, `get_usage` (`skip_behaviors:true`), `list_models` | the control requests answered with no model call. `get_usage` returned `subscription_type:"pro"`, five_hour 86, seven_day 12 (whole percents) |
| Overage state | `rate_limit_event.overageStatus`, `isUsingOverage` | observed `"rejected"`, `"out_of_credits"`, `false` |

### 1.2 Relied on but NOT yet verified (each has a probe gate in §8)

- `CLAUDE_CODE_SUBAGENT_MODEL` + `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`:
  - pinning `Agent({model:"opus"})`;
  - pinning built-in Explore;
  - pinning workflow `agent({model})`.

  The only evidence is the binary's `Geo()` and the docs. → V-5
- `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`: docs only. → V-5
- `maxEffortLevel` clamping the sub-agent `effort` input and `agent({effort})`, and the cap values `low`/`medium`. → V-5 plus mode-canary
- `--max-budget-usd` on `--resume`: is it per process or session-cumulative? Is `total_cost_usd` per turn or cumulative across a resume? → L-4
- Whether `--max-budget-usd` and `total_cost_usd` include sub-agent spend (L-2) and workflow-agent spend (U-3). p8 and p9 suggest yes.
- Agent `isolation:"remote"` refused under `--strict-mcp-config --restricted`. → V-2
- PostToolUse and PreToolUse hooks (from `--settings`) firing for sub-agent and workflow-agent tool calls. → V-1, V-8
- `--disallowed-tools Task` removing Task from init tools. → V-3
- Plan mode under the real Brahma argv: MCP tools usable, the resume leaves plan mode, an absolute `plansDirectory` works. → V-4
- `availableModels` constraining sub-agent and workflow models. → V-5
- Nested `claude` from sandboxed Bash failing (Keychain auth, network). → V-9
- Whether the `ultrathink` keyword in quoted text changes thinking. → V-10
- The CLI exiting before answering when given an unknown hidden flag. → V-11

### 1.3 Excluded

| Mode | Why | Enforcement |
|---|---|---|
| Fast mode | Usage credits only, at 2× Opus price, outside the windows, invisible to the pacer | env `CLAUDE_CODE_DISABLE_FAST_MODE=1` on every turn (Bash children inherit it); settings `fastMode:false`; per-turn assertion `fast_mode_state=="off"` and `usage.speed=="standard"`. Plan 11 may add an owner "pay for speed" policy as a reserved money matter. |
| Fable, `best` | About 19× the baseline. In `-p` it "bills without asking" past the Fable weekly cap. | model allowlist |
| `default`, `opusplan`, `*[1m]`, `*-4-6*`, `claude-fable-*` | `default` means Opus. `opusplan` hides the model switch from accounting. Sonnet 4.6 [1m] needs credits. | model allowlist; settings `availableModels:["haiku","sonnet","opus"]` as a second lock (V-5) |
| Standing `ultracode:true` | Removes the size warning and the sub-agent cap, and tells the model "token cost is not a constraint" | never emitted (snapshot test); possible later opt-in after U-9 |
| `--advisor` | Hidden flag, no measured gain for Haiku/Sonnet executors, and a Fable advisor carries credit risk | never emitted; 3b may revisit |
| `--thinking`, `--max-thinking-tokens`, `MAX_THINKING_TOKENS` | No effect on 5.5 models | never emitted or passed |
| Ultrareview, `/code-review ultra`, Code Review app | Credits after 3 free runs; runs in the cloud outside the sandbox | `--disable-slash-commands` (3a); `Bash(claude *)` deny rules; nested-claude canary (5-lite); Skill deny for `deep-research`/`ultrareview` on Ultra turns |
| Agent teams | About 7× tokens and duplicates Brahma | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` never passed |
| `--task-budget` | Hidden and not exercised | later |

---

## 2. Work modes

### 2.1 Rung ladder

Costs are relative to R1 (Sonnet 5.5 medium, one work turn ≈ $0.54 LE at current list prices). They come from published cost-per-task figures and the binary's `effort_cost_index`, and calibration replaces them (§3.8).

| Rung | Model | Effort | Est. vs R1 | Notes |
|---|---|---|---|---|
| R0 | sonnet (haiku for notice turns) | low | 0.5× (haiku ≈ 0.05×) | haiku only while the context is under 100k tokens |
| R1 | sonnet | medium | 1× | set explicitly; Claude Code's default |
| R2 | sonnet | high | ≈ 1.7× | |
| R3 | opus | medium | ≈ 3.7× | PRD, architecture, confirmed tier L |
| R4 | opus | high | ≈ 5.1× | escalation, confirmed tier L only |
| R5 | Ultra: orchestrator at R2 or R3 plus a workflow | high | 4–25× per turn | 5-lite; gated (§3.6) |
| (opus-low) | opus | low | ≈ 1.9× | used when an Opus-required turn is clamped (Low usage mode, closed pace, overage allowed, Pro) |

- `xhigh` (about 13× on Opus) and `max` are **never automatic**. They are reachable only by an owner pin on an item or agent, and are still bounded by `--max-budget-usd` and the item budget.
- `est(rung)` adds a **cacheBreak cost** whenever the target model differs from the session's model: session tokens × the target model's 1-hour cache-write price.

### 2.2 Mode table (what the compiler emits)

Columns: **Quick**, **Standard**, **Deep**, **Plan-first** (modifier) and **Ultra** (5-lite only).

**Rungs and use**

| | Quick | Standard | Deep | Plan-first | Ultra |
|---|---|---|---|---|---|
| Rungs | R0 | R1 | R2–R4 | the plan turn runs at the item's session model, effort medium | R5 |
| Typical use | notice turns, DM replies, itemless work | tier S/M work, audit | risky/P0 M, confirmed tier L, PRD/architecture, escalations | confirmed tier L, first work turn; M with `migration`/`hotPath`; replan after 2 review rejections | confirmed tier L or P0 critical path, after policy or owner approval |
| `--effort` | low | medium | high (sonnet) / medium or high (opus) | medium | high |
| `maxEffortLevel` | low | medium | the turn's effort | medium | high |

**Sub-agents and Workflow**

| | Quick | Standard | Deep | Plan-first | Ultra |
|---|---|---|---|---|---|
| Sub-agents (`Task`), 3a workspace profile | off | **off** until the sub-agent gate passes (§3.9); then forced **haiku**, depth 1, ≤ 2 concurrent, foreground | **off** until the gate passes; then forced **sonnet**, depth 1, ≤ 3 concurrent, foreground | **off** | (not available) |
| Sub-agents, 5-lite sandboxed profile | off | as above, when the gate passes | as above | off | forced sonnet, depth 1, ≤ 3 concurrent, foreground |
| Workflow | off (kill switches) | off | off | off | **on**: inline scripts only; size `small` (Ultra-small) or `medium` (Ultra); workers forced sonnet; concurrency 2 (max5x) or 4 (max20x) |

**Limits**

| | Quick | Standard | Deep | Plan-first | Ultra |
|---|---|---|---|---|---|
| `--max-turns` | 10 | 40 | 60 | 25 | 100 |
| `--max-budget-usd`: min(mode cap, item $LE left) | 0.30 | 2.00 | 5.00 (sonnet) / 8.00 (opus) | 2.00 / 4.00 (opus) | 4.00 (small) / 15.00 (Ultra) |
| Wall clock (`profile.wallClock`, enforced by the runner) | 5 min | 20 min | 30 min | 15 min | 45 min; `PRINT_BG_WAIT_CEILING_MS` = wallClock − 5 min = 40 min |
| Workflow agent-count kill (watchdog) | — | — | — | — | 5 (small) / 10 (Ultra) distinct `agentId`s |

**MCP quotas per turn, and profiles**

| | Quick | Standard | Deep | Plan-first | Ultra |
|---|---|---|---|---|---|
| Posts+DMs / items created / comments | 3 / 1 / 5 | 10 / 3 / 20 | 10 / 5 / 20 | 3 / 0 / 5 | 15 / 3 / 40 |
| High-risk company tools (`reviewedHighRisk` plus `update_work_item` spec or owner changes) | normal | 1 per turn when Task is on | 1 per turn when Task is on | 0 | denied (see below) |
| Profiles | all | all | all | all | **sandboxed only** |

On Ultra turns, the high-risk tools are denied through `permissions.deny`: `mcp__company__{decide, propose_decision, escalate_decision, request_from_owner, request_access, request_secret, plan_sprint, close_sprint}`.

Two launch rules sit outside the table:
- **No-launch rule:** if the item's remaining $LE is below `est(Quick)`, or the computed cap would be ≤ 0, the turn is not launched. The item is blocked over budget with the existing 3a text.
- **Review and audit turns** use Standard, or Deep at R3 for confirmed tier L or flagged items. They **never** get `Task` or `Workflow`.
  - Review $LE is recorded on the item (`itemFact.reviewCostLE`).
  - Once review spend passes 25% of the tier $LE, reviews drop to Standard and the manager is notified.

### 2.3 Compiled examples

Only the additions to the current 3a argv are shown. Unchanged: `--setting-sources ""`, `--strict-mcp-config`, `--fallback-model sonnet`, `--disable-slash-commands`, the stdin prompt, the byte-stable `--append-system-prompt`, and the per-turn `BRAHMA_TURN_TOKEN` in the mcp-config env.

**Common to every mode.** Settings keys:
- `"availableModels":["haiku","sonnet","opus"]`
- `"fastMode":false`
- `"workflowKeywordTriggerEnabled":false`
- `"enabledPlugins":{}`
- `"hooks"`: `PreToolUse` with matcher `Agent|Task|Workflow` → `brahma hook pre-tool` (§4.2)

Env: `CLAUDE_CODE_DISABLE_FAST_MODE=1`, plus `CLAUDE_CODE_DISABLE_WORKFLOWS=1` on every non-Ultra turn.

**Quick (notice turn):**
```
--model haiku --effort low --max-turns 10 --max-budget-usd 0.30
--disallowed-tools <3a list>,Task
--settings {..common.., "disableWorkflows":true, "maxEffortLevel":"low"}
env + CLAUDE_CODE_DISABLE_FAST_MODE=1 CLAUDE_CODE_DISABLE_WORKFLOWS=1
```

**Standard (tier S/M work).** Shown with the sub-agent gate *passed*. Before it passes, it is identical except `Task` is added to `--disallowed-tools` and the sub-agent env vars are omitted.
```
--model sonnet --effort medium --max-turns 40 --max-budget-usd 2.00
--settings {..common.., "disableWorkflows":true, "maxEffortLevel":"medium"}
env + CLAUDE_CODE_SUBAGENT_MODEL=haiku CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
      CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2
      CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 CLAUDE_CODE_DISABLE_FAST_MODE=1 CLAUDE_CODE_DISABLE_WORKFLOWS=1
```

**Ultra (5-lite sandboxed profile; settings file 0600 at `<home>/run/<agentId>.settings.json`):**
```
--model sonnet|opus (= the session model) --effort high --max-turns 100 --max-budget-usd 15.00
--restricted --tools Bash,Read,Edit,Write,NotebookEdit,Skill,Task,ToolSearch,WebFetch,WebSearch,Workflow
--permission-prompts none
settings: {..5-lite sandbox block.., ..common.., "enableWorkflows":true, "workflowSizeGuideline":"medium",
           "maxEffortLevel":"high",
           "permissions":{"allow":[..5-lite..,"Workflow"],
                          "deny":[..5-lite..,"Bash(claude *)","Bash(*/claude *)",
                                  "mcp__company__decide","mcp__company__propose_decision", …(§2.2),
                                  "Skill(deep-research)","Skill(ultrareview)"]}}
env + CLAUDE_CODE_SUBAGENT_MODEL=sonnet CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
      CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=3
      CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1
      CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS=2 (max5x) | 4 (max20x)
      CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=2400000 CLAUDE_CODE_DISABLE_FAST_MODE=1
digest (engine line): "This turn is opted into multi-agent orchestration (approved by: owner | Brahma policy):
you may use the Workflow tool with an inline script. Hard cap $15 LE; at most 10 agents, or the turn is stopped."
```

The digest line names the real approver. It never claims the owner when policy approved. It is needed because the Workflow tool description says "ONLY call this tool when the user has explicitly opted into multi-agent orchestration". U-1 verifies that the policy wording still counts as an opt-in.

### 2.4 Plan-first mechanics

1. **Plan turn** (new `TurnKind.plan`):
   - `--permission-mode plan`; tools without `Task`, `Edit` and `NotebookEdit`. `Write` stays, for the plan file.
   - Settings `plansDirectory` = `<ws>/.brahma/plans/<KEY>/`, which is the only writable path for this turn. In 5-lite the worktree is a read-only dir in this turn's scope.
   - Without `plansDirectory`, the probe wrote to `~/.claude/plans/…`, outside the workspace.
2. **Write barrier (engine-side; plan mode alone is not trusted):**
   - After every plan turn, the engine checks that the worktree is clean and HEAD has not moved.
   - If either check fails, it resets the worktree to the pre-turn HEAD, records `planTurnWrote`, does not count the plan, and notifies the manager.
3. **Capture.** The source of truth is the `Write` tool_use path under `plansDirectory`, with a file read as a cross-check.
   - If nothing was written, the final result text is the plan.
   - Stored as item event `planWritten`, linked on the item, and quoted (`    | `) into the next digest and the Continuity block.
   - There is no approval gate, because gates block only irreversible work (spec §4.6.9). The manager gets an FYI; tier L with `migration`/`hotPath` also notifies the architect.
4. **Execute turn:** `--resume` with the normal permission mode, at the **same model** as the plan turn.
5. **Cost:** a trivial haiku plan turn cost $0.039 versus $0.0006 for a non-plan turn, so Plan-first is off for tier S.
6. **Gate:** Plan-first compiles only after V-4 passes. That two-turn probe covers MCP tools in plan mode, leaving plan mode on resume, and an absolute `plansDirectory`.

---

## 3. Selection policy

### 3.1 Inputs (`ModeInputs`, all derived by the engine)

| Input | Source |
|---|---|
| `turnKind` | `work, review, audit, notice, plan` (3a `TurnKind` plus `audit` and `plan`) |
| `decidingPRD/Architecture` | 3a `ModelContext` |
| `tier`, `priority`, `itemType` (**effective**) | the stored value counts only if `specConfirmedBy ∈ {manager, executive, owner, system}` **and** the confirmer is not the current lease holder. Otherwise the effective value is tier ≤ M, priority ≥ 2, and the item type does not count as Ultra-eligible. |
| `blockingCount` (**effective**) | counts only dependents that the current holder did not author and link |
| `riskTags` (derived) | `WorkPolicy.riskTags(item)`: `sensitivePath`, `hotPath`, `migration`, `flagged`, `securityLabel` |
| `intensity` | item field `auto` (default) / `thorough` / `ultra`. Managers may set at most `thorough`, only on their subtree. Only the owner may set `ultra`. Never settable by the assignee or through `create_work_item`. |
| `rungFloor` | item field, set only by escalation (§3.3); never settable through any tool schema |
| `sessionModel` | the model of the (agent, item) session's first work turn |
| `role.modeProfile` | role card v2: `defaultRung`, `maxRung`, `subagents: none\|readers\|workers` |
| `trust` | `Agent.trustLevel` (T1 until 3b) |
| `failureHistory` | counted failures only (§3.3), review rejections, consecutive `budgetCap` stops |
| `budgetLeft` | the item's remaining tier budget ($LE, turns) |
| `usageMode` | company `low\|balanced\|max` |
| `planTierEffective` | min(configured `planTier`, `get_usage.subscription_type`) until the owner confirms (§3.7) |
| `pace` | `UsageGate.pace`: `onPace \| near \| ahead \| closed`, plus `headroomLE` |
| `fiveHourUtil`, `sevenDayUtil` | the freshest of the last `rate_limit_event` and the last `get_usage`, **plus** the unspent `pctPerDollar5h` of open Ultra reservations |
| `overage` | `overageStatus`, `isUsingOverage` |
| `ultraState` | Ultra allowance left, Ultra runs today, Ultra turns running, calibration ready, Ultra probe gates passed for this CLI version |
| `subagentGate` | whether the sub-agent gate passed for this CLI version and profile (§3.9) |
| `opusScarce` | true for 1 h after ≥ 2 turns that requested opus showed only sonnet in `modelUsage` |

### 3.2 Algorithm (`ModePolicy.select`; pure; one reason string per step)

```
1. kind gate
   notice            → Quick (haiku low). done.
   review | audit    → Standard; Deep@R3 if effective tier L or flagged/sensitive (sessionModel rule does not apply:
                       review is a fresh clean-context session). Never Task/Workflow. Review spend cap (§2.2). done.
   plan              → Plan-first turn (§2.4) at sessionModel (or the base rung's model if no session yet), effort medium.
   itemless work     → Quick (sonnet low).
2. base rung (uses EFFECTIVE tier/priority/type/blockingCount)
   PRD/architecture decision → R3
   tier L (confirmed)        → R3, Plan-first if no planWritten since claim
   tier M                    → R1; R2 if any riskTag or priority 0 or blockingCount ≥ 2;
                               Plan-first if riskTag ∈ {migration, hotPath} and no plan yet
   tier S                    → R1
   role.defaultRung overrides only upward; intensity=thorough → max(base, R2)
3. floor          rung = max(rung, item.rungFloor)
4. usage mode
   low      → maxRung R2, except Opus-required turns (PRD/arch/confirmed L) → opus-low; Task off; Ultra off;
              Plan-first only for tier L
   balanced → as computed
   max      → +1 rung (≤ R4) for effective priority 0 or blockingCount ≥ 2
5. pressure clamps (applied last; can only lower; any one may apply)
   overage == "allowed" (or isUsingOverage)
                        → rung ≤ R1 (Opus-required → opus-low); Task off; Ultra off; Plan-first only tier L;
                          admission refused when fiveHourUtil ≥ 0.85 or sevenDayUtil ≥ 1 − reserve (no exemption)
   planTierEffective == pro
                        → rung ≤ R2 (Opus-required → opus-low); Task off; Ultra off
   pace closed          → rung = min(base, R1) (Opus-required → opus-low); rungFloor IGNORED; Task off;
                          Plan-first off. (Admission: critical path only, and only while sevenDayUtil < 1 − reserve.)
   pace ahead           → no rung above base; effort −1 step (min low); Ultra off; Plan-first only tier L
   fiveHourUtil ≥ 0.85  → Task off; effort −1 step
   opusScarce           → R3/R4 → R2, except PRD/arch decisions (fallback-model covers those)
   model change vs sessionModel, not an explicit escalation to Opus
                        → keep sessionModel, adjust effort only
   budgetLeft < est(rung) (est includes cacheBreak)
                        → step down until it fits; record "held at Rn by budget";
                          below est(Quick) → do not launch (block over budget)
   role.maxRung, trust cap (T0 → ≤ R1, no Task; 3b)
   !subagentGate        → Task off
6. ultra  (only if all §3.6 gates pass; else the computed rung with a reason)
7. emit ModeDecision {mode, rung, model, effort, planFirst, subagents, workflow?, caps, wallClock, quotas, reasons[]}
```

Every decision is stored on the turn as `turn.mode`, `turn.rung`, `turn.effort` and `turn.modeReason`. The item inspector shows it, for example "Deep R2 · 2 failed checks · held by pace".

### 3.3 Escalation

**Counted failure.** A failed check counts toward escalation only when all of these hold:
- the submitted commit differs from the previous failing commit;
- the diff touches files in the item's scope;
- the failure is not flaky, inconclusive or infra.

Identical resubmits do not escalate.

| Event | Effect |
|---|---|
| 1 counted failure | none |
| **2 counted failures since claim** | `rungFloor = rung + 1`, effort first: R1→R2; R2→R3 only for confirmed tier L, or tier M that is P0 or has a risk tag (an explicit escalation to Opus, recorded as a cacheBreak); R3→R4 only for confirmed tier L |
| 3 counted failures | the existing 3a watchdog escalation. The next claimant starts at `rungFloor`, which persists across claims. |
| 2 review rejections | `rungFloor +1` and a Plan-first **replan** turn |
| Flaky, inconclusive or infra failure | never escalates |
| Watchdog no-progress or loop | **no** escalation; 3a escalation applies |
| `error_max_budget_usd` twice in a row on the same item | manager notice "turn cap too small for <KEY>"; no rung change |
| Escalation would exceed `budgetLeft` | not applied; reason recorded; manager notice (raise tier, split, reassign) |
| R4 reached plus 2 more counted failures on a confirmed tier L or P0 item | the engine **proposes Ultra** as an owner `boost` ask, **under every preset** |

### 3.4 De-escalation

- `rungFloor` resets to 0 when the item merges.
- If a review requests changes and every finding is P2, the fix turn runs at the floor's model but at the base rung's effort. The model is not lowered mid-session.
- An approved Ultra is **one turn**. The item then returns to its prior floor.
- Pressure clamps are re-evaluated every turn.

### 3.5 Who may ask for more

| Requester | How | Maximum it can obtain |
|---|---|---|
| Assignee agent | MCP `request_mode {item, mode: deep\|ultra, reason, approach}` | **R2 (sonnet high)** via policy, next turn. An Ultra request becomes a manager-endorsed `boost` ask (§3.6). |
| Manager or executive (subtree) | `update_work_item intensity: thorough`, or confirm the spec (`specConfirmedBy`) | Thorough = floor R2; confirming tier L unlocks R3 by base policy; Ultra only through §3.6 |
| Engine | automatic proposal (§3.3) | always an owner ask |
| Owner | item Intensity = Ultra (pre-approves **one** Ultra run within caps), or answering a `boost` ask; `xhigh`/`max` only by explicit pin | Ultra within caps |

Rules:
- A request never changes the current turn.
- At most 1 open request per item and 3 per agent per active day.
- A denied request has a 1-active-day cooldown per item unless a new counted failure arrives.
- `request_mode` is **high-risk under taint**.
- Request text is quoted in the ask and never parsed for policy.
- `create_work_item` and `update_work_item` schemas cannot set `intensity`, `rungFloor`, `budgetBoostLE` or `specConfirmedBy`.

### 3.6 Ultra: eligibility, hard gates, approval, caps

**Eligibility.** At least one of the following, all using **effective** values:
- confirmed tier L;
- confirmed P0 with `blockingCount ≥ 2`;
- confirmed item type ∈ {audit, migration, research spike, broad refactor};
- the §3.3 R4 trigger.

**Hard gates.** All must hold. If any fails, the turn runs at the computed non-Ultra rung, with the reason recorded.

1. **Profile and probes:**
   - sandboxed profile (5-lite);
   - the Ultra canary key has passed for this CLI version: U-1, U-3, V-1, V-2, V-8 and V-9;
   - the init `tools` contains `Workflow`.
2. **No overage possible:** `overageStatus != "allowed"` and `isUsingOverage == false`.
3. **Plan tier confirmed:** `planTierEffective` is max5x or max20x, and the owner has confirmed it. The doctor's `get_usage.subscription_type` agrees.
4. **Calibrated:** `pctPerDollar` and `pctPerDollar5h` each have ≥ 10 qualifying windows (§3.8).
5. **Weekly:** pace not `ahead`/`closed`, **and** `sevenDayUtil + cap × pctPerDollar(p80) ≤ allowed`. There is no critical-path exemption.
6. **5-hour, using a fresh reading:** send `get_usage` (`skip_behaviors:true`) right before admission. Require `fiveHourUtil ≤ 0.60` **and** `fiveHourUtil + Σ open reservations + cap × pctPerDollar5h(p80) ≤ 0.85`.
7. **Ultra allowance** remaining ≥ cap.
8. **Caps:** Ultra runs today for this company < `ultraPerCompanyDay`; running Ultra turns (global) < `ultraConcurrent`.
9. **Slots:** the company has free slots ≥ `ultraSlots + 1` under its usage-mode cap, where `ultraSlots = 1 + WORKFLOW_MAX_CONCURRENT_AGENTS`. One slot is always left for reviews and the critical path.
10. **Mode and trust:** usage mode ≠ Low; trust ≥ T1; the session is not tainted.

**Approval:**

| Variant | Size guideline / cap / agent kill | `everything` preset | `important` (default) | `auto` |
|---|---|---|---|---|
| **Ultra-small** | `small` / $4 LE / 5 agents | owner `boost` ask | policy + owner FYI, **only** for a manager-endorsed request on an item that has not been escalated | policy + FYI |
| **Ultra** | `medium` / $15 LE / 10 agents | owner ask | **owner ask** | policy + FYI |
| Any Ultra proposed through the §3.3 failure path | — | owner ask | owner ask | owner ask |
| Ultra-large, Opus workers, standing ultracode | — | not available in v1 | — | — |

- The variants are *enforced* only by the budget cap, the concurrency env var and the engine's agent-count kill. `workflowSizeGuideline` and the digest line are advisory.
- Owner Intensity = Ultra approves one run of either variant.
- Ultra is not a reserved matter, because gate 2 guarantees it spends no money.

**Caps (pinned numbers):**

| | max5x | max20x | pro |
|---|---|---|---|
| `ultraShare` (of the weekly share) | 0.15 | 0.15 | 0 (Ultra off) |
| `ultraPerCompanyDay` (owner TZ) | 2 (≤ 1 full Ultra) | 6 | 0 |
| `ultraConcurrent` (global) | 1 | 2 | 0 |
| `WORKFLOW_MAX_CONCURRENT_AGENTS` | 2 | 4 | — |
| `ultraSlots` | 3 (so Ultra fits only in **Max** usage mode, cap 8) | 5 | — |

For scale: Max 5x at a 70% share is roughly $375 LE per week (±2×, needs calibration). 15% of that is about $56 LE, enough for about 3 full Ultra runs or about 14 Ultra-small runs.

### 3.7 Plan tier and the Pro row

New row in the 3a plan-tier table:

| planTier | Low / Balanced / Max concurrency | maxRung | Task | Ultra |
|---|---|---|---|---|
| pro | 1 / 1 / 2 | R2 (Opus-required → opus-low) | off | off |

- If the doctor's `get_usage.subscription_type` disagrees with the configured `planTier`, the engine uses the **lower** of the two.
- It also raises an `engineAlert` asking the owner to confirm, and keeps using the lower tier until they do.
- The CLI currently reports `"pro"`. Until the owner answers Q-M1, Brahma runs the Pro row.

### 3.8 Budgeting, accounting and calibration

1. **Reservation at admission (Ultra).** An `ultraReservation(turnId, capLE)` row is charged against:
   - the Ultra allowance;
   - the projected 7-day pace;
   - the 5-hour admission check for every other turn, as unspent cap × `pctPerDollar5h`.
2. **During the run:**
   - `--max-budget-usd = cap` is the hard stop. It can overshoot by up to one response per concurrent agent, so caps include a 10% margin.
   - The engine watchdog sends SIGINT and then killpg when distinct `workflow_progress[].agentId` exceeds the variant limit (`stopReason=agentCap`), or when `wallClock` is reached.
3. **At the end:**
   - Actual $LE = the **last** `result.total_cost_usd`. Whether that figure is per process or cumulative over a resume is settled by L-4 before W7 is finalized.
   - The reservation is released down to the actual figure.
   - **Killed with background work pending** (non-empty `background_tasks_changed`, or a `task_started` with no matching `task_notification`): the turn is `interrupted`, even if an early result was seen, and charged max(last `total_cost_usd`, cap).
   - Killed with no result (exit 143): `interrupted`, full cap charged.
4. **Item budget.** An approved Ultra adds `budgetBoostLE = cap` to the item once.
   - The Ultra turn's tokens are **excluded from the tier token cap** (S 300k / M 1M / L 3M); the $LE cap governs that turn.
   - It counts as one turn.
5. **Weekly share.** Ultra $LE is ordinary $LE in the 7-day pace. The Ultra allowance is a sub-limit inside the share.
6. **Calibration** (`pctPerDollar`, `pctPerDollar5h`):
   - A sample is one accumulation window in which Δutil ≥ 2 points; ratio = ΣΔutil / Σ$LE over that window. Utilization is reported in whole percents, so per-turn deltas are mostly noise.
   - Admission checks use the **80th percentile**, so the owner's own usage errs on the safe side. Require ≥ 10 windows.
7. **Rung cost** (`modeCalibration`):
   - An EMA of $LE per work turn for each (model, effort).
   - Before data exists: the R2 median × the binary's `effort_cost_index` (sonnet low .49 / med .54 / xhigh 1.87 / max 5.5; opus low .48 / med .66 / xhigh 1.66 / max 3.44; high = 1).
   - Outcome facts gain `rungAtPass` and `modesUsed`. The dogfood week re-derives the tier budgets ($3/$10/$40 were priced at the old Sonnet $3/$15).
8. **Fan-out accounting.**
   - Per-turn counters `subagentsSpawned` and `workflowAgents`.
   - `modelUsage` keys are checked against {main, fallback, forced worker}. The documented safety-fallback IDs (`claude-opus-5`, `claude-opus-4-8`) are recorded but not alerted on. Any other model raises an `engineAlert` and blocks that agent's next turn until the doctor re-runs.

### 3.9 Sub-agent gate (per CLI version, per profile)

`Task` compiles on only when all of these pass:

| Check | What it proves |
|---|---|
| L-2 | `total_cost_usd` ≥ Σ `modelUsage[*].costUSD` including the haiku worker, and a $0.02 cap stops a turn waiting on a sub-agent |
| V-2, or V-8 live | `isolation:"remote"` is refused, or the pre-tool hook denies it |
| V-3 | `--disallowed-tools Task` really removes Task, so "off" is real |
| V-5 | FORCE pins `Agent({model:"opus"})` and Explore to haiku, there is no `spawn_depth` 2 at depth 1, and the effort clamp works |

Further rules:
- If V-1 (PostToolUse fires for sub-agents) has not passed, a Task turn is **pre-tainted at launch** unless its network scope is empty (no `allowedDomains`) **and** it has no web tools.
- On the 3a **workspace** profile the gate also requires V-9 (nested `claude` cannot run). It cannot pass there, because Bash is unsandboxed. So **3a ships with Task off**, and sub-agents arrive with the 5-lite sandboxed profile.
- Until custom Brahma agent types are verified (F7), a turn is either Task without web tools or web tools without Task.

---

## 4. Enforcement

### 4.1 Single point of truth

- `ModePolicy.select` → `ModeDecision` → `TurnProfileCompiler`. The compiler emits argv, the settings JSON or file, the **engine-set child env**, `profile.wallClock` and the MCP quota env.
- The 3a rule "argv comes only from the compiler" extends to settings keys and `CLAUDE_CODE_*` env. Snapshot tests cover every mode.
- **`engineClaudeVars`** is one allowlist, admitted from `TurnRequest.environment` only. Today `ChildEnvironment.make` (TurnProfile.swift:110) admits only `BRAHMA_*` from `extra`, so without this every control would be dropped silently. The list:
  - `CLAUDE_CODE_SUBAGENT_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`
  - `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`
  - `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, `CLAUDE_CODE_DISABLE_FAST_MODE`, `CLAUDE_CODE_DISABLE_WORKFLOWS`
  - `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`
  - `CLAUDE_CODE_SHELL_PREFIX` (5-lite)
- The same allowlist is used by 3a W8 and 5-lite F1, so neither plan adds a second path.
- A TurnRunner-level test asserts the spawned process env contains every var the compiler emitted.
- **Never passed, whether inherited or engine-set:** `CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `CLAUDE_CODE_WORKFLOWS`, `MAX_THINKING_TOKENS`, `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS`. The last is allowed only in F7, once verified.
- **Model allowlist:** {`haiku`, `sonnet`, `opus`, `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`}.
  - Anything else is refused with `"model <m> is not allowed in Brahma turns"`, including an owner pin.
  - Settings `availableModels` is a second lock (V-5).
- **MCP quotas:** counted in memory inside the per-turn `brahma mcp` process. There is one per turn, and p8/p9 showed every sub-agent and workflow agent using the same pid. The counts are keyed to the existing `BRAHMA_TURN_TOKEN` and set by `BRAHMA_MCP_QUOTA_*` env in the per-turn mcp-config.

### 4.2 Engine pre-tool hook (`brahma hook pre-tool`, matcher `Agent|Task|Workflow`)

Denies, with a reason the model sees:
- `Agent`/`Task` input with `isolation` set, `run_in_background:true`, or a `subagent_type` outside the expected set: the built-ins plus approved Brahma types;
- `Workflow` with `name`, `scriptPath`, or a `resumeFromRunId` not recorded for this item (inline `script` only);
- any of these while the session is tainted: the flag file exists or `sessionTainted` is set;
- `Workflow` on any non-Ultra turn (a belt to the three locks).

Gate V-8 checks that the hook fires under `--setting-sources ""` and for calls made by sub-agents. If it does not, Task stays off and Ultra stays gated.

### 4.3 Locks on Workflow, and why an agent can't self-escalate

Workflow exists in a turn only if all three locks are open:
- (a) settings `enableWorkflows:true`;
- (b) `--tools` names it;
- (c) `permissions.allow` has `Workflow`.

Every non-Ultra turn also sets `disableWorkflows:true` and `CLAUDE_CODE_DISABLE_WORKFLOWS=1`, and the pre-tool hook denies it.

| Escalation path | Block |
|---|---|
| Text says "ultracode" or "use a workflow" | Workflow absent; the keyword is inert in `-p`; `workflowKeywordTriggerEnabled:false`. Test: byte-identical argv. |
| Agent authors a tier-L/P0/migration item, links its own dependents, claims it | effective tier/priority/type/blockingCount ignore unconfirmed and self-authored values (§3.1) |
| `Agent({model:"opus"\|"fable"})` | FORCE env plus `availableModels` (V-5); `modelUsage` check |
| `Agent({effort:"max"})` | `maxEffortLevel` (V-5) |
| `Agent({isolation:"remote"})`, background agents | pre-tool hook (V-8); V-2 |
| Named or bundled workflows (`deep-research`, `batch`), `scriptPath` | pre-tool hook; Skill deny rules on Ultra |
| Custom agent types from the worktree (`.claude/agents/x.md`) or plugins with `permissionMode`/`isolation`/`background` | PluginLibrary refuses agent frontmatter keys other than `name, description, tools, disallowedTools`. Each turn asserts that the init `agents` list equals the expected set; if not, the turn is aborted before any tool runs and an `engineAlert` is raised. |
| Agent edits its item's intensity, floor or spec | not in the tool schemas; spec is not editable by the assignee; intensity is manager (≤ thorough) or owner only |
| Gaming failures to climb the ladder | only counted failures escalate (§3.3); failure-path Ultra always needs the owner |
| `export CLAUDE_CODE_EFFORT_LEVEL=…` in Bash | affects only Bash children |
| Nested `claude -p …` from Bash | **all profiles:** env `CLAUDE_CODE_DISABLE_FAST_MODE=1` (and `DISABLE_WORKFLOWS=1` off Ultra), inherited by Bash children; `Bash(claude *)`/`Bash(*/claude *)` deny rules (prefix-bypassable). **5-lite:** canary V-9 requires a nested `claude -p` to fail. The barrier is **network and exec**: no `allowedDomains` entry may match `anthropic.com`/`claude.ai`, and the binary under the home must not be executable. `denyRead` of `~/.claude` is not the barrier, because auth is in the macOS Keychain. **Workspace profile: residual risk.** An agent can unset the env, and nested `claude` then loads the owner's `~/.claude/settings.json` (`fastMode:true`, `enableWorkflows:true`). Documented in the README's "Workspace is not a sandbox" paragraph. It is also why Task and Ultra stay off there. |
| Editing the settings or MCP file | `<home>/run/`, 0600, outside every writable scope (5-lite); the same residual risk on Workspace |
| Spamming `request_mode` | rate limits; high-risk under taint; next turn only |
| Sub-agents calling high-authority tools as the parent | quota 1 per turn for high-risk tools on Task turns; denied on Ultra (§2.2) |
| `--fallback-model` switching silently | `modelUsage` key check (§3.8) |
| Fast mode | env plus `fastMode:false`; per-turn and doctor assertions |
| Org effort cap lowering the requested effort | stderr `Effort '<x>' exceeds the cap` is parsed and the actual effort recorded |
| `ultrathink` in quoted text | V-10. If it has an effect, quoted blocks break the token (`ultra-think`). |

### 4.4 Containment of sub-agents and workflow agents

- **Sandbox:** inherited (p8, p9). Write scopes stay the item's narrow scope.
- **MCP:** same server and identity. Quotas are counted per turn inside the process (§4.1).
- **Taint (5-lite F4):**
  - Until V-1 passes, **every** Task or Workflow turn is pre-tainted unless its network scope is empty and it has no web tools. This covers `curl`, `npm` and `pip` in sub-agent Bash, which the stream cannot show.
  - Backup taint reads `tool_use` events that carry `parent_tool_use_id`, as well as `task_progress.last_tool_name` and `workflow_progress[].lastToolName`.
  - Optional: `--forward-subagent-text` for depth-1/2 inputs. Not relied on.
- **Built-in agents:** FORCE also pins Explore and Plan (V-5).
- **Kill switch:** 5-lite Task 7c `killpg` covers workflow agents (U-7).

### 4.5 TurnRunner and stream changes

These are conflicts with the built 3a code and must change:

1. **Wall clock per turn.** `ClaudeProcessRunner.maxTurnDuration` is a runner-wide 900 s (TurnRunner.swift:37), which would kill Deep and Ultra turns at 15 min. `run(request:)` takes `profile.wallClock`; the init value is only the Plan 1 fallback.
2. **More than one init and result.** Accept multiple `system/init` and `result` events. The outcome is the **last** `result`.
3. **Pending background work.** `if sawResult { return }` (TurnRunner.swift:162) would book a killed Ultra turn as a success at a partial cost. The runner instead tracks pending background work. If the watchdog, EmergencyStop or the bg ceiling ends the process while work is pending, it throws `.interrupted`/`.timedOut` even though a result was seen.
4. **Controlled stops.** Short-circuit on result subtype *before* the infra classifier:
   - `error_max_turns` → `stopReason=turnCap`; `error_max_budget_usd` → `budgetCap`.
   - Both are infra=false, counted in itemUsage and costLE, judged normally by the watchdog, and get no backoff.
5. **SIGTERM** (exit 143, no result) → `interrupted`, not counted against the agent.
6. **Fan-out events.** Parse `task_started` (`spawn_depth`), `task_progress.usage`, `task_notification`, `background_tasks_changed` and `workflow_progress`. They feed the activity feed ("ENG-142 · workflow 3/4 agents done"), the counters and the agent-count kill.
7. **Per-turn assertions:** `fast_mode_state=="off"`, `usage.speed=="standard"`, the init `agents` list equals the expected set, and the init `tools` match the mode (no `Task` when off; `Workflow` only on Ultra).

---

## 5. Owner experience (five nouns, none new)

| Noun | Addition |
|---|---|
| **Work** | Item field **Intensity: Auto · Thorough · Ultra** (chip and picker; default Auto). Inspector line: `Mode now: Deep R2 · 2 failed checks · $4.10/$10 LE`. An agent-authored tier L/P0 shows "unconfirmed: runs as M until a manager confirms". |
| **Company** | The existing **Low / Balanced / Max** dial. Tooltip: "Low: no deep or Ultra runs. Max: P0 and critical-path work gets more thinking; Ultra needs Max on Max 5x." |
| **Inbox** | `boost` ask card on the decision brief. Example: *"ENG-142 'Payment migration' wants an Ultra run: 4 failed checks across 2 escalations. Up to $15 LE ≈ 4% of this week (Ultra allowance left: 11%)."* Options: **Run Ultra once** · **Thorough instead** · **No, keep going**. Expires after 1 active day. Plus a plan-tier confirmation alert ("Claude reports a Pro plan…"). |
| **Budget** | Read-only rows under the weekly-share slider: `This week by mode: Quick 3% · Standard 41% · Deep 38% · Plan 4% · Ultra 14%` and `Ultra allowance 15% of share · used 9%` (Advanced). A digest line: `Ultra: 1 run, $9.80 LE, ENG-142 (passed)`. |

---

## 6. Where it lands

### 6.1 Plan 3a patch notes (Tasks 1–4 built)

- **W1, Task 4 (built; follow-up in 14c).**
  - Test `effortEnvNeverInherited`: `CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` and `MAX_THINKING_TOKENS` are absent from the turn env.
  - Add `engineClaudeVars` to `ChildEnvironment.make` (admitted only from `TurnRequest.environment`), plus a spawned-env test.
- **W2, Task 5 (UsageGate/calibration).**
  - `pctPerDollar5h`; the windowed (Δ ≥ 2 pt) p80 calibration.
  - `Pace.state` (`onPace|near|ahead|closed`) and `headroomLE`.
  - **The critical-path exemption ends at `sevenDayUtil ≥ 1 − reserve`.**
  - Open-reservation load counted in the 5-hour check.
  - The overage clamp's admission rule.
  - The `pro` plan-tier row and `planTierEffective`.
  - Controlled-stop subtypes short-circuit the infra classifier.
  - Tests: `fiveHourCalibration`, `calibrationIgnoresSubPointDeltas`, `paceStateAndHeadroom`, `criticalPathNeverEntersReserve`, `overageAllowedClampsAllModes`, `planTierMismatchClampsToDetected`, `budgetCappedTurnsCountTowardItemBudget`.
- **W3, Task 6 (schema).**
  - `workItem` gets:
    - `intensity TEXT NOT NULL DEFAULT 'auto'`
    - `rungFloor INT NOT NULL DEFAULT 0`
    - `budgetBoostLE DOUBLE NOT NULL DEFAULT 0`
    - `specConfirmedBy TEXT NULL` (actor id plus role)
    - `sessionModel TEXT NULL` on the (agent, item) session record

    All of these go in `"v3-work"`.
  - `WorkPolicy.riskTags(_:)`, derived.
  - The tool schemas exclude intensity, floor, boost and confirmation; managers confirm through a dedicated `confirm_spec` (manager, executive, owner).
  - `items add|edit --intensity`, `items confirm`.
  - Event kinds `planWritten`, `planTurnWrote`, `modeEscalated`, `specConfirmed`.
  - `itemFact.reviewCostLE`.
  - Tests: `agentAuthoredTierLNotOpusUntilConfirmed`, `selfLinkedDependentsDontCountForBlocking`, `schemasCannotSetIntensityOrFloor`.
- **W4, Task 9 (review).**
  - Review and audit profiles always compile with no Task and no Workflow.
  - **Replace `ModelPolicy.resolve`** (which hard-returns `sonnet` for `.review`) with `ModePolicy.select` for auto agents.
  - Add `TurnKind.audit` and `.plan`.
  - The review spend cap (25% of the tier $LE).
  - Update the existing ModelPolicy tests in the same commit.
  - Tests: `reviewTurnHasNoTaskOrWorkflow`, `reviewSpendCapDropsToStandard`.
- **W5, Task 10 (continuity / plan flow).**
  - The plan turn (§2.4), including the engine's clean-worktree check and reset.
  - The Continuity block quotes the plan.
  - A model or tool change on `--resume` is recorded as `cacheBreak`.
  - The session-model rule.
  - Tests: `planTurnWriteIsReverted`, `sessionModelFixedEffortVaries`.
- **W6, Task 11a (asks).**
  - `AskKind.boost` (not reserved).
  - `request_mode` with an R2 cap for assignees, rate limits, cooldown, `request_id` dedupe, and high-risk under taint.
  - Failure-path Ultra always goes to the owner.
  - Tests: `boostAskRoutedByPreset`, `requestModeNextTurnOnly`, `assigneeRequestCappedAtR2`, `failurePathUltraAlwaysAsksOwner`.
- **W7, Task 14a (StreamParser / TurnRunner / budget). Every item in §4.5:**
  - `profile.wallClock` in `run(request:)`; multiple init and result events with the last result winning; pending-background tracking; controlled stops; `interrupted`; fan-out events; per-turn assertions.
  - The `modelUsage` check with safety-fallback IDs recorded only.
  - The `turn` record gets `mode, rung, effort, modeReason, stopReason, subagentsSpawned, workflowAgents, costLE`.
  - Pin the cost rule (last total vs delta) from L-4 **before** the per-mode caps are enabled.
  - Fixtures: `stream-workflow.jsonl` (p9), `stream-workflow-cut17.jsonl`, `stream-max-turns.jsonl`, `stream-max-budget.jsonl`.
  - Tests: `lastResultWins`, `secondInitAccepted`, `killedWithPendingWorkflowIsInterruptedDespiteEarlyResult`, `deepTurnNotKilledAt15Min`, `maxTurnsIsControlledStop`, `maxBudgetIsControlledStop`, `sigtermWithoutResultInterrupted`, `unexpectedModelInModelUsageAlerts`, `safetyFallbackModelRecordedOnly`, `effortCapWarningRecorded`, `initAgentsMismatchAborts`.
- **W8, new Task 14c "Work modes" (after 14b; needs 5, 6, 8, 11a, 14a).**
  - `Work/ModePolicy.swift` (`ModeInputs`, `ModeDecision`, `select`) with Quick, Standard, Deep and Plan-first.
  - `TurnProfile` gets `effort`, `maxEffortLevel`, `maxTurns`, `maxBudgetUSD`, `permissionModeOverride`, `subagents`, `workflow?`, `wallClock`, `quotas`.
  - **Add `Task` to the workspace profile's disallowed tools** (it is missing from `ClaudeCommand.disallowedTools` today).
  - Compiler emission per §2.3: model allowlist, `availableModels`, `engineClaudeVars`, kill switches, `fastMode:false`, keyword trigger off.
  - The `brahma hook pre-tool` hook (§4.2). It is present on every turn, so the V-8 data accumulates.
  - In-process MCP quotas (`BRAHMA_MCP_QUOTA_*`).
  - Escalation and de-escalation in `endTurn`, with the counted-failure rule.
  - `opusScarce`, `modeCalibration`, the no-launch rule, doctor `mode-canary` (§6.4), and the sub-agent gate record (always false on Workspace).
  - Ultra requests are accepted and recorded, then answered "Ultra arrives with the sandbox (5-lite)".
  - **Step 1** runs probes V-3, V-4, V-5, V-8, V-10, V-11, L-2 and L-4 (haiku, `--max-budget-usd ≤ 0.05`). Plan-first compiles only if V-4 passes. Per-mode caps are enabled only once L-4 is pinned.
- **W9, Tasks 15 and 16a (app).** Intensity chip and picker with the "unconfirmed" label; mode chip on running agents; the Budget by-mode breakdown; the Inbox `boost` card; the plan-tier confirmation alert.
- **W10, Global Constraints.**
  - Add the mode table (§2.2), the rung ladder, the Ultra caps (§3.6) and the pro row as `static let`s on `ModePolicy`/`ModeCaps`.
  - "Any argv change updates the snapshots" now covers settings keys, engine env and the hook block.
- **W11, Doctor.**
  - `requiredFlags` gains only `--effort` and `--max-budget-usd` (both in `--help`).
  - Hidden flags (`--max-turns`) are detected through the mode-canary, after V-11 has shown that a bogus `--max-turnz` exits non-zero before answering.
  - `overageStatus == "allowed"` is still a warning, plus the all-mode clamp and the stall-explainer text "deep modes and Ultra are off while extra usage is on".
- **W12, README.** Under Workspace profile limits, add: nested `claude` from agent Bash can load the owner's settings (`fastMode`, `enableWorkflows`) and Keychain auth. Brahma sets env defusers, but an agent can unset them, which is why sub-agents and Ultra wait for the sandbox.

### 6.2 Plan 5-lite patch notes

- **F1, Task 1b.**
  - `ClaudeSettings` typed keys: `enableWorkflows`, `disableWorkflows`, `workflowSizeGuideline`, `workflowKeywordTriggerEnabled`, `maxEffortLevel`, `fastMode`, `plansDirectory`, `availableModels`, plus the `hooks` block for `pre-tool`. `ultracode` is declared but never emitted (test).
  - `BuiltinTools.quick` = sandboxed − Task; `BuiltinTools.plan` = sandboxed − Task − Edit − NotebookEdit; `BuiltinTools.ultra` = sandboxed + Workflow.
  - `allow` gets `Workflow` on Ultra only. `deny` gets `Bash(claude *)`, `Bash(*/claude *)` on all profiles, and the Ultra high-risk MCP and Skill denies.
  - `engineClaudeVars` is shared with W1, including `CLAUDE_CODE_SHELL_PREFIX`.
- **F2, Task 1a (scopes).**
  - Plan-turn scope: the worktree as a read-only dir, `<ws>/.brahma/plans/<KEY>` writable and passed as `--add-dir`.
  - Ultra uses the item-turn scope.
  - No scope's `allowedDomains` may match `anthropic.com` or `claude.ai`.
- **F3, Task 3 (canary).** Keyed by settings shape.
  - Every shape: **V-9**, a nested `claude -p --model haiku --max-budget-usd 0.001 'x'` from agent Bash must fail with a non-zero rc and no `result`. Also `init tools` matches the shape.
  - Ultra shape: the p8/p9 checks plus V-1, V-2, V-8, U-1 and U-3, and the recorded init prefix tokens and `slash_commands`.
  - Sub-agent shape: L-2, V-2, V-3, V-5.
  - Correct the 5-lite text: the barrier is network and exec, not `denyRead` of `~/.claude` (auth is in the Keychain).
- **F4, Task 10 (taint).**
  - `request_mode` goes into `reviewedHighRisk`.
  - The pre-taint rule: every Task/Workflow turn unless its network scope is empty and it has no web tools, until V-1 passes.
  - Backup taint from `parent_tool_use_id` tool_use events, `last_tool_name` and `lastToolName`.
  - The pre-tool hook denies Agent, Task and Workflow when tainted.
  - Tests: `subagentWebFetchTaints`, `subagentBashNetworkPreTaints`, `preTaintUntilHookVerified`, `taintedSessionCannotFanOut`.
- **F5, new Task 14 "Ultra" (after Tasks 1b, 3, 7c, 10).**
  - Ultra compile (§2.3), eligibility on effective values, hard gates (§3.6), fresh `get_usage` admission, reservation and allowance (§3.8), approvals, bg-wait ceiling clamp (wallClock − 5 min), slot accounting (`1 + WORKFLOW_MAX_CONCURRENT_AGENTS`, keep 1 free), agent-count kill, token-cap exclusion, interrupted charging.
  - Live haiku tests U-1…U-9.
  - `brahma settings ultra-share <0–50>` (owner shell); Budget view hookup.
  - The **sub-agent gate** also turns on here for Standard and Deep on the sandboxed profile.
- **F6, Task 7c.** `EmergencyStop` kills an Ultra turn's process group, workflow agents included, records `interrupted` and charges the cap.
- **F7, Task 5 plugins (optional).** Brahma worker agent types (for example `brahma-reader` with `disallowedTools: [WebFetch, WebSearch, Agent]`). PluginLibrary refuses agent frontmatter beyond `name, description, tools, disallowedTools`. `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS=1` only after verifying that plugin agents load under `--restricted`. This is what lifts the "Task without web or web without Task" rule.
- **F8, Task 8 (digest).** The Ultra line and spend by mode.
- **F9, doctor.** The Ultra stall explainer: overage on, plan tier unconfirmed, uncalibrated, probe gate failing, slots.
- **F10, `--disable-slash-commands`.** Keep it on every profile. 5-lite currently drops it; restore it, or replace it with `Skill(deep-research)`/`Skill(ultrareview)` deny rules on every profile.
- **F11, Ultra prompt surface.** With `disableBundledSkills:true` the Workflow tool description inlines the authoring reference. U-1 records its size, which feeds `est(R5)`.

### 6.3 Later plans and spec edits

**Later plans:**
- **3b:** the trust ladder sets `maxRung` and request rights (T0 ≤ R1, no sub-agents, no requests; T2 +1 `maxRung`; T3 may get Ultra-small by policy under `everything`). Sprint capacity uses `modeCalibration`. Performance facts by rung. `--advisor` re-evaluated.
- **Dogfood week:** calibrate rung costs, Ultra caps, tier budgets at current prices, first-pass rate by rung, and the share of escalations that pass.
- **Memory-lite:** memory tools classified for taint; sub-agent retrieval inherits taint.
- **L:** launch-critical items are P0 on the critical path, so they can be Ultra-eligible once confirmed. Deploy steps are always run by the engine, never inside a turn.
- **Plan 11:** fast mode only behind an explicit owner "pay for speed" policy (a reserved money matter). Ultrareview only as an owner-run pre-release step.
- **Future, labelled:** "Ultra (standing)" via `ultracode:true`, after U-9; Ultra-large; Opus workers; `--task-budget`; `--thinking-display summarized` for audit transcripts.

**Spec v2 edits:**
- §4.3.4: add "and work mode (§4.3.6)".
- New §4.3.6 Work modes: this document, condensed.
- §4.2.2: usage mode bounds intensity; add the pro row; the critical path never enters the reserve.
- §4.2.4: cost recorded by mode; the Ultra allowance; the no-overage clamp covers all modes.
- §4.7.1: ask kind `boost`.
- §1.3: Intensity is a Work field and the Ultra allowance lives under Budget (Advanced).
- §4.3.5: per-turn guardrails become the per-mode `--max-turns`, `--max-budget-usd` and wall clock.
- §4.6: spec fields count for intensity only once confirmed by a manager or the owner.

### 6.4 Doctor `mode-canary` (zero inference)

For each mode's compiled profile, run in a temp dir:

```
claude -p --input-format stream-json --output-format stream-json … <mode argv>
```

then send `{"type":"control_request","request_id":"m1","request":{"subtype":"get_settings"}}`. Read the `initialize` response and assert:

- `applied.model` = the expected id, and `applied.effort` = the mode's effort. Covers each cap value emitted: low, medium, high.
- `applied.ultracode == false` in every mode.
- The init `tools` contains `Workflow` **only** for the Ultra shape, and `Task` only when the sub-agent gate is on. `ultracodeAvailable` alone is not enough.
- The init `agents` list = the expected set.
- `fast_mode_state == "off"`, and `applied.advisor` is null.

It also sends `get_usage` (`skip_behaviors:true`). If `subscription_type` disagrees with `planTier`, the engine moves to the lower tier and raises an `engineAlert`.

Re-run per CLI version (24 h reuse, as in 3a). It is free. The live gates (L-*, V-*, U-*) are recorded per CLI version alongside it.

---

## 7. Tests that prove the policy

**ModePolicyTests (pure table):**
- `noticeIsQuickHaikuLow`
- `itemlessIsQuickSonnetLow`
- `tierSStandard`
- `tierMRiskOrP0IsDeep`
- `tierLConfirmedIsOpusMediumPlanFirst`
- `agentAuthoredTierLNotOpusUntilConfirmed`
- `selfLinkedDependentsDontCountForBlocking`
- `prdArchitectureR3NoPlanFirst`
- `reviewNeverHasTaskOrWorkflow`
- `twoCountedFailuresEscalateOneRung`
- `identicalResubmitDoesNotEscalate`
- `flakyInconclusiveInfraNeverEscalate`
- `noProgressDoesNotEscalate`
- `rungFloorSurvivesReclaim`
- `mergeResetsFloor`
- `p2OnlyFixLowersEffortNotModel`
- `sessionModelFixedEffortVaries`
- `cacheBreakInEstimate`
- `escalationHeldByBudget`
- `belowQuickEstimateNotLaunched`
- `lowUsageModeCapsR2AndOpusLow`
- `maxUsageModeBoostsP0`
- `paceAheadClampsEffortAndNoUltra`
- `paceClosedCapsR1IgnoresFloor`
- `overageAllowedClampsAllModes`
- `proTierClamps`
- `fiveHourHighRemovesTask`
- `opusScarceFallsToSonnetHigh`
- `xhighMaxNeverAutomatic`
- `subagentGateOffMeansNoTask`
- `trustT0CapsR1`
- `reasonsRecorded`

**UltraGateTests:**
- `ultraNeedsConfirmedEligibility`
- `ultraRefusedOnWorkspaceProfile`
- `ultraRefusedUntilU3AndV1V2V8V9Pass`
- `ultraRefusedWhenOverageAllowed`
- `ultraRefusedOnUnconfirmedPlanTier`
- `ultraRefusedUncalibrated`
- `ultraMustFitPace`
- `ultraFiveHourGateUsesFreshUsageAndReservations`
- `ultraAllowanceAndReservation`
- `ultraDailyCap`
- `ultraGlobalConcurrency`
- `ultraSlotsLeaveOneFree`
- `ultraSmallPolicyOnlyForEndorsedUnescalated`
- `ultraFullAsksOwnerUnderImportant`
- `failurePathUltraAlwaysAsksOwner`
- `ownerIntensityUltraIsOneRun`
- `ultraExtendsItemBudgetOnce`
- `ultraDoesNotTripTokenBudget`
- `ultraNotReservedMatter`
- `taintedSessionNoUltra`

**TurnProfileTests (snapshots per mode):**
- `quickHasNoTaskAndWorkflowKillSwitches`
- `workspaceDisallowsTask`
- `standardForcesHaikuWorkersDepth1`
- `deepForcesSonnetWorkers`
- `ultraHasThreeWorkflowLocks`
- `ultraHasSubagentCaps`
- `ultraDeniesHighRiskMcpAndSkills`
- `nonUltraNeverEnablesWorkflows`
- `everyModeHasExplicitModelEffortTurnsBudgetWallClock`
- `fastModeOffEverywhere`
- `availableModelsEverywhere`
- `preToolHookEverywhere`
- `modelAllowlistRejectsFableBestDefaultOpusplan1m`
- `ownerPinStillAllowlisted`
- `planTurnHasPlanModePlansDirectoryNoEditNoTask`
- `keywordTriggerOff`
- `ultracodeNeverEmitted`
- `engineClaudeVarsOnlyFromCompiler`
- `spawnedEnvContainsEmittedVars`
- `promptTextCannotChangeArgv`
- `worktreeFilesCannotAddAgentTypes`
- `ultraDigestNamesActualApprover`
- `bgCeilingBelowWallClock`

**PreToolHookTests:**
- `deniesRemoteIsolation`
- `deniesBackgroundAgent`
- `deniesUnknownSubagentType`
- `deniesNamedWorkflowAndScriptPath`
- `deniesForeignResumeRun`
- `deniesFanOutWhenTainted`
- `deniesWorkflowOffUltra`

**RequestModeTests:**
- `nextTurnOnly`
- `assigneeRequestCappedAtR2`
- `rateLimitedAndCooldown`
- `highRiskUnderTaint`
- `managerIntensityCappedThorough`
- `assigneeCannotSetIntensity`
- `schemasCannotSetIntensityOrFloor`

**StreamParser / TurnRunner tests:**
- `lastResultWins`
- `secondInitAccepted`
- `killedWithPendingWorkflowIsInterruptedDespiteEarlyResult`
- `deepTurnNotKilledAt15Min`
- `maxTurnsIsControlledStop`
- `maxBudgetIsControlledStop`
- `budgetCappedTurnsCountTowardItemBudget`
- `sigtermWithoutResultInterrupted`
- `workflowProgressParsed`
- `agentCountKill`
- `unexpectedModelInModelUsageAlerts`
- `safetyFallbackModelRecordedOnly`
- `effortCapWarningRecorded`
- `initAgentsMismatchAborts`
- `planTurnWriteIsReverted`

**Budget / Pacing tests:**
- `costByModeRecorded`
- `ultraCountsInWeeklyPace`
- `reservationReleasedToActual`
- `interruptedUltraChargesFullCap`
- `fiveHourCalibration`
- `calibrationIgnoresSubPointDeltas`
- `criticalPathNeverEntersReserve`
- `planTierMismatchClampsToDetected`
- `reviewSpendCapDropsToStandard`

**MCP quota tests:**
- `perTurnQuotaByMode`
- `subagentCallsShareParentQuota`
- `subagentHighRiskCallsQuotaOne`

**DoctorTests (faked control responses):**
- `modeCanaryAppliedEffortMatchesEachCap`
- `workflowInInitToolsOnlyForUltraShape`
- `ultracodeFalseEverywhere`
- `fastModeOnFails`
- `hiddenFlagUnknownFails`
- `planTierMismatchWarnsAndClamps`

**Live probes (`BRAHMA_LIVE=1`, haiku, tiny prompts, `--max-budget-usd ≤ 0.05`):**
- L-1 `liveQuickInitLacksTask`
- L-2 `liveSubagentCostIncludedAndCapStops`
- L-3 `livePlanTurnWritesInsidePlansDirectory`
- L-4 `liveMaxBudgetOnResume` (fresh turn, then `--resume`; records per-process vs cumulative)

**5-lite live (Ultra):**
- U-1 `liveUltraSmallTwoAgentWorkflowLastResult` (exact Ultra argv with acceptEdits; records prefix tokens and slash_commands; policy-wording opt-in works)
- U-2 `liveUltraWorkersForcedModelAndNoNestedAgent`
- U-3 `liveBudgetCapStopsWorkflowAndCostIncludesAgents`
- U-4 `liveSubagentWebFetchTaints` (V-1)
- U-5 `liveRemoteIsolationRefused` (V-2)
- U-6 `liveBgCeilingStops`
- U-7 `emergencyStopKillsWorkflowAgents`
- U-8 `ultraRSSMeasured`
- U-9 `ultracodeCapsStillHold`
- U-10 `liveNamedWorkflowRefused`

**App model tests:**
- `budgetByModePresentation`
- `boostAskCard`
- `itemIntensityChip`
- `unconfirmedSpecLabel`
- `modeChipOnRunningAgent`
- `planTierAlert`

---

## 8. Probe gates, and owner questions

| # | Unverified | Gates | Probe |
|---|---|---|---|
| V-1 | PostToolUse hook fires for sub-agent and workflow-agent tool calls | dropping pre-taint; Ultra | haiku sub-agent WebFetch; hook writes a flag file |
| V-2 | `Agent` `isolation:"remote"` refused under `--strict-mcp-config --restricted` | sub-agent gate; Ultra | one Agent call with isolation remote (with and without the hook) |
| V-3 | `--disallowed-tools Task` removes Task from init tools (workspace) | Quick; "Task off" on Workspace | init `tools` |
| V-4 | Plan mode under the real argv: plan written to an absolute `plansDirectory` inside `--add-dir`; one `mcp__company` read and one post callable; a `--resume` acceptEdits turn creates a file | Plan-first | two-turn haiku probe, workspace and sandboxed argv |
| V-5 | FORCE pins `Agent({model:"opus"})`, Explore and workflow `agent({model})`; SPAWN_DEPTH=1 blocks depth 2; `maxEffortLevel` clamps sub-agent `effort:"max"`; `availableModels` limits workers | sub-agent gate; Ultra | one haiku probe; assert the `modelUsage` keys are only `claude-haiku-5-5`, no `spawn_depth` 2, thinking tokens within the band |
| V-6 | Plan is Max 5x or Pro (`subscriptionType:"pro"` observed) | Ultra; caps; the plan-tier row | owner confirms; doctor `get_usage` |
| V-7 | `--max-budget-usd`/`total_cost_usd` include workflow agents | **all Ultra** | U-3 |
| V-8 | `PreToolUse` hook from `--settings` fires under `--setting-sources ""`, including for sub-agent calls | sub-agent gate; Ultra | Agent call with isolation remote; the hook denies it |
| V-9 | Nested `claude` from sandboxed Bash fails | Ultra; sandboxed sub-agent gate | canary step (F3) |
| V-10 | `ultrathink` in quoted digest text changes thinking | quoting rule | haiku pair with and without it, comparing thinking tokens |
| V-11 | Unknown hidden flag → exit before answering `get_settings` | hidden-flag detection | `--max-turnz` probe |
| L-2 | Sub-agent cost included in `total_cost_usd`; cap stops a turn waiting on a sub-agent | sub-agent gate | live |
| L-4 | `--max-budget-usd` and `total_cost_usd` semantics on `--resume` | all per-mode caps; W7 cost rule | live |

**Questions for the owner:**
- **Q-M1.** The CLI reports a **Pro** subscription (`claude auth status` and `get_usage`), not Max 5x. Which is right? Until you confirm, Brahma uses the Pro row: concurrency 1/1/2, at most sonnet high (Opus-required turns at opus low), no sub-agents, no Ultra.
- **Q-M2.** Defaults: Ultra allowance 15% of the weekly share; Ultra-small $4 LE by policy only for manager-endorsed, non-escalated items; full Ultra $15 LE by owner ask under "Important only"; failure-driven Ultra always asks you. Keep these?
- **Q-M3.** On Max 5x, Ultra needs the **Max** usage mode, because it takes 3 slots and Balanced has 3. Acceptable, or should Ultra-small run in Balanced with 1 workflow agent?
- **Q-M4.** Brahma's "Ultra" is Claude's workflow engine under Brahma's caps, not Claude's standing "ultracode" setting. OK for v1?
- **Q-M5.** In 3a (before the sandbox), sub-agents are turned **off**. Today they are on with no model pin, so built-in Explore runs on Opus. Agents still get the effort and model ladder. OK?

Leftovers from the research probes (all deletable):
- `/Users/chandra/.claude/plans/create-a-file-named-hashed-bachman.md`
- `/Users/chandra/.claude/projects/-Users-chandra--claude-jobs-6d89b87c-tmp-modes-probe-opus-work/`
- `/Users/chandra/.claude/jobs/6d89b87c/tmp/modes-probe-*/`

---

## 9. Review dispositions

**High fixes, all adopted:**

| Review finding | Disposition |
|---|---|
| Cost H1 / Safety H3: Ultra-small cap unverified, agent count advisory | U-3 gates every Ultra variant (gate 1, V-7 row); agent-count kill (§3.8) |
| Cost H2 / Safety M: no-overage only for Ultra | all-mode overage clamp (§3.2 step 5, W2) |
| Cost H3: Pro vs Max 5x | `planTierEffective` = lower tier; pro row (§3.7) |
| Cost H4: closed pace plus critical path drains the reserve | closed → min(base, R1), floor ignored, Task and Plan-first off; exemption ends at the reserve (W2) |
| Safety H1: self-escalation through authored spec fields | `specConfirmedBy`; effective values (§3.1, W3) |
| Safety H2: `isolation:"remote"` unverified on shipped turns | Task off on Workspace; pre-tool hook; V-2 and V-8 in the sub-agent gate |
| Safety H4: nested `claude` escapes controls | env defusers on all profiles; V-9 canary; Keychain correction; Workspace residual documented; Task and Ultra off there |
| Feasibility H1: killed Ultra booked as success | pending-background tracking → `interrupted` (§4.5) |
| Feasibility H2: 900 s runner constant | `profile.wallClock` in `run(request:)` |
| Feasibility H3: pre-taint misses Bash network | pre-taint every fan-out turn unless network scope is empty and there are no web tools |

**Medium fixes adopted:**
- fresh `get_usage` plus reservations in the 5-hour check;
- Ultra sub-agent env caps;
- slot accounting that leaves one slot free;
- windowed p80 calibration;
- token-cap exclusion for Ultra;
- L-2 gating Task;
- high-risk MCP quota and deny;
- plan-turn write barrier (clean-worktree check, no Edit/Task);
- custom agent frontmatter restriction plus the init `agents` assertion;
- inline-only workflows;
- taint denies fan-out;
- counted-failure rule;
- spawned-env test plus `availableModels`;
- V-5 extended;
- the `maxEffortLevel` sub-agent clamp moved to unverified;
- V-4 expanded;
- L-4 on resume;
- canary checks `tools`, not `ultracodeAvailable`;
- nested-claude canary;
- controlled stops before the classifier.

**Low fixes adopted:**
- cacheBreak cost and session-model rule;
- review spend cap;
- failure-path Ultra asks the owner;
- no-launch rule;
- assignee requests capped at R2;
- approver-accurate digest;
- safety-fallback IDs recorded only;
- `ultrathink` probe;
- `requiredFlags` limited to visible flags;
- `CLAUDE_CODE_SHELL_PREFIX` in `engineClaudeVars`;
- `ModelPolicy` replaced, with new TurnKinds;
- Ultra prompt surface and Skill denies;
- `--disable-slash-commands` kept (F10).

**One correction to a review.** The feasibility review said 3a has no turn token. It does: `ClaudeCommand.tokenVariable = "BRAHMA_TURN_TOKEN"`, passed in the mcp-config env. Quotas use the in-process counters keyed by that token.
