import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// The supervision helpers, with real processes (FakeSandbox: unsandboxed, its own process group).
@Suite(.scratch) struct PreviewSupervisionTests {
    static let policy = SandboxPolicy(writable: [URL(fileURLWithPath: "/nowhere")], readable: [], network: .none, toolchain: false)

    /// The pids whose process group is `pgid` (`ps`, the whole table).
    static func members(of pgid: Int32) throws -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "pid=,pgid="]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count == 2, let pid = Int32(cols[0]), let group = Int32(cols[1]), group == pgid else { return nil }
            return pid
        }
    }

    static func waitUntil(_ timeout: Duration, _ condition: () throws -> Bool) async rethrows -> Bool {
        let deadline = AwakeTime.deadline(after: timeout)
        while AwakeTime.now < deadline {
            if try condition() { return true }
            try? await AwakeTime.sleep(for: .milliseconds(50))
        }
        return try condition()
    }

    @Test func stopKillsProcessGroup() async throws {
        let dir = try tempDir()
        let sandbox = FakeSandbox()
        let log = dir.appending(path: "logs/web.log")
        let process = try sandbox.spawn(command: "sleep 300 & sleep 300 & wait", cwd: dir, environment: ["PATH": "/bin:/usr/bin"],
                                        logURL: log, policy: Self.policy)
        let pgid = process.pid
        #expect(try await Self.waitUntil(.seconds(5)) { try Self.members(of: pgid).count >= 3 }, "the shell and its two sleeps")
        #expect(process.isAlive() && process.exitStatus() == nil)
        let started = AwakeTime.now
        await process.terminate(grace: .seconds(5))
        // A hang bound only: under the full suite's load the cooperative pool (and `ps`) can be slow, so the wall time of
        // the stop is not what is asserted; that the group is gone once `terminate` has returned is.
        #expect(AwakeTime.now - started < .seconds(60))
        #expect(try await Self.waitUntil(.seconds(6)) { try Self.members(of: pgid).isEmpty }, "no process is left in the group")
        #expect(!process.isAlive())
        #expect(process.exitStatus() != nil)
        // FakeSandbox recorded the spawn as it was asked.
        let calls = sandbox.calls
        #expect(calls.count == 1 && calls[0].kind == .spawn && calls[0].command == "sleep 300 & sleep 300 & wait")
        #expect(calls[0].cwd == dir && calls[0].output == log && calls[0].policy == Self.policy)
    }

    @Test func environmentAndCwd() async throws {
        let dir = try tempDir()
        let run = dir.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let base = ["PATH": "/bin:/usr/bin", "HOME": "/Users/x", "GITHUB_TOKEN": "nope", "BRAHMA_DEV": "1", "PORT": "1", "HOST": "0.0.0.0"]
        let env = PreviewContext.environment(base: base, port: 47123)
        #expect(env["PORT"] == "47123" && env["HOST"] == "127.0.0.1" && env["BRAHMA_AGENT_ID"] == "preview")
        #expect(env["GITHUB_TOKEN"] == nil && env["BRAHMA_DEV"] == nil && env["PATH"] == "/bin:/usr/bin")
        let sandbox = FakeSandbox()
        let log = dir.appending(path: "web.log")
        let process = try sandbox.spawn(command: "pwd; echo $PORT $HOST $BRAHMA_AGENT_ID", cwd: run, environment: env, logURL: log,
                                        policy: Self.policy)
        #expect(await Self.waitUntil(.seconds(10)) { !process.isAlive() })
        await process.terminate(grace: .seconds(1))
        #expect(process.exitStatus() == 0)
        let lines = PreviewLog.tail(log, lines: 10)
        #expect(lines.count == 2, "\(lines)")
        #expect(lines.first.map { $0 == run.path || $0 == run.resolvedForSandbox.path } == true, "\(lines)")
        #expect(lines.last == "47123 127.0.0.1 preview")
        #expect(sandbox.calls.first?.environment == env)
        // `run` too: to completion, its output in its file, recorded.
        let out = dir.appending(path: "build.log")
        let outcome = await sandbox.run(command: "echo built; exit 3", cwd: run, environment: env, timeout: .seconds(30), outputURL: out,
                                        policy: Self.policy)
        #expect(outcome.exitCode == 3 && !outcome.timedOut)
        #expect(try String(contentsOf: out, encoding: .utf8) == "built\n")
        #expect(sandbox.calls.map(\.kind) == [.spawn, .run] && sandbox.calls[1].output == out)
    }

    @Test func logIsCapped() throws {
        let dir = try tempDir()
        let log = dir.appending(path: "web.log")
        let line = String(repeating: "x", count: 99) + "\n"
        var text = String(repeating: line, count: 60_000)                   // 6 000 000 bytes
        text += "the last line\n"
        try Data(text.utf8).write(to: log)
        try PreviewLog.trimIfNeeded(log)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int)
        #expect(size <= PreviewLog.keep + 64, "\(size)")
        #expect(size > PreviewLog.keep / 2)
        #expect(PreviewLog.tail(log, lines: 1) == ["the last line"])
        // It starts on a whole line.
        let first = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").dropFirst().first
        #expect(first.map { $0 == Substring(line.dropLast()) } == true)
        // Under the cap: untouched.
        let small = dir.appending(path: "small.log")
        try Data("a\nb\n".utf8).write(to: small)
        try PreviewLog.trimIfNeeded(small)
        #expect(try String(contentsOf: small, encoding: .utf8) == "a\nb\n")
        #expect(PreviewLog.tail(small, lines: 1) == ["b"] && PreviewLog.tail(small, lines: 5) == ["a", "b"])
        #expect(PreviewLog.tail(dir.appending(path: "missing.log"), lines: 3) == [])
        // A link planted at the log's name is never followed, read or trimmed.
        let target = dir.appending(path: "target")
        try Data(text.utf8).write(to: target)
        let linked = dir.appending(path: "linked.log")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        #expect(throws: (any Error).self) { try PreviewLog.trimIfNeeded(linked) }
        #expect(PreviewLog.tail(linked, lines: 1) == [])
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) == text.utf8.count)
        // Nor a second hard link (it may be someone else's file).
        let hard = dir.appending(path: "hard.log")
        try FileManager.default.linkItem(at: target, to: hard)
        #expect(throws: (any Error).self) { try PreviewLog.trimIfNeeded(hard) }
        #expect(PreviewLog.tail(hard, lines: 1) == [])
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) == text.utf8.count)
    }

    @Test func portAllocatorSkipsBusy() throws {
        let first = try PortAllocator.allocate(excluding: [])
        #expect(PortAllocator.range.contains(first))
        // Hold `first` (bound on 127.0.0.1): the allocator, starting there, skips it.
        let held = try #require(Self.hold(first))
        defer { close(held) }
        let skipping = Set(PortAllocator.range.lowerBound..<first)
        let next = try PortAllocator.allocate(excluding: skipping)
        #expect(next > first && PortAllocator.range.contains(next))
        // Excluded ports are skipped even when free.
        let after = try PortAllocator.allocate(excluding: skipping.union([next]))
        #expect(after > next)
        #expect(throws: WorkError.self) { try PortAllocator.allocate(excluding: Set(PortAllocator.range)) }
    }

    static func hold(_ port: Int) -> Int32? {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 1) == 0 else { close(fd); return nil }
        return fd
    }

    @Test func lsofParsing() {
        #expect(LsofListenProbe.parse("p123\nn127.0.0.1:47100\nn*:47100") == ["127.0.0.1", "*"])
        #expect(LsofListenProbe.parse("p1\nf3\nn[::1]:47100\nn127.0.0.1:47100\n") == ["[::1]", "127.0.0.1"])
        #expect(LsofListenProbe.parse("") == [] && LsofListenProbe.parse("p9\nnoport") == [])
        #expect(LsofListenProbe.parse("n*:47100\nn*:47100") == ["*"], "deduplicated")
    }

    @Test func spawnedProcessesTable() async throws {
        let dir = try tempDir()
        let sandbox = FakeSandbox()
        let table = SpawnedProcesses()
        let p = try sandbox.spawn(command: "sleep 300", cwd: dir, environment: ["PATH": "/bin:/usr/bin"],
                                  logURL: dir.appending(path: "l.log"), policy: Self.policy)
        table.insert(p)
        #expect(table.count == 1 && table.process(p.pid)?.pid == p.pid && table.process(p.pid + 100_000) == nil)
        #expect(table.all.map(\.pid) == [p.pid])
        await p.terminate(grace: .seconds(2))
        table.remove(p.pid)
        #expect(table.count == 0 && table.process(p.pid) == nil)
    }

    @Test func liveDependencies() {
        let deps = PreviewDependencies.live(sandbox: FakeSandbox())
        #expect(deps.processes.count == 0)
        #expect(deps.http is URLSessionHTTPProbe && deps.listen is LsofListenProbe)
    }
}
