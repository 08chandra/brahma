# Plan 1 — Core Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Swift package (`AgentCompanyCore` + `agentco` CLI) that stores companies/agents/chat in SQLite, runs agents as short headless `claude` turns under a global thread-style scheduler with usage modes, and lets agents talk through a bundled MCP server — usable end-to-end from the terminal before any UI exists.

**Architecture:** Agents are database rows, not processes. A global `Orchestrator` picks Ready agents (weighted round-robin across running companies, capped by usage mode, an owner hard cap, a RAM-derived safety cap, and live usage data from Claude's `rate_limit_event`), and runs each as one `claude -p --resume <session>` turn that reads an inbox digest from stdin and acts only through company MCP tools. The MCP server is the same `agentco` binary in `mcp` mode; it writes straight into the shared SQLite DB (WAL), which acts as the message bus — this replaces the Unix-socket sketch in spec §7 (builder simplification: fewer moving parts, crash-safe).

**Tech Stack:** Swift 6.2, Swift Package Manager, macOS 14+ deployment target, GRDB.swift 7.x, swift-argument-parser 1.5+, Swift Testing (`import Testing`), Claude Code CLI 2.1.304.

**Spec:** `docs/superpowers/specs/2026-10-20-agent-company-design.md`

**Roadmap (later plans, each written after the previous ships):**
- Plan 2 — Mac app shell: SwiftUI app embedding the Orchestrator; company rail, sidebar, channels/DMs, search, menu bar extra, quit→pause.
- Plan 3 — Org & work: role catalog and org-chart generation, work items/backlog/sprints, decision gates + Auto mode, hire/kill tools, anti-chatter.
- Plan 4 — Mission control: agent map, activity feed, workspace git worktrees + merges, preview adapters (web, iOS, macOS, CLI, backend).
- Plan 5 — Owner requests & safety: requests inbox, Keychain secrets + redaction + pre-commit hook, notifications (macOS/iMessage/email), resources drag-drop, permission profiles incl. Sandboxed. Acceptance criterion for Sandboxed: an agent must not be able to write agentco.sqlite, run agentco as another agent, or read other companies' workspaces from Bash.
- Plan 6 — Scale: 300-agent load test, perf, map collapsing, cap tuning from measured per-process RAM.
- Plan 7 — External communication: connected email/social accounts, outbox approval queue, inbound `#external`, contacts/opt-outs, per-platform rate limits (spec §6.11a).
- Plan 8 — Headless server: `agentco serve` daemon on Linux (systemd), authenticated HTTPS+WebSocket API, Linux backends for secrets/notifications/sandbox, Mac app as remote client (spec §6.13).
- Plan 9 — Agent labs & modules: per-agent lab folders, notes memory, experimental modules with manifests, promotion to the company Toolbox (spec §6.14).
- Plan 10 — Self-evolving engine: the Steward meta-agent, telemetry, three change levels, simulation runs, protected areas, hot swap + rollback, changelog (spec §6.15).

## Global Constraints

- Agent states are exactly: `ready`, `running`, `blocked`, `sleeping`, `killed` (spec §6.4).
- Usage modes are exactly `low`, `balanced`, `max`; defaults for Max 20x: low = 2, balanced = 6, max = owner hard cap = 16 (spec §6.7).
- Never knowingly use paid overage: `isUsingOverage == true` closes the usage gate (spec §6.7).
- Multiple companies can run at once; scheduler, caps and usage gate are global; slots shared by weighted round-robin with per-company `priorityWeight` default 1 (spec §6.7).
- Every agent turn must be isolated from the owner's personal Claude setup: `--setting-sources ""` (empty: load NO settings files — `project` would load the agent-writable workspace `.claude/settings.json`, a privilege-escalation path verified 2026-10-20), `--settings '{"enabledPlugins":{}}'`, `--disable-slash-commands`, `--strict-mcp-config`. Never use `--bare` (it drops subscription OAuth).
- The role prompt is passed with `--append-system-prompt` **only on an agent's first turn**; Claude Code snapshots it for the life of the session.
- Prompt goes to `claude` on **stdin**, never argv.
- Every state transition is persisted before it takes effect; on startup, agents recorded `running` with no live turn return to `ready` (spec §6.12).
- Data home: `~/Library/Application Support/AgentCompany/` (override `AGENTCO_HOME`); single DB `agentco.sqlite`, WAL, busy timeout 5 s. Workspaces: `~/AgentCompany/<company-slug>/` (override `AGENTCO_WORKSPACES`).
- Owner is addressed as `@owner` everywhere.
- `AgentCompanyCore` stays Linux-portable (spec §6.13): no AppKit or Apple-only Foundation APIs (e.g. `FileHandle.bytes`); Mac-only features go behind protocols in later plans.

## Review Focus

1. Orchestrator killed mid-turn (crash, Ctrl-C, reboot) → on next start no agent is stuck `running`; it is `ready` and its undelivered inbox is still pending. → Task 2 test `recoverInterruptedTurns`, Task 8 test `crashRecoveryRequeues`.
2. `claude` exits non-zero, prints garbage, or never emits a `result` line → turn recorded failed, agent `blocked(.retry)` with backoff, inbox kept, never stuck `running`. → Task 8 tests `failedTurnBacksOff`, `missingResultIsFailure`.
3. Usage limit hit (rate-limit event with status ≠ allowed, overage, or HTTP 429) while several turns are in flight → no new turns start anywhere; in-flight finish; agents resume at `resetsAt`. → Task 5 `UsageGate` tests, Task 8 `usageLimitBlocksEveryone`.
4. Owner (or an agent) messages an agent while it is `running` → message is delivered on the next turn, not silently marked delivered. → Task 8 `messageDuringTurnIsNotLost`.
5. Many MCP server processes + orchestrator writing the DB at once → no `database is locked` errors. → Task 3 `concurrentWritersDoNotLock`.

---

## File Structure

```
Package.swift
Sources/AgentCompanyCore/
  Paths.swift                 AgentCoPaths: home, db, run dir, workspaces
  Store/Store.swift           Store: open, migrations, all queries
  Store/Migrations.swift      schema v1
  Model/Company.swift         Company, CompanyStatus, UsageMode
  Model/Agent.swift           Agent, AgentState, Blocker, Role weights
  Model/Messaging.swift       Channel, ChannelKind, Message, Sender, InboxItem
  Model/Turn.swift            Turn, TurnOutcome, ActivityEvent
  Lifecycle/AgentLifecycle.swift
  Messaging/MessageRouter.swift
  Turns/StreamParser.swift    StreamEvent, RateLimitInfo, TurnResult
  Turns/ClaudeCommand.swift   TurnRequest, PermissionProfile, argv builder
  Turns/Prompts.swift         RolePrompt, InboxDigest
  Turns/TurnRunner.swift      TurnRunning, ClaudeProcessRunner
  Scheduler/UsageGate.swift
  Scheduler/SafetyCap.swift
  Scheduler/Scheduler.swift   SchedulerConfig, Candidate, select
  Orchestrator.swift
  MCP/JSONValue.swift
  MCP/MCPServer.swift
  MCP/CompanyTools.swift
Sources/agentco/
  main.swift                  ArgumentParser root + subcommands
Tests/AgentCompanyCoreTests/
  Fixtures/stream-success.jsonl, stream-ratelimited.jsonl
  StoreTests.swift  LifecycleTests.swift  RouterTests.swift
  StreamParserTests.swift  SchedulerTests.swift  CommandTests.swift
  MCPTests.swift  OrchestratorTests.swift  FakeTurnRunner.swift
  LiveSmokeTests.swift        runs only when AGENTCO_LIVE=1
```

---

### Task 1: Package, paths, store, companies and agents

**Files:**
- Create: `Package.swift`, `Sources/AgentCompanyCore/Paths.swift`, `Store/Store.swift`, `Store/Migrations.swift`, `Model/Company.swift`, `Model/Agent.swift`, `Sources/agentco/main.swift` (stub root command)
- Test: `Tests/AgentCompanyCoreTests/StoreTests.swift`

**Interfaces:**
- Produces:
  - `struct AgentCoPaths { let home: URL; let workspaces: URL; var database: URL; var runDir: URL; static func fromEnvironment() -> AgentCoPaths }`
  - `enum UsageMode: String, Codable, CaseIterable { case low, balanced, max }`
  - `enum CompanyStatus: String, Codable { case running, paused }`
  - `struct Company: Codable, Equatable, FetchableRecord, PersistableRecord { var id: String; var name: String; var slug: String; var goal: String; var workspacePath: String; var status: CompanyStatus; var usageMode: UsageMode; var priorityWeight: Int; var createdAt: Date }`
  - `enum AgentState: String, Codable { case ready, running, blocked, sleeping, killed }`
  - `enum Blocker: Codable, Equatable { case agent(String) /*agent id*/, owner(reason: String), usageLimit(until: Date), turnBudget(until: Date), retry(until: Date, failures: Int) }` stored as JSON text.
  - `struct Agent: Codable, Equatable, FetchableRecord, PersistableRecord { var id: String; var companyId: String; var name: String /*handle, unique per company, lowercase*/; var role: String; var model: String; var sessionId: String /*UUID*/; var sessionStarted: Bool; var state: AgentState; var blocker: Blocker?; var requestedBlocker: Blocker?; var paused: Bool; var readySince: Date?; var createdAt: Date }`
  - `final class Store: Sendable { init(path: String) throws; static func inMemory() throws -> Store; let writer: any DatabaseWriter }` — `DatabasePool` for files, `DatabaseQueue` for in-memory.
  - `Store.createCompany(name: String, goal: String, workspacesRoot: URL) throws -> Company` — slug = lowercased name, runs of non-alphanumerics → `-`; creates the workspace dir. (Task 3 extends it to also create `#general`.)
  - `Store.companies() throws -> [Company]`, `Store.company(id: String) throws -> Company?`, `Store.updateCompany(_ c: Company) throws`
  - `Store.hire(companyId: String, name: String, role: String, model: String) throws -> Agent` — new agent starts `sleeping`, `sessionStarted = false`, fresh UUID session id. Duplicate name in company throws `StoreError.duplicateName`.
  - `Store.agent(id:) throws -> Agent?`, `Store.agent(companyId:name:) throws -> Agent?`, `Store.agents(companyId: String? = nil, states: Set<AgentState>? = nil) throws -> [Agent]`, `Store.save(_ agent: Agent) throws`

- [ ] **Step 1:** `Package.swift` with products `AgentCompanyCore` (library) and `agentco` (executable); deps `GRDB.swift` from `7.0.0`, `swift-argument-parser` from `1.5.0`; platform `.macOS(.v14)`; test target resources `.copy("Fixtures")`. Run `swift build` — Expected: builds.
- [ ] **Step 2: Write failing tests** in `StoreTests.swift`:
```swift
@Test func walModeAndBusyTimeout() throws {
  let dir = try tempDir(); let s = try Store(path: dir.appending(path: "t.sqlite").path)
  #expect(try s.pragma("journal_mode") == "wal")
  #expect(try s.pragma("busy_timeout") == "5000")
}
@Test func createCompanyMakesWorkspaceAndDefaults() throws {
  let root = try tempDir(); let s = try Store.inMemory()
  let c = try s.createCompany(name: "Acme Labs", goal: "Build a todo app", workspacesRoot: root)
  #expect(c.slug == "acme-labs"); #expect(c.status == .running)
  #expect(c.usageMode == .low); #expect(c.priorityWeight == 1)
  #expect(FileManager.default.fileExists(atPath: root.appending(path: "acme-labs").path))
}
@Test func hireStartsSleepingWithFreshSession() throws {
  let s = try Store.inMemory(); let c = try s.createCompany(name: "A", goal: "g", workspacesRoot: try tempDir())
  let a = try s.hire(companyId: c.id, name: "ceo", role: "ceo", model: "opus")
  #expect(a.state == .sleeping); #expect(a.sessionStarted == false); #expect(UUID(uuidString: a.sessionId) != nil)
  #expect(throws: StoreError.duplicateName) { try s.hire(companyId: c.id, name: "ceo", role: "cto", model: "opus") }
}
@Test func blockerRoundTripsThroughJSON() throws { /* save agent with .usageLimit(until:) and reload; equal */ }
@Test func pathsHonorEnvironment() { /* AGENTCO_HOME=/x → home == /x, database == /x/agentco.sqlite */ }
```
  `Store.pragma(_:) -> String` is a test helper on Store (internal).
- [ ] **Step 3:** Run `swift test --filter StoreTests` — Expected: FAIL (types missing).
- [ ] **Step 4:** Implement. `Store(path:)` uses `DatabasePool` with `Configuration.busyMode = .timeout(5)` and `prepareDatabase { try $0.execute(sql: "PRAGMA busy_timeout = 5000") }`; migrations via `DatabaseMigrator` id `"v1"`. Tables: `company`, `agent` (`UNIQUE(companyId, name)`). Dates stored as GRDB default.
- [ ] **Step 5:** Run `swift test --filter StoreTests` — Expected: PASS.
- [ ] **Step 6:** Commit `feat(core): package, paths, store with companies and agents`.

---

### Task 2: Agent lifecycle, turns table, crash recovery

**Files:**
- Create: `Lifecycle/AgentLifecycle.swift`, `Model/Turn.swift`; Modify: `Store/Store.swift`, `Store/Migrations.swift`
- Test: `LifecycleTests.swift`

**Interfaces:**
- Consumes: `Store`, `Agent`, `AgentState`, `Blocker` (Task 1).
- Produces:
  - `enum AgentLifecycle { static func canTransition(from: AgentState, to: AgentState) -> Bool }`
  - `enum LifecycleError: Error, Equatable { case illegal(from: AgentState, to: AgentState) }`
  - `Store.transition(agentId: String, to: AgentState, blocker: Blocker? = nil, now: Date = .now) throws -> Agent` — validates, sets `blocker` (nil unless `to == .blocked`), sets `readySince = now` on entering `ready` (nil otherwise), appends an `ActivityEvent(kind: .stateChanged)`.
  - `enum TurnOutcome: String, Codable { case inProgress, succeeded, failed, usageLimited, interrupted }`
  - `struct Turn: Codable, FetchableRecord, PersistableRecord { var id: String; var agentId: String; var companyId: String; var startedAt: Date; var endedAt: Date?; var outcome: TurnOutcome; var summary: String?; var costUSD: Double? }`
  - `Store.startTurn(agentId: String, now: Date = .now) throws -> Turn`, `Store.finishTurn(id: String, outcome: TurnOutcome, summary: String?, costUSD: Double?, now: Date = .now) throws`
  - `Store.turnCount(agentId: String, since: Date) throws -> Int`, `Store.oldestTurnStart(agentId: String, since: Date) throws -> Date?`
  - `Store.recoverInterruptedTurns(now: Date = .now) throws -> Int` — every `inProgress` turn → `interrupted`; every agent in `running` → `ready`. Returns count of agents recovered.
  - `enum ActivityKind: String, Codable { case stateChanged, message, toolUse, turnStarted, turnFinished, usage, error }`
  - `struct ActivityEvent: Codable, FetchableRecord, PersistableRecord { var id: Int64?; var companyId: String; var agentId: String?; var turnId: String?; var kind: ActivityKind; var text: String; var createdAt: Date }`
  - `Store.appendEvent(_ e: ActivityEvent) throws`, `Store.events(afterId: Int64, companyId: String? = nil, limit: Int = 500) throws -> [ActivityEvent]`

Legal transitions: `sleeping→ready`, `sleeping→blocked`, `ready→running`, `ready→blocked`, `ready→sleeping`, `running→sleeping`, `running→ready`, `running→blocked`, `blocked→ready`, `blocked→sleeping`, any non-killed → `killed`. Everything else (including same→same and anything out of `killed`) is illegal.

- [ ] **Step 1: Write failing tests:**
```swift
@Test(arguments: [(AgentState.sleeping, AgentState.ready, true), (.ready, .running, true), (.running, .blocked, true),
                  (.blocked, .ready, true), (.sleeping, .running, false), (.killed, .ready, false), (.ready, .ready, false)])
func transitionTable(from: AgentState, to: AgentState, ok: Bool) { #expect(AgentLifecycle.canTransition(from: from, to: to) == ok) }
@Test func illegalTransitionThrowsAndPersistsNothing() throws { /* sleeping→running throws .illegal; reload: still sleeping */ }
@Test func enteringReadyStampsReadySinceAndClearsBlocker() throws { /* blocked(.retry) → ready: blocker nil, readySince == now */ }
@Test func recoverInterruptedTurns() throws {
  /* agent ready→running, startTurn; new Store on same file; recoverInterruptedTurns() == 1;
     agent.state == .ready; turn.outcome == .interrupted */
}
@Test func turnCountSince() throws { /* 3 turns at t-90m, t-30m, t-5m → turnCount(since: t-60m) == 2 */ }
```
- [ ] **Step 2:** `swift test --filter LifecycleTests` — Expected: FAIL.
- [ ] **Step 3:** Implement; `transition` runs in one `write` transaction (read-validate-write-event).
- [ ] **Step 4:** `swift test --filter LifecycleTests` — Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): agent lifecycle, turns, activity events, crash recovery`.

---

### Task 3: Channels, messages, inbox, router, search

**Files:**
- Create: `Model/Messaging.swift`, `Messaging/MessageRouter.swift`; Modify: `Store/Store.swift`, `Store/Migrations.swift`
- Test: `RouterTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - `enum ChannelKind: String, Codable { case channel, dm }`
  - `struct Channel: Codable, FetchableRecord, PersistableRecord { var id: String; var companyId: String; var name: String /*"general", or "dm:<a>:<b>" sorted handles*/; var kind: ChannelKind; var createdAt: Date }`
  - Membership table `channelMember(channelId, member)` where member is an agent id or the literal `"owner"`.
  - `enum Sender: Equatable { case owner, agent(String) }`
  - `struct Message: Codable, FetchableRecord, PersistableRecord { var id: String; var companyId: String; var channelId: String; var senderId: String /*agent id or "owner"*/; var text: String; var createdAt: Date }`
  - `struct InboxItem: Codable, FetchableRecord, PersistableRecord { var id: Int64?; var agentId: String; var messageId: String; var deliveredTurnId: String? }`
  - `Store.createChannel(companyId: String, name: String, members: [String]) throws -> Channel` (name normalized: strip `#`, lowercase; duplicate throws `.duplicateName`); `Store.channel(companyId:name:)`, `Store.channels(companyId:memberId:)`, `Store.addMember(channelId:member:)`, `Store.messages(channelId: String, limit: Int, before: Date? = nil) throws -> [Message]` (oldest→newest).
  - `Store.createCompany` now also creates `#general` with member `owner`; `Store.hire` adds the new agent to `#general`.
  - `Store.pendingInbox(agentId: String) throws -> [(InboxItem, Message, Channel)]` (oldest first), `Store.markDelivered(itemIds: [Int64], turnId: String) throws`
  - `Store.searchMessages(companyId: String, query: String, limit: Int = 50) throws -> [Message]` — FTS5 virtual table `messageFts(text, content='message', content_rowid='rowid')` created with raw SQL plus insert trigger.
  - `struct MessageRouter { let store: Store; func post(companyId: String, channel: String, from: Sender, text: String, now: Date = .now) throws -> Message; func sendDM(companyId: String, from: Sender, to handle: String, text: String, now: Date = .now) throws -> Message }`

Routing rules (one write transaction each):
1. Recipients = channel members except the sender, plus every `@handle` mentioned in the text that names a non-killed agent in the company (mentioned non-members get the inbox item but are not added as members). `@owner` mentions add nothing to any inbox (owner reads in UI/CLI).
2. DM: channel `dm:<x>:<y>` (handles sorted; owner's handle is `owner`) created on first use with both members.
3. For each agent recipient: insert `InboxItem`; if recipient is not killed: if `sleeping && !paused` → `ready`; if `blocked(.agent(senderAgentId))` → `ready`; if `blocked(.owner)` and sender is `.owner` → `ready`. Never wake `paused` agents.
4. Unknown channel → `RouterError.unknownChannel(name)`; unknown DM handle → `RouterError.unknownAgent(handle)`; sender must be a member of the channel unless it is `.owner` → else `RouterError.notAMember`.
5. Append `ActivityEvent(kind: .message, text: "#<channel> @<sender>: <first 200 chars>")`.

- [ ] **Step 1: Write failing tests:**
```swift
@Test func channelPostFansOutToMembersExceptSender() throws { /* 3 agents in #general; ceo posts; cto+eng get 1 pending each, ceo 0 */ }
@Test func postWakesSleepingButNotPaused() throws { /* cto sleeping → ready; eng paused stays sleeping but has inbox item */ }
@Test func mentionReachesNonMember() throws { /* #exec has ceo,cto; ceo posts "@eng1 ping" → eng1 has item, not a member */ }
@Test func dmCreatesSortedChannelOnce() throws { /* cto→ceo then ceo→cto: one channel named "dm:ceo:cto" */ }
@Test func replyUnblocksAgentWaitingOnSender() throws { /* eng blocked(.agent(cto.id)); cto DMs eng → eng ready */ }
@Test func ownerMessageUnblocksOwnerBlocker() throws { /* blocked(.owner(reason:"key")) → owner DMs → ready */ }
@Test func markDeliveredOnlyAffectsGivenItems() throws { /* 2 pending, deliver first → 1 pending */ }
@Test func searchFindsByWord() throws { /* post "stripe webhooks please" → search "webhooks" returns it */ }
@Test func concurrentWritersDoNotLock() async throws {
  /* file-backed DB; 8 separate Store instances on same path (simulating MCP processes) each post 50 messages
     concurrently via TaskGroup; expect no throw and 400 messages total */
}
```
- [ ] **Step 2:** `swift test --filter RouterTests` — Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` (all) — Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): channels, DMs, inbox routing, wakeups, FTS search`.

---

### Task 4: Claude stream-json parser

**Files:**
- Create: `Turns/StreamParser.swift`, `Tests/.../Fixtures/stream-success.jsonl`, `Fixtures/stream-ratelimited.jsonl`
- Test: `StreamParserTests.swift`

**Interfaces:**
- Produces:
  - `struct RateLimitInfo: Codable, Equatable, Sendable { var status: String; var resetsAt: Date?; var rateLimitType: String?; var isUsingOverage: Bool; var fiveHourUtilization: Double?; var sevenDayUtilization: Double?; var observedAt: Date }`
  - `struct TurnResult: Equatable, Sendable { var isError: Bool; var subtype: String; var text: String?; var costUSD: Double?; var apiErrorStatus: Int?; var sessionId: String }`
  - `enum StreamEvent: Equatable, Sendable { case initialized(sessionId: String, model: String); case assistantText(String); case toolUse(name: String); case rateLimit(RateLimitInfo); case result(TurnResult); case other(type: String) }`
  - `enum StreamParser { static func parse(line: String, now: Date = .now) -> StreamEvent? }` — nil for blank or non-JSON lines. An `assistant` line yields `.toolUse` for the first `tool_use` content block if present, else `.assistantText` of concatenated text blocks.

Real shapes observed from Claude Code 2.1.304 (use these verbatim in `stream-success.jsonl`, trimmed of extra keys):
```
{"type":"system","subtype":"init","session_id":"7081f66a-b7b1-4f6f-96e7-c690d4b0cec0","model":"claude-haiku-5-5","tools":["Bash"]}
{"type":"assistant","session_id":"7081f66a-b7b1-4f6f-96e7-c690d4b0cec0","message":{"content":[{"type":"text","text":"ok"}]}}
{"type":"rate_limit_event","session_id":"7081f66a-b7b1-4f6f-96e7-c690d4b0cec0","rate_limit_info":{"status":"allowed","resetsAt":1792522800,"rateLimitType":"five_hour","overageStatus":"allowed","overageResetsAt":1793491200,"isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.38,"resetsAt":1792522800},"seven_day":{"utilization":0.12,"resetsAt":1792677600}}}}
{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.00098121,"api_error_status":null,"session_id":"7081f66a-b7b1-4f6f-96e7-c690d4b0cec0"}
```
`stream-ratelimited.jsonl`: same init, then rate_limit_event with `"status":"rejected"`, then `{"type":"result","subtype":"error_during_execution","is_error":true,"result":"usage limit reached","api_error_status":429,"session_id":"…"}`. `resetsAt` is Unix seconds.

- [ ] **Step 1: Write failing tests:** parse each fixture line and assert: init → `.initialized(sessionId: "7081f66a-…", model: "claude-haiku-5-5")`; rate limit → `status == "allowed"`, `fiveHourUtilization == 0.38`, `sevenDayUtilization == 0.12`, `resetsAt == Date(timeIntervalSince1970: 1792522800)`, `isUsingOverage == false`; result → `isError == false`, `text == "ok"`, `costUSD == 0.00098121`, `apiErrorStatus == nil`; ratelimited result → `apiErrorStatus == 429`, `isError == true`; `parse(line: "")` and `parse(line: "not json")` → nil; unknown type `{"type":"hook_started"}` → `.other(type: "hook_started")`; assistant with a `tool_use` block named `mcp__company__post_message` → `.toolUse(name: "mcp__company__post_message")`.
- [ ] **Step 2:** `swift test --filter StreamParserTests` — FAIL.
- [ ] **Step 3:** Implement with `JSONSerialization` (tolerant of unknown keys).
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(core): parse claude stream-json events`.

---

### Task 5: Usage gate, safety cap, scheduler selection

**Files:**
- Create: `Scheduler/UsageGate.swift`, `Scheduler/SafetyCap.swift`, `Scheduler/Scheduler.swift`; Modify: `Model/Agent.swift` (role weight), `Store/Store.swift` (rate-limit persistence)
- Test: `SchedulerTests.swift`

**Interfaces:**
- Consumes: `RateLimitInfo` (Task 4), `Agent`, `Company`, `UsageMode`.
- Produces:
  - `enum UsageDecision: Equatable { case open; case closed(until: Date) }`
  - `enum UsageGate { static func threshold(_ m: UsageMode) -> Double /* low 0.80, balanced 0.90, max 0.97 */; static func evaluate(_ info: RateLimitInfo?, mode: UsageMode, now: Date) -> UsageDecision }`
    Closed when: `info.status != "allowed"` → until `resetsAt ?? now+15min`; `isUsingOverage` → until `resetsAt ?? now+15min`; `fiveHourUtilization >= threshold(mode)` → until `resetsAt ?? now+15min`. A `resetsAt` already in the past means open. `nil` info → open.
  - `Store.saveRateLimit(_ info: RateLimitInfo) throws`, `Store.latestRateLimit() throws -> RateLimitInfo?` (single-row table `usageState`).
  - `enum SafetyCap { static func compute(physicalMemoryBytes: UInt64, perProcessBytes: UInt64 = 350 * 1_048_576, reserveFraction: Double = 0.4) -> Int /* max(1, floor(phys*(1-reserve)/perProcess)) */; static var current: Int /* uses ProcessInfo.processInfo.physicalMemory */ }`
  - `func roleWeight(_ role: String) -> Int` — `ceo, cto, cpo` = 3; `architect` = 2; `manager` = 1; else 0.
  - `struct SchedulerConfig: Sendable { var hardCap: Int = 16; var safetyCap: Int = SafetyCap.current; var turnBudgetPerHour: Int = 30; func modeCap(_ m: UsageMode) -> Int /* low 2, balanced 6, max hardCap */ }`
  - `struct Candidate { var agent: Agent; var company: Company; var blockingCount: Int }`
  - `enum Scheduler { static func select(candidates: [Candidate], runningByCompany: [String: Int], config: SchedulerConfig, usage: (Company) -> UsageDecision) -> [Agent] }`

Selection algorithm (code it as written):
```
globalFree = min(config.hardCap, config.safetyCap) - sum(runningByCompany.values); if <= 0 return []
queues[companyId] = candidates for running companies whose usage(company) == .open,
                    sorted by (blockingCount desc, roleWeight desc, readySince asc, name asc)
assigned[companyId] = runningByCompany[companyId] ?? 0
loop while globalFree > 0:
   eligible = companies with non-empty queue and assigned < modeCap(company.usageMode)
   if eligible empty: break
   pick c minimizing (Double(assigned[c]) / Double(max(1, c.priorityWeight)), c.name)
   pop c's queue head into result; assigned[c] += 1; globalFree -= 1
```

- [ ] **Step 1: Write failing tests:**
```swift
@Test func thresholdsPerMode() { #expect(UsageGate.threshold(.low) == 0.80); #expect(UsageGate.threshold(.balanced) == 0.90); #expect(UsageGate.threshold(.max) == 0.97) }
@Test func gateClosesOnRejectedOverageOrHighUtilization() { /* status "rejected" → closed(until resetsAt); isUsingOverage → closed;
   util 0.85 → closed for .low, open for .max; resetsAt in the past → open; nil → open */ }
@Test func safetyCapFor24GiB() { #expect(SafetyCap.compute(physicalMemoryBytes: 25_769_803_776) == 42) }
@Test func respectsModeCaps() { /* one company .low with 5 ready → selects 2 */ }
@Test func respectsGlobalCapAcrossCompanies() { /* hardCap 4, two .max companies with 10 ready each → 4 total, 2 each */ }
@Test func weightedRoundRobin() { /* hardCap 6, A weight 2, B weight 1, both .max, plenty ready → A 4, B 2 */ }
@Test func pausedCompanyAndClosedGateGetNothing() { /* company.status .paused → 0; usage closed → 0 */ }
@Test func priorityOrderWithinCompany() { /* blockingCount 2 eng beats ceo with 0; equal blocking → ceo beats eng; then oldest readySince */ }
@Test func alreadyRunningCountsAgainstCaps() { /* .low, runningByCompany 2 → selects 0 */ }
```
- [ ] **Step 2:** `swift test --filter SchedulerTests` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(core): usage gate, safety cap, weighted round-robin scheduler`.

---

### Task 6: Claude command, role prompt, inbox digest, MCP config

**Files:**
- Create: `Turns/ClaudeCommand.swift`, `Turns/Prompts.swift`
- Test: `CommandTests.swift`

**Interfaces:**
- Consumes: `Agent`, `Company`, `Message`, `Channel`, `InboxItem`, `AgentCoPaths`.
- Produces:
  - `enum PermissionProfile: String, Codable { case workspace, full }` (Sandboxed arrives in Plan 5)
  - `struct TurnRequest: Sendable { var agent: Agent; var company: Company; var prompt: String; var appendSystemPrompt: String?; var mcpConfigPath: String; var workingDirectory: String; var profile: PermissionProfile }`
  - `enum ClaudeCommand { static let disallowedTools: [String]; static func arguments(for r: TurnRequest) -> [String] }`
  - `enum RolePrompt { static func render(agent: Agent, company: Company, roster: [Agent]) -> String }`
  - `enum InboxDigest { static func render(agent: Agent, company: Company, items: [(InboxItem, Message, Channel)], handles: [String: String] /* id → handle */) -> String }`
  - `enum MCPConfig { static func write(paths: AgentCoPaths, executable: String, agent: Agent) throws -> String /* returns file path <runDir>/<agentId>.mcp.json */ }`

`ClaudeCommand.arguments` must produce, in this order:
```
-p --output-format stream-json --verbose
--model <agent.model> --fallback-model sonnet
--setting-sources "" --settings {"enabledPlugins":{}} --disable-slash-commands
--strict-mcp-config --mcp-config <mcpConfigPath>
--disallowed-tools <disallowedTools joined by ",">
( --session-id <sessionId> --append-system-prompt <appendSystemPrompt> )   if !agent.sessionStarted
( --resume <sessionId> )                                                    if agent.sessionStarted
workspace: --permission-mode acceptEdits --allowed-tools Bash,Read,Edit,Write,Glob,Grep,mcp__company --add-dir <company.workspacePath>
full:      --permission-mode bypassPermissions
```
`disallowedTools` = `CronCreate,CronDelete,CronList,ScheduleWakeup,Monitor,RemoteTrigger,PushNotification,SendMessage,ListAgents,EnterWorktree,ExitWorktree,DesignSync,ReportFindings,TaskStop` (these are harness tools that would bypass the company's own messaging/scheduling).

MCP config JSON: `{"mcpServers":{"company":{"command":"<executable>","args":["mcp","--db","<paths.database>","--company","<companyId>","--agent","<agentId>"]}}}`.

RolePrompt must state (exact facts, wording free): the agent's handle and role, the company name and goal, the roster as `@handle — role`, that **all communication happens only via the `company` tools** (plain-text replies are not seen by anyone), that `@owner` is the human owner, to keep messages short and actionable, to call `set_blocked` when waiting on someone, never to print secrets or environment variables, and that the turn should end once its inbox is handled.

InboxDigest format (first line exact):
```
New since your last turn (<n> items):
- #general @owner: Build a landing page
- DM @cto: Use Stripe webhooks, not polling
```
DMs render as `DM @<sender>`; owner sender renders `@owner`. Zero items renders `New since your last turn (0 items):` followed by `- (nothing new — check your work and continue)`.

- [ ] **Step 1: Write failing tests:** first-turn args equal the exact expected array for a `workspace` agent (assert whole array); resumed args contain `--resume <id>` and contain neither `--session-id` nor `--append-system-prompt`; `full` profile contains `bypassPermissions` and no `--allowed-tools`; prompt text never appears in args; MCP config file decodes to the exact JSON structure above; digest renders the two example lines exactly; role prompt contains `@ceo`, the goal string, every roster handle, and the substrings `company` tools and `@owner`.
- [ ] **Step 2:** `swift test --filter CommandTests` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(core): isolated claude turn command, prompts, MCP config`.

---

### Task 7: MCP server and company tools (`agentco mcp`)

**Files:**
- Create: `MCP/JSONValue.swift`, `MCP/MCPServer.swift`, `MCP/CompanyTools.swift`; Modify: `Sources/agentco/main.swift` (add `mcp` subcommand)
- Test: `MCPTests.swift`

**Interfaces:**
- Consumes: `Store`, `MessageRouter`, `Blocker`.
- Produces:
  - `enum JSONValue: Codable, Equatable, Sendable { case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null }`
  - `struct ToolSpec: Encodable { var name: String; var description: String; var inputSchema: JSONValue }`
  - `struct CompanyTools { init(store: Store, companyId: String, agentId: String); func specs() -> [ToolSpec]; func call(name: String, arguments: [String: JSONValue]) throws -> String }`
  - `final class MCPServer { init(tools: CompanyTools); func handle(line: String) -> String? /* one JSON-RPC response line, nil for notifications */; func serve(input: FileHandle, output: FileHandle) }`
  - CLI: `agentco mcp --db <path> --company <id> --agent <id>`

Tools (names exact; all text results are short human-readable confirmations or listings):
| Tool | Args | Effect |
|---|---|---|
| `post_message` | `channel`, `text` | `router.post(... from: .agent(self))` |
| `send_dm` | `to` (handle, may be `owner`), `text` | `router.sendDM` |
| `read_channel` | `channel`, `limit` (default 20, max 100) | last N messages as `@handle: text` lines |
| `list_channels` | — | channels this agent is in |
| `list_agents` | — | roster: `@handle — role — state` |
| `create_channel` | `name`, `members` (array of handles) | creates channel incl. self |
| `set_blocked` | `on` (`@handle` or `owner`), `reason` | sets `agent.requestedBlocker` (`.agent(id)` or `.owner(reason:)`); applied by orchestrator at turn end |

JSON-RPC: newline-delimited. Handle `initialize` (reply `protocolVersion` = client's requested version, `capabilities: {"tools": {}}`, `serverInfo: {"name":"agentco","version":"0.1.0"}`), `notifications/initialized` (no reply), `tools/list`, `tools/call` (result `{"content":[{"type":"text","text":…}],"isError":false}`; tool errors → same shape with `isError: true` and the error message), unknown method → JSON-RPC error `-32601`. Tool calls also append `ActivityEvent(kind: .toolUse)`.

- [ ] **Step 1: Write failing tests:** `initialize` echoes `protocolVersion "2025-06-18"`; `tools/list` returns exactly the 7 names; `tools/call post_message {"channel":"general","text":"hi"}` → `isError false` and a message exists from the agent; `send_dm` to unknown handle → `isError true` with text containing `unknown agent`; `set_blocked {"on":"@cto","reason":"need schema"}` → agent's `requestedBlocker == .agent(cto.id)`; unknown method → error code `-32601`; notification line → `handle` returns nil; end-to-end: launch the built `agentco mcp` binary via `Process` with pipes, send initialize + tools/list, read two response lines.
- [ ] **Step 2:** `swift test --filter MCPTests` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Verify with the real CLI: `swift build && claude -p "Call the company list_agents tool and print its output" --mcp-config <a written config> --strict-mcp-config --setting-sources project --allowed-tools mcp__company --model haiku` from a temp company — Expected: output lists the roster.
- [ ] **Step 6:** Commit `feat(core): company MCP server and agentco mcp`.

---

### Task 8: Turn runner and orchestrator

**Files:**
- Create: `Turns/TurnRunner.swift`, `Orchestrator.swift`, `Tests/.../FakeTurnRunner.swift`
- Test: `OrchestratorTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `protocol TurnRunning: Sendable { func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> }`
  - `struct ClaudeProcessRunner: TurnRunning { var claudePath: String = "claude"; var maxTurnDuration: Duration = .seconds(900) }` — spawns via `/usr/bin/env claude …args`, cwd = `request.workingDirectory`, writes `request.prompt` to stdin then closes it, parses stdout lines with `StreamParser`, stderr captured (last 4 KB) into the thrown error; kills the process (SIGTERM, then SIGKILL after 5 s) on timeout or task cancellation; throws `TurnError.exitedWithoutResult(code:stderrTail:)` if no `.result` event.
  - `FakeTurnRunner` (tests): scripted per agent handle: list of `StreamEvent`s, optional side-effect closure run mid-stream (e.g., to simulate an MCP tool posting), optional thrown error, optional delay.
  - `actor Orchestrator { init(store: Store, runner: TurnRunning, paths: AgentCoPaths, config: SchedulerConfig = .init(), mcpExecutable: String, profile: PermissionProfile = .workspace, clock: @escaping @Sendable () -> Date = { .now }); func start() throws /* recoverInterruptedTurns */; func tick() async; func runningCount() -> Int; func waitUntilIdle(timeout: Duration) async throws; func runForever(interval: Duration = .seconds(1)) async }`

`tick()` does, in order:
1. Unblock: every `blocked` agent whose blocker is `.usageLimit/.turnBudget/.retry` with `until <= now` → `ready`.
2. Usage: `info = store.latestRateLimit()`; per company decision `UsageGate.evaluate(info, mode: company.usageMode, now)`. For every company that is closed, move its `ready` agents → `blocked(.usageLimit(until:))` and append one `ActivityEvent(kind: .usage)`.
3. Turn budget: any `ready` agent with `turnCount(since: now-1h) >= turnBudgetPerHour` → `blocked(.turnBudget(until: oldestTurnStart(since: now-1h)! + 1h))`.
4. `blockingCount` per ready agent = number of non-killed agents whose blocker is `.agent(thisAgent.id)`.
5. `Scheduler.select(...)` with in-memory `runningByCompany`; for each selected agent spawn a child task `runTurn(agent)`.

`runTurn(agent)`:
1. `transition(→ running)`; `turn = startTurn`; snapshot `items = pendingInbox(agent)`; render digest; first turn renders `RolePrompt`; `MCPConfig.write`.
2. Consume `runner.run(request)`: `.initialized` → if `!sessionStarted` set `sessionStarted = true` and save; `.rateLimit(info)` → `saveRateLimit`; `.toolUse` → event; `.result(r)` → keep.
3. Outcome:
   - `r.apiErrorStatus == 429` **or** last rate-limit info has status ≠ `allowed` → `finishTurn(.usageLimited)`; agent → `blocked(.usageLimit(until: info?.resetsAt ?? now+15min))`; **do not** mark items delivered.
   - stream threw, or `r.isError` → `finishTurn(.failed, summary: error text)`; failures = previous `.retry` failures + 1; agent → `blocked(.retry(until: now + min(30s·2^(failures-1), 30min), failures:))`; **do not** mark delivered.
   - success → `markDelivered(items, turn.id)`; `finishTurn(.succeeded, summary: r.text, costUSD: r.costUSD)`; reload agent; if `requestedBlocker != nil` → `blocked(requestedBlocker)` and clear `requestedBlocker`; else if `pendingInbox` non-empty (arrived mid-turn) → `ready`; else → `sleeping`.
4. If the agent was killed or paused mid-turn (re-read state), skip the state change but still finish the turn record.

- [ ] **Step 1: Write failing tests** (all with `FakeTurnRunner`, in-memory store, injected clock):
```swift
@Test func ownerMessageRunsAgentAndSleepsAfter() async throws { /* owner posts to #general mentioning @ceo; tick; waitUntilIdle → ceo had 1 turn .succeeded, items delivered, state .sleeping, sessionStarted true */ }
@Test func firstTurnSendsRolePromptThenResumes() async throws { /* capture requests: turn1 has appendSystemPrompt != nil; turn2 nil and args contain --resume */ }
@Test func toolPostDuringTurnWakesRecipient() async throws { /* fake side-effect: router.post as ceo to #general → cto becomes ready and runs on next tick */ }
@Test func messageDuringTurnIsNotLost() async throws { /* side-effect: owner DMs ceo mid-turn → after turn ceo is .ready, 1 pending item */ }
@Test func requestedBlockerAppliedAtTurnEnd() async throws { /* side-effect set requestedBlocker .agent(cto) → ceo .blocked(.agent(cto.id)); cto DM → ceo ready */ }
@Test func failedTurnBacksOff() async throws { /* runner throws → .blocked(.retry(until: now+30s, failures:1)); items still pending; 2nd failure → +60s */ }
@Test func missingResultIsFailure() async throws { /* stream ends with only .initialized → failed turn, retry blocker */ }
@Test func usageLimitBlocksEveryone() async throws { /* agent A's turn emits rateLimit(status "rejected", resetsAt t+2h) + result 429;
     next tick: A and ready agent B (other company) → .blocked(.usageLimit(until: t+2h)); advance clock past t+2h, tick → both ready */ }
@Test func highUtilizationStopsLowButNotMax() async throws { /* latest info util 0.85: low company's ready agent blocked, max company's agent runs */ }
@Test func turnBudgetBlocksChatterbox() async throws { /* budget 3; 3 turns in last hour → 4th tick blocks .turnBudget */ }
@Test func crashRecoveryRequeues() async throws { /* agent set running + turn inProgress; new Orchestrator.start() → agent ready, runs on tick */ }
@Test func capsHonoredUnderLoad() async throws { /* hardCap 3, 10 ready agents, fake delay 200ms; max observed concurrency == 3 */ }
```
- [ ] **Step 2:** `swift test --filter OrchestratorTests` — FAIL.
- [ ] **Step 3:** Implement `ClaudeProcessRunner`, then `Orchestrator`.
- [ ] **Step 4:** `swift test` — Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core): turn runner and global orchestrator`.

---

### Task 9: `agentco` CLI and live smoke test

**Files:**
- Modify: `Sources/agentco/main.swift`; Create: `Tests/.../LiveSmokeTests.swift`, `README.md`

**Interfaces:**
- Consumes: `Store`, `MessageRouter`, `Orchestrator`, `ClaudeProcessRunner`, `AgentCoPaths.fromEnvironment()`.
- Produces CLI (company resolved by name or slug):
  - `agentco company create <name> --goal <text>` → prints id + workspace path
  - `agentco company list` → `name  status  mode  weight  agents(running/ready/blocked/sleeping)`
  - `agentco company pause|resume <name>`; `agentco company mode <name> low|balanced|max`; `agentco company weight <name> <n>`
  - `agentco hire <company> <handle> --role <role> --model opus|sonnet|haiku`
  - `agentco say <company> (#channel|@handle) <text>` → owner post or DM
  - `agentco log <company> (#channel|@handle) [--limit 30]`
  - `agentco search <company> <query>`
  - `agentco status` → per company: agents with state, blocker, last turn outcome; latest usage (5h %, 7d %, resets)
  - `agentco kill|pause|wake <company> <handle>` (pause = `paused=true` + → sleeping; wake = `paused=false`, → ready)
  - `agentco run [--hard-cap 16] [--profile workspace|full]` → foreground orchestrator; prints every new `ActivityEvent` as `HH:mm:ss [company] text`; Ctrl-C cancels in-flight turns cleanly (SIGINT handler → task cancel → runner kills children) and exits 0.
  - `agentco mcp …` (Task 7).
  - `mcpExecutable` for `run` = absolute path of the running binary (`Bundle.main.executablePath`).

- [ ] **Step 1:** Implement subcommands (thin wrappers; no new core logic).
- [ ] **Step 2: Write `LiveSmokeTests`** guarded by `.enabled(if: ProcessInfo.processInfo.environment["AGENTCO_LIVE"] == "1")`: temp `AGENTCO_HOME`/`AGENTCO_WORKSPACES`; company "Smoke"; hire `alice` and `bob` (model `haiku`); owner posts to #general: `@alice send @bob a DM saying "ping". @bob, when you get a DM from alice, reply to her by DM with "pong". Then both stop.`; run orchestrator with real `ClaudeProcessRunner` until idle (timeout 240 s). Assert: DM channel `dm:alice:bob` has a message from alice containing `ping` and one from bob containing `pong`; no agent `running`; at least one rate-limit row saved.
- [ ] **Step 3:** Run `swift test` — Expected: PASS (live test skipped). Run `AGENTCO_LIVE=1 swift test --filter LiveSmokeTests` — Expected: PASS.
- [ ] **Step 4:** Manual check: `swift run agentco company create Demo --goal "Plan a todo app"`, hire `ceo` (sonnet) and `cto` (sonnet), `agentco say Demo #general "@ceo propose a 3-bullet plan and ask @cto for a stack"`, `agentco run` — Expected: activity lines show both agents taking turns and messages in `agentco log Demo #general`; Ctrl-C exits with no agent left `running` (`agentco status`).
- [ ] **Step 5:** `README.md`: what it is, build, the commands above, data locations, and the warning that `--profile full` gives agents your whole Mac.
- [ ] **Step 6:** Commit `feat(cli): agentco commands and live smoke test`.
