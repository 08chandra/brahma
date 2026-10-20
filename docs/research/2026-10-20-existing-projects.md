# Research A: Multi-agent "AI company" and Claude Code orchestration projects

Date of research: 2026-10-20. Method: WebSearch and WebFetch. Primary sources (vendor docs, papers, READMEs) were fetched where possible. Where only secondary summaries were available, this is flagged with "(secondary)". Star counts and vendor benchmark numbers are unverified unless stated.

---

## 1. Per-project findings

### 1.1 Anthropic first-party material (highest signal for us)

**A. Multi-agent research system** — https://www.anthropic.com/engineering/multi-agent-research-system
- Orchestrator-worker. The lead agent spawns 3-5 subagents in parallel, and each subagent runs 3+ tools in parallel. Anthropic reports up to 90% less research time on complex queries.
- Mechanisms worth copying:
  - **Full task briefs.** Each subagent gets an objective, an output format, tool/source guidance and task boundaries. Vague briefs caused duplicated searches and gaps.
  - **Effort scaling written into the prompt.** Simple fact-finding gets 1 agent and 3-10 tool calls. Comparisons get 2-4 subagents. Complex research gets 10+.
  - **Plan persisted to external memory.** Context beyond 200k tokens is truncated, so agents summarize finished phases and can hand off to fresh subagents.
  - **Artifact references instead of copies.** Subagents write outputs to external storage and return lightweight references. This avoids the "telephone game" loss and saves tokens.
  - **A tool-testing agent rewrote flawed MCP tool descriptions.** This cut task completion time by 40%.
  - **Eval method.** About 20 real queries, an LLM-judge rubric (accuracy, citations, completeness, source quality, tool efficiency), and end-state evaluation for stateful tasks.
  - **Production reliability.** Resume from the point of failure, checkpoints, and "rainbow deployments" so long-running agents are not killed by a deploy.
- Weaknesses documented by Anthropic:
  - Early failures: 50 subagents spawned for simple queries, endless searching, agents distracting each other with updates, duplicated work.
  - The lead is synchronous: it cannot steer a subagent mid-run, and one slow subagent blocks the batch.
  - Cost: about 4x the tokens of chat for a single agent, about 15x for multi-agent. Token usage explained about 80% of BrowseComp performance variance.
  - Anthropic says multi-agent is a poor fit for tightly coupled work, "most coding tasks" included.

**B. Effective harnesses for long-running agents** — https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- An initializer session creates `init.sh`, a progress log and the first commit, and expands the prompt into a 200+ item JSON feature list. Every item starts as `passes: false`.
- Coding sessions may change only the `passes` field. JSON was chosen because models overwrite it less readily than Markdown.
- Each session works on one feature and leaves the repo clean and mergeable. A session starts by reading the git log and progress file, running `init.sh`, and running a smoke end-to-end test.
- Failure modes found: declaring the project done too early, marking features complete after only unit tests or curl checks, and wasting time figuring out how to run the app. Browser automation (Puppeteer MCP) improved verification a lot.
- Open question stated by Anthropic: whether one generalist agent or specialist QA/cleanup agents work better.

**C. 16 parallel agents build a C compiler (Carlini)** — https://www.anthropic.com/engineering/building-c-compiler
- Harness: a `while true` bash loop runs `claude -p` with a fixed prompt file. Each agent runs in its own Docker container. A bare git repo is shared as upstream. Every cycle is a fresh session with no prior context. There is no orchestrator and no messaging beyond git.
- Task claiming: an agent writes a lock file in `current_tasks/<name>.txt`. Git sync makes a duplicate claim fail. When done, the agent pulls, merges, pushes and deletes the lock. Merge conflicts were frequent and Claude resolved them itself.
- Test and verifier design (very relevant to us):
  - The verifier must be near-perfect or agents solve the wrong problem.
  - Test output is kept short, with details written to log files and `ERROR` tagged on a single line.
  - A `--fast` deterministic sample guards against "time blindness".
  - CI was added late because agents kept breaking existing features.
  - Agents maintain READMEs and progress files for orientation.
- Parallelism lesson: when all agents hit the same monolithic failure (the Linux kernel build), they overwrote each other. A GCC oracle that split the work per file fixed it.
- Specialist roles that emerged: dedup, performance, codegen quality, design critic, docs.
- Scale and cost: about 2,000 sessions, about 2B input and 140M output tokens, just under $20k, about 100k lines of Rust.
- Weaknesses: frequent regressions, hours burned on tests with no progress, `pkill -9 bash` killed its own loop, code quality below expert level, and some pieces (16-bit boot, assembler, linker) still needed GCC.

**D. Claude Code Agent Teams (official, experimental)** — https://code.claude.com/docs/en/agent-teams
- Architecture: team lead, teammates (each a full Claude Code session), a shared task list, and a mailbox.
  - Mailbox: one JSON file per agent at `~/.claude/teams/{team}/inboxes/{agent}.json`, validated on read. A message counts as sent only when the file write succeeds.
  - Tasks live in `~/.claude/tasks/{team}/`. States are pending, in progress and completed, with dependencies that auto-unblock. Claiming uses file locking.
- Quality gates are hooks: `TeammateIdle`, `TaskCreated` and `TaskCompleted`. Exit code 2 blocks the action and sends feedback to the agent.
- Plan-approval mode: teammates plan read-only first. Note that the lead auto-approves the plan without review.
- Messages between agents are marked as coming from another agent, not the user. In auto mode a classifier reviews inter-agent messages, so agents cannot launder approvals.
- Practical guidance from the docs: 3-5 teammates, 5-6 tasks per teammate, one file owner per teammate, and start with research and review tasks.
- Documented limitations:
  - No resume for in-process teammates.
  - Task status lags because teammates forget to mark tasks complete.
  - The lead sometimes starts doing the work itself or declares the team finished early.
  - One team per session, no nested teams, and the lead is fixed.
  - Teammates cannot be spawned from `-p` headless mode. Our `claude -p --resume` model therefore cannot use this feature directly and must reimplement the mailbox and task list.

**E. Anthropic related:** Claude Code subagents and worktrees docs are linked from the Agent Teams page (https://code.claude.com/docs/en/agent-teams).

### 1.2 ChatDev (OpenBMB) — https://github.com/OpenBMB/ChatDev
- 1.0 (2023): a "virtual software company" of CEO, CTO and programmer roles in a chat chain with seminar phases (design, code, test, docs).
- Experiential Co-Learning (announced Dec 2023, merged Jan 2024): instructor and assistant agents harvest "shortcut" experiences from past trajectories and reuse them. See arXiv 2312.17025 (cited from https://arxiv.org/html/2407.07061; the paper itself was not fetched).
- MacNet (June 2024, ICLR 2025): DAG topologies ordered by topological sort, claimed to scale past 1,000 agents, with irregular topologies outperforming regular ones and a logistic-growth "collaborative scaling law". https://arxiv.org/abs/2406.07155 (secondary summary via search).
- ChatDev 2.0 "DevAll" (Jan 7, 2026): a zero-code platform with YAML workflows, a visual canvas, a Python SDK and a web console. Examples include data viz, 3D, games and research.
- Weaknesses: the README lists no limitations. MAST (below) found ChatDev's failures were dominated by system-design and verification issues. Small prompt fixes (role spec, CEO final say) bought only about +9.4% success. The project's own 1.0 branch is now in maintenance mode.
- Worth copying: experience distillation (shortcut library), the "CEO final say" tie-break, and seminar-style cross-role review phases.

### 1.3 MetaGPT / MGX — https://arxiv.org/abs/2308.00352 (HTML: https://arxiv.org/html/2308.00352)
- SOPs encoded into prompt sequences. An assembly line of PM, Architect, Project Manager and Engineer.
- Agents "communicate through documents and diagrams (structured outputs) rather than dialogue". The PM writes a PRD, the Architect writes file lists, data structures, interfaces and sequence diagrams, and the Project Manager writes a task list with one task per code file.
- A global message pool with publish/subscribe means agents read only what they subscribe to, and an agent acts only once all prerequisite artifacts exist.
- Executable feedback: write unit tests, run them, debug, up to 3 retries. This gave about +4.2% on HumanEval and +5.4% on MBPP.
- Weaknesses (paper): no UI/front-end capability, weak with small models, self-improvement only edits role constraints. MAST found MetaGPT had 1.56x more verification failures than ChatDev despite 60-68% fewer spec and alignment failures (https://arxiv.org/html/2503.13657v3).
- MGX and Data Interpreter were not researched in depth. Only the original MetaGPT paper was fetched.

### 1.4 AutoGen / AG2 / Magentic-One — https://microsoft.github.io/autogen/0.7.3/user-guide/agentchat-user-guide/magentic-one.html
- Magentic-One uses an orchestrator with an outer loop (a Task Ledger of facts, guesses and plan) and an inner loop (a Progress Ledger checked each step). When progress stalls, the orchestrator re-plans. Workers are WebSurfer, FileSurfer, Coder and ComputerTerminal.
- Worth copying: the two-ledger design, plus stall-triggered replanning.
- Weaknesses: conversation-driven design is flexible but hard to constrain (secondary: https://pickaxe.co/post/crewai-vs-langgraph-vs-autogen). No authoritative failure data was found.

### 1.5 CrewAI, LangGraph, OpenAI Agents SDK/Swarm
- CrewAI offers sequential and hierarchical (manager-agent) processes. Secondary, weakly sourced: one blog benchmark reports about 17.4k tokens per hierarchical run vs 4.5k for LangGraph, attributed to the manager's routing calls (https://businesstechnavigator.com/blog/langgraph-vs-crewai-vs-autogen-production-2026). Error handling is called coarse.
- LangGraph: explicit state graph plus checkpointing. One practitioner reported the checkpoint DB growing to 2.4 GB in 6 weeks at 800 runs per day. Learning curve is steep (same secondary source family: https://fme.safe.com/guides/ai-agent-architecture/langgraph-alternatives/).
- OpenAI Agents SDK: successor to Swarm. Primitives are agents, handoffs, guardrails, sessions and built-in tracing (OpenTelemetry export). Details are from secondary pages: https://www.respan.ai/articles/openai-agents-sdk-vs-swarm.
- Worth copying: handoff as a first-class typed event, input/output guardrails as separate cheap checks, and trace spans per turn.

### 1.6 CAMEL / OWL / Eigent — https://docs.camel-ai.org/key_modules/workforce.md
- Workforce: a coordinator agent assigns subtasks (with dependencies) to workers, and a task-planner agent decomposes tasks. Workers are single agents or role-playing pairs, with an optional shared memory.
- On failure, a `RecoveryDecision` selects Retry, Replan or Decompose. There is a per-task timeout and lifecycle callbacks.
- OWL (built on CAMEL) reports a GAIA score, but sources conflict (58.18 vs 69.09). Eigent is the commercial product (https://www.camel-ai.org/techstack).
- Worth copying: the explicit three-way failure policy (retry, replan, decompose).

### 1.7 Gas Town (Steve Yegge) — https://github.com/steveyegge/gastown
- Roles (README): Mayor (coordinator), Crew (human's clone), Polecats (workers with persistent identity but ephemeral sessions), Witness (per-rig lifecycle watchdog), Deacon (cross-rig patrol), Dogs (maintenance helpers) and Refinery (merge queue).
- Beads: git-backed issues with prefix-plus-5-character IDs. Convoys bundle beads. Hooks are worktree-based persistent storage, and a "GUPP violation" means hooked work with no progress for a long time.
- Merge queue: the Refinery batches polecat work and runs gates in a Bors-style bisecting queue. Polecats never push to main. A `scheduler.max_polecats` cap governs rate limits.
- Mailboxes provide inter-agent messaging, and `gt feed --problems` surfaces stalled or zombie agents.
- Weaknesses:
  - A first-week user report (https://lakshminp.substack.com/p/6-ai-agents-coding-experiment): six sessions overloaded an M2 MacBook, orphaned daemons accumulated, and about two weeks were spent debugging the orchestrator.
  - The report cites unverified claims of about $100/hour burn.
  - A DoltHub field test reportedly found none of the PRs mergeable (as reported by the same blog).
  - Ten concepts caused cognitive load, and human dispatch remained the bottleneck.
  - The author's lesson: use fewer concepts (hub, worker, task) and expect 2-3 concurrent workers on a laptop.
- Gas City is described as a rewrite of Gas Town as an SDK (https://gascity.com/about/, secondary).

### 1.8 Claude Flow / Ruflo — https://github.com/ruvnet/ruflo
- Queen-led hierarchical swarm, 100+ agent definitions, vector memory (AgentDB/HNSW), learned routing, a federation layer with mTLS and trust scores.
- Caveats from its own README: topology and consensus (Raft, Byzantine, Gossip) appear only in a table with no explanation. Demos use sample data. "Creating a mission does not mean the feature has been implemented." Counts are inconsistent. The 84.8% SWE-bench and 75% savings figures are promotional with no independent evaluation (secondary: https://codex.danielvaughan.com/2026/04/09/claude-multi-agent-ecosystem/).
- Takeaway: treat as a cautionary example of breadth over verified outcomes. Mods run unsandboxed.

### 1.9 Claude Squad — https://github.com/smtg-ai/claude-squad
- TUI that gives each agent a tmux session plus a git worktree. Autoyes mode is experimental. A common failure is "timed out waiting for tmux session".
- Little of interest for orchestration. It is a session multiplexer, not a coordinator.

### 1.10 ccpm (automazeio) — https://github.com/automazeio/ccpm (via search summaries)
- Flow: PRD, then Epic, then GitHub Issues, then parallel agents in worktrees, then shipped code. GitHub Issues serve as the database and `.claude/prds` and `.claude/epics` hold local files. Five phases: brainstorm, document, plan, execute, track.
- Worth copying: spec-first decomposition (PRD to epic to tasks), with traceability from each task to a spec. Source is a secondary summary: https://feedbagel.com/post/ccpm-github-based-project-management-system-for-parallel-claude-code-execution.

### 1.11 Mission Control (builderz-labs) and Deck — https://www.mintlify.com/builderz-labs/mission-control
- Self-hosted Kanban board with quality-review gates, live activity feed, SQLite (WAL), and automatic discovery of local Claude Code sessions from `~/.claude/projects/` with token and cost extraction from the JSONL transcripts. Describes itself as alpha. `dested/deck` is a read-only localhost viewer of Claude Code sessions.
- Worth copying: reading cost and usage straight from Claude Code JSONL transcripts.

### 1.12 Conductor, Vibe Kanban, Sculptor
- Conductor: one workspace equals one branch, one worktree and one review path, with setup scripts, diff review and a "Spotlight" mode for apps that need fixed ports (https://conductor.build/compare/claude-code).
- Vibe Kanban: Kanban board that dispatches agents into worktrees. The original company shut down on April 10, 2026 and the repo is community-maintained (secondary: https://aiidelist.com/ide/vibe-kanban). This is a business-continuity warning for the "kanban for agents" category.
- Sculptor (Imbue): one Docker container per Claude Code agent (no worktrees), "Pairing Mode" that syncs agent container state to the local IDE, and a Merge Review UI (vendor claims: https://imbue.com/sculptor, https://docs.imbue.com/features/containers).
- Worth copying: per-agent containers for strong isolation (also gives us a path to the Linux server), and a dedicated merge-review surface.

### 1.13 OpenHands (All-Hands) — https://arxiv.org/html/2511.03690v1, https://docs.openhands.dev/sdk/arch/overview
- Software Agent SDK: immutable agents, tools and LLM configs, with a single mutable ConversationState and an event log that supports replay and recovery. Optional Docker sandbox with the same agent code. Condensers summarize history while the full log is retained, with a claimed up to 2x cost reduction (self-reported, secondary).
- Worth copying: event-sourced agent state, so any turn is replayable and a crashed agent resumes from its log.
- Delegation and stuck-detection details were not found in my sources.

### 1.14 Devin / Cognition — https://cognition.com/blog/multi-agents-working and the original "Don't Build Multi-Agents" (https://jxnl.co/writing/2025/09/11/why-cognition-does-not-use-multi-agent-systems/, secondary)
- 2025 position: share full traces, not summaries, because actions carry implicit decisions and parallel writers produce conflicting ones.
- April 2026 follow-up. Patterns that work:
  - **Single-threaded writes with parallel intelligence.**
  - **A clean-context reviewer** that sees only the diff. Devin Review reportedly catches about 2 bugs per PR, about 58% severe.
  - A "communication bridge" in which the coder filters review findings against the user's instructions to avoid endless review loops.
  - **A smart-friend escalation**, where a cheaper model calls a stronger one with a fork of its full context.
  - Capability routing across frontier models.
  - Manager/child "map-reduce-and-manage".
- Failure modes listed: conflicting implicit decisions, overly prescriptive managers, children assuming shared state, children not reporting discoveries upward, context rot, costly review loops, and demos with simple success criteria.

### 1.15 Cursor (background/cloud agents and "scaling agents") — https://cursor.com/blog/scaling-agents
- Experiment with hundreds of concurrent agents for weeks.
  - Flat self-coordination through a shared file with locks failed: 20 agents ran at the throughput of 2-3. Optimistic concurrency was simpler but agents became risk-averse and avoided hard tasks.
  - What worked: root planner, sub-planners and workers, with a judge at the end of each cycle. An integrator role for conflicts was removed because it was a bottleneck, and workers resolve their own conflicts.
  - Prompts mattered more than harness or model. Different models per role helped (GPT-5.2 for planning and long autonomy, Opus 4.5 tended to stop early and take shortcuts, per Cursor).
  - Open problems: planners need wake-on-completion, runaway agents, and periodic fresh starts to counter drift.
- Cloud agents run in isolated VMs. Cost is usage-based and review is a human bottleneck (secondary: https://www.morphllm.com/cursor-background-agents).

### 1.16 Factory (Droids / Missions) — https://docs.factory.com/missions/overview, https://factory.ai/news/missions
- Orchestrator, worker and validator roles, with configurable model per role. Plan is features grouped into milestones (1-500 features per mission), with a fresh worker session per feature. Each milestone ends with a validation pass (user-facing QA, regression checks), and the orchestrator adds fix tasks when it fails.
- Docs recommend an automatable app ("Agent Readiness Level 4+"). A third-party summary reports missions up to 16 days (https://www.zenml.io/llmops-database/multi-agent-software-development-system-with-extended-autonomous-execution).
- Honest limits stated by Factory: not fire-and-forget (pause and redirect when stuck), errors accumulate in long plans, and it is unproven whether parallel beats sequential.

### 1.17 GitHub Copilot coding agent / Agent HQ — https://visualstudiomagazine.com/Articles/2025/10/28/GitHub-Introduces-Agent-HQ-to-Orchestrate-Any-Agent-Any-Way-You-Work.aspx (Oct 2025)
- "Mission Control" to assign, steer and track agents from many vendors across GitHub, VS Code, mobile and CLI. Agents commit only to designated branches in sandboxed Actions environments. Planned: agent identity and policy management, and a Plan mode that asks clarifying questions.
- Worth copying: agent-as-coworker identity and policy, branch-restricted commit rights, and a plan-first step. I did not find Copilot coding agent's documented weaknesses in this pass.

### 1.18 Benchmarks and "AI company" simulators
- **TheAgentCompany** (CMU): self-hosted fake software company (GitLab, OwnCloud, Plane, RocketChat) with simulated colleagues and 175 tasks. Best agent about 30% (24% in v1). https://arxiv.org/abs/2412.14161. Secondary summaries report failure types such as misreading instructions, UI navigation errors, and deceptive shortcuts like renaming a user to bypass a constraint (https://eastgate-software.com/ai-agent-adoption-stumbles-benchmarks-reveal-only-30-task-success-rate-in-office-use). Relevant to us: an honest ceiling on what an unsupervised "company" achieves today.
- **ai-simulated-startup** (CEO, CTO, marketer agents in Slack-style channels): https://github.com/simerusm/ai-simulated-startup. Small hobby scale. I did not assess its quality.
- **YC-Bench**: an LLM acts as CEO of a simulated startup for a year (partial observability, discrete-event simulation) (secondary: https://www.emergentmind.com/topics/yc-bench). A possible regression benchmark for the Steward.
- **MAST** ("Why Do Multi-Agent LLM Systems Fail?", NeurIPS 2025): https://arxiv.org/html/2503.13657v3. 14 failure modes in 3 groups, from 1,600+ traces:
  - FC1 System design (44.2%): disobey task spec 11.8%, step repetition 15.7%, unaware of termination 12.4%, lost history 2.8%, disobey role 1.5%.
  - FC2 Inter-agent misalignment (32.4%): reasoning-action mismatch 13.2%, task derailment 7.4%, fail to ask for clarification 6.8%, conversation reset 2.2%, ignored input 1.9%, info withholding 0.85%.
  - FC3 Verification (23.5%): incorrect verification 9.1%, no/incomplete verification 8.2%, premature termination 6.2%.
  - Many verifiers only check superficially (code compiles, no TODOs). A high-level objective verification step gave +15.6% on ProgramDev. The paper recommends multi-level verification.

---

## 2. Cross-cutting patterns that work

1. **Files and git as the shared substrate, not chat.** Carlini's agents coordinate only through git, lock files and progress notes. Anthropic's long-running harness uses a JSON feature list and progress file. Claude Code Agent Teams uses JSON mailboxes and a task directory. MetaGPT uses structured documents. Gas Town uses git-backed beads. (Sources in section 1.)
2. **Fresh context per unit of work, with a written handoff.** Carlini, Factory (fresh worker per feature), Cursor (fresh starts against drift), Anthropic harness (read git log and progress first). Matches our `claude -p --resume` turn model, which should treat resume as a cache and files as truth.
3. **Hierarchy beats flat self-organization at scale.** Cursor found flat locking failed. Planner, worker and judge worked. Factory uses orchestrator, worker and validator. Anthropic uses lead plus subagents. But keep layers few: Cursor dropped its integrator role.
4. **Single-writer per file or area, with parallel readers.** Agent Teams docs advise one file owner per teammate. Cognition recommends single-threaded writes. Carlini's kernel failure shows what happens when many agents share one target.
5. **Verifier quality is the main lever.** Carlini ("test quality matters most"), Anthropic harness (end-to-end browser tests), Factory milestone validation, MAST (verification is 23.5% of failures), and Cognition's clean-context reviewer.
6. **Independent reviewer with clean context seeing only the diff plus the spec.** Cognition, Carlini's critic agent, and Agent Teams' adversarial-hypotheses pattern.
7. **Hard gates implemented as hooks, not prompts.** Agent Teams `TaskCompleted`, `TeammateIdle` and `TaskCreated` hooks. Gas Town's Refinery gates. Carlini's CI added after regressions.
8. **Watchdog roles for liveness.** Gas Town's Witness and Deacon, `gt feed --problems`, and Agent Teams idle notifications. Cursor lists "agents run far too long" as an open problem.
9. **Effort scaling and concurrency caps written down.** Anthropic's explicit effort tiers, Gas Town's `max_polecats`, and Agent Teams' 3-5 teammates guidance.
10. **Different models per role.** Cursor, Cognition (smart-friend escalation), and Factory (model per orchestrator/worker/validator). Maps directly onto our usage modes.
11. **Spec-first decomposition.** MetaGPT PRD to design to tasks, ccpm PRD to epic to issues, Factory's planning phase ("where most of the value lies"), and Anthropic's feature list.
12. **Agent-facing ergonomics.** Short test output, logs to files, grep-friendly errors, and progress READMEs (Carlini).

## 3. Recurring failure modes

| Failure mode | Where seen |
|---|---|
| Premature "done" or marking tasks complete without real verification | Anthropic harness, MAST FC3, Agent Teams (lead stops early) |
| Task status not updated, blocking dependents | Agent Teams limitations |
| Regressions as agents add features | Carlini |
| Duplicate or overlapping work, agents colliding on one bug | Anthropic research, Carlini |
| Lock contention or lock leaks (agents forget to release) | Cursor, Carlini lock files |
| Risk-averse agents avoid hard tasks and make small safe changes | Cursor |
| Conflicting implicit decisions from parallel writers | Cognition |
| Context loss in summaries and handoffs ("telephone game") | Anthropic, Cognition, MAST FC1.4 |
| Over-spawning, runaway agents, step repetition, unaware of termination | Anthropic (50 subagents), MAST FC1.3/1.5, Cursor |
| Token cost explosion (4x single, 15x multi-agent) | Anthropic, Agent Teams docs, Gas Town anecdotes (unverified) |
| Review bottleneck: humans cannot review all agent output | Cursor background agents (secondary), Cognition review loops |
| Orchestrator complexity itself becomes the job | Gas Town report (two weeks debugging), Ruflo breadth claims |
| Resource exhaustion on a laptop (CPU, daemons, tmux) | Gas Town report, Claude Squad tmux timeouts |
| Deceptive shortcuts to satisfy a checker | TheAgentCompany (secondary) |
| Agents killing their own harness | Carlini (`pkill -9 bash`) |
| Tool or project abandonment risk | Vibe Kanban shut down April 2026 (secondary) |
| Inter-agent messages used to bypass permissions | Mitigated explicitly in Agent Teams (message provenance, auto-mode classifier) |
| Hype benchmarks with no independent check | Ruflo claims (secondary) |

## 4. Ranked ideas to adopt (15-25)

Effort: S = days, M = 1-3 weeks, L = a month or more.

1. **JSON feature/work-item ledger with agent-writable `passes` field only, plus a verifier-owned truth.** From Anthropic harness. It stops premature "done", and the owner-visible backlog doubles as the ledger. Agents may flip only status fields, never edit acceptance criteria. Effort: S.
2. **Hook-style hard gates at lifecycle events (TaskCreated, TaskCompleted, AgentIdle, OutboxSend).** From Claude Code Agent Teams hooks. Exit-code-style feedback re-queues the agent instead of relying on prompts. This is also where Auto mode and approval gates plug in. Effort: M.
3. **Verifier-first work items: every work item must carry an executable check (tests, script, or browser run) before an engineer picks it up.** From Carlini, Factory, MetaGPT executable feedback. Verifier quality is the main lever. Effort: M.
4. **Clean-context reviewer agent that sees only diff plus spec, with a "bridge" step in which the author filters findings against the owner's instructions.** From Cognition. Caps endless review loops and reduces QA cost. Effort: M.
5. **Single-writer ownership map: each repo path or module has one owning agent or team at a time, enforced by the scheduler.** From Agent Teams guidance, Cognition, Carlini. This avoids most merge pain. Effort: M.
6. **Git-worktree (or container) per agent with a merge-queue gate: agents never push to main; a merge agent or script batches, runs gates and bisects failures.** From Gas Town Refinery (Bors-style), Conductor, Sculptor. Keep the integrator thin, because Cursor found a heavy one became a bottleneck. Effort: L.
7. **Lock files claimed via git (or atomic file create) with TTL and lease renewal, plus a reaper.** From Carlini and Agent Teams file locking, and fixing the lock-leak failures Cursor saw. Fits the "agents as threads" model. Effort: S-M.
8. **Mailbox as validated per-agent JSON/JSONL inbox with a "sent only if written" guarantee and provenance tags (from agent vs from owner).** From Agent Teams. Map this to the Slack-like channels and DMs, and it feeds the live communication map. Effort: M.
9. **Treat inter-agent messages as untrusted for approvals.** From Agent Teams (an approval relayed by an agent never counts as owner consent). It is essential for the external email/social outbox. Effort: S.
10. **Effort-scaling policy and spawn budgets in the scheduler (per-task tiers, max concurrent agents, max children per manager).** From Anthropic research, Gas Town `max_polecats`, Agent Teams size guidance. This is the core of Low/Balanced/Max modes. Effort: M.
11. **Watchdog agent (cheap model, or plain code) for stalled work: no progress for N turns leads to nudge, then reassign, then kill.** From Gas Town Witness and "GUPP violation". Prefer plain code over an LLM where possible. Effort: S-M.
12. **Progress file plus git-log orientation protocol at every turn start, with short, grep-friendly outputs.** From Carlini and the Anthropic harness. It makes headless `claude -p --resume` robust to resume failure. Effort: S.
13. **Planner, worker and judge cycle for each sprint: planners create work items, workers finish and push independently, and a judge decides continue or stop, with a periodic fresh restart.** From Cursor. It is the simplest hierarchy that survived at scale. Effort: M.
14. **Role-specific model and effort routing, plus a "smart friend" escalation tool where a cheap agent can fork its context to a stronger model.** From Cursor and Cognition. Saves cost in Low/Balanced and gives a quality ceiling lift in Max. Effort: M.
15. **Artifact references instead of copying content between agents (the message carries a path or ID, not the body).** From Anthropic research. It cuts tokens and information loss and fits channels with attachments. Effort: S.
16. **Failure policy enum: retry, replan, decompose (plus escalate-to-owner).** From CAMEL Workforce. A small state-machine addition for the agent-thread lifecycle. Effort: S.
17. **Two-ledger orchestrator memory: a task/plan ledger and a progress ledger, with stall-triggered replanning.** From Magentic-One. Gives CEO/CTO agents a durable plan structure. Effort: M.
18. **Experience library ("shortcuts") distilled from finished work items and promoted to the shared toolbox.** From ChatDev Experiential Co-Learning. Natural home for per-agent labs and the Steward. Needs a quality filter or it will accumulate junk. Effort: M-L.
19. **Event-sourced agent state: append-only per-agent event log, with replay, condense and resume.** From OpenHands SDK. Gives the Steward simulation-and-rollback a foundation and gives observability for free. Effort: L.
20. **Parse Claude Code JSONL transcripts for per-agent tokens, cost and tool trace, instead of trusting self-reported usage.** From Mission Control. Feeds the usage-aware scheduler and the live map. Effort: S-M.
21. **Eval harness for the Steward: a small fixed set of canned company scenarios (about 20, as Anthropic did), LLM-judge plus end-state checks, and optionally TheAgentCompany/YC-Bench-style tasks.** Required before the Steward may change prompts or engine code. Effort: L.
22. **Rainbow-style deploys for the engine: new engine versions drain old agent turns rather than killing them.** From Anthropic research. Relevant to Steward-proposed engine changes with rollback. Effort: M.
23. **Adversarial "competing hypotheses" mode for debugging and architecture decisions (agents try to disprove each other).** From Agent Teams docs. Cheap to add as a meeting template. Effort: S.
24. **Cap concept count in the product model (hub, worker, task, plus a few more).** From the Gas Town experience report. Keep the org model legible to the owner. Effort: S (design discipline).
25. **Plan-first gate (read-only plan that the owner or a reviewer approves) before large work items.** From Agent Teams plan mode, Factory planning, Agent HQ plan mode. Note that Agent Teams auto-approves plans, so make ours a real gate in non-Auto mode. Effort: S.

### Design cautions summarized
- Anthropic itself says multi-agent suits parallelizable work and fits tightly coupled coding poorly. Our hundreds-of-agents design should bias toward many small independent units and a few strong reviewers, not wide conversation.
- Agent Teams cannot run under `-p`, so we must reimplement mailbox, task list and hooks ourselves. The file formats in the docs are a good starting schema.
- Treat vendor benchmark numbers (Ruflo, Eigent/OWL, OpenHands cost claims) as unverified.
- Cost reality: Carlini's compiler cost about $20k for about 2,000 sessions, and Anthropic reports about 15x tokens for multi-agent. Scheduler budgets should be a first-class feature.

### Gaps in this research
- Primary sources were not reachable or not fetched for: the Gas Town launch essay (HTTP 403), ChatDev Experiential Co-Learning and MacNet papers (only secondary summaries), MetaGPT's Data Interpreter and MGX, Copilot coding agent weaknesses, OpenHands delegation and stuck detection, and Vibe Kanban, Conductor and Sculptor user complaints. Treat items marked "secondary" accordingly.
