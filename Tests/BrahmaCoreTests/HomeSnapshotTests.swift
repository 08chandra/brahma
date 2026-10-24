import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 13a: data-home snapshots and restore of the files to any point.
@Suite struct HomeSnapshotTests {
    struct Rig {
        let root: URL
        let paths: BrahmaPaths
        let clock = StepClock(Date(timeIntervalSince1970: 1_781_107_200))

        init() throws {
            root = try tempDir()
            paths = ownerPaths(root)
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        }

        func url(_ relative: String) -> URL { paths.home.appending(path: relative) }

        func put(_ relative: String, _ text: String) throws {
            let u = url(relative)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }

        func read(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }

        func makeSQLite(_ relative: String, rows: [String]) throws {
            let u = url(relative)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            let queue = try DatabaseQueue(path: u.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS note (text TEXT)")
                for row in rows { try db.execute(sql: "INSERT INTO note VALUES (?)", arguments: [row]) }
            }
            try queue.close()
        }

        func take() throws -> HomeSnapshotInfo { try HomeSnapshot.take(paths: paths, now: clock.next()).info }

        func inode(_ info: HomeSnapshotInfo, _ relative: String) -> (ino: UInt64, links: UInt16)? {
            var st = stat()
            guard stat(info.treeURL.appending(path: relative).path, &st) == 0 else { return nil }
            return (UInt64(st.st_ino), UInt16(st.st_nlink))
        }
    }

    @Test func includesArchivesTranscriptsRoleCardsExcludesCaches() throws {
        let rig = try Rig()
        try rig.makeSQLite("archive/acme/notes.sqlite", rows: ["one", "two"])
        try rig.put("transcripts/c1/a1/s1/t1.jsonl.gz", "gz bytes")
        try rig.put("companies/c1/roles/ceo.md", "# CEO")
        try rig.put("packs/p/pack.json", "{}")
        // Excluded: run/, backups/, tmp/, cache/, sidecars, locks and the live database.
        try rig.put("run/orchestrator.lock", "x")
        try rig.put("run/exports/e1/data", "x")
        try rig.put("backups/db/brahma-old.sqlite", "x")
        try rig.put("tmp/staging", "x")
        try rig.put("cache/blob", "x")
        try rig.put("brahma.sqlite", "live")
        try rig.put("brahma.sqlite-wal", "wal")
        try rig.put("brahma.sqlite-shm", "shm")
        try rig.put("companies/c1/thing.lock", "x")
        try rig.put("archive/acme/notes.sqlite-wal", "wal")
        try rig.put("archive/acme/notes.sqlite-shm", "shm")
        // A link is never followed or recorded.
        try FileManager.default.createSymbolicLink(at: rig.url("companies/c1/escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))

        let result = try HomeSnapshot.take(paths: rig.paths, now: rig.clock.next())
        let info = result.info
        let included = try HomeSnapshot.relativeFiles(under: info.treeURL).sorted()
        #expect(included == ["archive/acme/notes.sqlite", "companies/c1/roles/ceo.md", "packs/p/pack.json",
                             "transcripts/c1/a1/s1/t1.jsonl.gz"])
        for relative in ["run/orchestrator.lock", "backups/db/brahma-old.sqlite", "tmp/staging", "cache/blob", "brahma.sqlite",
                         "brahma.sqlite-wal", "companies/c1/thing.lock"] {
            #expect(HomeSnapshot.excluded(relative), "\(relative) should be excluded")
        }
        for relative in ["archive/a.sqlite", "transcripts/x", "companies/c1/roles/r.md", "notes.txt"] {
            #expect(!HomeSnapshot.excluded(relative), "\(relative) should be included")
        }
        // The SQLite file is a verified VACUUM INTO copy.
        let copy = info.treeURL.appending(path: "archive/acme/notes.sqlite")
        #expect(BackupService.integrity(of: copy) == ["ok"])
        let queue = try BackupService.openForReading(copy)
        #expect(try queue.read { db in try String.fetchAll(db, sql: "SELECT text FROM note ORDER BY rowid") } == ["one", "two"])
        try queue.close()
        let manifest = try HomeSnapshot.manifest(of: info)
        #expect(Set(manifest.files.keys) == Set(included))
        #expect(manifest.files["archive/acme/notes.sqlite"]?.kind == "sqlite")
        // Staging is gone from tmp/.
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.paths.tmpDir.path).sorted() == ["staging"])
        #expect(result.problems.isEmpty)
        // Snapshots are private.
        var st = stat()
        #expect(stat(info.url.appending(path: "MANIFEST.json").path, &st) == 0 && st.st_mode & 0o777 == 0o600)
    }

    @Test func unchangedFilesAreHardLinked() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "# CEO")
        try rig.put("companies/c1/roles/cto.md", "# CTO v1")
        try rig.makeSQLite("archive/acme/notes.sqlite", rows: ["one"])
        let first = try rig.take()
        try rig.put("companies/c1/roles/cto.md", "# CTO v2")
        try rig.makeSQLite("archive/other/new.sqlite", rows: ["n"])
        let second = try rig.take()
        let a = try #require(rig.inode(first, "companies/c1/roles/ceo.md"))
        let b = try #require(rig.inode(second, "companies/c1/roles/ceo.md"))
        #expect(a.ino == b.ino)
        #expect(b.links >= 2)
        // A changed file is a new file; the old snapshot keeps its content.
        let c = try #require(rig.inode(first, "companies/c1/roles/cto.md"))
        let d = try #require(rig.inode(second, "companies/c1/roles/cto.md"))
        #expect(c.ino != d.ino)
        #expect(try String(contentsOf: first.treeURL.appending(path: "companies/c1/roles/cto.md"), encoding: .utf8) == "# CTO v1")
        #expect(try String(contentsOf: second.treeURL.appending(path: "companies/c1/roles/cto.md"), encoding: .utf8) == "# CTO v2")
        // An unchanged SQLite file is linked too (the same VACUUM INTO bytes).
        let e = try #require(rig.inode(first, "archive/acme/notes.sqlite"))
        let f = try #require(rig.inode(second, "archive/acme/notes.sqlite"))
        #expect(e.ino == f.ino)
    }

    @Test func restoreAnyPointWithFiles() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo v1")
        try rig.put("transcripts/c1/a/s/t1.jsonl.gz", "t1")
        try rig.makeSQLite("archive/acme/notes.sqlite", rows: ["v1"])
        let s1 = try rig.take()
        try rig.put("companies/c1/roles/ceo.md", "ceo v2")
        try rig.put("transcripts/c1/a/s/t2.jsonl.gz", "t2")
        try rig.makeSQLite("archive/acme/notes.sqlite", rows: ["v2"])
        let s2 = try rig.take()
        try rig.put("companies/c1/roles/ceo.md", "ceo v3")
        try FileManager.default.removeItem(at: rig.url("transcripts/c1/a/s/t1.jsonl.gz"))
        try rig.put("run/orchestrator.lock", "pid")                    // excluded: untouched by a restore
        try rig.put("cache/blob", "cached")

        // Back to the first point.
        let outcome = try HomeSnapshot.restore(s1, paths: rig.paths, now: rig.clock.next())
        #expect(rig.read("companies/c1/roles/ceo.md") == "ceo v1")
        #expect(rig.read("transcripts/c1/a/s/t1.jsonl.gz") == "t1")             // deleted since: back
        #expect(rig.read("transcripts/c1/a/s/t2.jsonl.gz") == nil)              // made after the point: moved away
        let queue = try DatabaseQueue(path: rig.url("archive/acme/notes.sqlite").path)
        #expect(try queue.read { db in try String.fetchAll(db, sql: "SELECT text FROM note") } == ["v1"])
        try queue.close()
        #expect(rig.read("run/orchestrator.lock") == "pid" && rig.read("cache/blob") == "cached")
        // What was overwritten or moved is kept under .pre-restore-<stamp>/.
        let kept = outcome.preRestore
        #expect(kept.lastPathComponent.hasPrefix(".pre-restore-"))
        #expect(try String(contentsOf: kept.appending(path: "companies/c1/roles/ceo.md"), encoding: .utf8) == "ceo v3")
        #expect(try String(contentsOf: kept.appending(path: "transcripts/c1/a/s/t2.jsonl.gz"), encoding: .utf8) == "t2")
        #expect(outcome.restored == 3)

        // Forward to the second point; a new snapshot does not carry the pre-restore directory.
        _ = try HomeSnapshot.restore(s2, paths: rig.paths, now: rig.clock.next())
        #expect(rig.read("companies/c1/roles/ceo.md") == "ceo v2")
        #expect(rig.read("transcripts/c1/a/s/t2.jsonl.gz") == "t2")
        let s3 = try rig.take()
        #expect(try HomeSnapshot.relativeFiles(under: s3.treeURL).allSatisfy { !$0.hasPrefix(".pre-restore-") })
    }

    @Test func restoreRefusesDamagedSnapshotBeforeChangingAnything() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo v1")
        let s1 = try rig.take()
        try rig.put("companies/c1/roles/ceo.md", "ceo v2")
        try Data("tampered".utf8).write(to: s1.treeURL.appending(path: "companies/c1/roles/ceo.md"))
        #expect(throws: HomeSnapshotError.self) { try HomeSnapshot.restore(s1, paths: rig.paths, now: rig.clock.next()) }
        #expect(rig.read("companies/c1/roles/ceo.md") == "ceo v2")
    }

    @Test func pruneKeeps30() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "x")
        var last: HomeSnapshotInfo?
        for _ in 0..<32 { last = try rig.take() }
        let all = HomeSnapshot.list(paths: rig.paths)
        #expect(HomeSnapshot.keepDaily == 30)
        #expect(all.count == 30)
        #expect(all.first == last)                                       // newest first
        // The oldest two are gone; the survivors still restore (their links were not broken by the prune).
        try rig.put("companies/c1/roles/ceo.md", "changed")
        _ = try HomeSnapshot.restore(try #require(all.last), paths: rig.paths, now: rig.clock.next())
        #expect(rig.read("companies/c1/roles/ceo.md") == "x")
    }

    @Test func atOrBeforePicksTheNewest() throws {
        let rig = try Rig()
        try rig.put("a", "x")
        let s1 = try rig.take(), s2 = try rig.take(), s3 = try rig.take()
        #expect(HomeSnapshot.newest(atOrBefore: s2.date, paths: rig.paths) == s2)
        #expect(HomeSnapshot.newest(atOrBefore: s2.date.addingTimeInterval(0.5), paths: rig.paths) == s2)
        #expect(HomeSnapshot.newest(atOrBefore: s3.date.addingTimeInterval(100), paths: rig.paths) == s3)
        #expect(HomeSnapshot.newest(atOrBefore: s1.date.addingTimeInterval(-1), paths: rig.paths) == nil)
    }

    // MARK: Restore of the database and the files together

    @Test func restorePlanCarriesTheHomeSnapshotAtOrBeforeTheDatabaseSnapshot() throws {
        let env = try BackupEnv()
        _ = try env.company("Acme")
        let service = env.service(start: Date(timeIntervalSince1970: 1_781_107_200))
        try FileManager.default.createDirectory(at: env.paths.home.appending(path: "companies/c1/roles"), withIntermediateDirectories: true)
        let role = env.paths.home.appending(path: "companies/c1/roles/ceo.md")
        try Data("v1".utf8).write(to: role)
        let early = try HomeSnapshot.take(paths: env.paths, now: Date(timeIntervalSince1970: 1_781_107_100)).info
        try Data("v2".utf8).write(to: role)
        let later = try HomeSnapshot.take(paths: env.paths, now: Date(timeIntervalSince1970: 1_781_107_190)).info
        _ = try HomeSnapshot.take(paths: env.paths, now: Date(timeIntervalSince1970: 1_781_107_900))        // after the DB snapshot
        let db = try service.snapshot(reason: .manual)                                                        // 1_781_107_200
        try Data("v3".utf8).write(to: role)
        try env.store.close()

        let plan = try service.planRestore(snapshot: db)
        #expect(plan.homeSnapshot == later)
        #expect(plan.homeSnapshot != early)
        // Without --with-files the files are not touched.
        _ = try service.restore(plan)
        #expect(try String(contentsOf: role, encoding: .utf8) == "v3")
        // With them, the home returns to that point as well.
        let again = try service.planRestore(snapshot: db)
        let outcome = try service.restore(again, withFiles: true)
        #expect(try String(contentsOf: role, encoding: .utf8) == "v2")
        #expect(outcome.filesRestored >= 1)
        #expect(outcome.filesPreRestore?.lastPathComponent.hasPrefix(".pre-restore-") == true)
    }

    @Test func withFilesWithoutAHomeSnapshotChangesNothing() throws {
        let env = try BackupEnv()
        _ = try env.company("Acme")
        let service = env.service()
        let db = try service.snapshot(reason: .manual)
        try env.store.close()
        let plan = try service.planRestore(snapshot: db)
        #expect(plan.homeSnapshot == nil)
        #expect(throws: RestoreError.self) { try service.restore(plan, withFiles: true) }
        #expect(!FileManager.default.fileExists(atPath: BackupService.restoreMarker(paths: env.paths).path))
    }

    @Test func backupHomeJobTakesASnapshot() async throws {
        let env = try BackupEnv()
        try FileManager.default.createDirectory(at: env.paths.home.appending(path: "archive/acme"), withIntermediateDirectories: true)
        try Data("memo".utf8).write(to: env.paths.home.appending(path: "archive/acme/memo.md"))
        let timer = EngineTimer(id: "t", companyId: nil, name: "backup.home", action: .job("backup.home"),
                                schedule: .daily(hour: 4, minute: 0), nextFireAt: Date(), lastFiredAt: nil, enabled: true, createdAt: Date())
        let context = TimerContext(store: env.store, paths: env.paths, timer: timer, now: Date(), blocking: Blocking())
        let job = try #require(TimerJobRegistry.system.job("backup.home"))
        try await job(context)
        let snapshots = HomeSnapshot.list(paths: env.paths)
        #expect(snapshots.count == 1)
        #expect(try HomeSnapshot.relativeFiles(under: try #require(snapshots.first).treeURL) == ["archive/acme/memo.md"])
    }
}
