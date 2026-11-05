import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// A canary that passes every key it is asked about (or none), recording the keys' shapes.
final class PassingCanary: SandboxCanaryRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _shapes: [String] = []
    private var _passes: Bool
    init(passes: Bool = true) { _passes = passes }
    var shapes: [String] { lock.withLock { _shapes } }
    var passes: Bool { get { lock.withLock { _passes } } set { lock.withLock { _passes = newValue } } }

    func run(paths: BrahmaPaths, claudePath: String, runner: any TurnRunning, key: SandboxCanaryKey, settings: ClaudeSettings?) async -> CanaryRun {
        let ok = lock.withLock { _shapes.append(key.shape); return _passes }
        return CanaryRun(items: [DoctorItem(name: "sandbox-canary", status: ok ? .pass : .fail, detail: "fake")], verified: key)
    }
}

/// An orchestrator world with a sandbox gate (a fake `claude` to fingerprint, a canary the test controls).
struct GatedWorld {
    let world: World
    let canary: PassingCanary
    let claude: URL
    let company: Company
    let eng: Agent

    init(mode: UsageMode = .max, profile: PermissionProfile = .sandboxed, canaryPasses: Bool = true, tag: String) throws {
        let canary = PassingCanary(passes: canaryPasses)
        let claude = try FakeTools.script("claude", "# \(tag) fingerprint fixture\nexit 0")
        var gate = SandboxCanaryGate(canary: canary, runner: FakeTurnRunner(), claudePath: claude.path, retryAfter: 0)
        gate.fingerprintCacheSeconds = 0
        self.canary = canary; self.claude = claude
        world = try World(sandboxCanary: gate)
        company = try world.company("Acme", mode: mode, profile: profile)
        eng = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
    }

    var store: Store { world.store }
    func fingerprint() throws -> String { try CLIFingerprint.of(claudePath: claude.path).key }

    func record(_ gates: [String], _ shape: ProbeShape, passed: Bool = true) throws {
        for g in gates {
            try store.recordProbeGate(GateResult(gate: g, shape: shape, passed: passed, detail: "test"), fingerprint: try fingerprint(),
                                      now: world.clock.now)
        }
    }

    func inputs(kind: TurnKind = .work, item: WorkItem? = nil) async throws -> ModeInputs {
        let c = try #require(try store.company(id: company.id))
        let a = try #require(try store.agent(id: eng.id))
        let facts = try item.flatMap { try store.itemModeFacts(itemId: $0.id, holderId: eng.id) }
        return world.orchestrator.modeInputs(kind: kind, agent: a, company: c, template: store.catalog.template(role: a.role, pack: c.packId),
                                             deciding: ModelContext(), facts: facts, hasItem: item != nil, itemBudget: item != nil,
                                             sessionModel: nil, sessionTokens: 0)
    }

    func requests() -> [TurnRequest] { world.fake.requests.filter { $0.agent.id == eng.id } }

    /// Ticks until the agent's turn reached the runner (canary runs happen in between), at most `rounds` times.
    func runUntilTurn(rounds: Int = 8) async throws {
        let before = requests().count
        for _ in 0..<rounds where requests().count == before {
            try world.dm(company, eng, "go")
            try await world.cycle()
        }
    }
}

private let subagentGates = ["L-2", "V-2", "V-3", "V-5"]

@Suite(.scratch, .serialized) struct SubagentGateTests {
    @Test func taskOffUntilGatesPass() async throws {
        var gates: Set<String> = []
        for g in ["L-2", "V-3", "V-5"] {
            #expect(!SubagentGate.passed(profile: .sandboxed, gates: gates)); gates.insert(g)
        }
        #expect(!SubagentGate.passed(profile: .sandboxed, gates: gates), "V-2 or V-8 is still missing")
        #expect(SubagentGate.passed(profile: .sandboxed, gates: gates.union(["V-8"])))
        #expect(SubagentGate.passed(profile: .sandboxed, gates: gates.union(["V-2"])))
        // In the engine: off until this CLI build passed them for the sandboxed-Task shape.
        let g = try GatedWorld(tag: "taskOffUntilGatesPass")
        let item = try g.store.createWorkItem(companyId: g.company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "T", ownerId: g.eng.id,
                                                                                                        status: .ready), now: g.world.clock.now)
        #expect(!(try await g.inputs(item: item)).subagentGate)
        try g.record(subagentGates, .sandboxedTask)
        let open = try await g.inputs(item: item)
        #expect(open.subagentGate)
        #expect(ModePolicy.select(open).subagents == .forced(model: "haiku", depth: 1, concurrent: 2))
    }

    @Test func gateIsPerFingerprintAndShape() async throws {
        let g = try GatedWorld(tag: "gateIsPerFingerprintAndShape")
        try g.record(subagentGates, .ultra)
        #expect(!(try await g.inputs()).subagentGate, "another shape's passes do not count")
        try g.store.recordProbeGate(GateResult(gate: "L-2", shape: .sandboxedTask, passed: true, detail: ""), fingerprint: "other-build")
        for gate in ["V-2", "V-3", "V-5"] {
            try g.store.recordProbeGate(GateResult(gate: gate, shape: .sandboxedTask, passed: true, detail: ""), fingerprint: "other-build")
        }
        #expect(!(try await g.inputs()).subagentGate, "another CLI build's passes do not count")
        try g.record(subagentGates, .sandboxedTask)
        #expect(try await g.inputs().subagentGate)
        // A new build of the CLI (a new fingerprint) starts over.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: g.claude.path)
        #expect(!(try await g.inputs()).subagentGate)
        // A later failure replaces the pass.
        try g.record(["V-3"], .sandboxedTask, passed: false)
        #expect(!(try g.store.passedProbeGates(fingerprint: try g.fingerprint(), shape: .sandboxedTask).contains("V-3")))
    }

    /// The per-shape canary plumbing (Task 3's gate, keyed by fingerprint, shape and macOS): a Task turn's shape has its own key.
    /// Until it passed, the turn runs without Task (its canary asked for in the background); once it passed, Task compiles,
    /// without web tools until F7-agents, and pre-tainted until V-1.
    @Test func taskTurnWithoutWebUntilF7() async throws {
        var forced = ModePolicy.select({ var i = ModeInputs(); i.hasItem = true; i.tier = .s; i.subagentGate = true; return i }())
        forced.maxBudgetUSD = 1
        #expect(forced.subagents != .off)
        #expect(BuiltinTools.taskTurn == BuiltinTools.withTask.filter { $0 != "WebFetch" && $0 != "WebSearch" })

        let g = try GatedWorld(tag: "taskTurnWithoutWebUntilF7")
        let item = try g.store.createWorkItem(companyId: g.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "T", acceptanceCriteria: "ok", checkSpec: CheckSpec(command: "true", paths: ["src/a"]), status: .ready),
            now: g.world.clock.now)
        _ = try CompanyTools(store: g.store, companyId: g.company.id, agentId: g.eng.id).call(name: "claim_lease", arguments: ["key": .string(item.key)])
        // A plain turn first: its key passes (the agent waits for that one, as every sandboxed turn does).
        try await g.runUntilTurn()
        #expect(!(TurnProfileCompiler.profile(for: try #require(g.requests().last)).tools ?? []).contains("Task"))
        // The sub-agent gate passes, but the Task shape's own key has no pass yet: the turn runs without Task (the agent does not
        // wait), and that key's canary is asked for in the background.
        try g.record(subagentGates, .sandboxedTask)
        try await g.runUntilTurn()
        let fallback = try #require(g.requests().last)
        #expect(!(TurnProfileCompiler.profile(for: fallback).tools ?? []).contains("Task"))
        #expect(try g.store.events(afterId: 0, companyId: g.company.id).contains { $0.text.hasPrefix("sandbox not verified for the task shape") })
        try await g.world.orchestrator.waitUntilIdle(timeout: .seconds(300))
        let fp = try g.fingerprint(), os = ProcessInfo.processInfo.operatingSystemVersionString
        // Now the Task shape is verified: the next turn has Task and no web tools.
        try await g.runUntilTurn()
        let second = try #require(g.requests().last)
        let tools = TurnProfileCompiler.profile(for: second).tools ?? []
        #expect(tools.contains("Task")); #expect(!tools.contains("WebFetch")); #expect(!tools.contains("WebSearch"))
        #expect(!second.taskWebTools)
        let settings = TurnProfileCompiler.profile(for: second).settings
        #expect(try g.store.sandboxVerified(SandboxCanaryKey(fingerprint: fp, shape: CanaryShape.key(settings, launch: "task"), osVersion: os)))
        // Pre-tainted at launch: V-1 has not passed for this build.
        #expect(try g.store.agent(id: g.eng.id)?.taintSources.contains(TaintPolicy.preTaintSource) == true)
        // Once F7-agents passed, a Task turn keeps its web tools.
        try g.record(["F7-agents"], .sandboxedTask)
        try await g.runUntilTurn()
        let third = try #require(g.requests().last)
        #expect(third.taskWebTools)
        #expect((TurnProfileCompiler.profile(for: third).tools ?? []).contains("WebFetch"))
    }

    @Test func preTaintUntilV1() async throws {
        let g = try GatedWorld(tag: "preTaintUntilV1")
        #expect(!(await g.world.orchestrator.postToolGateVerified()))
        // V-1 on another shape does not end the pre-taint; on the sandboxed-Task shape it does (Task 10's `hookGate`).
        try g.record(["V-1"], .ultra)
        #expect(!(await g.world.orchestrator.postToolGateVerified()))
        let r = await ProbeGates.run(gate: "V-1", shape: .sandboxedTask, runner: RecordingGates(passing: ["V-1"]), store: g.store,
                                     fingerprint: try g.fingerprint(), now: g.world.clock.now)
        #expect(r.passed)
        #expect(await g.world.orchestrator.postToolGateVerified())
        #expect(TaintPolicy.preTaint(tools: Set(BuiltinTools.withTask), network: nil, hookVerified: false))
        #expect(!TaintPolicy.preTaint(tools: Set(BuiltinTools.withTask), network: nil, hookVerified: true))
    }

    @Test func reviewAndAuditNeverFanOutBeforeV1() async throws {
        let g = try GatedWorld(tag: "reviewAndAuditNeverFanOutBeforeV1")
        try g.record(subagentGates, .sandboxedTask)
        for kind in [TurnKind.review, .audit] {
            #expect(!(try await g.inputs(kind: kind)).subagentGate, "\(kind) before V-1")
        }
        try g.record(["V-1"], .sandboxedTask)
        for kind in [TurnKind.review, .audit] {
            var i = try await g.inputs(kind: kind)
            i.tier = .l
            // Even then the policy and the compiler keep review and audit turns clean-context.
            #expect(ModePolicy.select(i).subagents == .off)
            var forced = ModePolicy.select(i)
            forced.subagents = .forced(model: "haiku", depth: 1, concurrent: 2)
            var r = TurnRequest(agent: g.eng, company: g.company, prompt: "", appendSystemPrompt: nil, mcpConfigPath: "/dev/null",
                                workingDirectory: g.company.workspacePath, profile: .sandboxed)
            r.kind = kind; r.mode = forced
            let p = TurnProfileCompiler.profile(for: r)
            #expect(p.subagents == .off); #expect(!(p.tools ?? []).contains("Task")); #expect(p.disallowedTools.contains("Task"))
        }
    }

    @Test func workspaceNeverGetsTask() async throws {
        #expect(!SubagentGate.passed(profile: .workspace, gates: Set(subagentGates + ["V-8", "V-1", "V-9"])))
        #expect(!SubagentGate.passed(profile: .full, gates: Set(subagentGates + ["V-8"])))
        let g = try GatedWorld(profile: .workspace, tag: "workspaceNeverGetsTask")
        try g.record(subagentGates + ["V-8", "V-1"], .sandboxedTask)
        #expect(!(try await g.inputs()).subagentGate)
        // Whatever the decision says, the workspace compile has no Task.
        var forced = ModePolicy.select({ var i = ModeInputs(); i.hasItem = true; i.tier = .s; i.subagentGate = true; return i }())
        forced.subagents = .forced(model: "haiku", depth: 1, concurrent: 2)
        var r = TurnRequest(agent: g.eng, company: g.company, prompt: "", appendSystemPrompt: nil, mcpConfigPath: "/dev/null",
                            workingDirectory: g.company.workspacePath, profile: .workspace)
        r.mode = forced; r.hookExecutable = "/usr/local/bin/brahma"
        let p = TurnProfileCompiler.profile(for: r)
        #expect(p.subagents == .off); #expect(p.disallowedTools.contains("Task")); #expect(p.disallowedTools.contains("Agent"))
        #expect(!p.allowedTools.contains("Task")); #expect(p.environment["CLAUDE_CODE_SUBAGENT_MODEL"] == nil)
    }

    @Test func planFirstSandboxedNeedsV4() async throws {
        let g = try GatedWorld(tag: "planFirstSandboxedNeedsV4")
        let created = try g.store.createWorkItem(companyId: g.company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Big", ownerId: g.eng.id,
                                                                                                            status: .ready), now: g.world.clock.now)
        let itemId = created.id
        try await g.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET tier = 'l', specConfirmedBy = 'owner:owner' WHERE id = ?", arguments: [itemId])
        }
        let item = try #require(try g.store.workItem(id: itemId))
        let before = try await g.inputs(item: item)
        #expect(!before.planFirstGate)
        #expect(!ModePolicy.select(before).planFirst); #expect(ModePolicy.select(before).reason.contains("probe V-4 has not passed"))
        try g.record(["V-4"], .sandboxedTask)
        #expect(!(try await g.inputs(item: item)).planFirstGate, "V-4 counts only for the sandboxed plan shape")
        try g.record(["V-4"], .sandboxedPlan)
        let after = try await g.inputs(item: item)
        #expect(after.planFirstGate); #expect(ModePolicy.select(after).planFirst)
        // The workspace profile keeps 3a's own V-4 gate.
        let ws = try GatedWorld(profile: .workspace, tag: "planFirstSandboxedNeedsV4-ws")
        try ws.record(["V-4"], .sandboxedPlan)
        #expect(try await ws.inputs().planFirstGate == ModeGates.planFirst)
    }

    @Test func fanOutShapesHaveTheirOwnCanaryKeys() {
        var s = ClaudeSettings(); s.disableBundledSkills = true
        let keys = [CanaryShape.key(s, launch: nil), CanaryShape.key(s, launch: "task"), CanaryShape.key(s, launch: "ultra-small"),
                    CanaryShape.key(s, launch: "ultra")]
        #expect(Set(keys).count == 4)
        #expect(keys[0] == s.shape(), "a plain turn keeps the key it always had")
        #expect(CanaryShape.launch(ultraDecision(.small)) == "ultra-small"); #expect(CanaryShape.launch(ultraDecision(.full)) == "ultra")
        var task = ModePolicy.select({ var i = ModeInputs(); i.hasItem = true; i.tier = .s; i.subagentGate = true; return i }())
        #expect(CanaryShape.launch(task) == "task")
        task.subagents = .off
        #expect(CanaryShape.launch(task) == nil)
    }

    @Test func probeGatesRecordAndRunMissing() async throws {
        let store = try Store.inMemory()
        try store.recordProbeGate(GateResult(gate: "V-3", shape: .sandboxedTask, passed: true, detail: "ok"), fingerprint: "fp")
        let runner = RecordingGates(passing: ["L-2"])
        let results = await ProbeGates.runMissing(runner: runner, store: store, fingerprint: "fp")
        #expect(!runner.asked.contains("sandboxed-task/V-3"), "a passed gate is not run again")
        #expect(!runner.asked.contains { $0.hasSuffix("/V-9") }, "V-9 is pending the owner: nothing runs")
        #expect(results.contains { $0.gate == "V-9" && !$0.passed })
        #expect(try store.passedProbeGates(fingerprint: "fp", shape: .sandboxedTask) == ["V-3", "L-2"])
        let rows = try store.probeGateRows(fingerprint: "fp")
        #expect(Set(rows.map { "\($0.shape)/\($0.gate)" }) == Set(ProbeShape.allCases.flatMap { s in ProbeGates.catalog(s).map { "\(s.rawValue)/\($0)" } }))
    }

    @Test func liveProbeJudgesReadTheStream() {
        func obs(_ lines: [String], events: [StreamEvent] = []) -> LiveProbeGates.Observation {
            var o = LiveProbeGates.Observation()
            o.raw = lines
            for l in lines { for e in StreamParser.parseAll(line: l) ?? [] { o.state.apply(e) } }
            for e in events { o.state.apply(e) }
            return o
        }
        let call = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"isolation":"remote","prompt":"x"}}]}}"#
        let refused = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Remote isolation is not available"}]}}"#
        let hookDenied = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Brahma: sub-agents with isolation (remote) are not allowed"}]}}"#
        let ran = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"ok"}]}}"#
        #expect(LiveProbeGates.judgeRemoteRefused(obs([call, refused])) == nil)
        #expect(LiveProbeGates.judgeRemoteRefused(obs([call, ran])) == "the isolation call was not refused")
        #expect(LiveProbeGates.judgeRemoteRefused(obs([])) == "the probe made no Agent call with isolation remote")
        #expect(LiveProbeGates.judgeHookDenied(obs([call, hookDenied])) == nil)
        #expect(LiveProbeGates.judgeHookDenied(obs([call, refused])) != nil, "refused, but not by the hook")
        let initNoTask = #"{"type":"system","subtype":"init","session_id":"s","model":"claude-haiku-5-5","tools":["Bash","Read"],"agents":[]}"#
        let initTask = #"{"type":"system","subtype":"init","session_id":"s","model":"claude-haiku-5-5","tools":["Bash","Task","Workflow"],"agents":[]}"#
        #expect(LiveProbeGates.judgeTaskOff(obs([initNoTask])) == nil)
        #expect(LiveProbeGates.judgeTaskOff(obs([initTask])) == "the session offers Task with sub-agents off")
        let capped = #"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"session_id":"s","total_cost_usd":0.012,"modelUsage":{"claude-haiku-5-5":{"costUSD":0.012}}}"#
        let started = #"{"type":"system","subtype":"task_started","task_id":"a1","task_type":"local_agent","spawn_depth":1}"#
        #expect(LiveProbeGates.judgeCapStops(obs([initTask, started, capped])) == nil)
        let opus = #"{"type":"result","subtype":"success","is_error":false,"session_id":"s","total_cost_usd":0.02,"modelUsage":{"claude-haiku-5-5":{"costUSD":0.01},"claude-opus-5-5":{"costUSD":0.01}}}"#
        #expect(LiveProbeGates.judgeForcedWorkers(obs([initTask, started, opus]))?.contains("claude-opus-5-5") == true)
        let progress = #"{"type":"system","subtype":"task_progress","task_id":"w1","workflow_progress":[{"type":"workflow_agent","agentId":"x1"}]}"#
        let done = #"{"type":"result","subtype":"success","is_error":false,"session_id":"s","total_cost_usd":0.02}"#
        #expect(LiveProbeGates.judgeWorkflowRan(obs([initTask, progress, done])) == nil)
        #expect(LiveProbeGates.judgeWorkflowRan(obs([initNoTask, progress, done])) == "the init tools have no Workflow")
        // Gates with no automated probe fail closed.
        #expect(LiveProbeGates.notAutomated["V-1"] != nil); #expect(LiveProbeGates.notAutomated["F7-agents"] != nil)
    }
}
