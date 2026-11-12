import Testing
import Foundation
@testable import BrahmaCore

// The owner-written canary probe file and the two canary layers. Every probe line here is a benign fake that lives only in
// the test target: each is expected to be DENIED (or, on purpose, to succeed or print the dummy token, proving the canary
// then fails). Nothing here runs a model.

/// A sandboxed runner that runs nothing: it answers each command the way a sandbox would, by `behave`. The model-free layer's
/// probe arrives in `SandboxCanary.probeVariable`; `sandbox-backend`'s `/bin/cat '<path>'` reads only its own control file.
private final class FakeSandbox: SandboxedRunner, @unchecked Sendable {
    typealias Behave = @Sendable (_ probe: String, _ env: [String: String], _ cwd: URL) -> CheckOutcome
    private let lock = NSLock()
    private var _probes: [String] = []
    let behave: Behave

    init(behave: @escaping Behave = FakeSandbox.denyAll) { self.behave = behave }
    var probes: [String] { lock.withLock { _probes } }

    /// The positive control reads its file; every other probe is denied.
    static let denyAll: Behave = { probe, _, cwd in
        if probe == SandboxCanary.controlCommand { return control(cwd) }
        return CheckOutcome(exitCode: 1, timedOut: false, tail: "cat: x: Operation not permitted")
    }

    static func control(_ cwd: URL) -> CheckOutcome {
        let text = (try? String(contentsOf: cwd.appending(path: "own.txt"), encoding: .utf8)) ?? ""
        return CheckOutcome(exitCode: text.isEmpty ? 1 : 0, timedOut: false, tail: text)
    }

    func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
             policy: SandboxPolicy) async -> CheckOutcome {
        let out: CheckOutcome
        if let probe = environment[SandboxCanary.probeVariable] {
            lock.withLock { _probes.append(probe) }
            out = behave(probe, environment, cwd)
        } else if command.hasPrefix("/bin/cat '"), command.contains("control.txt") {
            let path = String(command.dropFirst("/bin/cat '".count).dropLast())
            out = CheckOutcome(exitCode: 0, timedOut: false, tail: (try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        } else {
            out = CheckOutcome(exitCode: 1, timedOut: false, tail: "Operation not permitted")
        }
        try? Data(out.tail.utf8).write(to: outputURL)
        return out
    }

    func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        throw SandboxError.unavailable
    }
}

/// How the fake model's turn goes: which commands it skips, what each tool result says, the init tools, whether Read is denied.
private struct TurnPlay: Sendable {
    var skip: Set<String> = []
    var result: @Sendable (_ command: String, _ request: TurnRequest) -> (isError: Bool, text: String) = TurnPlay.denied
    var tools: [String]? = nil
    var readDenied = true
    var extraLines: @Sendable (TurnRequest) -> [String] = { _ in [] }

    static let denied: @Sendable (String, TurnRequest) -> (isError: Bool, text: String) = { command, request in
        if command == SandboxCanary.controlCommand {
            let text = (try? String(contentsOfFile: request.workingDirectory + "/own.txt", encoding: .utf8)) ?? ""
            return (false, text)
        }
        return (true, "Exit code 1\ncat: x: Operation not permitted")
    }
}

private func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

/// The raw stream-json lines of a canary turn as the CLI would emit them: init, one Bash tool_use and tool_result per numbered
/// command of the prompt, the Read of the home token, the result with its permission denials.
private func streamLines(_ request: TurnRequest, _ play: TurnPlay) -> [String] {
    let tools = play.tools ?? (TurnProfileCompiler.profile(for: request).tools ?? [])
    var lines = [json(["type": "system", "subtype": "init", "session_id": request.agent.sessionId, "model": "haiku", "tools": tools])]
    let commands = request.prompt.split(separator: "\n").compactMap { line -> String? in
        guard let r = line.range(of: "^[0-9]+\\. ", options: .regularExpression) else { return nil }
        return String(line[r.upperBound...])
    }
    for (i, command) in commands.enumerated() where !play.skip.contains(command) {
        let id = "toolu_\(i)"
        lines.append(json(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": "Bash",
                                                                         "input": ["command": command]]]]]))
        let r = play.result(command, request)
        lines.append(json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": r.isError,
                                                                    "content": r.text]]]]))
    }
    let home = request.environment[CanaryProbes.homeFileVariable] ?? ""
    lines.append(json(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "toolu_read", "name": "Read",
                                                                     "input": ["file_path": home]]]]]))
    lines.append(json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_read", "is_error": true,
                                                                "content": "Permission denied"]]]]))
    lines += play.extraLines(request)
    let denials: [[String: Any]] = play.readDenied ? [["tool_name": "Read", "tool_use_id": "toolu_read"]] : []
    lines.append(json(["type": "result", "subtype": "success", "is_error": false, "result": "DONE", "session_id": request.agent.sessionId,
                       "permission_denials": denials]))
    return lines
}

private func canaryRunner(_ play: TurnPlay = TurnPlay()) -> FakeTurnRunner {
    let runner = FakeTurnRunner()
    runner.defaultScript = FakeTurnRunner.Script(make: { request in streamLines(request, play).map { StreamEvent.raw($0) } })
    return runner
}

/// A data home, a workspaces root and a stand-in owner's home in one temp dir; a fake `claude` to fingerprint.
private struct CanaryWorld {
    let paths: BrahmaPaths
    let userHome: URL
    let claude: URL

    init() throws {
        let root = try tempDir()
        paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        userHome = root.appending(path: "user")
        for dir in [paths.home, paths.workspaces, userHome] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        claude = try FakeTools.script("claude", "# SandboxCanaryProbeTests fingerprint fixture\nexit 0")
    }

    var env: SandboxEnvironment { SandboxEnvironment(userHome: userHome, darwinUserTemp: nil, shell: "/bin/zsh") }
    var probesURL: URL { CanaryProbes.url(paths: paths) }

    /// Writes the probe file as the owner would (0600 in a 0700 `canary` directory).
    func writeProbes(_ text: String, mode: mode_t = 0o600) throws {
        try BrahmaPaths.ensurePrivateDirectory(probesURL.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: probesURL)
        try Data(text.utf8).write(to: probesURL)
        #expect(chmod(probesURL.path, mode) == 0)
    }

    func canary(local: FakeSandbox = FakeSandbox()) -> SandboxCanary {
        SandboxCanary(environment: env, sandbox: FakeSandbox(), hookExecutable: "/usr/local/bin/brahma", localRunner: { _ in local })
    }

    func run(_ canary: SandboxCanary, runner: FakeTurnRunner = canaryRunner()) async -> CanaryRun {
        await canary.run(paths: paths, claudePath: claude.path, runner: runner,
                         key: SandboxCanaryKey(fingerprint: "asked", shape: "s", osVersion: "o"), settings: nil)
    }

    func item(_ run: CanaryRun, _ name: String) throws -> DoctorItem { try #require(run.items.first { $0.name == name }) }

    func leftovers() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: paths.workspaces.path)) ?? []).filter { $0.hasPrefix(".brahma-canary") } }
}

/// Three benign probes, each expected to be denied.
private let deniedProbes = """
    # owner probes (test fixture)
    cat "$CANARY_HOME_FILE"

    cat "$CANARY_DATA_FILE"
    echo x > "$CANARY_OUTSIDE_DIR/x"
    cat "$OTHER_AGENT_LAB/token"
    """

@Suite(.scratch, .serialized) struct SandboxCanaryProbeTests {
    // MARK: The probe file

    @Test func parseKeepsLineNumbersAndHelperMarks() {
        let probes = CanaryProbes.parse("# c\n\n  cat \"$CANARY_HOME_FILE\"  \r\npbpaste # helper\necho a#helper\n   # indented comment\n")
        #expect(probes == [CanaryProbe(line: 3, text: "cat \"$CANARY_HOME_FILE\""), CanaryProbe(line: 4, text: "pbpaste", helper: true),
                           CanaryProbe(line: 5, text: "echo a#helper")])
    }

    @Test func missingFileIsRefused() throws {
        let w = try CanaryWorld()
        #expect(CanaryProbes.load(paths: w.paths) == .failure(.missing(path: w.probesURL.path)))
        #expect(CanaryProbes.digest(paths: w.paths) == CanaryProbes.unavailableDigest)
    }

    @Test func templateHoldsNoProbeLines() throws {
        let w = try CanaryWorld()
        let made = try CanaryProbes.ensureTemplate(paths: w.paths)
        #expect(made.created)
        #expect(try String(contentsOf: made.url, encoding: .utf8) == CanaryProbes.template)
        #expect(CanaryProbes.parse(CanaryProbes.template).isEmpty)
        for line in CanaryProbes.template.split(separator: "\n") { #expect(line.hasPrefix("#"), "\(line)") }
        for name in CanaryProbes.variables { #expect(CanaryProbes.template.contains(name)) }
        var st = stat()
        #expect(lstat(made.url.path, &st) == 0); #expect(st.st_mode & 0o7777 == 0o600)
        #expect(lstat(made.url.deletingLastPathComponent().path, &st) == 0); #expect(st.st_mode & 0o7777 == 0o700)
        #expect(CanaryProbes.load(paths: w.paths) == .failure(.noProbes(path: made.url.path)))
        // An existing file is never overwritten.
        try w.writeProbes(deniedProbes)
        #expect(try CanaryProbes.ensureTemplate(paths: w.paths).created == false)
        #expect(try String(contentsOf: w.probesURL, encoding: .utf8) == deniedProbes)
        // Only helper lines: still no blocking probe.
        try w.writeProbes("pbpaste # helper\n")
        #expect(CanaryProbes.load(paths: w.paths) == .failure(.noProbes(path: w.probesURL.path)))
    }

    @Test func badPermissionsAreRefused() throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes, mode: 0o644)
        guard case .failure(.refused(_, let problem)) = CanaryProbes.load(paths: w.paths) else { Issue.record("0644 loaded"); return }
        #expect(problem.contains("mode 644"))
        // A symbolic link to a valid file.
        let real = w.paths.home.appending(path: "real-probes.txt")
        try Data(deniedProbes.utf8).write(to: real); chmod(real.path, 0o600)
        try FileManager.default.removeItem(at: w.probesURL)
        try FileManager.default.createSymbolicLink(at: w.probesURL, withDestinationURL: real)
        guard case .failure(.refused(_, let symlinked)) = CanaryProbes.load(paths: w.paths) else { Issue.record("a link loaded"); return }
        #expect(symlinked.contains("symbolic link"))
        // A second hard link.
        try FileManager.default.removeItem(at: w.probesURL)
        #expect(link(real.path, w.probesURL.path) == 0)
        guard case .failure(.refused(_, let hard)) = CanaryProbes.load(paths: w.paths) else { Issue.record("nlink 2 loaded"); return }
        #expect(hard.contains("another hard link"))
        // Another owner (checked on the descriptor's stat).
        var st = stat()
        #expect(lstat(real.path, &st) == 0)
        st.st_nlink = 1
        #expect(CanaryProbes.fileProblem(st) == nil)
        st.st_uid = getuid() &+ 1
        #expect(CanaryProbes.fileProblem(st)?.contains("another user") == true)
        // The 0600 regular file loads, with its SHA-256.
        try FileManager.default.removeItem(at: w.probesURL)
        try w.writeProbes(deniedProbes)
        let file = try CanaryProbes.load(paths: w.paths).get()
        #expect(file.probes.map(\.line) == [2, 4, 5, 6])
        #expect(file.sha256 == SHA256.hex(Data(deniedProbes.utf8)))
    }

    // MARK: Both layers

    @Test func allProbesDeniedInBothLayersPasses() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes)
        let local = FakeSandbox()
        let runner = canaryRunner()
        let run = await w.run(w.canary(local: local), runner: runner)
        let verified = try #require(run.verified)
        #expect(run.passes(verified), "\(run.items)")
        for name in ["sandbox-backend", "sandbox-canary-local", "sandbox-canary", "sandbox-helpers"] {
            let item = try w.item(run, name)
            #expect(item.status == .pass, "\(name): \(item.detail)")
        }
        #expect(try w.item(run, "sandbox-helpers").detail == "no helper probes")
        // The key carries the probe file's hash, computed as the gate computes it.
        let cli = try CLIFingerprint.of(claudePath: w.claude.path).key
        #expect(verified.fingerprint == CanaryProbes.keyFingerprint(cli: cli, probes: SHA256.hex(Data(deniedProbes.utf8))))
        #expect(verified.fingerprint == CanaryProbes.keyFingerprint(cli: cli, probes: CanaryProbes.digest(paths: w.paths)))
        // The control first, then every probe, through the prefix (never spliced: the probe travels in its variable).
        #expect(local.probes == [SandboxCanary.controlCommand] + CanaryProbes.parse(deniedProbes).map(\.text))
        #expect(run.probes.filter { $0.layer == .local }.count == 4); #expect(run.probes.filter { $0.layer == .turn }.count == 4)
        // The turn: the real compiled request, the four variables in its environment, a plainly worded self-test prompt.
        let request = try #require(runner.requests.first)
        #expect(runner.requests.count == 1)
        #expect(request.agent.model == "haiku"); #expect(request.profile == .sandboxed); #expect(request.emitRawLines)
        for name in CanaryProbes.variables { #expect(request.environment[name] != nil, "\(name)") }
        #expect(request.prompt.contains("sandbox self-test")); #expect(request.prompt.contains("expected to be DENIED"))
        #expect(request.prompt.contains("Read tool once on this file: \(request.environment[CanaryProbes.homeFileVariable] ?? "?")"))
        let profile = TurnProfileCompiler.profile(for: request)
        #expect(profile.maxBudgetUSD.map { $0 <= SandboxCanary.turnBudgetUSD } == true)
        #expect(profile.wallClock != nil)
        let childEnv = ChildEnvironment.make(base: [:], extra: profile.environment, engineClaudeVars: profile.environment, purpose: .claude)
        for name in CanaryProbes.variables { #expect(childEnv[name] == request.environment[name], "\(name) reaches the turn") }
        // The row a pass records names line, verdict, exit status and leak per probe, never output.
        let store = try Store.inMemory()
        try store.recordCanary(verified, detail: run.detail)
        #expect(try store.sandboxVerified(verified))
        let detail = try #require(try await store.writer.read { db in try String.fetchOne(db, sql: "SELECT detail FROM sandboxCanary") })
        #expect(detail.contains("line 2: pass, exit 1, leaked false"))
        #expect(!detail.contains("Operation not permitted"))
        #expect(w.leftovers().isEmpty, "\(w.leftovers())")
    }

    @Test func missingFileBlocksAndRunsNoTurn() async throws {
        let w = try CanaryWorld()
        let runner = canaryRunner()
        let run = await w.run(w.canary(), runner: runner)
        #expect(run.verified.map { !run.passes($0) } ?? true)
        // Not written yet: a warning (the doctor stays usable), never a pass.
        #expect(try w.item(run, "sandbox-canary-local").status == .warn)
        #expect(try w.item(run, "sandbox-canary-local").detail.hasPrefix("missing probe file"))
        #expect(try w.item(run, "sandbox-canary").status == .warn)
        #expect(runner.requests.isEmpty, "no model turn without a probe file")
        #expect(w.leftovers().isEmpty)
    }

    @Test func templateOnlyBlocks() async throws {
        let w = try CanaryWorld()
        try CanaryProbes.ensureTemplate(paths: w.paths)
        let run = await w.run(w.canary())
        #expect(run.verified.map { !run.passes($0) } ?? true)
        #expect(try w.item(run, "sandbox-canary-local").detail.hasPrefix("no probes in"))
    }

    @Test func aRefusedProbeFileFails() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes, mode: 0o644)
        let runner = canaryRunner()
        let run = await w.run(w.canary(), runner: runner)
        #expect(run.verified.map { !run.passes($0) } ?? true)
        let item = try w.item(run, "sandbox-canary-local")
        #expect(item.status == .fail); #expect(item.detail.hasPrefix("probe file refused"))
        #expect(runner.requests.isEmpty)
    }

    @Test func aSucceedingProbeBlocksNamingItsLine() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes + "\ntrue\n")
        let local = FakeSandbox { probe, env, cwd in
            if probe == "true" { return CheckOutcome(exitCode: 0, timedOut: false, tail: "") }
            return FakeSandbox.denyAll(probe, env, cwd)
        }
        let runner = canaryRunner()
        let run = await w.run(w.canary(local: local), runner: runner)
        #expect(!run.passes(try #require(run.verified)))
        let item = try w.item(run, "sandbox-canary-local")
        #expect(item.status == .fail); #expect(item.detail.hasPrefix("probe line 7 failed"), "\(item.detail)")
        #expect(item.detail.contains("line 7: FAIL, exit 0, leaked false"))
        #expect(runner.requests.isEmpty, "the turn runs only after the model-free layer passed")
    }

    @Test func aLeakingProbeBlocksAndItsOutputIsRedacted() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes + "\necho leak\n")
        // The fake sandbox "fails" to deny one probe: it prints the planted token, then exits non-zero.
        let local = FakeSandbox { probe, env, cwd in
            if probe == "echo leak" {
                let token = (try? String(contentsOfFile: env[CanaryProbes.homeFileVariable] ?? "", encoding: .utf8)) ?? ""
                return CheckOutcome(exitCode: 1, timedOut: false, tail: "here: \(token)")
            }
            return FakeSandbox.denyAll(probe, env, cwd)
        }
        let run = await w.run(w.canary(local: local))
        #expect(!run.passes(try #require(run.verified)))
        let item = try w.item(run, "sandbox-canary-local")
        #expect(item.detail.hasPrefix("probe line 7 leaked a canary token"), "\(item.detail)")
        let leaked = try #require(run.probes.first { $0.line == 7 })
        #expect(leaked.leaked); #expect(!leaked.output.contains("BRAHMA-CANARY-"))
        #expect(leaked.output.contains(SandboxCanary.redactedToken))
        // What `brahma canary run` prints: the redacted output, never the token.
        let printed = CanaryReport.lines(run, redact: { $0 }).joined(separator: "\n")
        #expect(printed.contains("LEAKED A TOKEN")); #expect(printed.contains("echo leak"))
        #expect(printed.contains(SandboxCanary.redactedToken)); #expect(!printed.contains("BRAHMA-CANARY-"))
        #expect(CanaryReport.lines(run, redact: { _ in nil }).joined().contains("output withheld"))
        #expect(!run.detail.contains("here:"), "the row never holds output")
    }

    @Test func aFailingPositiveControlBlocks() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes)
        // A runner that runs nothing: every command "fails", so every probe would look denied.
        let local = FakeSandbox { _, _, _ in CheckOutcome(exitCode: 1, timedOut: false, tail: "") }
        let run = await w.run(w.canary(local: local))
        #expect(!run.passes(try #require(run.verified)))
        #expect(try w.item(run, "sandbox-canary-local").detail.hasPrefix("the positive control"))
    }

    @Test func aProbeTheModelNeverRanBlocks() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes)
        let run = await w.run(w.canary(), runner: canaryRunner(TurnPlay(skip: ["cat \"$CANARY_DATA_FILE\""])))
        #expect(!run.passes(try #require(run.verified)))
        let item = try w.item(run, "sandbox-canary")
        #expect(item.status == .fail); #expect(item.detail.hasPrefix("probe line 4 was not run (unverified)"), "\(item.detail)")
        #expect(try w.item(run, "sandbox-canary-local").status == .pass)
    }

    @Test func aProbeTheTurnRanSuccessfullyBlocks() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes)
        let play = TurnPlay(result: { command, request in
            command == "cat \"$OTHER_AGENT_LAB/token\"" ? (false, "nothing here") : TurnPlay.denied(command, request)
        })
        let run = await w.run(w.canary(), runner: canaryRunner(play))
        #expect(try w.item(run, "sandbox-canary").detail.hasPrefix("probe line 6 failed"))
        #expect(!run.passes(try #require(run.verified)))
    }

    @Test func readNotDeniedBlocks() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes)
        let run = await w.run(w.canary(), runner: canaryRunner(TurnPlay(readDenied: false)))
        #expect(!run.passes(try #require(run.verified)))
        #expect(try w.item(run, "sandbox-canary").detail.hasPrefix("Read was not denied"))
    }

    /// The init tools are judged by the subset rule: a tool beyond the shape's list (an extra capability) blocks.
    @Test func anExtraInitToolBlocks() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes)
        let run = await w.run(w.canary(), runner: canaryRunner(TurnPlay(tools: BuiltinTools.sandboxed + ["Task"])))
        #expect(!run.passes(try #require(run.verified)))
        let detail = try w.item(run, "sandbox-canary").detail
        #expect(detail.hasPrefix("the init tools hold tools the shape does not allow (extra: Task)"), "\(detail)")
    }

    /// An expected tool the session lacks (2.1.322 lists no `Skill` when no skill loads) is noted, never a failure.
    @Test func aMissingExpectedInitToolPassesWithANote() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes)
        let run = await w.run(w.canary(), runner: canaryRunner(TurnPlay(tools: BuiltinTools.sandboxed.filter { $0 != "Skill" })))
        let item = try w.item(run, "sandbox-canary")
        #expect(item.status == .pass, "\(item.detail)")
        #expect(item.detail.contains("info: expected tools absent from the init list: Skill"))
        #expect(run.passes(try #require(run.verified)))
    }

    @Test func aTokenAnywhereInTheStreamBlocks() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes)
        let play = TurnPlay(extraLines: { request in
            let token = (try? String(contentsOfFile: request.environment[CanaryProbes.dataFileVariable] ?? "", encoding: .utf8)) ?? "?"
            return [json(["type": "assistant", "message": ["content": [["type": "text", "text": "I found \(token)"]]]])]
        })
        let run = await w.run(w.canary(), runner: canaryRunner(play))
        #expect(!run.passes(try #require(run.verified)))
        #expect(try w.item(run, "sandbox-canary").detail.hasPrefix("a canary token appeared in 1 stream line(s) (leak)"))
    }

    @Test func aSucceedingHelperProbeWarnsButPasses() async throws {
        let w = try CanaryWorld()
        try w.writeProbes(deniedProbes + "\npbpaste # helper\n")
        let local = FakeSandbox { probe, env, cwd in
            probe == "pbpaste" ? CheckOutcome(exitCode: 0, timedOut: false, tail: "clipboard") : FakeSandbox.denyAll(probe, env, cwd)
        }
        let play = TurnPlay(result: { command, request in command == "pbpaste" ? (false, "clipboard") : TurnPlay.denied(command, request) })
        let run = await w.run(w.canary(local: local), runner: canaryRunner(play))
        let helpers = try w.item(run, "sandbox-helpers")
        #expect(helpers.status == .warn)
        #expect(helpers.detail.contains("line 7 (model-free)")); #expect(helpers.detail.contains("line 7 (turn)"))
        #expect(try w.item(run, "sandbox-canary-local").status == .pass)
        #expect(try w.item(run, "sandbox-canary").status == .pass)
        #expect(run.passes(try #require(run.verified)), "a helper warning never blocks the canary")
    }

    /// The model-free layer under the real Seatbelt runner: the planted places are denied through the agent's own shell
    /// prefix, the positive control runs, and a probe that succeeds fails the canary. No model.
    @Test(.enabled(if: Toolchain.seatbeltAvailable, "no /usr/bin/sandbox-exec"))
    func modelFreeLayerUnderSeatbelt() async throws {
        let root = try Scratch.homeDir().resolvedForSandbox
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let userHome = root.appending(path: "user")
        for dir in [paths.home, paths.workspaces, userHome] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // As the owner's environment has it: the per-user Darwin temp dir (the scope then reads its toolchain entries).
        let env = SandboxEnvironment(userHome: userHome, darwinUserTemp: SandboxEnvironment.current.darwinUserTemp, shell: "/bin/zsh")
        let p = try SandboxCanary.prepare(paths: paths, environment: env, hookExecutable: "/usr/local/bin/brahma")
        defer { p.cleanup() }
        let places = SandboxCanary.LocalPlaces(paths: paths, workspace: URL(fileURLWithPath: p.request.company.workspacePath),
                                               otherWorkspaces: [p.otherCompany], userHome: userHome)
        let runner = SandboxCanary.platformLocalRunner(baseline: nil, places: places)
        let probes = CanaryProbes.parse(deniedProbes + "\ntrue\n")
        let file = CanaryProbeFile(path: "probes.txt", probes: probes, sha256: "x")
        let a = await SandboxCanary.localLayer(p, file: file, runner: runner, timeout: .seconds(20))
        #expect(a.item.status == .fail)
        #expect(a.item.detail.hasPrefix("probe line 7 failed"), "\(a.item.detail)")
        for r in a.results where r.text != "true" {
            #expect(r.passed, "\(r.summary): \(r.output)")
        }
        #expect(a.results.first { $0.text == "true" }?.exitStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: p.otherCompany.appending(path: "x").path), "the write outside was denied")
        #expect(!a.results.contains { $0.leaked })
    }
}
