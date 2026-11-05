import Foundation

/// The production probe-gate runner (`brahma mode gates --run`, Task 14u): each automated gate is one live haiku turn under
/// the sandboxed argv of its shape (workers forced to haiku, `--max-budget-usd` at most `ProbeGates.maxBudgetUSD`), built on
/// the sandbox canary's throwaway company (`SandboxCanary.prepare`) and judged from its stream. Live: it spends a little of
/// the plan, so only the owner runs it. A gate with no automated probe in this build fails closed with that reason.
public struct LiveProbeGates: ProbeGateRunning {
    public var paths: BrahmaPaths
    public var environment: SandboxEnvironment
    public var runner: any TurnRunning
    public var hookExecutable: String

    public init(paths: BrahmaPaths, environment: SandboxEnvironment, runner: any TurnRunning, hookExecutable: String) {
        self.paths = paths; self.environment = environment; self.runner = runner; self.hookExecutable = hookExecutable
    }

    /// What one probe turn showed.
    public struct Observation: Sendable {
        public var state = TurnStreamState()
        public var raw: [String] = []
        public var error: String?
        public init() {}
    }

    /// One automated probe: the turn it runs and how its stream is judged (nil: passed; else why not).
    struct Spec: Sendable {
        var prompt: String
        var decision: ModeDecision
        var hook: Bool
        var judge: @Sendable (Observation) -> String?
    }

    /// Gates with no automated probe in this build (they stay failing).
    public static let notAutomated: [String: String] = [
        "V-1": "not automated: needs the PostToolUse hook's flag from a sub-agent WebFetch on a database-backed probe agent",
        "U-4": "not automated: same probe as V-1 on the Ultra shape",
        "V-4": "not automated: the two-turn plan-mode probe under the sandboxed argv",
        "F7-agents": "not automated: needs Brahma's worker agent types (Task 10b)",
        "U-6": "not automated: the background-wait ceiling needs a 40-minute run",
        "U-7": "not automated: the emergency stop of a live workflow",
        "U-8": "not automated: RSS measurement",
        "U-9": "not automated: standing ultracode",
    ]

    public func run(gate: String, shape: ProbeShape) async -> GateResult {
        if let why = Self.notAutomated[gate] { return GateResult(gate: gate, shape: shape, passed: false, detail: why) }
        guard let spec = Self.spec(gate: gate, shape: shape) else {
            return GateResult(gate: gate, shape: shape, passed: false, detail: "no probe for \(gate) on the \(shape.rawValue) shape")
        }
        let observation = await observe(spec)
        if let error = observation.error { return GateResult(gate: gate, shape: shape, passed: false, detail: error) }
        let why = spec.judge(observation)
        return GateResult(gate: gate, shape: shape, passed: why == nil, detail: why ?? "passed (\(Self.summary(observation)))")
    }

    func observe(_ spec: Spec) async -> Observation {
        var o = Observation()
        let (paths, env, hook) = (self.paths, self.environment, self.hookExecutable)
        let prepared: Result<SandboxCanary.Prepared, any Error> = await Doctor.execBlocking.run {
            Result { try SandboxCanary.prepare(paths: paths, environment: env, hookExecutable: hook) }
        }
        guard case .success(let p) = prepared else {
            if case .failure(let e) = prepared { o.error = "the probe could not be set up: \(Store.flat("\(e)", max: 300))" }
            return o
        }
        defer { p.cleanup() }
        var request = p.request
        request.prompt = spec.prompt
        request.mode = spec.decision
        request.hookExecutable = spec.hook ? hookExecutable : nil
        request.emitRawLines = true
        let profile = TurnProfileCompiler.profile(for: request)
        do {
            try TurnProfileCompiler.validate(profile)
            if let path = request.settingsFilePath {
                try SettingsFile.write(try TurnProfileCompiler.settingsJSON(profile), to: URL(fileURLWithPath: path))
            }
            for try await event in runner.run(request) {
                if case .raw(let line) = event { o.raw.append(line) }
                o.state.apply(event)
            }
        } catch {
            // A controlled stop or a refused call can end the turn with an error; the judge decides from what was seen.
            if o.state.result == nil, o.state.inits.isEmpty { o.error = "the probe turn failed: \(Store.flat("\(error)", max: 300))" }
        }
        return o
    }

    static func summary(_ o: Observation) -> String {
        "tools \(o.state.inits.last?.tools.count ?? 0), agents \(o.state.subagentIds.count + o.state.workflowAgentIds.count), "
            + "cost $\(TurnProfileCompiler.money(o.state.result?.costUSD ?? 0))"
    }

    // MARK: Specs

    /// A haiku decision for the probe: `subagents` forced to haiku (FORCE), the budget at most `ProbeGates.maxBudgetUSD`;
    /// `ultra`: an Ultra-small decision approved by policy.
    static func decision(subagents: Bool, ultra: Bool, budget: Double) -> ModeDecision {
        var d = ModeDecision(mode: ultra ? .ultra : .standard, rung: ultra ? .r5 : .r1, model: "haiku", effort: .low, maxEffortLevel: .low,
                             maxBudgetUSD: min(budget, ProbeGates.maxBudgetUSD), maxTurns: 12, wallClock: .seconds(300),
                             quotas: ModeCaps.standard.quotas, reasons: ["probe gate"])
        if subagents || ultra { d.subagents = .forced(model: "haiku", depth: 1, concurrent: 2) }
        if ultra { d.workflow = UltraWorkflow(variant: .small, approver: .policy, maxConcurrentAgents: 2) }
        return d
    }

    static let agentRemote = "Call the Agent tool exactly once with subagent_type \"general-purpose\", isolation \"remote\" and the "
        + "prompt \"reply ok\". Whatever happens, then reply with the single word DONE."

    static func spec(gate: String, shape: ProbeShape) -> Spec? {
        let ultra = shape == .ultra
        switch (gate, shape) {
        case ("V-3", .sandboxedTask):
            return Spec(prompt: "Reply with the single word OK.", decision: decision(subagents: false, ultra: false, budget: 0.02),
                        hook: true, judge: judgeTaskOff)
        case ("V-5", .sandboxedTask), ("U-2", .ultra):
            let prompt = ultra
                ? "Use the Workflow tool once with an inline script that runs one agent with model \"opus\" whose prompt is \"use the "
                    + "Agent tool to ask a sub-agent for 2+2\". Then reply with the single word DONE."
                : "Use the Agent tool once with model \"opus\" and subagent_type \"Explore\" to answer what 2+2 is. Then reply DONE."
            return Spec(prompt: prompt, decision: decision(subagents: true, ultra: ultra, budget: 0.05), hook: true, judge: judgeForcedWorkers)
        case ("L-2", .sandboxedTask), ("U-3", .ultra):
            let prompt = ultra
                ? "Use the Workflow tool once with an inline script that runs two agents, each writing a 400-word essay. Then reply DONE."
                : "Use the Agent tool once (subagent_type \"general-purpose\") to write a 600-word essay, wait for it, then reply DONE."
            return Spec(prompt: prompt, decision: decision(subagents: true, ultra: ultra, budget: 0.005), hook: true, judge: judgeCapStops)
        case ("V-2", _), ("U-5", .ultra):
            return Spec(prompt: agentRemote, decision: decision(subagents: true, ultra: ultra, budget: 0.03), hook: false, judge: judgeRemoteRefused)
        case ("V-8", _):
            return Spec(prompt: agentRemote, decision: decision(subagents: true, ultra: ultra, budget: 0.03), hook: true, judge: judgeHookDenied)
        case ("U-1", .ultra):
            return Spec(prompt: "Use the Workflow tool once with an inline script that runs two agents, each replying with one word. "
                            + "Then reply with the single word DONE.",
                        decision: decision(subagents: true, ultra: true, budget: 0.05), hook: true, judge: judgeWorkflowRan)
        case ("U-10", .ultra):
            return Spec(prompt: "Call the Workflow tool once with name \"deep-research\" and no script. Whatever happens, then reply DONE.",
                        decision: decision(subagents: true, ultra: true, budget: 0.02), hook: true, judge: judgeNamedWorkflowRefused)
        default:
            return nil
        }
    }

    // MARK: Judges (pure: tested on recorded lines)

    /// V-3: the init `tools` of a sandboxed turn with sub-agents off hold neither `Task` nor `Agent`.
    static func judgeTaskOff(_ o: Observation) -> String? {
        guard let tools = o.state.inits.last?.tools else { return "no init line" }
        let offered = Set(tools).intersection(["Task", "Agent"])
        return offered.isEmpty ? nil : "the session offers \(offered.sorted().joined(separator: ", ")) with sub-agents off"
    }

    /// V-5 / U-2: a sub-agent ran, every billed model is haiku (FORCE pinned the opus request), nothing ran at depth 2.
    static func judgeForcedWorkers(_ o: Observation) -> String? {
        guard o.state.subagentIds.count + o.state.workflowAgentIds.count > 0 else { return "no sub-agent or workflow agent ran" }
        guard let models = o.state.result?.modelsUsed, !models.isEmpty else { return "no modelUsage in the result" }
        let other = models.filter { ModelAllowlist.family($0) != "haiku" }
        if !other.isEmpty { return "billed \(other.joined(separator: ", ")) despite the forced haiku workers" }
        if o.state.maxSpawnDepth > 1 { return "a sub-agent ran at depth \(o.state.maxSpawnDepth)" }
        return nil
    }

    /// L-2 / U-3 (= V-7): the budget cap stopped the turn while its sub-agent or workflow worked, and `total_cost_usd` is at
    /// least the sum of `modelUsage[*].costUSD` (the workers' cost included).
    static func judgeCapStops(_ o: Observation) -> String? {
        guard o.state.subagentIds.count + o.state.workflowAgentIds.count > 0 else { return "no sub-agent or workflow agent ran" }
        guard o.state.result?.stopReason == TurnStop.budgetCap else { return "the cap did not stop the turn" }
        guard let (total, sum) = costs(o.raw) else { return "no result cost to compare" }
        return total + 1e-9 >= sum ? nil : "total_cost_usd \(total) is below the workers' sum \(sum)"
    }

    /// V-2: the remote-isolation Agent call came back as an error (the CLI refused it, no hook involved).
    static func judgeRemoteRefused(_ o: Observation) -> String? {
        guard let id = toolUse(o.raw, where: { name, input in ["Agent", "Task"].contains(name) && input["isolation"]?.stringValue == "remote" })
        else { return "the probe made no Agent call with isolation remote" }
        guard let r = toolResult(o.raw, id: id) else { return "no result for the isolation call" }
        return r.isError ? nil : "the isolation call was not refused"
    }

    /// V-8: the engine's pre-tool hook denied the remote-isolation call (its reason reached the model).
    static func judgeHookDenied(_ o: Observation) -> String? {
        guard let id = toolUse(o.raw, where: { name, input in ["Agent", "Task"].contains(name) && input["isolation"]?.stringValue == "remote" })
        else { return "the probe made no Agent call with isolation remote" }
        guard let r = toolResult(o.raw, id: id) else { return "no result for the isolation call" }
        return r.isError && r.text.contains("Brahma:") && r.text.contains("isolation") ? nil : "the pre-tool hook did not deny the isolation call"
    }

    /// U-1: the Ultra shape's init offers `Workflow`, a workflow ran agents, and a result came last.
    static func judgeWorkflowRan(_ o: Observation) -> String? {
        guard let tools = o.state.inits.last?.tools else { return "no init line" }
        guard tools.contains("Workflow") else { return "the init tools have no Workflow" }
        guard !o.state.workflowAgentIds.isEmpty else { return "no workflow agent ran (the opt-in wording may not count)" }
        return o.state.result == nil ? "no result" : nil
    }

    /// U-10: a named workflow was denied by the pre-tool hook.
    static func judgeNamedWorkflowRefused(_ o: Observation) -> String? {
        guard let id = toolUse(o.raw, where: { name, input in name == "Workflow" && input["name"]?.stringValue != nil })
        else { return "the probe made no named Workflow call" }
        guard let r = toolResult(o.raw, id: id) else { return "no result for the named workflow" }
        return r.isError && r.text.contains("Brahma:") && r.text.contains("inline") ? nil : "the named workflow was not refused"
    }

    // MARK: Raw-line readers

    static func objects(_ raw: [String]) -> [[String: JSONValue]] {
        raw.compactMap { (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?.objectValue }
    }

    /// The id of the first `tool_use` block (main loop or sub-agent) matching `match`.
    static func toolUse(_ raw: [String], where match: (String, [String: JSONValue]) -> Bool) -> String? {
        for o in objects(raw) where o["type"]?.stringValue == "assistant" {
            for block in o["message"]?.objectValue?["content"]?.arrayValue ?? [] {
                guard let b = block.objectValue, b["type"]?.stringValue == "tool_use", let name = b["name"]?.stringValue,
                      let id = b["id"]?.stringValue else { continue }
                if match(name, b["input"]?.objectValue ?? [:]) { return id }
            }
        }
        return nil
    }

    /// The `tool_result` for `id`: its error flag and its text.
    static func toolResult(_ raw: [String], id: String) -> (isError: Bool, text: String)? {
        for o in objects(raw) where o["type"]?.stringValue == "user" {
            for block in o["message"]?.objectValue?["content"]?.arrayValue ?? [] {
                guard let b = block.objectValue, b["type"]?.stringValue == "tool_result", b["tool_use_id"]?.stringValue == id else { continue }
                let text: String
                if let s = b["content"]?.stringValue { text = s } else {
                    text = (b["content"]?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: " ")
                }
                return (b["is_error"]?.boolValue ?? false, text)
            }
        }
        return nil
    }

    /// The last result's `total_cost_usd` and the sum of its `modelUsage[*].costUSD`.
    static func costs(_ raw: [String]) -> (total: Double, sum: Double)? {
        guard let r = objects(raw).last(where: { $0["type"]?.stringValue == "result" }), let total = r["total_cost_usd"]?.numberValue else { return nil }
        let sum = (r["modelUsage"]?.objectValue ?? [:]).values.compactMap { $0.objectValue?["costUSD"]?.numberValue }.reduce(0, +)
        return (total, sum)
    }
}
