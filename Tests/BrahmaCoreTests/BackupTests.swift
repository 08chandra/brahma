import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite(.scratch) struct BackupTests {
    @Test func snapshotIsConsistentAndPruned() throws {
        let env = try BackupEnv()
        let acme = try env.company()
        try env.post(acme, "hello before the snapshot")
        let service = env.service()
        let first = try service.snapshot(reason: .hourly)
        #expect(BackupService.integrity(of: first) == ["ok"])
        #expect(try env.companyNames(in: first) == ["Acme"])
        #expect(first.lastPathComponent.hasPrefix("brahma-") && first.lastPathComponent.hasSuffix("-hourly.sqlite"))
        var st = stat()
        #expect(stat(first.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        for _ in 0..<54 { _ = try service.snapshot(reason: .hourly) }
        _ = try service.snapshot(reason: .manual)
        let list = service.list()
        #expect(list.filter { $0.reason == .hourly }.count == BackupService.keep[.hourly])
        #expect(BackupService.keep == [.hourly: 48, .preMigration: 10, .manual: 20, .preRestore: 5])
        #expect(BackupService.keepBundles == 14)
        // The newest are the ones kept; the first one is gone; another reason is untouched.
        #expect(!list.contains { $0.url == first })
        #expect(list.filter { $0.reason == .manual }.count == 1)
        #expect(list.first?.reason == .manual)
    }

    @Test func badSnapshotDiscardedWithoutPruning() throws {
        let env = try BackupEnv()
        _ = try env.company()
        var service = env.service()
        for _ in 0..<48 { _ = try service.snapshot(reason: .hourly) }
        let before = service.list().map(\.name)
        #expect(before.count == 48)
        service.integrityCheck = { _ in ["page 3 corrupt"] }
        #expect(throws: BackupError.snapshotFailedCheck(["page 3 corrupt"])) { try service.snapshot(reason: .hourly) }
        #expect(service.list().map(\.name) == before)          // the previous 48 are all kept
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.tmpDir.path).isEmpty)    // nothing left staged
    }

    @Test func preMigrationBackupWhenPending() throws {
        let root = try tempDir()
        let paths = ownerPaths(root)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        // A database from an older Brahma: the first two migrations only, with a company in it.
        let pool = try DatabasePool(path: paths.database.path)
        try Migrations.migrator().migrate(pool, upTo: "v2-owner-read")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO company (id, name, slug, goal, workspacePath, status, usageMode, priorityWeight, createdAt)
                VALUES ('c1', 'Old Co', 'old-co', 'g', '/tmp/x', 'running', 'balanced', 1, '2026-01-01 00:00:00.000')
                """)
        }
        try pool.close()
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        let backups = BackupService(paths: paths, writer: store.writer).list().filter { $0.reason == .preMigration }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(BackupService.integrity(of: backup.url) == ["ok"])
        let snapshot = try BackupService.openForReading(backup.url)
        // The snapshot is of the database as it was: still the old schema, with the old data.
        let migrations = try snapshot.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(migrations.last == "v2-owner-read")
        #expect(try snapshot.read { db in try String.fetchAll(db, sql: "SELECT name FROM company") } == ["Old Co"])
        // And the live database was migrated afterwards.
        #expect(try store.writer.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }.count > migrations.count)
    }

    @Test func noBackupWhenUpToDate() throws {
        let root = try tempDir()
        let paths = ownerPaths(root)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let first = try Store(path: paths.database.path, backupsDir: paths.backupsDir)       // a new database: nothing to protect
        try first.close()
        let second = try Store(path: paths.database.path, backupsDir: paths.backupsDir)      // nothing pending
        #expect(BackupService(paths: paths, writer: second.writer).list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.dbBackups.path))
    }

    @Test func repoBundleSkipsUnchanged() throws {
        let env = try BackupEnv()
        let acme = try env.company()
        let service = env.service()
        func run() -> BackupService.BundleResult.Outcome {
            service.bundleRepos(companies: [acme]) { env.store.gitWorkspace(root: URL(fileURLWithPath: $0.workspacePath), companyId: $0.id) }[0].outcome
        }
        guard case .created(let bundle) = run() else { Issue.record("expected a bundle"); return }
        #expect(bundle.path.hasPrefix(env.paths.repoBackups.appending(path: acme.id).path))
        #expect(bundle.lastPathComponent.range(of: "^[0-9]{8}\\.bundle$", options: .regularExpression) != nil)
        _ = try GitFixture.plainGit(["bundle", "verify", bundle.path], in: URL(fileURLWithPath: acme.workspacePath))   // throws unless ok
        #expect(run() == .unchanged)
        try env.commit(acme, file: "a.txt", text: "new work")
        guard case .created(let again) = run() else { Issue.record("expected a new bundle after a commit"); return }
        #expect(again.path == bundle.path)                        // same day: replaced
        #expect(run() == .unchanged)
    }

    @Test func bundleIgnoresCraftedRepoConfig() throws {
        let env = try BackupEnv()
        let acme = try env.company()
        let marker = env.root.appending(path: "pwned")
        let config = URL(fileURLWithPath: acme.workspacePath).appending(path: ".git/config")
        var text = try String(contentsOf: config, encoding: .utf8)
        text += "\n[core]\n\tfsmonitor = touch \(marker.path)\n[uploadpack]\n\tpackObjectsHook = touch \(marker.path)\n"
        text += "[pack]\n\twriteBitmaps = true\n[bundle]\n\tversion = 3\n"
        try text.write(to: config, atomically: true, encoding: .utf8)
        let service = env.service()
        let results = service.bundleRepos(companies: [acme]) { env.store.gitWorkspace(root: URL(fileURLWithPath: $0.workspacePath), companyId: $0.id) }
        // The hardened git either refuses the repository or runs without the settings; it never runs what the config names.
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        if case .created = results[0].outcome { Issue.record("a repository with a program-naming config must not be bundled") }
    }

    @Test func hourlyJobRuns() async throws {
        let env = try BackupEnv()
        let acme = try env.company()
        let clock = TestClock()
        let orchestrator = Orchestrator(store: env.store, runner: FakeTurnRunner(), paths: env.paths, mcpExecutable: "/usr/local/bin/brahma",
                                        clock: clock.function, vault: MemoryVault())
        try await orchestrator.start()
        clock.advance(3601)
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(300))
        let snapshots = BackupService(paths: env.paths).list().filter { $0.reason == .hourly }
        #expect(snapshots.count == 1)
        #expect(try env.companyNames(in: try #require(snapshots.first).url) == ["Acme"])
        #expect(try env.store.events(afterId: 0, limit: 100).filter { $0.companyId == acme.id && $0.kind == .error }.isEmpty)
    }

    @Test func failedHourlyJobWritesActivityAndNotifiesOwner() async throws {
        let env = try BackupEnv()
        let acme = try env.company()
        // A file where the backups directory should be: the snapshot cannot be stored.
        try Data("x".utf8).write(to: env.paths.backupsDir)
        let clock = TestClock()
        let orchestrator = Orchestrator(store: env.store, runner: FakeTurnRunner(), paths: env.paths, mcpExecutable: "/usr/local/bin/brahma",
                                        clock: clock.function, vault: MemoryVault())
        try await orchestrator.start()
        clock.advance(3601)
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(300))
        let errors = try env.store.events(afterId: 0, limit: 100).filter { $0.companyId == acme.id && $0.kind == .error }
        #expect(errors.contains { $0.text.contains("backup.hourly") && $0.text.contains("database backup failed") })
        #expect(try env.store.allNotices().contains { $0.title == "Backup failed" })
    }

    @Test func stagingUsesHomeTmp() throws {
        let env = try BackupEnv()
        _ = try env.company()
        var service = env.service()
        let staged = SeenPaths()
        service.integrityCheck = { url in staged.add(url); return BackupService.integrity(of: url) }
        _ = try service.snapshot(reason: .manual)
        let seen = try #require(staged.first)
        #expect(seen.deletingLastPathComponent().standardizedFileURL.path == env.paths.tmpDir.standardizedFileURL.path)
        #expect(env.paths.tmpDir.path == env.paths.home.appending(path: "tmp").path)
        var st = stat()
        #expect(stat(env.paths.tmpDir.path, &st) == 0 && st.st_mode & 0o777 == 0o700)
        #expect(!FileManager.default.fileExists(atPath: seen.path))     // and it is gone again
    }
}

final class SeenPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    var first: URL? { lock.withLock { urls.first } }
}
