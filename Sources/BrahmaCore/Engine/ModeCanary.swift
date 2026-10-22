import Foundation

/// The doctor's `mode-canary` (design §6.4): zero inference. For each mode's compiled profile the CLI is started with
/// `--input-format stream-json` and asked `initialize`, `get_settings` and `get_usage`; no prompt is sent, so no model is called.
/// It checks the applied model and effort (one shape per emitted effort cap), that ultracode, the advisor, fast mode and workflows
/// are off, records the built-in agent types every turn's init must list, and reads the plan the CLI reports. A CLI that no longer
/// knows the hidden `--max-turns` exits before answering (probe V-11), which fails the canary.
public enum ModeCanary {
    public struct Result: Equatable, Sendable {
        public var item: DoctorItem
        public var builtinAgents: [String]?
        public var reportedSubscription: String?
    }

    static let timeout: Duration = .seconds(20)

    /// Quick (haiku low), Standard (sonnet medium) and Deep (sonnet high): every cap value a 3a turn emits.
    public static func shapes() -> [(String, ModeDecision)] {
        var notice = ModeInputs(); notice.turnKind = .notice
        var standard = ModeInputs(); standard.hasItem = true; standard.tier = .s
        var deep = ModeInputs(); deep.hasItem = true; deep.tier = .m; deep.riskTags = ["hotPath"]
        return [("quick", ModePolicy.select(notice)), ("standard", ModePolicy.select(standard)), ("deep", ModePolicy.select(deep))]
    }

    static func message(_ id: String, _ subtype: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var request: [String: JSONValue] = ["subtype": .string(subtype)]
        request.merge(extra) { a, _ in a }
        return .object(["type": .string("control_request"), "request_id": .string(id), "request": .object(request)])
    }

    /// Nil when the runner cannot run control sessions (test fakes).
    public static func run(runner: any TurnRunning) async -> Result? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "brahma-canary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appending(path: "empty.mcp.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{\"mcpServers\":{}}".utf8).write(to: config)
        } catch {
            return Result(item: DoctorItem(name: "mode-canary", status: .fail, detail: "can't prepare the canary directory: \(error)"),
                          builtinAgents: nil, reportedSubscription: nil)
        }
        var problems: [String] = []
        var agents: [String]?
        var subscription: String?
        for (index, (name, d)) in shapes().enumerated() {
            let agent = Agent(id: "doctor-canary", companyId: "doctor", name: "canary", role: "probe", model: d.model,
                              sessionId: UUID().uuidString.lowercased(), sessionStarted: false, state: .running, blocker: nil,
                              requestedBlocker: nil, paused: false, readySince: nil, createdAt: Date())
            let company = Company(id: "doctor", name: "Doctor", slug: "doctor", goal: "canary", workspacePath: dir.path,
                                  status: .running, usageMode: .low, priorityWeight: 1, createdAt: Date())
            var request = TurnRequest(agent: agent, company: company, prompt: "", appendSystemPrompt: nil, mcpConfigPath: config.path,
                                      workingDirectory: dir.path, profile: .workspace, environment: ["BRAHMA_AGENT_ID": "doctor-canary"])
            request.mode = d
            var messages = [message("i\(index)", "initialize"), message("s\(index)", "get_settings")]
            if index == 0 { messages.append(message("u\(index)", "get_usage", ["skip_behaviors": .bool(true)])) }
            guard let transcript = await runner.control(request, messages: messages, timeout: timeout) else { return nil }
            let responses = parse(transcript.lines)
            guard !responses.isEmpty else {
                if let status = transcript.exitStatus, status != 0 {
                    problems.append("\(name): the CLI exited \(status) before answering (an unknown flag such as the hidden --max-turns?)")
                } else {
                    problems.append("\(name): no control response")
                }
                continue
            }
            if let initialize = responses["i\(index)"] {
                if let fast = initialize["fast_mode_state"]?.stringValue, fast != "off" { problems.append("\(name): fast mode is \(fast)") }
                if agents == nil {
                    agents = initialize["agents"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
                }
            } else {
                problems.append("\(name): no initialize response")
            }
            if let settings = responses["s\(index)"] {
                let applied = settings["applied"]?.objectValue ?? [:]
                let effective = settings["effective"]?.objectValue ?? [:]
                let model = applied["model"]?.stringValue ?? "?"
                if ModelAllowlist.family(model) != ModelAllowlist.family(d.model) { problems.append("\(name): applied model \(model), expected \(d.model)") }
                let effort = applied["effort"]?.stringValue ?? "?"
                if effort != d.effort.rawValue { problems.append("\(name): applied effort \(effort), expected \(d.effort.rawValue)") }
                if applied["ultracode"]?.boolValue != false { problems.append("\(name): ultracode is not off") }
                if let advisor = applied["advisor"], advisor != .null { problems.append("\(name): an advisor is set") }
                if effective["enableWorkflows"]?.boolValue == true || effective["disableWorkflows"]?.boolValue != true {
                    problems.append("\(name): workflows are not switched off")
                }
                if effective["fastMode"]?.boolValue == true { problems.append("\(name): fast mode is on in the settings") }
            } else {
                problems.append("\(name): no get_settings response")
            }
            if let usage = responses["u\(index)"] { subscription = usage["subscription_type"]?.stringValue }
        }
        let item = problems.isEmpty
            ? DoctorItem(name: "mode-canary", status: .pass,
                         detail: "quick, standard and deep apply their model and effort; no ultracode, advisor, fast mode or workflows")
            : DoctorItem(name: "mode-canary", status: .fail, detail: problems.joined(separator: "; "))
        return Result(item: item, builtinAgents: agents, reportedSubscription: subscription)
    }

    /// request_id → the `response` body of each successful `control_response`.
    static func parse(_ lines: [String]) -> [String: [String: JSONValue]] {
        var out: [String: [String: JSONValue]] = [:]
        for line in lines {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), let obj = value.objectValue,
                  obj["type"]?.stringValue == "control_response", let response = obj["response"]?.objectValue,
                  let id = response["request_id"]?.stringValue else { continue }
            out[id] = response["response"]?.objectValue ?? [:]
        }
        return out
    }
}
