import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite(.scratch) struct RestoreTests {
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
        #expect(Data("SELECT count(*) FROM company;\n".utf8).withUnsafeBytes { Spawn.writeAll(input.fileHandleForWriting.fileDescriptor, $0) } == 0)
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
        #expect(plan.warnings == [RepoAhead(company: "Acme", commitsAfterSnapshot: 2).warning])
        #expect(plan.warnings.first?.contains("Brahma will not adopt them until you review main and accept it") == true)
        // S5 fix 3 (R1, Ruling S-c1): the binary resolves its tools before it counts (red at f7820e4: it never installed them,
        // so `commitCount` refused with `notInstalled` and the warning silently vanished).
        let result = try runBrahma(["restore", "--dry-run", snapshot.path], home: home.url)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Acme: repo has 2 commits after the snapshot; they are kept, but Brahma will not adopt them"),
                "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(!result.stdout.contains("could not check"))
        #expect(!result.stdout.contains("git checks were skipped"))
        #expect(result.stdout.contains("nothing was changed"))
        let after = try snapshotOfTree(paths.home)
        #expect(after == before, "changed: \(Set(after).symmetricDifference(Set(before)).sorted())")   // not a byte, not a file, not a marker
        #expect(!FileManager.default.fileExists(atPath: BackupService.restoreMarker(paths: paths).path))
    }

    /// S5 fix 3 (R1): a repo whose commits cannot be counted (here: no tools installed in this task) is a warning that names
    /// the company and the reason, never silence.
    @Test func uncountableRepoIsReportedNotDropped() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        let snapshot = try env.service().snapshot(reason: .manual)
        try env.store.close()
        let fixture = GitFixture(existing: URL(fileURLWithPath: acme.workspacePath, isDirectory: true))
        try fixture.write("later.txt", "x")
        try fixture.git(["add", "-A"])
        try fixture.git(["commit", "-m", "later"])
        let plan = try ToolPaths.withIsolatedSlot { try env.service().planRestore(snapshot: snapshot) }
        #expect(plan.reposAhead.isEmpty)
        let warning = try #require(plan.warnings.first { $0.contains("could not check Acme's repo") }, "warnings: \(plan.warnings)")
        #expect(warning.contains("\(ToolPathsError.notInstalled)"))
        #expect(!warning.contains("\n"))
        // The restore's own install: the snapshot's (and the live database's) workspaces are forbidden roots, then it counts.
        let service = env.service()
        #expect(try service.workspacePaths(snapshot: snapshot) == [acme.workspacePath])
        #expect(try service.liveWorkspacePaths() == [acme.workspacePath])
        let installed = try ToolPaths.withIsolatedSlot { () throws -> RestorePlan in
            #expect(service.installRestoreTools(paths: env.paths, snapshot: snapshot) == nil)
            #expect(ToolPaths.isInstalled)
            return try service.planRestore(snapshot: snapshot)
        }
        #expect(installed.reposAhead == [RepoAhead(company: "Acme", commitsAfterSnapshot: 1)])
        #expect(installed.reposUnchecked.isEmpty)
        // Nothing lists a workspace (no live database, a snapshot without the table): nothing installed, and a note says so.
        let barePaths = ownerPaths(try tempDir())
        let bare = BackupService(paths: barePaths)
        let empty = try tempDir().appending(path: "empty.sqlite")
        try DatabaseQueue(path: empty.path).close()
        ToolPaths.withIsolatedSlot {
            let note = bare.installRestoreTools(paths: barePaths, snapshot: empty)
            #expect(note?.contains("git checks were skipped") == true)
            #expect(!ToolPaths.isInstalled)
        }
        // S5-8: a snapshot whose list cannot be read (no company table) leaves the roots partial, even though the live
        // database lists a workspace, so nothing is installed. With no snapshot to read (`restore --at`'s install before
        // litestream), the live database's list alone installs.
        ToolPaths.withIsolatedSlot {
            let note = service.installRestoreTools(paths: env.paths, snapshot: empty)
            #expect(note?.hasPrefix("git checks were skipped: the company workspaces the snapshot lists could not be read") == true,
                    "note: \(note ?? "nil")")
            #expect(!ToolPaths.isInstalled)
            #expect(service.installRestoreTools(paths: env.paths, snapshot: nil) == nil)
            #expect(ToolPaths.isInstalled)
        }
    }

    /// S5 fix 3 (R1): with no company workspace in the current database or the snapshot, `brahma restore` resolves no tools
    /// (Ruling S-c1: never without the real forbidden roots) and says that its git checks were skipped, instead of nothing.
    @Test func dryRunWithNoWorkspaceAnywhereSaysGitChecksWereSkipped() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let snapshot: URL
        do {
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            snapshot = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .manual)
            try store.close()
        }
        let result = try runBrahma(["restore", "--dry-run", snapshot.path], home: home.url)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("git checks were skipped"), "stdout: \(result.stdout)")
        #expect(result.stdout.contains("nothing was changed"))
    }

    /// Ruling S5-8 (S5 fix 4): a dry run reads the current database's workspaces too, without touching a byte of it. A company
    /// only the live database knows, with its workspace outside BRAHMA_WORKSPACES, is a forbidden root, so a git planted
    /// there and first on PATH is never resolved (resolving runs `git --version`). The live database here is the way an
    /// engine that was killed leaves it: the later company's row only in its WAL, with a `-shm` beside it. Neither file
    /// changes: not its bytes, not its mtime.
    @Test func dryRunForbidsALiveOnlyWorkspaceAndTouchesNoLiveFile() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let elsewhere = try tempDir()
        let marks = try tempDir()
        let side = try tempDir().appending(path: "brahma.sqlite")
        let snapshot: URL
        let later: Company
        do {
            let store = try Store(path: side.path, backupsDir: paths.backupsDir)
            _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            snapshot = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .manual)
            later = try store.createCompany(name: "Later", goal: "g", workspacesRoot: elsewhere)
            // Copied while the connection is still open: the copy is a database nobody has open, with its WAL and -shm.
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                try FileManager.default.copyItem(atPath: side.path + suffix, toPath: paths.database.path + suffix)
            }
            try store.close()
        }
        let walSize = try #require(try FileManager.default.attributesOfItem(atPath: paths.database.path + "-wal")[.size] as? Int)
        #expect(walSize > 0, "the later company is only in the WAL")
        let plantedDir = URL(fileURLWithPath: later.workspacePath, isDirectory: true).appending(path: "bin")
        try FakeTools.install(at: plantedDir.appending(path: "git"), "touch '\(marks.path)/planted-ran'\necho 'git version 2.99.0'")
        func stamp(_ suffix: String) throws -> String {
            let a = try FileManager.default.attributesOfItem(atPath: paths.database.path + suffix)
            return "\(a[.size] ?? "") \((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        let liveBefore = try ["", "-wal", "-shm"].map(stamp)
        let before = try snapshotOfTree(paths.home)
        let result = try runBrahma(["restore", "--dry-run", snapshot.path], home: home.url,
                                   extra: ["PATH": plantedDir.path + ":/usr/bin:/bin"])
        #expect(result.status == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: marks.appending(path: "planted-ran").path),
                "the git planted in the live-only workspace was resolved: \(result.stdout)")
        #expect(!result.stdout.contains("git checks were skipped"), "stdout: \(result.stdout)")
        #expect(result.stdout.contains("nothing was changed"))
        #expect(try ["", "-wal", "-shm"].map(stamp) == liveBefore, "the live database, its WAL or its -shm changed")
        let after = try snapshotOfTree(paths.home)
        #expect(after == before, "changed: \(Set(after).symmetricDifference(Set(before)).sorted())")
        // The same read in this process: the live-only workspace is listed, and the install never takes the planted git.
        let service = BackupService(paths: paths)
        #expect(try service.liveWorkspacePaths().contains(later.workspacePath))
        try ToolPaths.withIsolatedSlot { () throws in
            #expect(service.installRestoreTools(paths: paths, snapshot: snapshot, path: plantedDir.path + ":/usr/bin:/bin") == nil)
            let git = try ToolPaths.engine().get().git
            #expect(!git.hasPrefix(plantedDir.path), "resolved \(git)")
        }
        #expect(!FileManager.default.fileExists(atPath: marks.appending(path: "planted-ran").path))
        #expect(try ["", "-wal", "-shm"].map(stamp) == liveBefore)
    }

    /// Ruling S5-8 (S5 fix 4): a workspace list that cannot be read leaves the forbidden roots incomplete, so no tools are
    /// installed at all (never a resolution against a partial list) and the restore says its git checks were skipped and why.
    @Test func unreadableLiveDatabaseInstallsNoTools() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let snapshot: URL
        do {
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            snapshot = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .manual)
            try store.close()
        }
        for suffix in ["-wal", "-shm"] { unlink(paths.database.path + suffix) }
        try Data("not a database at all, just text".utf8).write(to: paths.database)
        let service = BackupService(paths: paths)
        ToolPaths.withIsolatedSlot {
            let note = service.installRestoreTools(paths: paths, snapshot: snapshot)
            #expect(note?.hasPrefix("git checks were skipped: ") == true, "note: \(note ?? "nil")")
            #expect(note?.contains("current database") == true, "note: \(note ?? "nil")")
            #expect(!ToolPaths.isInstalled)
        }
        let result = try runBrahma(["restore", "--dry-run", snapshot.path], home: home.url)
        #expect(result.status == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stdout.contains("warning: git checks were skipped: "), "stdout: \(result.stdout)")
        #expect(result.stdout.contains("current database"), "stdout: \(result.stdout)")
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

    // `markerReadoptsRepos` planted a bare marker and expected main's current head adopted: that was the review bypass fixed in
    // Task 12 fix round 1. Its coverage lives in RestoreMarkerTests (happyPathAdoptsRecordedMain and the refusals).

    // MARK: Final review I3: what a restore must not roll back

    /// A data home with one company, two agents and two approved grants (one of them one-use), snapshotted.
    private struct Forward {
        let env: BackupEnv
        let service: BackupService
        let acme: Company
        let eng: Agent, other: Agent
        let always: Grant, once: Grant
        let snapshot: URL

        init() throws {
            let env = try BackupEnv()
            let acme = try env.company("Acme")
            let eng = try env.store.hire(companyId: acme.id, name: "eng-1", role: "engineer", model: "sonnet")
            self.env = env; self.acme = acme; self.eng = eng
            service = env.service()
            other = try env.store.hire(companyId: acme.id, name: "eng-2", role: "engineer", model: "sonnet")
            always = try Self.approve(env, acme, eng, "always.example.com", .agent)
            once = try Self.approve(env, acme, eng, "once.example.com", .once)
            snapshot = try service.snapshot(reason: .manual)
        }

        /// `request_access` by `eng`, approved the owner's way.
        static func approve(_ env: BackupEnv, _ acme: Company, _ eng: Agent, _ domain: String, _ scope: GrantScope,
                            duration: GrantDuration = .always) throws -> Grant {
            _ = try CompanyTools(store: env.store, companyId: acme.id, agentId: eng.id).call(name: "request_access", arguments: [
                "kind": .string("network_domain"), "value": .string(domain), "reason": .string("I need it")])
            let ask = try #require(try env.store.asks(companyId: acme.id).last { $0.kind == .grant })
            let grantEnv = SandboxEnvironment(userHome: try tempDir(), darwinUserTemp: nil, shell: "/bin/zsh")
            return try env.store.approveAccess(askId: ask.id, scope: scope, duration: duration, note: "ok", environment: grantEnv)
        }

        /// Restores the snapshot (the live store closed first) and opens the restored database as the engine would.
        func restore() throws -> (Store, RestoreOutcome) {
            try env.store.close()
            let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
            return (try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir), outcome)
        }

        func grant(_ store: Store, _ g: Grant) throws -> Grant {
            try #require(try store.grants(companyId: acme.id, includeInactive: true).first { $0.id == g.id })
        }
    }

    /// The engine comes back stopped, whatever the snapshot said: the owner resumes it.
    @Test func restoreComesBackStopped() async throws {
        let f = try Forward()
        #expect(try f.env.store.engineStopped() == nil, "neither the snapshot nor the live database was stopped")
        let (restored, _) = try f.restore()
        let stop = try #require(try restored.engineStopped())
        #expect(stop.by == "restore"); #expect(stop.note?.contains(f.snapshot.lastPathComponent) == true)
        #expect(stop.note?.contains("nothing you had turned off was rolled back") == true, "\(stop.note ?? "")")
        // An engine on the restored database admits nothing until the owner resumes it.
        let paths = f.env.paths
        let fake = FakeTurnRunner()
        let orchestrator = Orchestrator(store: restored, runner: fake, paths: paths, mcpExecutable: "/usr/local/bin/brahma",
                                        clock: TestClock().function, vault: MemoryVault())
        try onWorkspaceProfile(restored, f.acme)
        _ = try MessageRouter(store: restored).sendDM(companyId: f.acme.id, from: .owner, to: f.eng.name, text: "go", now: Date())
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(300))
        #expect(fake.requests.isEmpty, "a restored engine ran a turn before the owner resumed it")
        #expect(try restored.resumeAfterStop(now: Date()))
    }

    /// Final-review m7: a snapshot taken while a release was `approved` (not started) never carries out that deploy after the
    /// restore without a fresh approval (the owner may have rolled it back since): the release is cancelled ("restored from
    /// backup; propose again") and the restore's notes say so. Every other release is left as the snapshot recorded it.
    @Test func restoreCancelsApprovedReleases() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        let devops = try env.store.hire(companyId: acme.id, name: "devops-1", role: "devops", model: "sonnet")
        let plan = try DeployPlan(steps: [DeployStep(label: "deploy", argv: ["/opt/fake/bin/wrangler", "pages", "deploy", "dist"])],
                                  stageFrom: ["dist"], cwdPath: "/tmp/brahma-restore-test/upload", network: [],
                                  tokenSecret: "CLOUDFLARE_API_TOKEN", build: nil, outputDir: "dist")
        let t = Date(timeIntervalSince1970: 1_781_000_000)
        func release(_ n: Int, _ status: ReleaseStatus) -> Release {
            var r = Release(companyId: acme.id, number: n, version: "0.\(n).0", status: status, provider: .cloudflarePages, project: "acme",
                            commit: String(repeating: "\(n)", count: 40), build: nil, outputDir: "dist", plan: plan, rollbackPlan: plan,
                            proposedById: devops.id, createdAt: t)
            if status != .proposed { r.approvedAt = t; r.approvedBy = "owner" }
            return r
        }
        try env.store.writer.write { db in
            try release(1, .deployed).insert(db)
            try release(2, .approved).insert(db)
        }
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        let r2 = try #require(try restored.release(companyId: acme.id, ref: "R-2"))
        #expect(r2.status == .cancelled)
        #expect(r2.failedReason == "restored from backup; propose again")
        #expect(r2.finishedAt != nil)
        #expect(try restored.release(companyId: acme.id, ref: "R-1")?.status == .deployed)
        #expect(outcome.warnings.contains("Acme: R-2 (release 0.2.0) was approved in the snapshot and is cancelled; propose it again"),
                "\(outcome.warnings)")
        let activity = try restored.writer.read { try ActivityEvent.filter(Column("companyId") == acme.id).fetchAll($0) }.map(\.text)
        #expect(activity.contains("R-2 (release 0.2.0) was cancelled: restored from backup; propose again"), "\(activity)")
        // Resumed, the engine finds nothing to carry out.
        _ = try restored.resumeAfterStop(now: Date())
        #expect(try restored.claimRelease(companyId: acme.id, now: Date()) == nil)
    }

    /// Final-fix2 R1 (m7 residual): a rollback the snapshot holds `requested` is the owner's action from before the snapshot;
    /// the restored engine never carries it out. It is cleared (no rollback status), named in the restore's warnings and an
    /// activity line, and, resumed, the engine claims nothing. The release itself stays deployed, so the owner can ask again.
    @Test func restoreCancelsRequestedRollbacks() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        let devops = try env.store.hire(companyId: acme.id, name: "devops-1", role: "devops", model: "sonnet")
        let plan = try DeployPlan(steps: [DeployStep(label: "deploy", argv: ["/opt/fake/bin/wrangler", "pages", "deploy", "dist"])],
                                  stageFrom: ["dist"], cwdPath: "/tmp/brahma-restore-test/upload", network: [],
                                  tokenSecret: "CLOUDFLARE_API_TOKEN", build: nil, outputDir: "dist")
        let t = Date(timeIntervalSince1970: 1_781_000_000)
        func release(_ n: Int) -> Release {
            var r = Release(companyId: acme.id, number: n, version: "0.\(n).0", status: .deployed, provider: .cloudflarePages,
                            project: "acme", commit: String(repeating: "\(n)", count: 40), build: nil, outputDir: "dist", plan: plan,
                            rollbackPlan: plan, proposedById: devops.id, createdAt: t)
            r.approvedAt = t; r.approvedBy = "owner"; r.deployedAt = t; r.deployStartedAt = t
            return r
        }
        try env.store.writer.write { db in
            try release(1).insert(db)
            try release(2).insert(db)
        }
        let requested = try env.store.requestRollback(companyId: acme.id, releaseRef: "R-2", by: .owner, now: t)
        #expect(requested.rollbackStatus == .requested)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        let r2 = try #require(try restored.release(companyId: acme.id, ref: "R-2"))
        #expect(r2.rollbackStatus == nil, "a rollback requested in the snapshot is still \(r2.rollbackStatus?.rawValue ?? "")")
        #expect(r2.rollbackRequestedAt == nil)
        #expect(r2.status == .deployed)
        #expect(outcome.warnings.contains(
            "Acme: the rollback of R-2 (release 0.2.0) was requested in the snapshot and is cancelled; request it again"),
            "\(outcome.warnings)")
        let activity = try restored.writer.read { try ActivityEvent.filter(Column("companyId") == acme.id).fetchAll($0) }.map(\.text)
        #expect(activity.contains("the rollback of R-2 (release 0.2.0) was cancelled: restored from backup; request it again"),
                "\(activity)")
        // Resumed, the engine finds nothing to carry out, and the owner can request it again.
        _ = try restored.resumeAfterStop(now: Date())
        #expect(try restored.claimRollback(companyId: acme.id, now: Date()) == nil)
        #expect(try restored.companiesWithReleaseWork().isEmpty)
        #expect(try restored.requestRollback(companyId: acme.id, releaseRef: "R-2", by: .owner, now: Date()).rollbackStatus == .requested)
    }

    /// Grants revoked (or used up) after the snapshot stay revoked (used up): carried from the live database.
    @Test func restoreKeepsRevocations() throws {
        let f = try Forward()
        let revoked = try f.env.store.revokeGrant(companyId: f.acme.id, number: f.always.number, now: Date())
        #expect(revoked.revokedAt != nil)
        #expect(try f.env.store.consumeGrants(ids: [f.once.id], turnId: "t-1", now: Date()).isEmpty, "the use was counted")
        let usesAfter = try f.grant(f.env.store, f.once).usesLeft
        let (restored, _) = try f.restore()
        let always = try f.grant(restored, f.always)
        #expect(always.revokedAt != nil, "a grant revoked after the snapshot is active again")
        #expect(always.revokedBy == revoked.revokedBy)
        #expect(try f.grant(restored, f.once).usesLeft == usesAfter, "a one-use grant used after the snapshot is usable again")
        #expect(try restored.grants(companyId: f.acme.id).isEmpty, "no grant is live after the restore")
    }

    /// Every taint mark made after the snapshot survives the restore (agent, company, machine-wide, never-clean commits, the
    /// session and item flags), and the machine-wide mark is set by the restore itself.
    @Test func restoreKeepsTaintMarks() throws {
        let f = try Forward()
        try f.env.store.markTainted(agentId: f.eng.id, source: "web: evil.example", now: Date())
        let neverClean = String(repeating: "c", count: 40)
        try f.env.store.recordTaintedLabCommits([neverClean])
        try f.env.store.writer.write { db in
            try db.execute(sql: "INSERT INTO companyTaint (companyId, source, profile, markedAt) VALUES (?, 'full session', 'full', ?)",
                           arguments: [f.acme.id, Date()])
        }
        let (restored, outcome) = try f.restore()
        #expect(outcome.warnings.isEmpty, "\(outcome.warnings)")
        let own = try restored.writer.read { db in try String.fetchOne(db, sql: "SELECT source FROM labTaint WHERE agentId = ?", arguments: [f.eng.id]) }
        #expect(own?.contains("evil.example") == true, "the agent's lab mark was lost")
        let agent = try #require(try restored.agent(id: f.eng.id))
        #expect(agent.sessionTainted, "the agent's tainted session reads clean again")
        #expect(agent.taintSources.contains("evil.example"))
        #expect(try restored.companyLabTaint(companyId: f.acme.id)?.profile == "full")
        #expect(try restored.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taintedLabCommit WHERE sha = ?", arguments: [neverClean]) } == 1)
        let machine = try #require(try restored.machineLabTaint())
        #expect(machine.source?.contains(f.snapshot.lastPathComponent) == true, "the restore did not set the machine-wide mark")
        // Every lab reads as marked until the owner clears it.
        #expect(try restored.labTaint(agentId: f.other.id) != nil)
    }

    /// Lab commits made after the snapshot are never recorded clean: one recorded tainted before the restore stays tainted, and
    /// one never recorded at all is recorded tainted under the restore's machine-wide mark, and still not clean after the
    /// owner's clear unless the engine saw it made in a clean turn.
    @Test func restoreNeverRecordsPostSnapshotLabCommitsClean() throws {
        let f = try Forward()
        let taintedAfter = String(repeating: "a", count: 40), unrecorded = String(repeating: "b", count: 40)
        #expect(try f.env.store.recordLabCommits(agentId: f.eng.id, turnId: nil, shas: [taintedAfter], tainted: true) == 1)
        let (restored, _) = try f.restore()
        // The next clean turn of the agent records the lab's commits.
        _ = try restored.recordLabCommits(agentId: f.eng.id, turnId: nil, shas: [taintedAfter, unrecorded], tainted: false)
        #expect(try restored.labCommitTainted(agentId: f.eng.id, sha: taintedAfter))
        #expect(try restored.labCommitTainted(agentId: f.eng.id, sha: unrecorded))
        // After the owner's machine-wide clear, a commit the engine did not see made in a clean turn still is not clean.
        try restored.clearMachineLabTaint(now: Date())
        let later = String(repeating: "d", count: 40)
        _ = try restored.recordLabCommits(agentId: f.other.id, turnId: nil, shas: [later, taintedAfter], tainted: false)
        #expect(try restored.labCommitTainted(agentId: f.other.id, sha: later))
        #expect(try restored.labCommitTainted(agentId: f.other.id, sha: taintedAfter), "a commit tainted in one lab is clean in another")
    }

    /// Fix-wave F1: a grant that ended on company-active time, or with its sprint, after the snapshot stays ended. Both clocks
    /// are in the database and roll back with it; the restore revokes every grant the live database no longer counts.
    @Test func restoreKeepsExpiredGrantsExpired() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        let eng = try env.store.hire(companyId: acme.id, name: "eng-1", role: "engineer", model: "sonnet")
        // No sprint yet: seven active days.
        let timed = try Forward.approve(env, acme, eng, "timed.example.com", .agent, duration: .sprint)
        #expect(timed.expiresActive != nil && timed.sprintId == nil)
        let sprint = Sprint(id: UUID().uuidString, companyId: acme.id, number: 1, team: nil, goal: "g", cadence: .sprint,
                            status: .active, createdAt: Date())
        try env.store.writer.write { db in try sprint.insert(db) }
        let sprintBound = try Forward.approve(env, acme, eng, "sprint.example.com", .agent, duration: .sprint)
        #expect(sprintBound.sprintId == sprint.id)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        #expect(try env.store.grants(companyId: acme.id).count == 2, "both live at the snapshot")
        // After the snapshot: the active week runs out, and the sprint ends.
        try env.store.advanceActive(companyId: acme.id, by: GrantResolver.noSprintTTL + 60)
        try env.store.writer.write { db in
            try db.execute(sql: "UPDATE sprint SET status = ? WHERE id = ?", arguments: [SprintStatus.closed.rawValue, sprint.id])
        }
        #expect(try env.store.grants(companyId: acme.id).isEmpty)
        try env.store.close()
        _ = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        // The restored database's own clocks say both are live again; the restore revoked them.
        #expect(try restored.grants(companyId: acme.id).isEmpty, "a grant that ended after the snapshot is live again")
        for g in [timed, sprintBound] {
            let row = try #require(try restored.grants(companyId: acme.id, includeInactive: true).first { $0.id == g.id })
            #expect(row.revokedAt != nil && row.revokedBy == "restore", "\(g.value)")
        }
    }

    /// Fix-wave F2: what the owner turned off after the snapshot and the restore turns back on is listed in the restore's
    /// warnings, its stop note and its alert, so the owner reviews it before resuming.
    @Test func restoreListsWhatItRolledBack() throws {
        let f = try Forward()
        // After the snapshot the owner removes eng-2.
        try f.env.store.writer.write { db in try db.execute(sql: "UPDATE agent SET state = 'killed' WHERE id = ?", arguments: [f.other.id]) }
        let (restored, outcome) = try f.restore()
        let removed = "@eng-2 (Acme), removed after the snapshot, is back"
        #expect(outcome.warnings.contains { $0.contains(removed) }, "\(outcome.warnings)")
        #expect(!outcome.warnings.contains { $0.contains("@eng-1") })
        let stop = try #require(try restored.engineStopped())
        #expect(stop.note?.contains(removed) == true, "\(stop.note ?? "")")
        let alert = try #require(try restored.asks(companyId: f.acme.id).first {
            $0.kind == .engineAlert && $0.subjectId == Store.engineAlertKey(RestoreCarry.restoreAlertReason) && $0.status == .pendingOwner
        })
        #expect(alert.summary.contains(removed) && alert.summary.contains("stopped"), "\(alert.summary)")
    }

    /// S35: a company profile narrowed after the snapshot (Full in the backup, Sandboxed live) stays narrowed, and is reported.
    @Test func restoreKeepsTheNarrowerProfile() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.store.updateSandbox(companyId: acme.id, SandboxPatch(profile: .full), userHome: try tempDir())
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.updateSandbox(companyId: acme.id, SandboxPatch(profile: .sandboxed), userHome: try tempDir())
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.company(id: acme.id)?.permissionProfile == .sandboxed, "the restore widened the profile back to Full")
        #expect(outcome.warnings.contains { $0.contains("Acme: profile kept at sandboxed (the snapshot had full)") }, "\(outcome.warnings)")
        #expect(try restored.engineStopped()?.note?.contains("profile kept at sandboxed") == true)
    }

    /// S35: a backup taken under `auto`, restored while the company asks the owner what matters (`important`): it stays
    /// `important`, and the report says so.
    @Test func restoreKeepsTheStricterAutonomy() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.store.setAutonomy(companyId: acme.id, .auto)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.setAutonomy(companyId: acme.id, .important)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.company(id: acme.id)?.autonomy == .important, "the restore loosened autonomy back to auto")
        #expect(outcome.warnings.contains { $0.contains("Acme: autonomy kept at important (the snapshot had auto)") }, "\(outcome.warnings)")
        let alert = try #require(try restored.asks(companyId: acme.id).first {
            $0.kind == .engineAlert && $0.subjectId == Store.engineAlertKey(RestoreCarry.restoreAlertReason)
        })
        #expect(alert.summary.contains("autonomy kept at important"), "\(alert.summary)")
    }

    /// S35: where a restore keeps auto-merge off (the company's switch here, and the owner-wide one), an item the snapshot had
    /// auto-approved and waiting to land loses that approval, as switching auto-merge off live does: it needs a review again.
    @Test func restoreKeepingAutoMergeOffRevokesAutoApprovals() throws {
        for ownerWide in [false, true] {
            let env = try BackupEnv()
            let acme = try env.company("Acme")
            try env.store.setAutoMergeSmall(companyId: acme.id, true)
            let item = try env.store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Small fix", status: .ready), now: Date())
            try env.store.writer.write { db in
                try db.execute(sql: "UPDATE workItem SET autoApproved = 1, status = ?, mergeState = ? WHERE id = ?",
                               arguments: [WorkItemStatus.inReview.rawValue, MergeState.pending.rawValue, item.id])
            }
            let service = env.service()
            let snapshot = try service.snapshot(reason: .manual)
            if ownerWide { try env.store.setAutoMerge(false) } else { try env.store.setAutoMergeSmall(companyId: acme.id, false) }
            try env.store.close()
            let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
            let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
            let after = try #require(try restored.workItem(id: item.id))
            #expect(!after.autoApproved, "an auto-approval from the snapshot survived (owner-wide: \(ownerWide))")
            #expect(after.mergeState == MergeState.none)
            let events = try restored.writer.read { db in
                try String.fetchAll(db, sql: "SELECT text FROM workItemEvent WHERE itemId = ?", arguments: [item.id])
            }
            #expect(events.contains { $0.contains("auto-merge was switched off before it landed") }, "\(events)")
            let line = ownerWide ? "owner-wide auto-merge kept off" : "Acme: auto-merge kept at off"
            #expect(outcome.warnings.contains { $0.contains(line) }, "\(outcome.warnings)")
        }
    }

    /// S36: the owner-wide auto-merge folder list is never widened by a restore: backup [a, b], live [a] keeps [a], reported.
    @Test func restoreKeepsTheNarrowerAutoMergePaths() throws {
        let env = try BackupEnv()
        try env.store.setAutoMergePaths(["docs/**", "tests/**"])
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.setAutoMergePaths(["docs/**"])
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        let stored = try restored.writer.read { db in try String.fetchOne(db, sql: "SELECT autoMergePaths FROM ownerSettings WHERE id = 1") }
        #expect(stored.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } == ["docs/**"], "\(stored ?? "nil")")
        #expect(outcome.warnings.contains { $0.contains("owner-wide auto-merge folders kept at docs/** (the snapshot had docs/**, tests/**)") },
                "\(outcome.warnings)")
        // The rule itself: both set, the intersection; one set, the live list.
        #expect(RestoreCarry.Settings.narrowerAutoMergePaths(live: ["a", "c"], restored: ["a", "b"]) == ["a"])
        #expect(RestoreCarry.Settings.narrowerAutoMergePaths(live: nil, restored: ["a"]) == nil)
        #expect(RestoreCarry.Settings.narrowerAutoMergePaths(live: ["a"], restored: nil) == ["a"])
    }

    /// The other direction: a setting the owner loosened after the snapshot goes back to the snapshot's stricter value.
    @Test func restoreNeverLoosensASetting() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.store.setAutonomy(companyId: acme.id, .everything)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.setAutonomy(companyId: acme.id, .auto)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.company(id: acme.id)?.autonomy == .everything)
        #expect(!outcome.warnings.contains { $0.contains("autonomy") }, "\(outcome.warnings)")
    }

    /// When the live database cannot be read, nothing it held can be carried: the restore fails closed (every grant revoked,
    /// every session and open item marked), and still comes back stopped with the machine-wide mark.
    @Test func unreadableLiveDatabaseFailsClosed() throws {
        let f = try Forward()
        try f.env.store.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: f.env.paths.database.path + suffix) }
        try Data(repeating: 0x5a, count: 8192).write(to: f.env.paths.database)
        let outcome = try f.service.restore(try f.service.planRestore(snapshot: f.snapshot))
        #expect(outcome.warnings.contains { $0.contains("could not be read") }, "\(outcome.warnings)")
        let restored = try Store(path: f.env.paths.database.path, backupsDir: f.env.paths.backupsDir)
        #expect(try restored.engineStopped() != nil)
        #expect(try restored.grants(companyId: f.acme.id).isEmpty, "a grant stayed live")
        #expect(try f.grant(restored, f.always).revokedBy == "restore")
        #expect(try restored.agent(id: f.eng.id)?.sessionTainted == true)
        #expect(try restored.machineLabTaint()?.source != nil)
    }

    // MARK: Plan C P2 fix round 4: C's taint data through a backup and restore (R4-1: Ruling 21; R4-4)

    /// A file-backed data home with company Acme (a git workspace, one commit on `main`), for C's tainted-commit rows, Ruling
    /// 19's `taintOrder` and 4a's worktree artifacts through a snapshot and a restore.
    private struct TaintWorld {
        let env: BackupEnv
        let service: BackupService
        let acme: Company
        let git: GitFixture

        init() throws {
            env = try BackupEnv()
            acme = try env.company("Acme")
            git = GitFixture(existing: URL(fileURLWithPath: acme.workspacePath, isDirectory: true))
            try env.commit(acme, file: "README.md", text: "hello\n")
            service = env.service()
        }

        /// A ready item leased by a designer of its own (the lease row as `claimLease` writes it; 4a publishes only from the
        /// publisher's own leased worktree), its branch at `main` and its worktree folder.
        func item(_ title: String) throws -> (item: WorkItem, worktree: URL) {
            let designer = try env.store.hire(companyId: acme.id, name: "design-\(title.lowercased())", role: "designer", model: "sonnet")
            let item = try env.store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: title, checkSpec: CheckSpec(command: "true", paths: ["src/\(UUID().uuidString.prefix(8))"]),
                status: .ready))
            let lease = WorkLease(itemId: item.id, companyId: acme.id, agentId: designer.id, acquiredAt: Date(), expiresActive: 1e9)
            let designerId = designer.id
            try env.store.writer.write { db in
                try lease.insert(db)
                try db.execute(sql: "UPDATE workItem SET status = 'inProgress', ownerId = ? WHERE id = ?", arguments: [designerId, item.id])
            }
            try git.git(["branch", "item/\(item.key)", "main"])
            let wt = URL(fileURLWithPath: acme.workspacePath, isDirectory: true).appending(path: ".brahma/wt/\(item.key)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
            return (item, wt)
        }

        /// A commit on the item's branch (`main` stays checked out); recorded as a tainted commit when `tainted`.
        @discardableResult
        func commit(on item: WorkItem, _ path: String, tainted: Bool) throws -> String {
            let before = try git.git(["rev-parse", "refs/heads/item/\(item.key)"])
            try git.git(["checkout", "-q", "item/\(item.key)"])
            try git.write(path, "\(path) \(UUID().uuidString)\n")
            try git.git(["add", "--", path])
            try git.git(["commit", "-q", "-m", "work on \(path)"])
            let sha = try git.git(["rev-parse", "HEAD"])
            try git.git(["checkout", "-q", "main"])
            if tainted {
                try env.store.recordTaintedCommits(companyId: acme.id, itemId: item.id, agentId: try env.store.workItem(id: item.id)?.ownerId ?? "", turnId: nil,
                                                   headBefore: before, headAfter: sha, source: "docs.swift.org",
                                                   git: SafeGit(workspace: URL(fileURLWithPath: acme.workspacePath, isDirectory: true)),
                                                   now: Date())
            }
            return sha
        }

        /// The item's designer publishes `mock.html` from its worktree (4a's publish: a clean session, so the row says clean).
        func publish(from wt: URL, _ title: String) throws -> Artifact {
            try Data("<p>\(title)</p>\n".utf8).write(to: wt.appending(path: "mock.html"))
            let designer = try #require(try env.store.agents(companyId: acme.id).first { $0.name == "design-\(title.lowercased())" })
            let a = try env.store.publishArtifact(companyId: acme.id, by: .agent(designer.id), sourcePath: "mock.html", title: title,
                                                  itemKey: nil, baseDirectory: wt)
            #expect(!a.tainted)
            return a
        }

        func tainted(_ store: Store, _ ref: String) throws -> Bool {
            let ctx = RefContext(companyId: acme.id, keyPrefixes: [Store.keyPrefix(slug: acme.slug)])
            return try store.refTaint(try #require(WorkRef.parse(ref, context: ctx)), companyId: acme.id).tainted
        }

        /// A ref's taint as another company (`companyId`) reads it.
        func tainted(_ store: Store, _ ref: String, companyId: String) throws -> Bool {
            let company = try #require(try store.company(id: companyId))
            let ctx = RefContext(companyId: companyId, keyPrefixes: [Store.keyPrefix(slug: company.slug)])
            return try store.refTaint(try #require(WorkRef.parse(ref, context: ctx)), companyId: companyId).tainted
        }

        /// The engine records `main`'s head (as a merge does): `main`'s history up to it is what the snapshot knows is clean.
        @discardableResult
        func recordMain() throws -> String {
            let head = try env.mainHead(acme)
            try env.store.recordMainCommit(companyId: acme.id, commit: head)
            return head
        }

        /// Restores the snapshot over a live database that can't be read (its file overwritten), and opens the restored one.
        func restoreOverUnreadable(_ snapshot: URL) throws -> Store {
            try env.store.close()
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: env.paths.database.path + suffix) }
            try Data(repeating: 0x5a, count: 8192).write(to: env.paths.database)
            _ = try service.restore(try service.planRestore(snapshot: snapshot))
            return try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        }

        /// Edits the snapshot file itself (an older or damaged backup).
        func editSnapshot(_ snapshot: URL, _ sql: String, _ arguments: StatementArguments = []) throws {
            let queue = try DatabaseQueue(path: snapshot.path)
            try queue.write { db in try db.execute(sql: sql, arguments: arguments) }
            try queue.close()
        }

        /// Restores the snapshot (the live store closed first) and opens the restored database as the engine would.
        func restore(_ snapshot: URL) throws -> Store {
            try env.store.close()
            _ = try service.restore(try service.planRestore(snapshot: snapshot))
            return try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        }
    }

    /// R4-1 (Ruling 21) (a): a snapshot taken after `vC-taint-order` carries the publish and clearing sequences, so a worktree
    /// artifact restored from it reads as it did: never tainted, or tainted and cleared before its publish (clean only while
    /// the clearing's sequence is below the publish's), reads clean; tainted at its publish and cleared after it reads tainted.
    @Test func restoreKeepsTaintOrderSequence() throws {
        let w = try TaintWorld()
        let (never, neverWt) = try w.item("Never")
        let a = try w.publish(from: neverWt, "Never")
        let (before, beforeWt) = try w.item("Before")
        try w.commit(on: before, "src/before.html", tainted: true)
        try w.env.store.clearTaintedCommits(itemId: before.id, by: "review", now: Date())
        let b = try w.publish(from: beforeWt, "Before")
        let (after, afterWt) = try w.item("After")
        try w.commit(on: after, "src/after.html", tainted: true)
        let c = try w.publish(from: afterWt, "After")
        try w.env.store.clearTaintedCommits(itemId: after.id, by: "review", now: Date())
        _ = never
        for (artifact, expected) in [(a, false), (b, false), (c, true)] {
            #expect(try w.tainted(w.env.store, artifact.ref) == expected, "\(artifact.ref) before the snapshot")
        }
        let snapshot = try w.service.snapshot(reason: .manual)
        let restored = try w.restore(snapshot)
        let sequences = try restored.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taintOrder") } ?? 0
        #expect(sequences >= 4, "the restored database lost the publish and clearing sequences")
        for (artifact, expected) in [(a, false), (b, false), (c, true)] {
            #expect(try w.tainted(restored, artifact.ref) == expected, "\(artifact.ref) after the restore")
            #expect(try w.tainted(restored, artifact.storedPath + "/" + artifact.entryFile) == expected, "\(artifact.ref)'s file after the restore")
        }
    }

    /// R4-1 (Ruling 21) (b): a snapshot without the sequences (taken before `vC-taint-order`, or with its rows gone) restores
    /// with no publish sequence for any artifact: every worktree artifact reads tainted (fail closed), the live database's
    /// sequences are not borrowed, and the restored database has the migration's triggers again.
    @Test func restoreWithoutTaintOrderFailsClosed() throws {
        for preMigration in [false, true] {
            let w = try TaintWorld()
            let (_, wt) = try w.item("Never")
            let a = try w.publish(from: wt, "Never")
            #expect(try !w.tainted(w.env.store, a.ref))
            let snapshot = try w.service.snapshot(reason: .manual)
            if preMigration {
                try w.editSnapshot(snapshot, """
                    DROP TRIGGER taintOrder_publish; DROP TRIGGER taintOrder_clear; DROP TRIGGER taintOrder_status;
                    DROP TABLE taintOrder; DELETE FROM grdb_migrations WHERE identifier = 'vC-taint-order'
                    """)
            } else {
                try w.editSnapshot(snapshot, "DELETE FROM taintOrder")
            }
            let restored = try w.restore(snapshot)
            #expect(try restored.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taintOrder") } == 0)
            #expect(try w.tainted(restored, a.ref), "pre-migration \(preMigration): an artifact with no publish sequence read clean")
            #expect(try w.tainted(restored, a.storedPath + "/" + a.entryFile))
            let triggers = try restored.writer.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'taintOrder_%' ORDER BY name")
            }
            #expect(triggers == ["taintOrder_clear", "taintOrder_epochClear", "taintOrder_publish", "taintOrder_status"])
        }
    }

    /// R4-4: a restore never loses C's tainted commits. A commit recorded tainted after the snapshot (git is not rolled back,
    /// so it is still on the item's branch) reads tainted after restoring the older snapshot: its commit ref, abbreviated, a
    /// key-less file at it, and the item's diff.
    @Test func restoreKeepsTaintedCommitsRecordedAfterTheSnapshot() throws {
        let w = try TaintWorld()
        let (item, _) = try w.item("Work")
        let snapshot = try w.service.snapshot(reason: .manual)
        let sha = try w.commit(on: item, "src/late.ts", tainted: true)
        #expect(try w.tainted(w.env.store, "commit:\(sha)"))
        let restored = try w.restore(snapshot)
        #expect(try w.tainted(restored, "commit:\(sha)"), "a tainted commit reads clean after the restore")
        #expect(try w.tainted(restored, "commit:\(sha.prefix(7))"))
        #expect(try w.tainted(restored, "src/late.ts@\(sha)"))
        #expect(try w.tainted(restored, "\(item.key):diff"))
    }

    /// C4b fix round 1 (I-1): a restore never loses the engine's commit-author record (git is not rolled back): a commit whose
    /// turn was recorded after the snapshot keeps its author, so `by @agent` still finds it and no later turn can claim it; one
    /// recorded before the snapshot is unchanged.
    @Test func restoreKeepsCommitAuthorsRecordedAfterTheSnapshot() throws {
        let w = try TaintWorld()
        let (item, _) = try w.item("Work")
        let designer = try #require(try w.env.store.workItem(id: item.id)?.ownerId)
        let start = try w.git.git(["rev-parse", "refs/heads/item/\(item.key)"])
        let early = try w.commit(on: item, "src/early.ts", tainted: false)
        w.env.store.recordTurnCommits(companyId: w.acme.id, agentId: designer, turnId: "t-1", heldAtStart: [item.id: start], now: Date())
        let snapshot = try w.service.snapshot(reason: .manual)
        let late = try w.commit(on: item, "src/late.ts", tainted: false)
        w.env.store.recordTurnCommits(companyId: w.acme.id, agentId: designer, turnId: "t-2", heldAtStart: [item.id: early], now: Date())
        #expect(try w.env.store.recordedCommitAuthors(companyId: w.acme.id, shas: [early, late]) == [early: "design-work", late: "design-work"])
        let restored = try w.restore(snapshot)
        #expect(try restored.recordedCommitAuthors(companyId: w.acme.id, shas: [early, late]) == [early: "design-work", late: "design-work"])
        // First record wins after the restore too: another agent's turn reaching the commit doesn't take it.
        let other = try restored.hire(companyId: w.acme.id, name: "other", role: "engineer", model: "sonnet")
        restored.recordTurnCommits(companyId: w.acme.id, agentId: other.id, turnId: "t-3", heldAtStart: [item.id: start], now: Date())
        #expect(try restored.recordedCommitAuthors(companyId: w.acme.id, shas: [late]) == [late: "design-work"])
    }

    /// R4-4: the clearing of a carried row: a row uncleared in either database stays uncleared; a row only the live database
    /// has comes back as it is there (cleared there: cleared).
    @Test func restoreKeepsTaintedCommitClearingStricter() throws {
        let w = try TaintWorld()
        let (one, _) = try w.item("One")
        let (two, _) = try w.item("Two")
        let x = try w.commit(on: one, "src/x.ts", tainted: true)     // uncleared live, cleared in the snapshot (below)
        let y = try w.commit(on: two, "src/y.ts", tainted: true)     // uncleared in the snapshot, cleared live
        let snapshot = try w.service.snapshot(reason: .manual)
        try w.editSnapshot(snapshot, "UPDATE taintedCommit SET clearedBy = 'review', clearedAt = ? WHERE sha = ?", [Date(), x])
        try w.env.store.clearTaintedCommits(itemId: two.id, by: "review", now: Date())
        let (three, _) = try w.item("Three")
        let z = try w.commit(on: three, "src/z.ts", tainted: true)   // only live, cleared there
        try w.env.store.clearTaintedCommits(itemId: three.id, by: "owner", now: Date())
        let restored = try w.restore(snapshot)
        #expect(try w.tainted(restored, "commit:\(x)"), "a row uncleared live came back cleared")
        #expect(try w.tainted(restored, "commit:\(y)"), "a row uncleared in the snapshot came back cleared")
        let carried = try restored.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT clearedBy, itemId FROM taintedCommit WHERE companyId = ? AND sha = ?", arguments: [w.acme.id, z])
        }
        #expect(carried?["clearedBy"] as String? == "owner", "a live-only row was not carried as it is")
        #expect(carried?["itemId"] as String? == three.id)
    }

    /// R4-4: when the live database can't be read its tainted commits can't be carried, so every open item of the restored
    /// database reads tainted: a commit made and recorded tainted after the snapshot still reads tainted.
    @Test func unreadableLiveDatabaseTaintsEveryItemsCommits() throws {
        let w = try TaintWorld()
        let (item, _) = try w.item("Work")
        let snapshot = try w.service.snapshot(reason: .manual)
        let sha = try w.commit(on: item, "src/late.ts", tainted: true)
        try w.env.store.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: w.env.paths.database.path + suffix) }
        try Data(repeating: 0x5a, count: 8192).write(to: w.env.paths.database)
        _ = try w.service.restore(try w.service.planRestore(snapshot: snapshot))
        let restored = try Store(path: w.env.paths.database.path, backupsDir: w.env.paths.backupsDir)
        #expect(try w.tainted(restored, "commit:\(sha)"), "a commit of an item reads clean though its taint record was lost")
        #expect(try w.tainted(restored, "\(item.key):diff"))
    }

    // MARK: Plan C P2 fix round 5: the restore epoch (R5-1: Ruling 22; R5-2) and the carry across companies (R5-4)

    /// R5-1 (Ruling 22): after a restore over an unreadable live database, a commit the restored database has no row for (on
    /// the branch of an item created after the snapshot) reads tainted: its commit ref, abbreviated, and a key-less file at it;
    /// a commit already on `main` in the snapshot does not. The owner's vouch clears it, each clearing with a `taintOrder`
    /// sequence.
    @Test func unreadableLiveRestoreTaintsCommitsTheSnapshotCannotPlace() throws {
        let w = try TaintWorld()
        let onMain = try w.recordMain()
        let snapshot = try w.service.snapshot(reason: .manual)
        let (late, _) = try w.item("Late")          // created after the snapshot: unknown to the restored database
        let sha = try w.commit(on: late, "src/late.ts", tainted: true)
        let restored = try w.restoreOverUnreadable(snapshot)
        #expect(try restored.workItem(id: late.id) == nil)
        #expect(try w.tainted(restored, "commit:\(sha)"), "a commit no snapshot row places reads clean")
        #expect(try w.tainted(restored, "commit:\(sha.prefix(7))"))
        #expect(try w.tainted(restored, "src/late.ts@\(sha)"), "a key-less file at it reads clean")
        #expect(try !w.tainted(restored, "commit:\(onMain)"), "a commit on main in the snapshot reads tainted")
        #expect(try !w.tainted(restored, "README.md@\(onMain)"))
        let epochs = try restored.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, listed, mainCommit, clearedBy FROM restoreEpoch WHERE companyId = ?", arguments: [w.acme.id])
        }
        #expect(epochs.count == 1)
        #expect(epochs.first?["listed"] as Bool? == true)
        #expect(epochs.first?["mainCommit"] as String? == onMain)
        try restored.vouchRestoredCommits(companyId: w.acme.id, now: Date())
        #expect(try !w.tainted(restored, "commit:\(sha)"), "the owner's vouch did not clear it")
        #expect(try !w.tainted(restored, "src/late.ts@\(sha)"))
        let epochId = try #require(epochs.first?["id"] as String?)
        let clears = try restored.writer.read { db in
            try String.fetchAll(db, sql: "SELECT subject FROM taintOrder WHERE companyId = ? AND kind = 'clear'", arguments: [w.acme.id])
        }
        #expect(clears.contains(sha), "the commit's clearing has no taintOrder sequence")
        #expect(clears.contains("restore-epoch:\(epochId)"), "the epoch's clearing has no taintOrder sequence")
    }

    /// R5-1: when the restore can't list the repository's commits (here its `.git` is away during the restore), every commit
    /// off the snapshot's recorded `main` reads tainted until the owner vouches; `main`'s own history stays clean.
    @Test func unreadableLiveRestoreWithoutAListingTaintsEveryCommitOffMain() throws {
        let w = try TaintWorld()
        let onMain = try w.recordMain()
        let snapshot = try w.service.snapshot(reason: .manual)
        let (late, _) = try w.item("Late")
        let sha = try w.commit(on: late, "src/late.ts", tainted: false)
        let gitDir = URL(fileURLWithPath: w.acme.workspacePath, isDirectory: true).appending(path: ".git")
        let away = URL(fileURLWithPath: w.acme.workspacePath, isDirectory: true).appending(path: ".git-away")
        try FileManager.default.moveItem(at: gitDir, to: away)
        let restored: Store
        do {
            defer { try? FileManager.default.moveItem(at: away, to: gitDir) }
            restored = try w.restoreOverUnreadable(snapshot)
        }
        #expect(try w.tainted(restored, "commit:\(sha)"), "an unlisted restore let a commit off main read clean")
        #expect(try w.tainted(restored, "src/late.ts@\(sha)"))
        #expect(try !w.tainted(restored, "commit:\(onMain)"))
        #expect(try !w.tainted(restored, "README.md@\(onMain)"))
        let listed = try restored.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT listed FROM restoreEpoch WHERE companyId = ?", arguments: [w.acme.id])
        }
        #expect(listed == false)
        try restored.vouchRestoredCommits(companyId: w.acme.id, now: Date())
        #expect(try !w.tainted(restored, "commit:\(sha)"))
        #expect(try !w.tainted(restored, "src/late.ts@\(sha)"))
    }

    /// R5-2: an item done in the snapshot, reopened and worked by a tainted session after it, with the live database unreadable
    /// at the restore: the restored database has it done (no marker), yet its later commit reads tainted.
    @Test func unreadableLiveRestoreTaintsADoneItemsLaterCommits() throws {
        let w = try TaintWorld()
        _ = try w.recordMain()
        let (item, _) = try w.item("Reopened")
        try w.env.store.writer.write { db in
            try db.execute(sql: "DELETE FROM workLease WHERE itemId = ?", arguments: [item.id])
            try db.execute(sql: "UPDATE workItem SET status = 'done' WHERE id = ?", arguments: [item.id])
        }
        let snapshot = try w.service.snapshot(reason: .manual)
        try w.env.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'inProgress' WHERE id = ?", arguments: [item.id])
        }
        let sha = try w.commit(on: item, "src/reopened.ts", tainted: true)
        let restored = try w.restoreOverUnreadable(snapshot)
        #expect(try restored.workItem(id: item.id)?.status == .done)
        #expect(try w.tainted(restored, "commit:\(sha)"), "a done item's later commit reads clean")
        #expect(try w.tainted(restored, "src/reopened.ts@\(sha)"))
        #expect(try w.tainted(restored, "\(item.key):diff"))
    }

    /// R5-4: the carry keeps each company's `taintedCommit` rows apart: the same sha in Acme and Beta, with different taint
    /// and clearing states in the snapshot and the live database, comes back per company.
    @Test func restoreCarriesTaintedCommitsPerCompany() throws {
        let w = try TaintWorld()
        let beta = try w.env.company("Beta")
        let (a, b) = (w.acme.id, beta.id)
        let (s, t, u) = (String(repeating: "a1", count: 20), String(repeating: "b2", count: 20), String(repeating: "c3", count: 20))
        func put(_ company: String, _ sha: String, cleared: Bool) throws {
            try w.env.store.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO taintedCommit (companyId, sha, source, createdAt, clearedBy, clearedAt) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [company, sha, "src-\(company == a ? "acme" : "beta")", Date(), cleared ? "owner" : nil, cleared ? Date() : nil])
            }
        }
        // In the snapshot: s uncleared in Acme only; t uncleared in Acme, cleared in Beta.
        try put(a, s, cleared: false)
        try put(a, t, cleared: false)
        try put(b, t, cleared: true)
        let snapshot = try w.service.snapshot(reason: .manual)
        // After it, live only: Acme clears s; Beta records s uncleared; u cleared in Acme, uncleared in Beta.
        try w.env.store.writer.write { db in
            try db.execute(sql: "UPDATE taintedCommit SET clearedBy = 'owner', clearedAt = ? WHERE companyId = ? AND sha = ?", arguments: [Date(), a, s])
        }
        try put(b, s, cleared: false)
        try put(a, u, cleared: true)
        try put(b, u, cleared: false)
        let restored = try w.restore(snapshot)
        func row(_ company: String, _ sha: String) throws -> Row? {
            try restored.writer.read { db in
                try Row.fetchOne(db, sql: "SELECT clearedBy, source FROM taintedCommit WHERE companyId = ? AND sha = ?", arguments: [company, sha])
            }
        }
        let expected: [(company: String, sha: String, clearedBy: String?, tainted: Bool)] = [
            (a, s, nil, true), (b, s, nil, true),          // uncleared in the snapshot stays uncleared; Beta's live-only row arrives
            (a, t, nil, true), (b, t, "owner", false),     // Acme's uncleared row does not un-clear Beta's
            (a, u, "owner", false), (b, u, nil, true),     // live-only rows of both companies, each as it is
        ]
        for e in expected {
            let r = try #require(try row(e.company, e.sha), "\(e.company == a ? "Acme" : "Beta")'s row for \(e.sha.prefix(4)) is missing")
            #expect(r["clearedBy"] as String? == e.clearedBy, "\(e.company == a ? "Acme" : "Beta") \(e.sha.prefix(4))")
            #expect(r["source"] as String == (e.company == a ? "src-acme" : "src-beta"))
            #expect(try w.tainted(restored, "commit:\(e.sha)", companyId: e.company) == e.tainted,
                    "\(e.company == a ? "Acme" : "Beta") commit:\(e.sha.prefix(4))")
        }
    }

    // MARK: Plan C P2 breaker fix: every epoch counts (B-1: Ruling 24), its range starts at its own main (B-2: Ruling 25),
    // the owner's vouch (B-3: Ruling 26), and the vouch launders no turn's row (B-4)

    /// A new item in `store` (the restored database) whose branch is `item/<KEY>` at `start`.
    private func restoredItem(_ w: TaintWorld, _ store: Store, _ title: String, at start: String) throws -> WorkItem {
        let item = try store.createWorkItem(companyId: w.acme.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: title, checkSpec: CheckSpec(command: "true", paths: ["src/\(UUID().uuidString.prefix(8))"]), status: .ready))
        try w.git.git(["branch", "item/\(item.key)", start])
        return item
    }

    /// B-1 (Ruling 24): a listed epoch protects more than the commits it listed. A commit dangling at the restore (made on a
    /// branch deleted before it, so the listing never saw it) and revived after it onto a new item's branch reads tainted: its
    /// commit ref, a key-less file at it and the item's diff. `main`'s own history stays clean, and after the owner's vouch
    /// the revived refs read by the usual rules (clean: no row names them).
    @Test func listedRestoreTaintsADanglingCommitRevivedAfterIt() throws {
        let w = try TaintWorld()
        let onMain = try w.recordMain()
        let snapshot = try w.service.snapshot(reason: .manual)
        try w.git.git(["checkout", "-q", "-b", "scratch"])
        try w.git.write("src/dangling.ts", "dangling \(UUID().uuidString)\n")
        try w.git.git(["add", "--", "src/dangling.ts"])
        try w.git.git(["commit", "-q", "-m", "dangling"])
        let sha = try w.git.git(["rev-parse", "HEAD"])
        try w.git.git(["checkout", "-q", "main"])
        try w.git.git(["branch", "-q", "-D", "scratch"])
        let restored = try w.restoreOverUnreadable(snapshot)
        let listed = try restored.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT listed FROM restoreEpoch WHERE companyId = ?", arguments: [w.acme.id])
        }
        #expect(listed == true, "the restore did not list")
        #expect(try restored.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taintedCommit WHERE companyId = ? AND sha = ?", arguments: [w.acme.id, sha])
        } == 0, "the dangling commit was listed after all")
        let item = try restoredItem(w, restored, "Revive", at: sha)      // a clean session moves a branch onto it
        for ref in ["commit:\(sha)", "commit:\(sha.prefix(7))", "src/dangling.ts@\(sha)", "\(item.key):diff"] {
            #expect(try w.tainted(restored, ref), "\(ref) read clean under a listed epoch")
        }
        #expect(try !w.tainted(restored, "commit:\(onMain)"))
        #expect(try !w.tainted(restored, "README.md@\(onMain)"))
        try restored.vouchRestoredCommits(companyId: w.acme.id, now: Date())
        for ref in ["commit:\(sha)", "src/dangling.ts@\(sha)", "\(item.key):diff"] {
            #expect(try !w.tainted(restored, ref), "\(ref) after the owner's vouch")
        }
    }

    /// B-2 (Ruling 25): the epoch's range runs from the epoch's own `main`, never live `main`. After the restore a commit X is
    /// merged into `main` (and recorded there), so live `main`'s merge base with X is X itself: `src/x.ts@X`, the merged item's
    /// diff, the rev-less `src/x.ts` (main's head), and an artifact published from the main checkout whose bytes X wrote all
    /// read tainted, under a listed and an unlisted epoch; a file X did not touch stays clean. After the owner's vouch they
    /// read by the usual rules (clean).
    @Test func restoreEpochRangeStartsAtTheEpochsOwnMain() throws {
        for listed in [true, false] {
            let w = try TaintWorld()
            let onMain = try w.recordMain()
            let snapshot = try w.service.snapshot(reason: .manual)
            let restored: Store
            if listed {
                restored = try w.restoreOverUnreadable(snapshot)
            } else {
                let gitDir = URL(fileURLWithPath: w.acme.workspacePath, isDirectory: true).appending(path: ".git")
                let away = URL(fileURLWithPath: w.acme.workspacePath, isDirectory: true).appending(path: ".git-away")
                try FileManager.default.moveItem(at: gitDir, to: away)
                defer { try? FileManager.default.moveItem(at: away, to: gitDir) }
                restored = try w.restoreOverUnreadable(snapshot)
            }
            let epochListed = try restored.writer.read { db in
                try Bool.fetchOne(db, sql: "SELECT listed FROM restoreEpoch WHERE companyId = ?", arguments: [w.acme.id])
            }
            #expect(epochListed == listed)
            let item = try restoredItem(w, restored, "Merged", at: onMain)
            try w.git.git(["checkout", "-q", "item/\(item.key)"])
            try w.git.write("src/x.ts", "x \(UUID().uuidString)\n")
            try w.git.write("page.html", "<p>from X</p>\n")
            try w.git.git(["add", "--", "src/x.ts", "page.html"])
            try w.git.git(["commit", "-q", "-m", "x"])
            let x = try w.git.git(["rev-parse", "HEAD"])
            try w.git.git(["checkout", "-q", "main"])
            try w.git.git(["merge", "-q", "--ff-only", "item/\(item.key)"])
            try restored.recordMainCommit(companyId: w.acme.id, commit: x)
            let artifact = try restored.publishArtifact(companyId: w.acme.id, by: .owner, sourcePath: "page.html", title: "Page",
                                                        itemKey: nil, baseDirectory: URL(fileURLWithPath: w.acme.workspacePath, isDirectory: true))
            let refs = ["src/x.ts@\(x)", "page.html@\(x)", "\(item.key):diff", "src/x.ts", artifact.ref, "commit:\(x)"]
            for ref in refs {
                #expect(try w.tainted(restored, ref), "listed \(listed): \(ref) read clean once live main moved past X")
            }
            #expect(try !w.tainted(restored, "README.md"), "listed \(listed): a file X did not touch")
            #expect(try !w.tainted(restored, "README.md@\(x)"), "listed \(listed)")
            try restored.vouchRestoredCommits(companyId: w.acme.id, now: Date())
            for ref in refs {
                #expect(try !w.tainted(restored, ref), "listed \(listed): \(ref) after the owner's vouch")
            }
        }
    }

    /// B-4: the carry never gives a turn's tainted row a restore epoch, so the owner's restore vouch can't clear it. An item is
    /// done in S0, reopened and worked by a tainted session (row for X, no epoch), S1 taken; a restore of S0 over an unreadable
    /// database lists X under its epoch; a readable restore of S1 then merges the two rows: X keeps no epoch, and after the
    /// vouch it is still uncleared and tainted.
    @Test func restoreVouchLeavesATurnTaintedCommitTainted() throws {
        let w = try TaintWorld()
        _ = try w.recordMain()
        let (item, _) = try w.item("Turn")
        try w.env.store.writer.write { db in
            try db.execute(sql: "DELETE FROM workLease WHERE itemId = ?", arguments: [item.id])
            try db.execute(sql: "UPDATE workItem SET status = 'done' WHERE id = ?", arguments: [item.id])
        }
        let s0 = try w.service.snapshot(reason: .manual)
        try w.env.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'inProgress' WHERE id = ?", arguments: [item.id])
        }
        let x = try w.commit(on: item, "src/turn.ts", tainted: true)
        let s1 = try w.service.snapshot(reason: .manual)
        let first = try w.restoreOverUnreadable(s0)
        #expect(try first.writer.read { db in
            try String.fetchOne(db, sql: "SELECT restoreEpoch FROM taintedCommit WHERE companyId = ? AND sha = ?", arguments: [w.acme.id, x])
        } != nil, "the first restore did not list X under its epoch")
        try first.close()
        _ = try w.service.restore(try w.service.planRestore(snapshot: s1))
        let second = try Store(path: w.env.paths.database.path, backupsDir: w.env.paths.backupsDir)
        let row = try #require(try second.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT restoreEpoch, source FROM taintedCommit WHERE companyId = ? AND sha = ?", arguments: [w.acme.id, x])
        })
        #expect(row["restoreEpoch"] as String? == nil, "a turn's row took the epoch of the earlier restore's listing")
        #expect(row["source"] as String == "docs.swift.org")
        try second.vouchRestoredCommits(companyId: w.acme.id, now: Date())
        #expect(try second.writer.read { db in
            try String.fetchOne(db, sql: "SELECT clearedBy FROM taintedCommit WHERE companyId = ? AND sha = ?", arguments: [w.acme.id, x])
        } == nil, "the restore vouch cleared a turn's tainted commit")
        #expect(try w.tainted(second, "commit:\(x)"), "a turn-tainted commit read clean after the restore vouch")
    }

    /// B-3 (Ruling 26): a data home with Acme and an uncleared restore epoch (no recorded main: every commit tainted) holding
    /// one listed commit row.
    private func epochHome(initOwner: Bool) throws -> (home: OwnerTestHome, company: Company, sha: String) {
        let home = try OwnerTestHome(initOwner: initOwner)
        let paths = ownerPaths(home.url)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let sha = String(repeating: "d4", count: 20)
        try store.writer.write { db in
            try RestoreEpoch(id: "epoch-1", companyId: company.id, mainCommit: nil, listed: true, source: RestoreCarry.unreadableCommitTaintSource,
                             createdAt: Date(), clearedBy: nil, clearedAt: nil).insert(db)
            try db.execute(sql: """
                INSERT INTO taintedCommit (companyId, sha, source, createdAt, restoreEpoch) VALUES (?, ?, ?, ?, 'epoch-1')
                """, arguments: [company.id, sha, RestoreCarry.unreadableCommitTaintSource, Date()])
        }
        try store.close()
        return (home, company, sha)
    }

    private func epochState(_ home: OwnerTestHome, _ company: Company, _ sha: String) throws -> (epochCleared: String?, commitCleared: String?, commitTainted: Bool, otherTainted: Bool) {
        let paths = ownerPaths(home.url)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        defer { try? store.close() }
        let (epoch, commit) = try store.writer.read { db in
            (try String.fetchOne(db, sql: "SELECT clearedBy FROM restoreEpoch WHERE id = 'epoch-1'"),
             try String.fetchOne(db, sql: "SELECT clearedBy FROM taintedCommit WHERE companyId = ? AND sha = ?", arguments: [company.id, sha]))
        }
        let other = String(repeating: "e5", count: 20)
        return (epoch, commit, try store.refTaint(WorkRef(kind: .commit, id: sha), companyId: company.id).tainted,
                try store.refTaint(WorkRef(kind: .commit, id: other), companyId: company.id).tainted)
    }

    /// B-3 (Ruling 26): `brahma vouch restore <company>` is the owner's way to clear a restore epoch: as the owner it clears
    /// the epoch and its rows (each clearing sequenced, an owner activity line), and refs then read by the usual rules; from an
    /// agent's shell (`BRAHMA_AGENT_ID`) or without the owner key it is refused and changes nothing.
    @Test func cliVouchRestoreOwnerOnly() throws {
        let noKey = try epochHome(initOwner: false)
        let refusedNoKey = try runBrahma(["vouch", "restore", "acme"], home: noKey.home.url)
        #expect(refusedNoKey.status != 0 && refusedNoKey.stderr.contains("owner key missing"), "\(refusedNoKey.stderr)")
        let afterNoKey = try epochState(noKey.home, noKey.company, noKey.sha)
        #expect(afterNoKey.epochCleared == nil && afterNoKey.commitCleared == nil && afterNoKey.commitTainted && afterNoKey.otherTainted)

        let h = try epochHome(initOwner: true)
        let before = try epochState(h.home, h.company, h.sha)
        #expect(before.commitTainted && before.otherTainted)
        let agent = try runBrahma(["vouch", "restore", "acme"], home: h.home.url, extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agent.status != 0 && agent.stderr.contains("owner commands can't run inside an agent turn"), "\(agent.stderr)")
        let afterAgent = try epochState(h.home, h.company, h.sha)
        #expect(afterAgent.epochCleared == nil && afterAgent.commitCleared == nil && afterAgent.commitTainted && afterAgent.otherTainted)
        #expect(try runBrahma(["vouch", "restore", "nosuch"], home: h.home.url).status != 0)

        let owner = try runBrahma(["vouch", "restore", "acme"], home: h.home.url)
        #expect(owner.status == 0, "\(owner.stderr)")
        #expect(owner.stdout.contains("Acme"), "\(owner.stdout)")
        let after = try epochState(h.home, h.company, h.sha)
        #expect(after.epochCleared == "owner" && after.commitCleared == "owner")
        #expect(!after.commitTainted && !after.otherTainted, "refs still read tainted after the owner's vouch")
        let paths = ownerPaths(h.home.url)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        defer { try? store.close() }
        let (clears, lines) = try store.writer.read { db in
            (try String.fetchAll(db, sql: "SELECT subject FROM taintOrder WHERE companyId = ? AND kind = 'clear'", arguments: [h.company.id]),
             try String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE companyId = ? AND kind = 'access' AND agentId IS NULL",
                                 arguments: [h.company.id]))
        }
        #expect(clears.contains("restore-epoch:epoch-1") && clears.contains(h.sha), "\(clears)")
        #expect(lines.contains { $0.contains("Owner vouched for the commits a restore could not place") }, "\(lines)")
        // Nothing left to clear: a second run says so and succeeds.
        let again = try runBrahma(["vouch", "restore", "acme"], home: h.home.url)
        #expect(again.status == 0, "\(again.stderr)")
    }

    /// B-3: no agent tool reaches the restore vouch: no company tool is named for it, and no tool source calls it or writes a
    /// restore epoch's clearing.
    @Test func noAgentToolReachesTheRestoreVouch() throws {
        #expect(!CompanyToolNames.all.contains { $0.contains("vouch") })
        var reaches: [String] = []
        for (path, text) in try EngineGitGuardTests.sources(under: "Sources/BrahmaCore/MCP") {
            let code = EngineGitGuardTests.code(text)
            if code.range(of: #"\bvouch(RestoredCommits|Item)\b|UPDATE\s+restoreEpoch"#, options: .regularExpression) != nil {
                reaches.append(path)
            }
        }
        #expect(reaches.isEmpty, "a tool path reaches the restore vouch: \(reaches)")
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
