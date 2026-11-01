import Foundation

public struct DoctorItem: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pass, warn, fail }
    public var name: String
    public var status: Status
    public var detail: String

    public init(name: String, status: Status, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public var cliVersion: String?
    public var items: [DoctorItem]
    public var checkedAt: Date
    /// `subscription_type` as the CLI reports it (`get_usage`, read by the mode-canary with no model call); nil until read.
    public var reportedSubscription: String? = nil
    /// The built-in agent types this CLI version lists (`initialize`): every turn's init `agents` must equal them.
    public var builtinAgents: [String]? = nil
    /// The sub-agent gate record for this CLI version and profile (design §3.9): always false on the workspace profile.
    public var subagentGate: Bool? = nil

    public init(cliVersion: String?, items: [DoctorItem], checkedAt: Date, reportedSubscription: String? = nil,
                builtinAgents: [String]? = nil, subagentGate: Bool? = nil) {
        self.cliVersion = cliVersion
        self.items = items
        self.checkedAt = checkedAt
        self.reportedSubscription = reportedSubscription
        self.builtinAgents = builtinAgents
        self.subagentGate = subagentGate
    }

    public var ok: Bool { !items.contains { $0.status == .fail } }
}

/// Checks that the installed `claude` still behaves the way the engine's argv and parsing assume.
public enum Doctor {
    /// 2.1.312: exec-form hooks (`command` + `args`) and `onFailure: "block"` are verified live there (1b fix round 1, C1); an
    /// older CLI may run a hook without its arguments, which would let the engine's PreToolUse hook fail open.
    public static let minimumVersion = "2.1.312"
    public static let maxAge: TimeInterval = 86_400
    public static let probeTimeout: Duration = .seconds(120)
    static let probeCodeword = "BRAHMA-PROBE-7"
    static let probePrompt = "Brahma probe: the codeword is \(probeCodeword)."

    public static let requiredFlags: [String] = [
        "-p", "--output-format", "--verbose", "--resume", "--session-id", "--mcp-config", "--strict-mcp-config",
        "--model", "--fallback-model", "--append-system-prompt", "--permission-mode", "--allowed-tools",
        "--disallowed-tools", "--add-dir", "--settings", "--setting-sources", "--disable-slash-commands",
        // Work modes (W11): visible in --help. The hidden --max-turns is checked by the mode-canary (probe V-11).
        "--effort", "--max-budget-usd",
        // The Sandboxed profile (5-lite Task 1b).
        "--restricted", "--tools", "--plugin-dir", "--permission-prompts",
    ]

    /// Where an administrator's managed settings live; `disableSideloadFlags` there makes the CLI ignore `--plugin-dir` (and
    /// `--mcp-config`).
    public static let managedSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
    /// The MDM profile Claude Code also reads (`com.anthropic.claudecode`).
    public static let managedPreferencesPath = "/Library/Managed Preferences/com.anthropic.claudecode.plist"

    /// The MDM profiles Claude Code reads: the machine's and the user's (fix round 2).
    public static func managedPreferencePaths(user: String = NSUserName()) -> [String] {
        [managedPreferencesPath, "/Library/Managed Preferences/\(user)/com.anthropic.claudecode.plist"]
    }

    /// Runs an executable with arguments and returns its stdout, or nil when it cannot run; throws `ExecTimedOut` when it hangs. Injected by tests.
    public typealias Exec = @Sendable (_ executable: String, _ arguments: [String]) async throws -> String?

    /// `hookExecutable`: the `brahma` the mode-canary's profiles name in their pre-tool hook, as real turns do.
    /// `sandbox`: the sandboxed runner the `plugin-details-inert` fixture (Task 5a) runs the CLI under; without one that item is skipped.
    public static func run(claudePath: String, runner: any TurnRunning, exec: @escaping Exec = defaultExec,
                           now: Date = .now, hookExecutable: String = "brahma",
                           managedSettingsPath: String = Doctor.managedSettingsPath,
                           managedPreferencesPath: String? = nil,
                           sandbox: (any SandboxedRunner)? = nil,
                           canary: (any SandboxCanaryRunning)? = nil, canaryPaths: BrahmaPaths? = nil) async -> DoctorReport {
        let found = await versionOutcome(claudePath: claudePath, exec: exec)
        guard let version = found.version else {
            let detail = found.timedOut?.description ?? "can't run '\(claudePath) --version'; is Claude Code installed?"
            return DoctorReport(cliVersion: nil, items: [DoctorItem(name: "version", status: .fail, detail: detail)], checkedAt: now)
        }
        var items = [versionItem(version)]
        items.append(await flagsItem(claudePath: claudePath, exec: exec))
        let probe = await runProbe(runner: runner)
        items += probe.items
        items.append(toolsItem(probe.tools))
        items.append(sideloadItem(path: managedSettingsPath, preferences: managedPreferencesPath.map { [$0] } ?? managedPreferencePaths()))
        if let sandbox { items.append(await pluginDetailsItem(claudePath: claudePath, sandbox: sandbox)) }
        // The sandbox canary (Task 3): `sandbox-backend`, `sandbox-canary`, `sandbox-helpers`. The doctor only reports them; the
        // engine's per-launch gate records a pass for the shapes its turns use.
        if let canary, let canaryPaths {
            items += await canary.run(paths: canaryPaths, claudePath: claudePath, runner: runner, shape: "doctor")
        }
        var report = DoctorReport(cliVersion: version, items: items, checkedAt: now)
        // The mode-canary: each mode's compiled argv answers control requests with no model call (design §6.4).
        if let canary = await ModeCanary.run(runner: runner, hookExecutable: hookExecutable) {
            report.items.append(canary.item)
            report.builtinAgents = canary.builtinAgents
            report.reportedSubscription = canary.reportedSubscription
            report.subagentGate = SubagentGate.passed(profile: .workspace)
            report.items.append(DoctorItem(name: "subagent-gate", status: .pass, detail: SubagentGate.workspaceDetail))
        }
        return report
    }

    /// Reuses the stored report when it passed, is fresh, and was made by the same CLI version.
    public static func ensure(store: Store, claudePath: String, runner: any TurnRunning,
                              exec: @escaping Exec = defaultExec, now: Date = .now) async -> DoctorReport {
        let version = await cliVersion(claudePath: claudePath, exec: exec)
        if let saved = try? store.latestProbe(), saved.ok, saved.cliVersion == version, version != nil,
           now.timeIntervalSince(saved.checkedAt) < maxAge, now >= saved.checkedAt {
            return saved
        }
        let report = await run(claudePath: claudePath, runner: runner, exec: exec, now: now)
        try? store.saveProbe(report)
        return report
    }

    public static func cliVersion(claudePath: String, exec: @escaping Exec = defaultExec) async -> String? {
        await versionOutcome(claudePath: claudePath, exec: exec).version
    }

    private static func versionOutcome(claudePath: String, exec: Exec) async -> (version: String?, timedOut: ExecTimedOut?) {
        let out: String?
        do { out = try await exec(claudePath, ["--version"]) } catch { return (nil, error as? ExecTimedOut) }
        guard let out, let token = out.split(whereSeparator: \.isWhitespace).first, token.first?.isNumber == true else { return (nil, nil) }
        return (String(token), nil)
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    private static func versionItem(_ v: String) -> DoctorItem {
        switch compare(v, minimumVersion) {
        case ..<0: DoctorItem(name: "version", status: .fail, detail: "\(v) is older than the minimum \(minimumVersion)")
        case 0: DoctorItem(name: "version", status: .pass, detail: v)
        default: DoctorItem(name: "version", status: .warn, detail: "\(v) is newer than the tested \(minimumVersion); the probe below checks it still works")
        }
    }

    static func help(_ text: String, mentions flag: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: flag, range: from..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? " " : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? " " : text[r.upperBound]
            func isName(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" }
            if !isName(before) && !isName(after) { return true }
            from = r.upperBound
        }
        return false
    }

    private static func flagsItem(claudePath: String, exec: Exec) async -> DoctorItem {
        let text: String?
        do { text = try await exec(claudePath, ["--help"]) } catch {
            return DoctorItem(name: "flags", status: .fail, detail: (error as? ExecTimedOut)?.description ?? "can't run '\(claudePath) --help': \(error)")
        }
        guard let text else { return DoctorItem(name: "flags", status: .fail, detail: "can't run '\(claudePath) --help'") }
        let missing = requiredFlags.filter { !help(text, mentions: $0) }
        return missing.isEmpty
            ? DoctorItem(name: "flags", status: .pass, detail: "all \(requiredFlags.count) required flags present")
            : DoctorItem(name: "flags", status: .fail, detail: "missing flag\(missing.count == 1 ? "" : "s"): \(missing.joined(separator: ", "))")
    }

    // MARK: probe

    private struct Outcome {
        var sawInit = false
        /// The init event's `tools`, when it carried them.
        var tools: [String]?
        var result: TurnResult?
        var limit: RateLimitInfo?
        var error: String?
    }

    private static func turn(_ runner: any TurnRunning, _ request: TurnRequest) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                var o = Outcome()
                do {
                    for try await event in runner.run(request) {
                        switch event {
                        case .initialized: o.sawInit = true
                        case .initInfo(let info): o.tools = info.tools
                        case .result(let r): o.result = r
                        case .rateLimit(let i): o.limit = i
                        default: break
                        }
                    }
                } catch {
                    o.error = "\(error)"
                }
                return o
            }
            group.addTask {
                try? await AwakeTime.sleep(for: probeTimeout)
                var o = Outcome()
                o.error = "timed out after \(probeTimeout.components.seconds) s"
                return o
            }
            let first = await group.next() ?? Outcome()
            group.cancelAll()
            return first
        }
    }

    /// `tools-present`: the probe's init `tools` hold every name the Sandboxed profile's `--tools` uses (`BuiltinTools.sandboxed`).
    static func toolsItem(_ tools: [String]?) -> DoctorItem {
        guard let tools, !tools.isEmpty else {
            // Nothing proves the tools are there (fix round 1, M2).
            return DoctorItem(name: "tools-present", status: .fail, detail: "the probe's init event listed no tools; the sandboxed --tools cannot be checked")
        }
        let missing = BuiltinTools.sandboxed.filter { !tools.contains($0) }
        return missing.isEmpty
            ? DoctorItem(name: "tools-present", status: .pass, detail: "every tool the sandboxed profile names is present")
            : DoctorItem(name: "tools-present", status: .fail,
                         detail: "the CLI lacks \(missing.joined(separator: ", ")), which the sandboxed profile's --tools names")
    }

    /// `sideload-allowed`: the managed setting `disableSideloadFlags` is set nowhere Claude Code reads managed settings: the file,
    /// its `managed-settings.d/*.json` drop-ins, the MDM profile (M3). Set, the CLI ignores `--plugin-dir` (extension parts would
    /// silently not load) and `--mcp-config` (every turn would lose its company server). Managed settings that cannot be read
    /// fail: the doctor cannot tell.
    static func sideloadItem(path: String, preferences: [String] = managedPreferencePaths()) -> DoctorItem {
        let name = "sideload-allowed"
        let fm = FileManager.default
        var documents: [(String, [String: Any]?)] = []
        if fm.fileExists(atPath: path) {
            documents.append((path, fm.contents(atPath: path).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }))
        }
        let dropIns = URL(fileURLWithPath: path).deletingLastPathComponent().appending(path: "managed-settings.d")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dropIns.path, isDirectory: &isDir) {
            // A drop-in folder that cannot be listed may hold the setting: the doctor cannot tell.
            guard isDir.boolValue, let names = try? fm.contentsOfDirectory(atPath: dropIns.path) else {
                return DoctorItem(name: name, status: .fail, detail: "can't read the managed settings folder \(dropIns.path)")
            }
            for file in names.sorted() where file.hasSuffix(".json") {
                let p = dropIns.appending(path: file).path
                documents.append((p, fm.contents(atPath: p).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }))
            }
        }
        for preferences in preferences where fm.fileExists(atPath: preferences) {
            documents.append((preferences, fm.contents(atPath: preferences).flatMap {
                (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
            }))
        }
        for (where_, object) in documents {
            guard let object else { return DoctorItem(name: name, status: .fail, detail: "can't read the managed settings at \(where_)") }
            switch object["disableSideloadFlags"] {
            case nil, is NSNull: continue
            case let flag as Bool where flag == false: continue
            default:
                return DoctorItem(name: name, status: .fail,
                                  detail: "managed setting disableSideloadFlags is set in \(where_): --plugin-dir and --mcp-config would be ignored")
            }
        }
        return DoctorItem(name: name, status: .pass, detail: documents.isEmpty ? "no managed settings" : "sideload flags allowed")
    }

    private static func runProbe(runner: any TurnRunning) async -> (items: [DoctorItem], tools: [String]?) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "brahma-doctor-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appending(path: "empty.mcp.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{\"mcpServers\":{}}".utf8).write(to: config)
        } catch {
            return ([DoctorItem(name: "probe", status: .fail, detail: "can't prepare the probe directory: \(error)")], nil)
        }
        let sessionId = UUID().uuidString.lowercased()
        var agent = Agent(id: "doctor-probe", companyId: "doctor", name: "probe", role: "probe", model: "haiku",
                          sessionId: sessionId, sessionStarted: false, state: .running, blocker: nil, requestedBlocker: nil,
                          paused: false, readySince: nil, createdAt: Date())
        let company = Company(id: "doctor", name: "Doctor", slug: "doctor", goal: "probe", workspacePath: dir.path,
                              status: .running, usageMode: .low, priorityWeight: 1, createdAt: Date())
        func request(_ prompt: String) -> TurnRequest {
            TurnRequest(agent: agent, company: company, prompt: prompt, appendSystemPrompt: probePrompt,
                        mcpConfigPath: config.path, workingDirectory: dir.path, profile: .workspace,
                        environment: ["BRAHMA_AGENT_ID": "doctor-probe"])
        }

        let first = await turn(runner, request("Reply with the single word OK."))
        var probe: DoctorItem
        if let e = first.error {
            probe = DoctorItem(name: "probe", status: .fail, detail: "probe turn failed: \(e)")
        } else if !first.sawInit {
            probe = DoctorItem(name: "probe", status: .fail, detail: "no init event; the stream format may have changed")
        } else if let r = first.result {
            if r.isError {
                probe = DoctorItem(name: "probe", status: .fail, detail: "probe turn returned an error: \(r.text ?? r.subtype)")
            } else if !r.hasUsage {
                probe = DoctorItem(name: "probe", status: .fail, detail: "result line has no usage; the stream format may have changed")
            } else if first.limit == nil {
                probe = DoctorItem(name: "probe", status: .warn, detail: "ok, but no rate_limit_event; usage gating has no data")
            } else {
                probe = DoctorItem(name: "probe", status: .pass, detail: "haiku turn answered with init, result and usage")
            }
        } else {
            probe = DoctorItem(name: "probe", status: .fail, detail: "no result line in the probe turn")
        }

        var resume: DoctorItem
        if probe.status == .fail {
            resume = DoctorItem(name: "resume-keeps-role", status: .warn, detail: "skipped; the probe failed")
        } else {
            agent.sessionStarted = true
            let second = await turn(runner, request("Reply with the codeword only."))
            if let e = second.error {
                resume = DoctorItem(name: "resume-keeps-role", status: .fail, detail: "resumed turn failed: \(e)")
            } else if let r = second.result, !r.isError, r.text?.contains(probeCodeword) == true {
                resume = DoctorItem(name: "resume-keeps-role", status: .pass, detail: "the role prompt survived --resume")
            } else {
                resume = DoctorItem(name: "resume-keeps-role", status: .fail,
                                    detail: "resumed turn did not echo the codeword; the appended role prompt is lost on --resume")
            }
        }

        let overage: DoctorItem
        if let l = first.limit {
            if l.isUsingOverage {
                overage = DoctorItem(name: "overage", status: .fail, detail: "the account is spending paid overage right now")
            } else if l.overageStatus == "allowed" {
                overage = DoctorItem(name: "overage", status: .warn, detail: "overage is allowed on this account; the engine gates on it, but check your plan")
            } else {
                overage = DoctorItem(name: "overage", status: .pass, detail: "not using overage")
            }
        } else {
            overage = DoctorItem(name: "overage", status: .warn, detail: "no rate_limit_event to read")
        }
        return ([probe, resume, overage], first.tools)
    }

    // MARK: default exec

    /// The owner's configured plan tier always wins; a CLI that reports a different subscription only earns a WARN
    /// (the CLI's value has been stale). Nil when there is nothing to compare or they agree.
    public static func planTierItem(configured: PlanTier, reported: String?) -> DoctorItem? {
        guard let reported, !reported.isEmpty else { return nil }
        guard let tier = PlanTier(reportedSubscription: reported) else {
            return DoctorItem(name: "plan-tier", status: .warn, detail: "configured \(configured.rawValue); the CLI reports the unknown plan '\(reported)'")
        }
        return tier == configured ? nil
            : DoctorItem(name: "plan-tier", status: .warn,
                         detail: "configured \(configured.rawValue), CLI reports \(tier.rawValue); keeping \(configured.rawValue) (see `brahma settings plan`)")
    }

    /// A doctor command that did not finish within `execTimeout` of awake time; it was killed.
    public struct ExecTimedOut: Error, Sendable, CustomStringConvertible {
        public var command: String
        public var seconds: Int
        public var description: String { "'\(command)' did not finish within \(seconds) s and was killed" }
    }

    /// Awake seconds a `--version` or `--help` run may take. Far above a healthy CLI; a hung one must not hold the doctor.
    public static let execTimeout: TimeInterval = 30
    /// Seconds between SIGTERM and SIGKILL of a timed-out child.
    static let execKillGrace: TimeInterval = 1

    /// The doctor's own blocking threads, apart from any engine's: a default exec has no engine to borrow a `Blocking` from.
    static let execBlocking = Blocking(maxConcurrent: 4)

    public static let defaultExec: Exec = { executable, arguments in
        try await execProcess(executable: executable, arguments: arguments, timeout: execTimeout)
    }

    /// Runs the process on a `Blocking` thread (never a cooperative worker), as its own process group (`GroupExec`). Past
    /// `timeout` awake seconds the group is SIGTERMed, then SIGKILLed, and `ExecTimedOut` is thrown; the output is never
    /// waited on after a kill, so a process holding the pipe cannot hang us.
    static func execProcess(executable: String, arguments: [String], timeout: TimeInterval,
                            blocking: Blocking = Doctor.execBlocking) async throws -> String? {
        let outcome: Result<String?, ExecTimedOut> = await blocking.run {
            let (path, args) = executable.hasPrefix("/") ? (executable, arguments) : ("/usr/bin/env", [executable] + arguments)
            let r = GroupExec.run(executable: path, arguments: args,
                                  environment: ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .claude),
                                  output: .capture(cap: 4 << 20, stderr: false), timeout: timeout, killGrace: execKillGrace)
            guard r.launched else { return .success(nil) }
            if r.timedOut {
                let shown = ([executable] + arguments).joined(separator: " ")
                return .failure(ExecTimedOut(command: shown, seconds: Int(timeout.rounded(.up))))
            }
            return .success(r.status == 0 ? String(decoding: r.output, as: UTF8.self) : nil)
        }
        return try outcome.get()
    }
}

// MARK: Backup items (Task 13b)

extension Doctor {
    /// `backup-targets`: every configured target is reachable (a folder is mounted and writable; an rclone remote exists, is of type
    /// `crypt` and rclone is installed).
    public static func backupTargetsItem(targets: [BackupTarget], tools: BackupTools = .system) -> DoctorItem {
        guard !targets.isEmpty else {
            return DoctorItem(name: "backup-targets", status: .pass, detail: "none configured (see: brahma backup target add)")
        }
        var problems: [String] = []
        for target in targets {
            switch target {
            case .folder(let path):
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
                    problems.append("\(path) is not connected")
                } else if !FileManager.default.isWritableFile(atPath: path) {
                    problems.append("\(path) is not writable")
                }
            case .rclone(let remote):
                guard let rclone = tools.rclone else { problems.append("rclone is not installed (\(remote):)"); continue }
                if !BackupTargets.isCrypt(remote: remote, rclone: rclone, tools: tools) {
                    problems.append("\(remote) is not an rclone crypt remote")
                }
            }
        }
        if problems.isEmpty { return DoctorItem(name: "backup-targets", status: .pass, detail: "\(targets.count) reachable") }
        return DoctorItem(name: "backup-targets", status: .warn, detail: problems.joined(separator: "; "))
    }

    /// The two backup items, off the cooperative pool (they run child processes).
    public static func backupItems(store: Store, tools: BackupTools = .system, now: Date = .now) async -> [DoctorItem] {
        let targets = (try? store.backupTargets()) ?? []
        let replica = (try? store.walShipping())?.replica
        return await execBlocking.run {
            [WALShipping.doctorItem(replica: replica, tools: tools, now: now), backupTargetsItem(targets: targets, tools: tools)]
        }
    }
}
