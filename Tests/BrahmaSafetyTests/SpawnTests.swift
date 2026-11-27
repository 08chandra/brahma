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

    /// M4: no descriptor of the engine reaches a child but the three streams, even one opened without close-on-exec.
    @Test func childGetsOnlyItsThreeStreams() throws {
        let opened = open("/dev/null", O_RDONLY)
        try #require(opened >= 0)
        let fd = fcntl(opened, F_DUPFD, 77)   // no FD_CLOEXEC on a F_DUPFD copy
        close(opened)
        try #require(fd >= 77)
        defer { close(fd) }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC == 0, "the descriptor is inheritable as far as exec goes")
        let root = URL(fileURLWithPath: "/")
        let leaked = try Spawn.run("/bin/sh", ["-c", "test -e /dev/fd/\(fd)"], cwd: root, env: [:], timeout: .seconds(10), outputCap: 0)
        #expect(leaked.status != 0, "descriptor \(fd) reached the child")
        let streams = try Spawn.run("/bin/sh", ["-c", "test -e /dev/fd/0 && test -e /dev/fd/1 && test -e /dev/fd/2"], cwd: root,
                                    env: [:], timeout: .seconds(10), outputCap: 0)
        #expect(streams.status == 0, "the three streams are there")
    }

    /// C1: a child that exits without reading its input. The bytes the engine still has to write fail with EPIPE; the engine
    /// is never killed by SIGPIPE (the run ends normally, with the child's own status).
    @Test func childThatIgnoresItsInputNeverKillsTheEngine() throws {
        let root = URL(fileURLWithPath: "/")
        let input = Data(repeating: 0x61, count: 4 << 20)
        for _ in 0..<3 {
            let out = try Spawn.run("/usr/bin/true", [], cwd: root, env: [:], stdin: .data(input), timeout: .seconds(20),
                                    outputCap: 0)
            #expect(out.status == 0 && !out.timedOut)
            let child = try Spawn.start("/bin/sh", ["-c", "exit 4"], cwd: root, env: [:], stdin: .data(input))
            #expect(ProcessGroupChild.exitCode(child.waitStatus()) == 4)
        }
        // The feeder's write fails after the child went away; give it time to do so (a SIGPIPE would end this process here).
        Thread.sleep(forTimeInterval: 0.5)
    }
}
