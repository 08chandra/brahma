import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite struct RestoreTests {
    /// A data home with one company and a message, a snapshot of it, and then a later company the snapshot does not have.
    private func scenario() throws -> (env: BackupEnv, snapshot: URL, service: BackupService) {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.post(acme, "findable zebra message")
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        _ = try env.company("Later")
        return (env, snapshot, service)
    }

    @Test func refusesWhileEngineRuns() throws {
        let (env, snapshot, service) = try scenario()
        let plan = try service.planRestore(snapshot: snapshot)
        let lock = try OrchestratorLock.acquire(paths: env.paths)
        #expect(throws: RestoreError.engineRunning) { try service.planRestore(snapshot: snapshot) }
        #expect(throws: RestoreError.engineRunning) { try service.restore(plan) }
        #expect(try env.companyNames(in: env.paths.database) == ["Acme", "Later"])      // untouched
        withExtendedLifetime(lock) {}
    }

    @Test func refusesWhileOtherProcessHasDBOpen() throws {
        let (env, snapshot, service) = try scenario()
        // A real child process holding a connection: sqlite3 reading statements from a pipe keeps the database open.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        child.arguments = [env.paths.database.path]
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { try? input.fileHandleForWriting.close(); child.terminate(); child.waitUntilExit() }
        input.fileHandleForWriting.write(Data("SELECT count(*) FROM company;\n".utf8))
        let answer = output.fileHandleForReading.availableData       // it answered, so the connection is open
        #expect(String(decoding: answer, as: UTF8.self).contains("2"))
        let pids = try DBOpeners.pids(of: env.paths.database)
        #expect(pids.contains(child.processIdentifier))
        #expect(!pids.contains(getpid()))                              // the caller is never listed
        #expect(throws: RestoreError.dbOpenElsewhere(pids)) { try service.planRestore(snapshot: snapshot) }
        // Closing the connection lets it through.
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        #expect(try DBOpeners.pids(of: env.paths.database).isEmpty)
        _ = try service.planRestore(snapshot: snapshot)
    }

    @Test func refusesNewerSchema() throws {
        let (env, snapshot, service) = try scenario()
        let future = env.paths.dbBackups.appending(path: "brahma-20991231T000000.000Z-manual.sqlite")
        try FileManager.default.copyItem(at: snapshot, to: future)
        let queue = try DatabaseQueue(path: future.path)
        try queue.write { db in try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v99-from-the-future')") }
        try queue.close()
        #expect(throws: RestoreError.newerSchema) { try service.planRestore(snapshot: future) }
        // `--latest` skips it.
        #expect(service.latestGood()?.url == snapshot)
    }

    @Test func refusesCorruptSnapshot() throws {
        let (env, snapshot, service) = try scenario()
        let bad = env.paths.dbBackups.appending(path: "brahma-20991231T000000.000Z-manual.sqlite")
        var bytes = try Data(contentsOf: snapshot)
        let middle = bytes.count / 2
        bytes.replaceSubrange(middle..<min(bytes.count, middle + 4096), with: Data(repeating: 0xAB, count: min(4096, bytes.count - middle)))
        try bytes.write(to: bad)
        #expect(throws: RestoreError.corrupt) { try service.planRestore(snapshot: bad) }
        let notADatabase = env.root.appending(path: "junk.sqlite")
        try Data("not a database at all, just text".utf8).write(to: notADatabase)
        #expect(throws: RestoreError.corrupt) { try service.planRestore(snapshot: notADatabase) }
        #expect(throws: RestoreError.notFound) { try service.planRestore(snapshot: env.root.appending(path: "missing.sqlite")) }
        #expect(try env.companyNames(in: env.paths.database) == ["Acme", "Later"])
    }

    @Test func dryRunTouchesNothing() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let acme: Company
        let snapshot: URL
        do {
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            snapshot = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .manual)
            try store.close()
        }
        // Two commits land after the snapshot: they are kept, and the dry run says so.
        let fixture = GitFixture(existing: URL(fileURLWithPath: acme.workspacePath, isDirectory: true))
        for n in 1...2 {
            try fixture.write("f\(n).txt", "x")
            try fixture.git(["add", "-A"])
            try fixture.git(["commit", "-m", "later \(n)"])
        }
        let before = try snapshotOfTree(paths.home)
        let service = BackupService(paths: paths)
        let plan = try service.planRestore(snapshot: snapshot)
        #expect(plan.reposAhead == [RepoAhead(company: "Acme", commitsAfterSnapshot: 2)])
        #expect(plan.warnings == ["Acme: repo has 2 commits after the snapshot; they are kept and re-adopted"])
        let result = try runBrahma(["restore", "--dry-run", snapshot.path], home: home.url)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Acme: repo has 2 commits after the snapshot; they are kept and re-adopted"))
        #expect(result.stdout.contains("nothing was changed"))
        let after = try snapshotOfTree(paths.home)
        #expect(after == before, "changed: \(Set(after).symmetricDifference(Set(before)).sorted())")   // not a byte, not a file, not a marker
        #expect(!FileManager.default.fileExists(atPath: BackupService.restoreMarker(paths: paths).path))
    }

    @Test func restoreIsAtomicRename() async throws {
        let (env, snapshot, service) = try scenario()
        try env.store.close()
        let plan = try service.planRestore(snapshot: snapshot)
        let path = env.paths.database.path
        let done = CallCounter()
        let misses = CallCounter()
        let probe = Thread {
            var st = stat()
            while !done.isSet {
                if stat(path, &st) != 0 { misses.mark() }
            }
        }
        probe.start()
        for _ in 0..<5 { _ = try service.restore(plan) }                   // repeated, to give the probe every chance
        done.mark()
        try await Task.sleep(for: .milliseconds(50))
        #expect(misses.calls == 0)                                         // the live path was never missing
        #expect(try env.companyNames(in: env.paths.database) == ["Acme"])
    }

    @Test func restoreKeepsPrevious() throws {
        let (env, snapshot, service) = try scenario()
        try env.store.close()
        let plan = try service.planRestore(snapshot: snapshot)
        let outcome = try service.restore(plan)
        #expect(try env.companyNames(in: env.paths.database) == ["Acme"])
        let previous = try #require(outcome.previousCopy)
        #expect(previous.lastPathComponent.hasPrefix("brahma.sqlite.pre-restore-"))
        #expect(try env.companyNames(in: previous) == ["Acme", "Later"])    // the database as it was, bytes and all
        let pre = try #require(outcome.preRestoreSnapshot)
        #expect(try env.companyNames(in: pre) == ["Acme", "Later"])
        #expect(service.list().contains { $0.reason == .preRestore && $0.url == pre })
        #expect(!FileManager.default.fileExists(atPath: env.paths.database.path + ".restoring"))
        #expect(!FileManager.default.fileExists(atPath: env.paths.database.path + "-wal"))
        // And the restored database opens, migrated, as a normal store.
        let reopened = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try reopened.companies().map(\.name) == ["Acme"])
    }

    @Test func restoreRebuildsSearchIndex() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.post(acme, "findable zebra message")
        let service = env.service()
        // Stand-in for a VACUUM that renumbered the rowids under an external-content index: the snapshot's index is wrong.
        try env.store.writer.write { db in try db.execute(sql: "INSERT INTO messageFts(messageFts) VALUES('delete-all')") }
        #expect(try env.store.searchMessages(companyId: acme.id, query: "zebra").isEmpty)
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        #expect(outcome.warnings.isEmpty)
        let reopened = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        // Messages written before the snapshot are found by full-text search after the restore ...
        #expect(try reopened.searchMessages(companyId: acme.id, query: "zebra").map(\.text) == ["findable zebra message"])
        // ... and the index agrees with the table.
        try reopened.writer.write { db in try db.execute(sql: "INSERT INTO messageFts(messageFts) VALUES('integrity-check')") }
    }

    @Test func markerReadoptsRepos() async throws {
        let store = try Store.inMemory()
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let hooks = RestoreHooks()
        let events = RestoreEvents()
        hooks.register { event in events.add(event) }
        let clock = TestClock()
        let orchestrator = Orchestrator(store: store, runner: FakeTurnRunner(), paths: paths, mcpExecutable: "/usr/local/bin/brahma",
                                        clock: clock.function, vault: MemoryVault(), restoreHooks: hooks)
        let acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        // A restored database holds the head from the snapshot; the repository has moved on since.
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [String(repeating: "a", count: 40), acme.id])
        }
        let fixture = GitFixture(existing: URL(fileURLWithPath: acme.workspacePath, isDirectory: true))
        try fixture.write("later.txt", "x")
        try fixture.git(["add", "-A"])
        try fixture.git(["commit", "-m", "after the snapshot"])
        let head = try fixture.git(["rev-parse", "refs/heads/main"])
        let marker = BackupService.restoreMarker(paths: paths)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("brahma-20260610T120000.000Z-manual.sqlite\n2026-06-10T12:00:00Z\n".utf8).write(to: marker)

        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(30))

        #expect(try store.company(id: acme.id)?.mainCommit == head)            // re-adopted from git
        #expect(!FileManager.default.fileExists(atPath: marker.path))          // marker removed
        let seen = events.all
        #expect(seen.count == 1 && seen.first?.companyId == acme.id && seen.first?.mainHead == head)
        #expect(seen.first?.snapshotName == "brahma-20260610T120000.000Z-manual.sqlite")
        let texts = try store.events(afterId: 0, limit: 100).filter { $0.companyId == acme.id }.map(\.text)
        #expect(texts.contains("restored from brahma-20260610T120000.000Z-manual.sqlite; repos re-adopted"))
        // The main guard accepts it: nothing reads as "main changed outside Brahma".
        try store.checkMain(company: try #require(try store.company(id: acme.id)))
        // A second tick does nothing more.
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(30))
        #expect(events.all.count == 1)
    }

    @Test func cliRestoreOwnerOnly() throws {
        let home = try OwnerTestHome(initOwner: false)
        // No owner key in this data home: refused.
        let noKey = try runBrahma(["restore", "--list"], home: home.url)
        #expect(noKey.status != 0 && noKey.stderr.contains("owner key missing"))
        try #require(try initOwnerKey(home: home.url) == 0, "brahma owner init failed under script")
        // From an agent's shell: refused, even with the key.
        let agent = try runBrahma(["restore", "--list"], home: home.url, extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agent.status != 0 && agent.stderr.contains("owner commands can't run inside an agent turn"))
        let agentBackup = try runBrahma(["backup", "list"], home: home.url, extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agentBackup.status != 0)
        let agentExport = try runBrahma(["export", "acme", "--to", home.url.appending(path: "out").path], home: home.url,
                                        extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agentExport.status != 0)
        // The owner can.
        let owner = try runBrahma(["restore", "--list"], home: home.url)
        #expect(owner.status == 0)
        // Neither argument nor flag: a usage error.
        let neither = try runBrahma(["restore"], home: home.url)
        #expect(neither.status != 0)
    }

    @Test func cliRunRefusesDamagedDatabase() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try Data("this is not a sqlite database, not even close to one".utf8).write(to: paths.database)
        let result = try runBrahma(["run", "--skip-doctor"], home: home.url)
        #expect(result.status == 1)
        #expect(result.stderr.contains("brahma: database check failed ("))
        #expect(result.stderr.contains("). See: brahma restore --list"))
    }
}

final class RestoreEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RestoreEvent] = []
    func add(_ e: RestoreEvent) { lock.withLock { events.append(e) } }
    var all: [RestoreEvent] { lock.withLock { events } }
}

struct BrahmaResult { var status: Int32; var stdout: String; var stderr: String }

/// Runs the built `brahma` against a throwaway data home (file owner-key store, never the Keychain).
func runBrahma(_ args: [String], home: URL, extra: [String: String] = [:]) throws -> BrahmaResult {
    let p = Process()
    p.executableURL = brahmaExecutableURL()
    p.arguments = args
    p.environment = cliEnvironment(home: home).merging(extra) { $1 }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return BrahmaResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
}

/// Every file under `root` with its size and modification time (and the bytes of the small ones): equal means untouched.
func snapshotOfTree(_ root: URL) throws -> [String] {
    var rows: [String] = []
    let fm = FileManager.default
    guard let walker = fm.enumerator(atPath: root.path) else { return rows }
    for case let rel as String in walker {
        let attrs = try fm.attributesOfItem(atPath: root.appending(path: rel).path)
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // The engine lock file is created empty by the first check that looks at the lock; it holds nothing.
        if rel == "orchestrator.lock" { continue }
        rows.append("\(rel) \(size) \(mtime)")
    }
    return rows.sorted()
}
