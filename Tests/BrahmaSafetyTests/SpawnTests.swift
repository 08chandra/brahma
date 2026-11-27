import Testing
import Foundation
@testable import BrahmaSafety

/// Plan S Task S5 (spec §6.5): `Spawn` is the one process primitive. It starts only an absolute executable, as argv[0], with
/// an explicit environment whose `PATH` holds only absolute entries, never through `/usr/bin/env` or a PATH lookup.
@Suite(.scratch, .serialized) struct SpawnTests {
    @Test func relativeExecutableIsAProgrammingError() throws {
        for exe in ["git", "bin/git", "./git", "", "claude"] {
            switch Spawn.validate(exe) {
            case .allow: Issue.record("\(exe.debugDescription) was allowed")
            case .deny(let why): #expect(why.contains("absolute"), "\(why)")
            }
        }
        #expect(Spawn.validate("/usr/bin/git") == .allow("/usr/bin/git", because: "an absolute path"))
        // Refused before anything starts, by every entry: a bounded run, a started child and the group spawn.
        #expect(throws: Spawn.Failure.self) {
            try Spawn.run("sh", ["-c", "exit 0"], cwd: URL(fileURLWithPath: "/"), env: [:], timeout: .seconds(5), outputCap: 1024)
        }
        #expect(throws: Spawn.Failure.self) {
            try Spawn.start("sh", ["-c", "exit 0"], cwd: URL(fileURLWithPath: "/"), env: [:])
        }
        #expect(throws: (any Error).self) {
            try ProcessGroupChild.spawn(executable: "sh", arguments: ["sh", "-c", "exit 0"], environment: [:],
                                        workingDirectory: URL(fileURLWithPath: "/"), output: -1)
        }
    }

    @Test func childPathIsSanitized() throws {
        let out = try Spawn.run("/usr/bin/env", [], cwd: URL(fileURLWithPath: "/"), env: ["PATH": ".:/usr/bin"],
                                timeout: .seconds(10), outputCap: 1 << 16)
        #expect(out.status == 0 && !out.timedOut)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "PATH=/usr/bin\n")
        #expect(Spawn.sanitizedPath(".::bin:/usr/bin::/bin:./x:") == "/usr/bin:/bin")
        #expect(Spawn.sanitized(["PATH": "a:/b", "X": "1"]) == ["PATH": "/b", "X": "1"])
        #expect(Spawn.sanitized(["X": "1"]) == ["X": "1"], "no PATH is added where there was none")
        // The working directory is the one given.
        let dir = try tempDir()
        let probe = try Spawn.run("/bin/pwd", ["-P"], cwd: dir, env: [:], timeout: .seconds(10), outputCap: 1 << 16)
        #expect(String(decoding: probe.stdout, as: UTF8.self) == SandboxPath.resolve(dir.path) + "\n")
        // The observer sees what started (tests' seam): executable, argv (argv[0] = the executable) and working directory.
        final class Seen: @unchecked Sendable { let lock = NSLock(); var all: [Spawn.Spawned] = [] }
        let seen = Seen()
        try Spawn.$observer.withValue({ s in seen.lock.withLock { seen.all.append(s) } }) {
            _ = try Spawn.run("/usr/bin/true", [], cwd: dir, env: [:], timeout: .seconds(10), outputCap: 0)
        }
        let started = seen.lock.withLock { seen.all }
        #expect(started.count == 1 && started.first?.executable == "/usr/bin/true" && started.first?.arguments == ["/usr/bin/true"]
                && started.first?.cwd == dir.path)
    }

    /// The bounded run: stdin bytes in, separate streams out, the output cap, and the timeout (SIGTERM to the group, then
    /// SIGKILL), measured in awake time.
    @Test func boundedRun() throws {
        let root = URL(fileURLWithPath: "/")
        let echo = try Spawn.run("/bin/sh", ["-c", "cat; echo err >&2; exit 3"], cwd: root, env: [:], stdin: .data(Data("in\n".utf8)),
                                 timeout: .seconds(10), outputCap: 1 << 16)
        #expect(echo.status == 3 && String(decoding: echo.stdout, as: UTF8.self) == "in\n" && String(decoding: echo.stderr, as: UTF8.self) == "err\n")
        let big = try Spawn.run("/bin/sh", ["-c", "/usr/bin/yes | /usr/bin/head -c 100000"], cwd: root, env: [:],
                                timeout: .seconds(10), outputCap: 1000)
        #expect(big.stdout.count == 1000 && big.truncated && big.status == 0)
        let started = AwakeTime.uptime()
        let slow = try Spawn.run("/bin/sh", ["-c", "/bin/sleep 30 & /bin/sleep 30"], cwd: root, env: [:],
                                 timeout: .milliseconds(300), outputCap: 1024)
        #expect(slow.timedOut && AwakeTime.uptime() - started < 10)
    }
}
