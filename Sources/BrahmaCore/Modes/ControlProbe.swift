import Foundation

/// What a zero-inference `get_usage` reported (Ultra's fresh admission reading, gate 6). Utilizations are fractions (the CLI
/// reports whole percents).
public struct UsageReading: Equatable, Sendable {
    public var fiveHourUtil: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDayUtil: Double?
    public var sevenDayResetsAt: Date?
    public var subscription: String?
    /// `extra_usage.is_enabled`: paid overage is possible.
    public var extraUsageEnabled: Bool?

    public init(fiveHourUtil: Double? = nil, fiveHourResetsAt: Date? = nil, sevenDayUtil: Double? = nil,
                sevenDayResetsAt: Date? = nil, subscription: String? = nil, extraUsageEnabled: Bool? = nil) {
        self.fiveHourUtil = fiveHourUtil; self.fiveHourResetsAt = fiveHourResetsAt; self.sevenDayUtil = sevenDayUtil
        self.sevenDayResetsAt = sevenDayResetsAt; self.subscription = subscription; self.extraUsageEnabled = extraUsageEnabled
    }
}

/// The zero-inference control session (design §3.6 gate 6, §6.4): the CLI is started with `--input-format stream-json` and
/// asked `initialize` and `get_usage` (`skip_behaviors: true`), or `get_settings`. No prompt is sent, so no model is called.
/// It reuses 3a's mode-canary messages (`ModeCanary.message`/`parse`) and runs a Quick workspace profile with an empty MCP
/// config written under the data home's `tmp` (never the system temp directory).
public enum ControlProbe {
    public static let timeout: Duration = .seconds(20)

    /// A fresh `get_usage`, or nil when the runner cannot run a control session (test fakes without a responder), the CLI did
    /// not answer, or the answer had no five-hour reading.
    public static func getUsage(runner: any TurnRunning, paths: BrahmaPaths, hookExecutable: String = "brahma") async -> UsageReading? {
        guard let response = await session(runner: runner, paths: paths, hookExecutable: hookExecutable,
                                           messages: [ModeCanary.message("ci", "initialize"),
                                                      ModeCanary.message("cu", "get_usage", ["skip_behaviors": .bool(true)])],
                                           want: "cu") else { return nil }
        let reading = parseUsage(response)
        return reading.fiveHourUtil == nil ? nil : reading
    }

    /// `get_settings` (`applied` and `effective`), or nil.
    public static func getSettings(runner: any TurnRunning, paths: BrahmaPaths, hookExecutable: String = "brahma") async -> [String: JSONValue]? {
        await session(runner: runner, paths: paths, hookExecutable: hookExecutable,
                      messages: [ModeCanary.message("ci", "initialize"), ModeCanary.message("cs", "get_settings")], want: "cs")
    }

    static func session(runner: any TurnRunning, paths: BrahmaPaths, hookExecutable: String, messages: [JSONValue],
                        want: String) async -> [String: JSONValue]? {
        let dir = paths.tmpDir.appending(path: "control-probe-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        defer { _ = try? EngineFiles.removeNoFollow(dir, under: paths.tmpDir) }
        let config = dir.appending(path: "empty.mcp.json")
        do {
            try paths.ensureTmpDir()
            try BrahmaPaths.ensurePrivateDirectory(dir)
            try SettingsFile.writePrivate(Data("{\"mcpServers\":{}}".utf8), to: config)
        } catch { return nil }
        let quick = ModeCanary.shapes().first?.1
        let agent = Agent(id: "control-probe", companyId: "control", name: "probe", role: "probe", model: quick?.model ?? "haiku",
                          sessionId: UUID().uuidString.lowercased(), sessionStarted: false, state: .running, blocker: nil,
                          requestedBlocker: nil, paused: false, readySince: nil, createdAt: Date())
        let company = Company(id: "control", name: "Control", slug: "control", goal: "control probe", workspacePath: dir.path,
                              status: .running, usageMode: .low, priorityWeight: 1, createdAt: Date())
        var request = TurnRequest(agent: agent, company: company, prompt: "", appendSystemPrompt: nil, mcpConfigPath: config.path,
                                  workingDirectory: dir.path, profile: .workspace, environment: ["BRAHMA_AGENT_ID": agent.id])
        request.mode = quick
        request.hookExecutable = hookExecutable
        guard let transcript = await runner.control(request, messages: messages, timeout: timeout) else { return nil }
        return ModeCanary.parse(transcript.lines)[want]
    }

    /// `rate_limits.five_hour/seven_day.{utilization, resets_at}`, `subscription_type`, `extra_usage.is_enabled`.
    public static func parseUsage(_ r: [String: JSONValue]) -> UsageReading {
        let limits = r["rate_limits"]?.objectValue ?? [:]
        func util(_ w: String) -> Double? { limits[w]?.objectValue?["utilization"]?.numberValue.map { $0 / 100 } }
        func reset(_ w: String) -> Date? { limits[w]?.objectValue?["resets_at"]?.stringValue.flatMap(date) }
        return UsageReading(fiveHourUtil: util("five_hour"), fiveHourResetsAt: reset("five_hour"),
                            sevenDayUtil: util("seven_day"), sevenDayResetsAt: reset("seven_day"),
                            subscription: r["subscription_type"]?.stringValue,
                            extraUsageEnabled: limits["extra_usage"]?.objectValue?["is_enabled"]?.boolValue)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
