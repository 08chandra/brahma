import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 3: owner commands never run from inside a turn (environment, then process ancestry against the turns the engine has
/// in flight), and the data home can never sit where an agent could reach it (`DataHomeGuard`).
@Suite(.scratch) struct OwnerGuardTests {
    private let launchd: Int32 = 1

    @Test func refusesWithAgentEnv() {
        let why = OwnerShellGuard.refusal(environment: ["BRAHMA_AGENT_ID": "a1"], ancestors: [getpid(), launchd], runningTurnPids: [])
        #expect(why?.contains("agent turn") == true)
        // The per-turn marker variable alone is a turn too (an agent can unset BRAHMA_AGENT_ID, but the engine sets both).
        #expect(OwnerShellGuard.refusal(environment: [TurnContainment.markerVariable: "x"], ancestors: [], runningTurnPids: []) != nil)
    }

    @Test func refusesWhenAncestorIsTurn() {
        let why = OwnerShellGuard.refusal(environment: [:], ancestors: [getpid(), 4242, 99, launchd], runningTurnPids: [4242])
        #expect(why?.contains("4242") == true)
        #expect(why?.contains("agent turn") == true)
    }

    @Test func allowsOwnerShell() {
        #expect(OwnerShellGuard.refusal(environment: ["HOME": "/Users/x", "PATH": "/bin"], ancestors: [getpid(), 77, launchd],
                                        runningTurnPids: [4242, 5]) == nil)
        // A running turn that is not an ancestor does not refuse.
        #expect(OwnerShellGuard.refusal(environment: [:], ancestors: [getpid(), launchd], runningTurnPids: [getpid() + 100_000]) == nil)
    }

    @Test func ancestryChainOfSelfEndsAtLaunchd() {
        let chain = ProcessAncestry.chain(of: getpid())
        #expect(chain.first == getpid())
        #expect(chain.last == launchd, "\(chain)")
        #expect(chain.count >= 2)
        // Bounded: a depth of 1 gives at most the process and its parent.
        #expect(ProcessAncestry.chain(of: getpid(), maxDepth: 1).count <= 2)
        // A pid that does not exist has no chain beyond itself.
        #expect(ProcessAncestry.chain(of: 2_000_000).count <= 1)
    }

    /// A real `brahma` owner command started from a shell the engine recorded as a turn's process is refused; the same command
    /// from a plain shell runs. The turn pid is the `/bin/sh` that execs brahma, recorded as the runner records it (`TurnRecords`) and in `turn.pid` (`Store.setTurnPid`).
    @Test(.timeLimit(.minutes(2))) func childOfFakeTurnIsRefused() async throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let store = try Store(path: paths.database.path)
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let agent = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "haiku")
        func network(recordTurn: Bool) throws -> (status: Int32, stderr: String) {
            // The shell is the "turn": its pid is recorded before it execs brahma, so brahma's parent is a running turn.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            let marker = home.url.appending(path: "shell.pid")
            p.arguments = ["-c", "echo $$ > '\(marker.path)'; while [ ! -f '\(marker.path).go' ]; do sleep 0.05; done; exec '\(brahmaExecutableURL().path)' network \(company.slug)"]
            p.environment = cliEnvironment(home: home.url)
            let err = Pipe()
            p.standardError = err; p.standardOutput = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            try p.run()
            var shellPid: Int32?
            for _ in 0..<400 {
                if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    shellPid = pid; break
                }
                usleep(10_000)
            }
            let pid = try #require(shellPid)
            if recordTurn {
                try store.transition(agentId: agent.id, to: .ready, now: Date())
                let (_, turn) = try #require(try store.beginTurn(agentId: agent.id, now: Date()))
                try store.setTurnPid(turnId: turn.id, pid: pid)
                #expect(try store.runningTurnPids() == [pid])
                // What the runner records at spawn (`TurnRecords`), the source the CLI reads without opening the database.
                let start = try #require(ProcessTable.entry(pid)?.start)
                try TurnRecords.add(TurnRecord(leader: pid, leaderStart: start, since: start, machMarker: nil), agentId: agent.id,
                                    in: paths.runDir.appending(path: "turns", directoryHint: .isDirectory))
                #expect(Store.recordedTurnLeaders(paths: paths) == [pid])
            }
            try Data().write(to: URL(fileURLWithPath: marker.path + ".go"))
            p.waitUntilExit()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            try? FileManager.default.removeItem(at: marker); try? FileManager.default.removeItem(atPath: marker.path + ".go")
            return (p.terminationStatus, text)
        }
        let plain = try network(recordTurn: false)
        #expect(plain.status == 0, "\(plain.stderr)")
        let inTurn = try network(recordTurn: true)
        #expect(inTurn.status != 0)
        #expect(inTurn.stderr.contains("agent turn"), "\(inTurn.stderr)")
    }

    @Test func dataHomeInsideWorkspacesRootRefused() throws {
        let root = try tempDir()
        let ws = root.appending(path: "ws")
        try FileManager.default.createDirectory(at: ws.appending(path: "acme"), withIntermediateDirectories: true)
        // The data home inside the workspaces root, and inside a company workspace: both refused, resolved or not.
        for home in [ws.appending(path: "home"), ws.appending(path: "acme/.brahma/home"), ws] {
            let paths = BrahmaPaths(home: home, workspaces: ws)
            #expect(throws: (any Error).self) { try DataHomeGuard.validate(paths: paths, workspacePaths: [ws.appending(path: "acme").path]) }
        }
        // A company workspace inside the data home is refused too.
        let home = root.appending(path: "home")
        #expect(throws: (any Error).self) {
            try DataHomeGuard.validate(paths: BrahmaPaths(home: home, workspaces: ws), workspacePaths: [home.appending(path: "companies/x").path])
        }
        // Through a link: a workspaces root that is a link to the data home's parent.
        let link = root.appending(path: "wslink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) { try DataHomeGuard.validate(paths: BrahmaPaths(home: home, workspaces: link), workspacePaths: []) }
        // Side by side is fine.
        try DataHomeGuard.validate(paths: BrahmaPaths(home: home, workspaces: ws), workspacePaths: [ws.appending(path: "acme").path])
    }

    @Test func lockDownMakesTheHomePrivate() throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        try FileManager.default.createDirectory(at: paths.runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])  // exec-bit fixture: a directory mode lockDown must tighten
        try FileManager.default.createDirectory(at: paths.backupsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])  // exec-bit fixture: a directory mode lockDown must tighten
        try DataHomeGuard.lockDown(paths: paths)
        for dir in [paths.home, paths.runDir, paths.tmpDir, paths.backupsDir] {
            var st = stat()
            #expect(lstat(dir.path, &st) == 0, "\(dir.path)")
            #expect(st.st_mode & 0o777 == 0o700, "\(dir.path): \(String(st.st_mode & 0o777, radix: 8))")
        }
        // A link where a private directory should be is refused, never followed.
        let other = root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: paths.tmpDir)
        try FileManager.default.createSymbolicLink(at: paths.tmpDir, withDestinationURL: other)
        #expect(throws: (any Error).self) { try DataHomeGuard.lockDown(paths: paths) }
    }

    /// M3: a bad directory does not stop the others; every bad one is reported.
    @Test func lockDownContinuesPastABadDirectory() throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let fm = FileManager.default
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.backupsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])  // exec-bit fixture: a directory mode lockDown must tighten
        let other = root.appending(path: "elsewhere")
        try fm.createDirectory(at: other, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])  // exec-bit fixture: a directory lockDown must leave alone
        try fm.createSymbolicLink(at: paths.runDir, withDestinationURL: other)
        try Data("x".utf8).write(to: paths.tmpDir)
        var reason = ""
        do { try DataHomeGuard.lockDown(paths: paths) } catch let e as DataHomeError { reason = e.reason }
        #expect(reason.contains(paths.runDir.path) && reason.contains("symbolic link"), "\(reason)")
        #expect(reason.contains(paths.tmpDir.path) && reason.contains("not a directory"), "\(reason)")
        for dir in [paths.home, paths.backupsDir] {
            var st = stat()
            #expect(lstat(dir.path, &st) == 0)
            #expect(st.st_mode & 0o777 == 0o700, "\(dir.path) locked down past the bad ones")
        }
        var st = stat()
        #expect(stat(other.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o755, "a link's target is never changed")
    }

    @Test func turnPidRecordedAndReadBack() throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let agent = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "haiku")
        try store.transition(agentId: agent.id, to: .ready, now: Date())
                let (_, turn) = try #require(try store.beginTurn(agentId: agent.id, now: Date()))
        #expect(try store.runningTurnPids().isEmpty)
        try store.setTurnPid(turnId: turn.id, pid: 31337)
        #expect(try store.runningTurnPids() == [31337])
        let stored = try store.writer.read { db in try Turn.fetchOne(db, key: turn.id) }
        #expect(stored?.pid == 31337)
        // Ended turns no longer count.
        try store.writer.write { db in
            try db.execute(sql: "UPDATE turn SET outcome = 'succeeded', endedAt = ? WHERE id = ?", arguments: [Date(), turn.id])
        }
        #expect(try store.runningTurnPids().isEmpty)
    }
}
