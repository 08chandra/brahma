import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The soak harness end to end (Plan X6a Task 7, rulings R8/R40): the built `brahma run` with a fake `claude` on its PATH (a
/// shell script that answers `--version` and otherwise starts a turn and sleeps: no model, no usage), killed with SIGKILL
/// mid-turn, started again, and `brahma measure --soak-verify` over the checkpoint taken before the kill. Every process this
/// test signals is one it started, by pid; the engine is stopped with SIGTERM to its pid, never `brahma stop`.
///
/// The data home sits under a short root in `/tmp` (the engine's run files and sockets live under it); the test removes it.
@Suite(.scratch, .serialized) struct SoakHarnessProcessTests {
    /// Stands in for `claude`: `--version` answers; a turn prints the stream's init line and sleeps until the engine ends it.
    static let fakeClaude = """
        #!/bin/sh
        for a in "$@"; do case "$a" in --version) echo "2.1.0 (Claude Code)"; exit 0;; esac; done
        cat > /dev/null &
        echo '{"type":"system","subtype":"init","session_id":"5a0c0de0-0000-4000-8000-000000000001","model":"claude-fake","tools":["Bash"]}'
        exec sleep 600
        """

    /// A data home of its own under `/tmp` (short paths), the owner key made, removed at the end.
    final class ShortHome {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: "/tmp/bsoak-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            try BrahmaPaths.ensurePrivateDirectory(url)
            try #require(try initOwnerKey(home: url) == 0, "brahma owner init failed under script")
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// The built `brahma` with the test home's file stores; `bin` (the fake `claude`) first on PATH.
    static func brahma(_ args: [String], home: URL, bin: URL? = nil, env: [String: String] = [:]) throws
        -> (status: Int32, stdout: String, stderr: String) {
        let url = brahmaExecutableURL()
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
        let p = Process()
        p.executableURL = url
        p.arguments = args
        var e = cliEnvironment(home: home)
        if let bin { e["PATH"] = "\(bin.path):/usr/bin:/bin" }
        e.merge(env) { _, new in new }
        p.environment = e
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
    }

    /// `brahma run --skip-doctor` as its own process group, output to `log`; the fake `claude` first on PATH.
    static func startEngine(home: URL, bin: URL, log: URL) throws -> ProcessGroupChild {
        var e = cliEnvironment(home: home)
        e["PATH"] = "\(bin.path):/usr/bin:/bin"
        let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        try #require(fd >= 0, "cannot open \(log.path)")
        defer { close(fd) }
        return try ProcessGroupChild.spawn(executable: brahmaExecutableURL().path, arguments: ["brahma", "run", "--skip-doctor"],
                                           environment: e, workingDirectory: home, output: fd)
    }

    /// The engine's start as the soak reads it (ruling R16): the sentinel's modification time.
    static func sentinelTime(_ paths: BrahmaPaths) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: paths.sentinel.path)[.modificationDate] as? Date)
    }

    /// Polls `condition` every 200 ms for up to `seconds` awake seconds.
    static func waitFor(_ seconds: TimeInterval, _ condition: () throws -> Bool) rethrows -> Bool {
        let until = AwakeTime.uptime() + seconds
        while AwakeTime.uptime() < until {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return try condition()
    }

    @Test func killNineThenRecover() throws {
        let home = try ShortHome()
        let bin = try FakeTools.bin(["claude": Self.fakeClaude])
        let made = try Self.brahma(["company", "create", "Acme", "--goal", "soak"], home: home.url)
        try #require(made.status == 0, "\(made.stderr)")
        try #require(try Self.brahma(["company", "profile", "Acme", "workspace"], home: home.url).status == 0)
        let paths = ownerPaths(home.url)
        let store = try Store(path: paths.database.path)
        let company = try #require(try store.companies().first)
        let eng = try #require(try store.agents(companyId: company.id).first { $0.name == "eng-1" })
        // ACME-1 claimed by eng-1 with a commit on its branch: the lease and the commit the soak must keep.
        let item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Soak item", checkSpec: CheckSpec(command: "true"), tier: .m, status: .ready))
        _ = try store.claimLease(itemId: item.id, agentId: eng.id)
        let ws = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        let head = try ws.plantCommit(parent: try ws.git(["rev-parse", "refs/heads/main"]), path: "soak.txt", text: "soak\n",
                                      message: "soak work")
        try ws.git(["update-ref", "refs/heads/item/\(item.key)", head])

        let state = home.url.appending(path: "state", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let checkpoint = state.appending(path: "h24.json")
        let log = state.appending(path: "engine.log")
        func runningTurns() throws -> [Turn] {
            try store.writer.read { db in try Turn.filter(Column("companyId") == company.id && Column("outcome") == TurnOutcome.inProgress.rawValue).fetchAll(db) }
        }

        // 1. The engine runs a turn (the owner's DM wakes the CEO).
        let first = try Self.startEngine(home: home.url, bin: bin, log: log)
        var engines = [first]
        defer {
            // Whatever happens, every engine this test started is ended (its own group only) and reaped.
            for engine in engines where !engine.hasExited() { _ = kill(engine.pid, SIGTERM) }
            for engine in engines {
                _ = Self.waitFor(30) { engine.hasExited() }
                if !engine.hasExited() { engine.signalGroup(SIGKILL) }
                engine.finish()
            }
        }
        try #require(try Self.brahma(["say", "Acme", "@ceo", "start the soak"], home: home.url).status == 0)
        try #require(try Self.waitFor(60) { try !runningTurns().isEmpty }, "no turn started: \((try? String(contentsOf: log, encoding: .utf8)) ?? "")")

        // 2. The checkpoint, while it runs.
        let cp = try Self.brahma(["measure", "Acme", "--soak-checkpoint", checkpoint.path], home: home.url)
        try #require(cp.status == 0, "\(cp.stderr)")
        let before = try SoakCheckpoint.read(from: checkpoint)
        #expect(before.leases[item.key] == eng.id)
        #expect(before.itemHeads[item.key] == head)
        #expect(!before.runningTurns.isEmpty)
        #expect(before.engineStartedAt != nil, "the engine holds the lock: its start is recorded")
        let killedTurns = Set(before.runningTurns)

        // 3. SIGKILL to that pid only: a crash. Its turn's processes are left behind (they run in their own sessions).
        try #require(kill(first.pid, SIGKILL) == 0)
        _ = first.waitForExit()
        // With no engine alive the verdict is `wait` (exit 3), never a pass or a fail.
        let dead = try Self.brahma(["measure", "Acme", "--soak-verify", checkpoint.path], home: home.url)
        #expect(dead.status == 3, "\(dead.stdout) \(dead.stderr)")
        #expect(dead.stdout.contains("wait settled"), "\(dead.stdout)")

        // 4. Started again: its start reaps what the killed engine left, records the turns interrupted, and runs again.
        let firstStart = try Self.sentinelTime(paths)
        let second = try Self.startEngine(home: home.url, bin: bin, log: log)
        engines.append(second)
        try #require(try Self.waitFor(30) { try Self.sentinelTime(paths) > firstStart }, "the restarted engine never started")
        let restarted = try Self.sentinelTime(paths)
        try #require(try Self.waitFor(60) {
            try runningTurns().contains { !killedTurns.contains($0.id) && $0.startedAt >= restarted.addingTimeInterval(-1) }
        }, "no turn after the restart: \((try? String(contentsOf: log, encoding: .utf8)) ?? "")")

        // 5. After settle (lowered for the test through the DEBUG-only override): every check passes.
        var verdict: (status: Int32, stdout: String, stderr: String) = (3, "", "")
        _ = try Self.waitFor(60) {
            verdict = try Self.brahma(["measure", "Acme", "--soak-verify", checkpoint.path], home: home.url,
                                      env: ["BRAHMA_SOAK_SETTLE_SECONDS": "2"])
            return verdict.status != 3
        }
        #expect(verdict.status == 0, "\(verdict.stdout) \(verdict.stderr)\n\((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
        for name in SoakVerify.checkNames { #expect(verdict.stdout.contains("pass \(name):"), "\(name): \(verdict.stdout)") }
        let json = try Self.brahma(["measure", "Acme", "--soak-verify", checkpoint.path, "--format", "json"], home: home.url,
                                   env: ["BRAHMA_SOAK_SETTLE_SECONDS": "2"])
        let decoded = try SoakVerdict.decode(Data(json.stdout.utf8))
        #expect(decoded.result == .pass && decoded.checks.count == SoakVerify.checkNames.count, "\(json.stdout)")
        // The killed engine's turns were recorded as ended, and their processes are gone.
        let ended = try store.writer.read { db in
            try Turn.filter(keys: Array(killedTurns)).fetchAll(db)
        }
        #expect(ended.count == killedTurns.count && ended.allSatisfy { $0.outcome == .interrupted }, "\(ended.map(\.outcome))")

        // 6. Stopped with SIGTERM to its pid (the owner's Ctrl-C), never `brahma stop`.
        try #require(kill(second.pid, SIGTERM) == 0)
        #expect(Self.waitFor(60) { second.hasExited() }, "brahma run did not stop on SIGTERM")
        #expect(try runningTurns().isEmpty, "a turn is still recorded in progress after the stop")
        for pid in try store.writer.read({ db in try Int32.fetchAll(db, sql: "SELECT pid FROM turn WHERE companyId = ? AND pid IS NOT NULL", arguments: [company.id]) }) {
            #expect(kill(pid, 0) != 0, "turn process \(pid) outlived the engine")
        }
    }

    /// The owner's 72-hour script spends real usage: without `BRAHMA_LIVE=1` it refuses, says why, and starts nothing (its
    /// state directory is never made).
    @Test func scriptRefusesWithoutLive() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appending(path: "scripts/soak/run-72h.sh")
        try #require(FileManager.default.isExecutableFile(atPath: script.path), "scripts/soak/run-72h.sh is missing or not executable")
        let state = try tempDir().appending(path: "soak-state", directoryHint: .isDirectory)
        let p = Process()
        p.executableURL = script
        p.arguments = ["Acme", "--hours", "1", "--state", state.path]
        // No brahma on PATH and no BRAHMA_LIVE: nothing could start even if the refusal were missing.
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": try tempDir().path]
        let err = Pipe(), out = Pipe()
        p.standardError = err; p.standardOutput = out; p.standardInput = FileHandle.nullDevice
        try p.run()
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        _ = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 3, "\(e)")
        #expect(e.contains("BRAHMA_LIVE=1") && e.contains("usage"), "\(e)")
        #expect(!FileManager.default.fileExists(atPath: state.path), "the refused script made its state directory")
    }
}
