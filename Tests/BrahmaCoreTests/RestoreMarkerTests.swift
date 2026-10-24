import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 12 fix round 1 (S1, M1): the restore marker only re-adopts `main` through a DB-recorded restore event.
@Suite struct RestoreMarkerTests {
    /// An in-memory store with one company whose repository has a commit nobody reviewed on `main`.
    private func movedMainRig(moveMain: Bool = true) async throws -> (store: Store, paths: BrahmaPaths, orchestrator: Orchestrator,
                                                                     acme: Company, recorded: String, moved: String, events: RestoreEvents) {
        let store = try Store.inMemory()
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let hooks = RestoreHooks()
        let events = RestoreEvents()
        hooks.register { event in events.add(event) }
        let orchestrator = Orchestrator(store: store, runner: FakeTurnRunner(), paths: paths, mcpExecutable: "/usr/local/bin/brahma",
                                        clock: TestClock().function, vault: MemoryVault(), restoreHooks: hooks)
        let acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let recorded = try #require(try store.company(id: acme.id)?.mainCommit)
        let moved = moveMain ? try commitUnreviewed(acme) : recorded
        return (store, paths, orchestrator, acme, recorded, moved, events)
    }

    /// Plain git moves `main` to a commit nobody reviewed; returns the new head.
    @discardableResult
    private func commitUnreviewed(_ company: Company, file: String = "unreviewed.txt") throws -> String {
        let fixture = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        try fixture.write(file, "x")
        try fixture.git(["add", "-A"])
        try fixture.git(["commit", "-m", "nobody reviewed this"])
        return try fixture.git(["rev-parse", "refs/heads/main"])
    }

    /// A file data home with one company, restored from a snapshot of itself; the store reopened on the restored database.
    private func restoredRig() async throws -> (env: BackupEnv, store: Store, orchestrator: Orchestrator, acme: Company,
                                                 recorded: String, snapshot: URL, events: RestoreEvents) {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        let recorded = try env.mainHead(acme)
        // The engine was moving main when the snapshot was taken: a pending head that never landed. Only `recorded` counts.
        try await env.store.writer.write { db in
            try db.execute(sql: "UPDATE company SET pendingMainCommit = ? WHERE id = ?", arguments: [String(repeating: "b", count: 40), acme.id])
        }
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        _ = try service.restore(try service.planRestore(snapshot: snapshot))
        let store = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        let hooks = RestoreHooks()
        let events = RestoreEvents()
        hooks.register { event in events.add(event) }
        let orchestrator = Orchestrator(store: store, runner: FakeTurnRunner(), paths: env.paths, mcpExecutable: "/usr/local/bin/brahma",
                                        clock: TestClock().function, vault: MemoryVault(), restoreHooks: hooks)
        return (env, store, orchestrator, acme, recorded, snapshot, events)
    }

    private func restoreRow(_ store: Store, _ nonce: String) throws -> Row? {
        try store.writer.read { db in try Row.fetchOne(db, sql: "SELECT * FROM restoreEvent WHERE nonce = ?", arguments: [nonce]) }
    }

    private func markerNonce(_ marker: URL) throws -> String {
        guard case .nonce(let nonce) = RestoreMarker.read(marker) else {
            Issue.record("marker unreadable: \(RestoreMarker.read(marker))")
            throw RestoreError.notFound
        }
        return nonce
    }

    private func mainAlertsOpen(_ store: Store, _ company: Company) throws -> Int {
        try store.writer.read { db in
            try Ask.filter(Column("kind") == AskKind.engineAlert && Column("status") == AskStatus.pendingOwner.rawValue
                           && Column("subjectId") == Store.engineAlertKey(Store.mainAlertReason(company.id))
                           && Column("companyId") == company.id).fetchCount(db)
        }
    }

    private func tick(_ orchestrator: Orchestrator) async throws {
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(30))
    }

    private func activity(_ store: Store, _ company: Company) throws -> [String] {
        try store.events(afterId: 0, limit: 500).filter { $0.companyId == company.id }.map(\.text)
    }

    @Test func plantedMarkerWithoutDBRowIgnored() async throws {
        let r = try await movedMainRig()
        let marker = BackupService.restoreMarker(paths: r.paths)
        try BrahmaPaths.ensurePrivateDirectory(marker.deletingLastPathComponent())
        // Whoever can create the file: a well-formed nonce, the right mode, but no restore ever recorded it.
        try Data((String(repeating: "ab", count: 32) + "\n").utf8).write(to: marker)
        chmod(marker.path, 0o600)

        try await tick(r.orchestrator)

        #expect(try r.store.company(id: r.acme.id)?.mainCommit == r.recorded)        // the unreviewed commit is not adopted
        #expect(r.events.all.isEmpty)                                                  // no restore handler ran
        let texts = try activity(r.store, r.acme)
        #expect(texts.contains { $0.hasPrefix("restore marker ignored: ") }, "\(texts)")
        #expect(!texts.contains { $0.contains("repos re-adopted") })
        #expect(!FileManager.default.fileExists(atPath: marker.path))                  // deleted (a plain file in run/)
        // Logged once: another tick adds nothing.
        try await tick(r.orchestrator)
        #expect(try activity(r.store, r.acme).filter { $0.hasPrefix("restore marker ignored: ") }.count == 1)
    }

    /// M1: when the live database's WAL cannot be checkpointed, its `-wal`/`-shm` are kept beside the pre-restore byte copy.
    @Test func checkpointFailureKeepsWalBesidePreviousCopy() throws {
        let env = try BackupEnv()
        _ = try env.company("Acme")
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        // A reader in this process (DBOpeners never lists the caller) holds a snapshot from before "Later": the TRUNCATE
        // checkpoint cannot finish, and Later's frames stay in the WAL.
        var config = Configuration()
        config.allowsUnsafeTransactions = true
        let reader = try DatabaseQueue(path: env.paths.database.path, configuration: config)
        try reader.inDatabase { db in
            try db.execute(sql: "BEGIN")
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM company")
        }
        _ = try env.company("Later")
        try env.store.close()
        var service2 = service
        service2.writer = nil
        let outcome = try service2.restore(try service2.planRestore(snapshot: snapshot))
        try reader.inDatabase { db in try db.execute(sql: "ROLLBACK") }
        try reader.close()

        let previous = try #require(outcome.previousCopy)
        #expect(outcome.warnings.contains { $0.contains("checkpoint") }, "\(outcome.warnings)")
        #expect(FileManager.default.fileExists(atPath: previous.path + "-wal"))
        // The byte copy together with its log is the database as it was: Later included.
        #expect(try env.companyNames(in: previous) == ["Acme", "Later"])
    }

    @Test func happyPathAdoptsRecordedMain() async throws {
        let r = try await restoredRig()
        let marker = BackupService.restoreMarker(paths: r.env.paths)
        var st = stat()
        #expect(lstat(marker.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && (st.st_mode & 0o7777) == 0o600)
        let nonce = try markerNonce(marker)
        #expect(nonce.count == 64)                                                       // 256 random bits, hex
        let row = try #require(try restoreRow(r.store, nonce))
        #expect(row["snapshot"] as String? == r.snapshot.lastPathComponent)
        #expect(row["consumedAt"] as Date? == nil)
        let recordedByRestore = try await r.store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT mainCommit FROM restoreMain WHERE nonce = ? AND companyId = ?", arguments: [nonce, r.acme.id])
        }
        #expect(recordedByRestore == r.recorded)

        try await tick(r.orchestrator)

        let company = try #require(try r.store.company(id: r.acme.id))
        #expect(company.mainCommit == r.recorded)
        #expect(company.pendingMainCommit == nil)
        #expect(r.events.all.count == 1 && r.events.all.first?.mainHead == r.recorded)
        #expect(r.events.all.first?.snapshotName == r.snapshot.lastPathComponent)
        #expect(try activity(r.store, r.acme).contains("restored from \(r.snapshot.lastPathComponent); repos re-adopted"))
        #expect(try restoreRow(r.store, nonce)?["consumedAt"] as Date? != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try r.store.checkMain(company: company)                                          // the guard agrees
        #expect(try mainAlertsOpen(r.store, r.acme) == 0)
    }

    @Test func matchingNonceButHeadMovedQuarantinesAndAlerts() async throws {
        let r = try await restoredRig()
        let marker = BackupService.restoreMarker(paths: r.env.paths)
        let nonce = try markerNonce(marker)
        // Between the restore and the engine's start, main moved to a commit nobody reviewed.
        let moved = try commitUnreviewed(r.acme)

        try await tick(r.orchestrator)

        let company = try #require(try r.store.company(id: r.acme.id))
        #expect(company.mainCommit == r.recorded)                                        // the restore's record, not git's head
        #expect(company.mainCommit != moved)
        #expect(company.pendingMainCommit == nil)
        #expect(r.events.all.isEmpty)                                                    // nothing re-adopted, no handler ran
        #expect(try mainAlertsOpen(r.store, r.acme) == 1)                                // 3a's main-moved owner alert
        #expect(throws: WorkError.conflict(Store.mainChangedMessage)) { try r.store.checkMain(company: company) }
        let texts = try activity(r.store, r.acme)
        #expect(texts.contains { $0.hasPrefix("restored from \(r.snapshot.lastPathComponent); main is not the commit") }, "\(texts)")
        #expect(!texts.contains { $0.contains("repos re-adopted") })
        #expect(try restoreRow(r.store, nonce)?["consumedAt"] as Date? != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func nonceConsumedOnce() async throws {
        let r = try await restoredRig()
        let marker = BackupService.restoreMarker(paths: r.env.paths)
        let nonce = try markerNonce(marker)
        try await tick(r.orchestrator)
        #expect(r.events.all.count == 1)
        // A replay: the same nonce in a fresh, well-formed marker, after main moved.
        try RestoreMarker.write(nonce: nonce, to: marker)
        let moved = try commitUnreviewed(r.acme)

        try await tick(r.orchestrator)

        #expect(try r.store.company(id: r.acme.id)?.mainCommit == r.recorded)
        #expect(try r.store.company(id: r.acme.id)?.mainCommit != moved)
        #expect(r.events.all.count == 1)
        #expect(try activity(r.store, r.acme).contains { $0.hasPrefix("restore marker ignored: ") })
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func symlinkOrWrongModeMarkerIgnored() async throws {
        let r = try await movedMainRig(moveMain: false)
        let nonce = try await r.store.writer.write { db in
            try BackupService.recordRestoreEvent(db, snapshot: "brahma-20260610T120000.000Z-manual.sqlite", now: Date())
        }
        let marker = BackupService.restoreMarker(paths: r.paths)
        try BrahmaPaths.ensurePrivateDirectory(marker.deletingLastPathComponent())
        func ignoredLines() throws -> [String] { try activity(r.store, r.acme).filter { $0.hasPrefix("restore marker ignored: ") } }

        // A symbolic link to a perfect marker elsewhere.
        let elsewhere = try tempDir().appending(path: "planted")
        try RestoreMarker.write(nonce: nonce, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: elsewhere)
        try await tick(r.orchestrator)
        #expect(try ignoredLines().last?.contains("symbolic link") == true)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: marker.path)) == nil)   // the link is gone
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))                              // its target untouched

        // The right nonce in a file others can read.
        try Data((nonce + "\n").utf8).write(to: marker)
        chmod(marker.path, 0o644)
        try await tick(r.orchestrator)
        #expect(try ignoredLines().last?.contains("mode") == true)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // The right nonce, mode 0600, but far too large.
        try Data((nonce + "\n" + String(repeating: "x", count: 64 * 1024)).utf8).write(to: marker)
        chmod(marker.path, 0o600)
        try await tick(r.orchestrator)
        #expect(try ignoredLines().last?.contains("too large") == true)
        #expect(try ignoredLines().count == 3)
        #expect(r.events.all.isEmpty)
        #expect(try restoreRow(r.store, nonce)?["consumedAt"] as Date? == nil)            // none of them used the event up

        // The real marker still works.
        try RestoreMarker.write(nonce: nonce, to: marker)
        try await tick(r.orchestrator)
        #expect(r.events.all.count == 1)
        #expect(try restoreRow(r.store, nonce)?["consumedAt"] as Date? != nil)
        #expect(try r.store.company(id: r.acme.id)?.mainCommit == r.recorded)
    }

    /// M4: the restore event and its marker are written before the search rebuild, so a failed rebuild still re-adopts.
    @Test func restoreWritesMarkerEvenWhenSearchRebuildFails() throws {
        let env = try BackupEnv()
        _ = try env.company("Acme")
        var service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        service.searchRebuild = { _ in throw RestoreError.failed("index broke") }
        let plan = try service.planRestore(snapshot: snapshot)
        #expect(throws: RestoreError.self) { try service.restore(plan) }
        let marker = BackupService.restoreMarker(paths: env.paths)
        let nonce = try markerNonce(marker)
        let store = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        let row = try #require(try restoreRow(store, nonce))
        #expect(row["consumedAt"] as Date? == nil)
    }

    #if os(macOS)
    /// M3: a hung `lsof` is killed after its awake-time bound and the restore is refused (`cannotCheckOpeners`).
    @Test func lsofThatHangsIsKilledAndRefused() throws {
        let dir = try tempDir()
        let db = dir.appending(path: "x.sqlite")
        try Data("x".utf8).write(to: db)
        let hung = dir.appending(path: "lsof-hung")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: hung)
        chmod(hung.path, 0o755)
        let start = AwakeTime.uptime()
        #expect(throws: RestoreError.cannotCheckOpeners) { try DBOpeners.pids(of: db, lsof: hung.path, timeout: 0.5) }
        #expect(AwakeTime.uptime() - start < 10)
        // A prompt one is read as before (the caller is never listed).
        let quick = dir.appending(path: "lsof-quick")
        try Data("#!/bin/sh\necho 4242\necho \(getpid())\nexit 0\n".utf8).write(to: quick)
        chmod(quick.path, 0o755)
        #expect(try DBOpeners.pids(of: db, lsof: quick.path, timeout: 5) == [4242])
    }
    #endif

    /// M1 (continued): the checkpoint failure reaches the activity log when the restore is taken up.
    @Test func checkpointWarningIsLoggedAsActivity() async throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        let snapshot = try env.service().snapshot(reason: .manual)
        let store = env.store
        let nonce = try await store.writer.write { db in
            try BackupService.recordRestoreEvent(db, snapshot: snapshot.lastPathComponent, now: Date(),
                                                 notes: ["the live database could not be checkpointed; its -wal/-shm were kept"])
        }
        try RestoreMarker.write(nonce: nonce, to: BackupService.restoreMarker(paths: env.paths))
        let orchestrator = Orchestrator(store: store, runner: FakeTurnRunner(), paths: env.paths, mcpExecutable: "/usr/local/bin/brahma",
                                        clock: TestClock().function, vault: MemoryVault())
        try await tick(orchestrator)
        #expect(try activity(store, acme).contains { $0.contains("could not be checkpointed") })
    }

    // MARK: Task 13a (Task 12 re-review minors)

    /// (a) A restore whose marker cannot be written does not leave a live nonce behind: the event is consumed.
    @Test func markerWriteFailureConsumesEvent() throws {
        let env = try BackupEnv()
        _ = try env.company("Acme")
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        let marker = BackupService.restoreMarker(paths: env.paths)
        // A directory where the marker goes: the rename onto it fails after the event was committed.
        try FileManager.default.createDirectory(at: marker.appending(path: "blocker"), withIntermediateDirectories: true)
        let plan = try service.planRestore(snapshot: snapshot)
        #expect(throws: RestoreError.self) { try service.restore(plan) }
        let store = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        let rows = try store.writer.read { db in try Row.fetchAll(db, sql: "SELECT nonce, consumedAt FROM restoreEvent") }
        #expect(rows.count == 1)
        #expect(rows.allSatisfy { ($0["consumedAt"] as Date?) != nil }, "a nonce nobody can use must not stay valid")
    }

    private func insertEvent(_ store: Store, nonce: String, at seconds: TimeInterval) async throws {
        try await store.writer.write { db in
            try Migrations.createRestoreTables(db)
            try db.execute(sql: "INSERT INTO restoreEvent (nonce, snapshot, restoredAt, notes) VALUES (?, 'x.sqlite', ?, '')",
                           arguments: [nonce, Date(timeIntervalSince1970: seconds)])
        }
    }

    /// (a) Unconsumed events older than the newest expire: on the first tick with no marker, and when a restore is taken up.
    @Test func staleEventExpires() async throws {
        let old = String(repeating: "a1", count: 32), newest = String(repeating: "b2", count: 32)
        // No marker: the first tick consumes everything older than the newest, and leaves the newest.
        let r = try await movedMainRig(moveMain: false)
        try await insertEvent(r.store, nonce: old, at: 1_000)
        try await insertEvent(r.store, nonce: newest, at: 2_000)
        try await tick(r.orchestrator)
        #expect(try restoreRow(r.store, old)?["consumedAt"] as Date? != nil)
        #expect(try restoreRow(r.store, newest)?["consumedAt"] as Date? == nil)
        // The stale nonce cannot be replayed into a marker: main is not rolled back, and the attempt is logged.
        let marker = BackupService.restoreMarker(paths: r.paths)
        try BrahmaPaths.ensurePrivateDirectory(marker.deletingLastPathComponent())
        try RestoreMarker.write(nonce: old, to: marker)
        try await tick(r.orchestrator)
        #expect(r.events.all.isEmpty)
        #expect(try activity(r.store, r.acme).contains { $0.hasPrefix("restore marker ignored: ") })

        // Take-up: the marker names the newest; an older unconsumed event goes with it.
        let t = try await movedMainRig(moveMain: false)
        try await insertEvent(t.store, nonce: old, at: 1_000)
        try await insertEvent(t.store, nonce: newest, at: 2_000)
        let tMarker = BackupService.restoreMarker(paths: t.paths)
        try BrahmaPaths.ensurePrivateDirectory(tMarker.deletingLastPathComponent())
        try RestoreMarker.write(nonce: newest, to: tMarker)
        try await tick(t.orchestrator)
        #expect(try restoreRow(t.store, newest)?["consumedAt"] as Date? != nil)
        #expect(try restoreRow(t.store, old)?["consumedAt"] as Date? != nil)
    }

    /// (c) A `main` that is a symbolic ref is never re-adopted, even when it resolves to the recorded commit.
    @Test func restoreWithSymbolicMainRefused() async throws {
        let r = try await restoredRig()
        let marker = BackupService.restoreMarker(paths: r.env.paths)
        let nonce = try markerNonce(marker)
        let fixture = GitFixture(existing: URL(fileURLWithPath: r.acme.workspacePath, isDirectory: true))
        try fixture.git(["branch", "elsewhere", r.recorded])
        try fixture.git(["symbolic-ref", "refs/heads/main", "refs/heads/elsewhere"])
        #expect(try fixture.git(["rev-parse", "refs/heads/main"]) == r.recorded)          // it resolves to the recorded commit

        try await tick(r.orchestrator)

        #expect(r.events.all.isEmpty)                                                       // nothing re-adopted, no handler ran
        let texts = try activity(r.store, r.acme)
        #expect(texts.contains { $0.hasPrefix("restored from \(r.snapshot.lastPathComponent); main is not the commit") }, "\(texts)")
        #expect(!texts.contains { $0.contains("repos re-adopted") })
        #expect(try restoreRow(r.store, nonce)?["consumedAt"] as Date? != nil)
        #expect(try r.store.company(id: r.acme.id)?.mainCommit == r.recorded)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
