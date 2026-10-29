import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 13a: data-home snapshots and restore of the files to any point.
@Suite(.scratch) struct HomeSnapshotTests {
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

    // MARK: Fix round 1 (S2): no link is followed out of the home; manifest paths are validated

    /// A symlinked directory under the home (planted after the snapshot) must not redirect the restore: that entry is refused
    /// and reported, the link's target is untouched, and every other entry is restored.
    @Test func symlinkedSubdirectoryInHomeRefused() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo v1")
        try rig.put("companies/c2/deep/a/b.md", "b v1")
        try rig.put("transcripts/c1/a/s/t1.jsonl.gz", "t1 v1")
        let s1 = try rig.take()
        try rig.put("transcripts/c1/a/s/t1.jsonl.gz", "t1 v2")
        // Outside the home: what the links point at.
        let outside = rig.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appending(path: "ceo.md"))
        let outsideDeep = rig.root.appending(path: "outside-deep", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outsideDeep.appending(path: "a"), withIntermediateDirectories: true)
        try Data("outside b".utf8).write(to: outsideDeep.appending(path: "a/b.md"))
        // The leaf directory and a middle directory are each replaced by a link.
        try FileManager.default.removeItem(at: rig.url("companies/c1/roles"))
        try FileManager.default.createSymbolicLink(at: rig.url("companies/c1/roles"), withDestinationURL: outside)
        try FileManager.default.removeItem(at: rig.url("companies/c2/deep"))
        try FileManager.default.createSymbolicLink(at: rig.url("companies/c2/deep"), withDestinationURL: outsideDeep)

        let outcome = try HomeSnapshot.restore(s1, paths: rig.paths, now: rig.clock.next())
        // Refused and reported, by name.
        #expect(outcome.refused.contains { $0.hasPrefix("companies/c1/roles/ceo.md") }, "\(outcome.refused)")
        #expect(outcome.refused.contains { $0.hasPrefix("companies/c2/deep/a/b.md") }, "\(outcome.refused)")
        #expect(outcome.refused.allSatisfy { $0.contains("symbolic link") }, "\(outcome.refused)")
        // Nothing outside the home changed: no file written, none moved away.
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() == ["ceo.md"])
        #expect(try String(contentsOf: outside.appending(path: "ceo.md"), encoding: .utf8) == "outside")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outsideDeep.appending(path: "a").path).sorted() == ["b.md"])
        #expect(try String(contentsOf: outsideDeep.appending(path: "a/b.md"), encoding: .utf8) == "outside b")
        // The links stay links (the restore never writes through or replaces them).
        var st = stat()
        #expect(lstat(rig.url("companies/c1/roles").path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK)
        // The other entry is restored.
        #expect(rig.read("transcripts/c1/a/s/t1.jsonl.gz") == "t1 v1")
        #expect(outcome.restored == 1)
        // The pre-restore directory holds only what the restore really replaced, from inside the home.
        #expect(try String(contentsOf: outcome.preRestore.appending(path: "transcripts/c1/a/s/t1.jsonl.gz"), encoding: .utf8) == "t1 v2")
        #expect(!FileManager.default.fileExists(atPath: outcome.preRestore.appending(path: "companies").path))
    }

    /// The take side never reads through a link either: a linked directory or file under the home is not in the snapshot.
    @Test func takeDoesNotFollowLinkedDirectories() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo")
        let outside = rig.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret outside".utf8).write(to: outside.appending(path: "private.md"))
        try FileManager.default.createSymbolicLink(at: rig.url("companies/c1/files"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: rig.url("companies/c1/linked.md"),
                                                   withDestinationURL: outside.appending(path: "private.md"))
        let info = try rig.take()
        #expect(try HomeSnapshot.relativeFiles(under: info.treeURL).sorted() == ["companies/c1/roles/ceo.md"])
        #expect(Set(try HomeSnapshot.manifest(of: info).files.keys) == ["companies/c1/roles/ceo.md"])
    }

    /// S7: a file under the home with another hard link (to a file outside, an owner secret) is never copied, by a snapshot
    /// or by a company export: it is left out and named; the outside file is untouched.
    @Test func multiplyLinkedFilesAreNeverCopied() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo")
        let secret = rig.root.appending(path: "secret")
        try Data("SECRET-BYTES".utf8).write(to: secret)
        try FileManager.default.linkItem(at: secret, to: rig.url("companies/c1/roles/leak.md"))
        let result = try HomeSnapshot.take(paths: rig.paths, now: rig.clock.next())
        #expect(try HomeSnapshot.relativeFiles(under: result.info.treeURL).sorted() == ["companies/c1/roles/ceo.md"])
        #expect(result.problems.contains { $0.contains("leak.md") && $0.contains("hard link") }, "\(result.problems)")
        // The exporter's tree copy.
        let home = try HomeFiles.root(rig.paths.home, create: false)
        let roles = try HomeFiles.walk(home, ["companies", "c1", "roles"], create: false)
        let out = rig.root.appending(path: "export-roles", directoryHint: .isDirectory)
        var skipped: [String] = []
        try CompanyExporter.copyTree(from: roles, to: out, relative: "roles", sqlite: false, tmpDir: rig.paths.tmpDir, skipped: &skipped)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["ceo.md"])
        #expect(skipped.contains { $0.contains("leak.md") && $0.contains("hard link") }, "\(skipped)")
        #expect(try String(contentsOf: secret, encoding: .utf8) == "SECRET-BYTES")
    }

    /// A manifest naming a path outside the tree (or one no snapshot writes) makes the whole restore refuse before anything
    /// changes, even when a file with the recorded hash sits where that path leads.
    @Test func manifestPathTraversalRefused() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo v1")
        let s1 = try rig.take()
        try rig.put("companies/c1/roles/ceo.md", "ceo v2")
        let bait = Data("bait".utf8)
        let baitURL = s1.url.appending(path: "bait")
        try bait.write(to: baitURL)
        let baitHash = try HomeSnapshot.fileHash(baitURL)
        // Files where the bad paths would lead, so only the path check can stop them.
        try bait.write(to: s1.url.appending(path: "x"))
        try FileManager.default.createDirectory(at: s1.treeURL.appending(path: "etc"), withIntermediateDirectories: true)
        try bait.write(to: s1.treeURL.appending(path: "etc/x"))
        let original = try HomeSnapshot.manifest(of: s1)
        for bad in ["../x", "/etc/x", "companies/../../x", "a\u{0}b", "companies//c1", "./companies/x", "companies/c1/",
                    "", "line\nbreak", "tab\there", "del\u{7f}x", ".."] {
            var tampered = original
            tampered.files[bad] = .init(size: 4, mtimeNs: 0, sha: baitHash, kind: "file")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(tampered).write(to: s1.manifestURL)
            #expect(HomeSnapshot.pathProblem(bad) != nil, "\(bad.debugDescription) should be refused")
            do {
                _ = try HomeSnapshot.restore(s1, paths: rig.paths, now: rig.clock.next())
                Issue.record("\(bad.debugDescription) restored")
            } catch let error as HomeSnapshotError {
                #expect("\(error)".contains("is not a path a snapshot may hold"), "\(bad.debugDescription): \(error)")
            }
            #expect(rig.read("companies/c1/roles/ceo.md") == "ceo v2")
            #expect(!FileManager.default.fileExists(atPath: rig.root.appending(path: "x").path))
            #expect(!FileManager.default.fileExists(atPath: rig.url("etc").path))
        }
    }

    /// m3: `..` inside a name is an ordinary name; only a whole `..` component is refused.
    @Test func dotsInsideANameAreAllowed() throws {
        let rig = try Rig()
        try rig.put("companies/c1/files/a..b.md", "dots v1")
        try rig.put("companies/c1/files/..hidden", "hidden v1")
        let s1 = try rig.take()
        try rig.put("companies/c1/files/a..b.md", "dots v2")
        #expect(HomeSnapshot.pathProblem("companies/c1/files/a..b.md") == nil)
        #expect(HomeSnapshot.pathProblem("companies/c1/files/..hidden") == nil)
        #expect(HomeSnapshot.pathProblem("companies/../x") != nil)
        _ = try HomeSnapshot.verify(s1)
        let outcome = try HomeSnapshot.restore(s1, paths: rig.paths, now: rig.clock.next())
        #expect(outcome.refused.isEmpty)
        #expect(rig.read("companies/c1/files/a..b.md") == "dots v1")
        #expect(rig.read("companies/c1/files/..hidden") == "hidden v1")
    }

    // MARK: Fix round 2 (S4 + re-review)

    /// Writes `MANIFEST.json` by hand, so keys a Swift dictionary would merge (NFC vs NFD) can both be present.
    private func writeManifest(_ info: HomeSnapshotInfo, keys: [String], sha: String) throws {
        func quoted(_ text: String) throws -> String { String(decoding: try JSONEncoder().encode(text), as: UTF8.self) }
        let entries = try keys.map { "\(try quoted($0)): {\"size\": 1, \"mtimeNs\": 0, \"sha\": \(try quoted(sha)), \"kind\": \"file\"}" }
        let text = "{\"format\": 1, \"takenAt\": \"2026-06-10T16:00:00Z\", \"files\": {\(entries.joined(separator: ", "))}}"
        try Data(text.utf8).write(to: info.manifestURL)
    }

    /// S4 #1: exclusions and collisions compare case- and normalization-insensitively (APFS is both by default).
    @Test func manifestCaseAndNormalizationCollisionsRefused() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo v1")
        let s1 = try rig.take()
        try rig.put("companies/c1/roles/ceo.md", "ceo v2")
        let sha = try #require(try HomeSnapshot.manifest(of: s1).files["companies/c1/roles/ceo.md"]).sha
        let cases: [[String]] = [
            ["Brahma.SQLITE"], ["BRAHMA.sqlite-wal"], ["RUN/orchestrator.pid"], ["Backups/x"], ["companies/c1/notes.SQLITE-SHM"],
            ["companies/c1/x.Lock"], ["companies/c1/x.sqlite-journal"], [".Pre-Restore-x/y"],
            ["companies/c1/Roles/CEO.md"],                                          // differs from the real key only in case
            ["companies/c1/caf\u{e9}.md", "companies/c1/cafe\u{301}.md"],           // NFC and NFD spellings of one name
        ]
        for extra in cases {
            try writeManifest(s1, keys: ["companies/c1/roles/ceo.md"] + extra, sha: sha)
            do {
                _ = try HomeSnapshot.restore(s1, paths: rig.paths, now: rig.clock.next())
                Issue.record("\(extra) restored")
            } catch let error as HomeSnapshotError {
                #expect("\(error)".contains("is not a path a snapshot may hold"), "\(extra): \(error)")
            }
            #expect(rig.read("companies/c1/roles/ceo.md") == "ceo v2", "\(extra)")
        }
        #expect(HomeSnapshot.excluded("Brahma.SQLITE") && HomeSnapshot.excluded("Cache/x") && HomeSnapshot.excluded("a/b.SQLITE-WAL"))
        #expect(HomeSnapshot.excluded("a/b.sqlite-journal"))
    }

    /// S4 #1 on the take side: the same normalized comparison decides what is left out.
    @Test func takeSideExclusionsAreCaseInsensitive() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo")
        try rig.put("Brahma.SQLITE-copy", "db copy")
        try rig.put("companies/c1/x.SQLITE-WAL", "wal")
        try rig.put("companies/c1/y.Lock", "lock")
        try rig.put("companies/c1/z.sqlite-journal", "journal")
        try rig.put("Cache/blob", "cached")
        let info = try rig.take()
        #expect(try HomeSnapshot.relativeFiles(under: info.treeURL).sorted() == ["companies/c1/roles/ceo.md"])
    }

    /// Re-review: verify changes nothing, not even a missing snapshot tree.
    @Test func verifyCreatesNothing() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo")
        let s1 = try rig.take()
        try FileManager.default.removeItem(at: s1.treeURL)
        #expect(throws: HomeSnapshotError.self) { try HomeSnapshot.verify(s1) }
        #expect(!FileManager.default.fileExists(atPath: s1.treeURL.path))
    }

    /// Re-review: a leaf file replaced by a link is moved aside as a link; nothing is written through it.
    @Test func leafFileSymlinkMovedAsideOnRestore() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo v1")
        let s1 = try rig.take()
        let outside = rig.root.appending(path: "outside.md")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: rig.url("companies/c1/roles/ceo.md"))
        try FileManager.default.createSymbolicLink(at: rig.url("companies/c1/roles/ceo.md"), withDestinationURL: outside)
        let outcome = try HomeSnapshot.restore(s1, paths: rig.paths, now: rig.clock.next())
        var st = stat()
        #expect(lstat(rig.url("companies/c1/roles/ceo.md").path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG)
        #expect(rig.read("companies/c1/roles/ceo.md") == "ceo v1")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
        #expect(lstat(outcome.preRestore.appending(path: "companies/c1/roles/ceo.md").path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK)
    }

    /// S4 #2: a directory swapped for a link between the walk and the copy of a SQLite file: refused, the outside database
    /// never read into the snapshot and never opened (no sidecar appears next to it).
    @Test func sqliteSwapSeamRefusedOnTake() throws {
        let rig = try Rig()
        try rig.makeSQLite("archive/acme/notes.sqlite", rows: ["inside"])
        try rig.makeSQLite("archive/leaf/notes.sqlite", rows: ["inside leaf"])
        let outside = rig.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: outside.appending(path: "notes.sqlite").path)
        try queue.write { db in try db.execute(sql: "CREATE TABLE note (text TEXT); INSERT INTO note VALUES ('OUTSIDE')") }
        try queue.close()
        let before = try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted()
        let paths = rig.paths
        let result = try HomeSnapshot.$sqliteCopyProbe.withValue({ relative in
            let fm = FileManager.default
            if relative == "archive/acme/notes.sqlite" {                        // a directory on the way becomes a link
                try? fm.moveItem(at: paths.home.appending(path: "archive/acme"), to: paths.home.appending(path: "archive/acme-moved"))
                try? fm.createSymbolicLink(at: paths.home.appending(path: "archive/acme"), withDestinationURL: outside)
            } else if relative == "archive/leaf/notes.sqlite" {                 // the file itself becomes a link
                try? fm.removeItem(at: paths.home.appending(path: "archive/leaf/notes.sqlite"))
                try? fm.createSymbolicLink(at: paths.home.appending(path: "archive/leaf/notes.sqlite"),
                                           withDestinationURL: outside.appending(path: "notes.sqlite"))
            }
        }) { try HomeSnapshot.take(paths: rig.paths, now: rig.clock.next()) }
        #expect(result.problems.contains { $0.hasPrefix("archive/acme/notes.sqlite") }, "\(result.problems)")
        #expect(result.problems.contains { $0.hasPrefix("archive/leaf/notes.sqlite") }, "\(result.problems)")
        let manifest = try HomeSnapshot.manifest(of: result.info)
        #expect(manifest.files["archive/acme/notes.sqlite"] == nil && manifest.files["archive/leaf/notes.sqlite"] == nil)
        for relative in try HomeSnapshot.relativeFiles(under: result.info.treeURL) {
            let data = try Data(contentsOf: result.info.treeURL.appending(path: relative))
            #expect(data.range(of: Data("OUTSIDE".utf8)) == nil, "\(relative)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() == before)
        // Staging is gone from tmp/.
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.paths.tmpDir.path).isEmpty)
    }

    /// S4 #2: a live WAL-mode archive (writer open, nothing checkpointed) is snapshotted from a private copy of the file and
    /// its -wal: every committed row is there and the copy passes its integrity check.
    @Test func liveWALArchiveSnapshotFromPrivateCopy() throws {
        let rig = try Rig()
        let live = rig.url("archive/acme/live.sqlite")
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try DatabaseQueue(path: live.path)
        defer { try? writer.close() }
        try writer.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "CREATE TABLE note (text TEXT)")
            for n in 0..<40 { try db.execute(sql: "INSERT INTO note VALUES (?)", arguments: ["row \(n)"]) }
        }
        #expect(FileManager.default.fileExists(atPath: live.path + "-wal"))
        let info = try rig.take()
        let copy = info.treeURL.appending(path: "archive/acme/live.sqlite")
        #expect(BackupService.integrity(of: copy) == ["ok"])
        let reader = try BackupService.openForReading(copy)
        #expect(try reader.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note") } == 40)
        try reader.close()
    }

    // MARK: Fix round 3

    /// X1: the owner-key file store and the file secret vault are never in a snapshot, and a restore never rolls them back.
    @Test func ownerKeyAndFileVaultExcluded() throws {
        let rig = try Rig()
        try rig.put("companies/c1/roles/ceo.md", "ceo")
        try rig.put("owner.key", "key v1")
        try rig.put(".owner.key.0D4C", "key temp")
        try rig.put("owner/keyhash", "hash v1")
        try rig.put("secrets/vault.json", #"{"STRIPE_KEY":"sk-plain-secret-0123456789"}"#)
        let s1 = try rig.take()
        #expect(try HomeSnapshot.relativeFiles(under: s1.treeURL).sorted() == ["companies/c1/roles/ceo.md"])
        for relative in ["owner.key", "Owner.Key", ".owner.key.x", "owner/keyhash", "OWNER/keyhash", "secrets/vault.json", "Secrets/x"] {
            #expect(HomeSnapshot.excluded(relative), "\(relative)")
        }
        #expect(!HomeSnapshot.excluded("companies/c1/files/owner.key"))         // only the data home's own key store
        // A restore leaves the current key and vault alone.
        try rig.put("owner.key", "key v2")
        try rig.put("owner/keyhash", "hash v2")
        try rig.put("secrets/vault.json", "vault v2")
        _ = try HomeSnapshot.restore(s1, paths: rig.paths, now: rig.clock.next())
        #expect(rig.read("owner.key") == "key v2" && rig.read("owner/keyhash") == "hash v2" && rig.read("secrets/vault.json") == "vault v2")
    }

    /// X3: a rollback-journal database with a hot `-journal` is refused (listed), never copied without its journal.
    @Test func hotJournalRefused() throws {
        let rig = try Rig()
        try rig.makeSQLite("archive/acme/rollback.sqlite", rows: ["one"])
        try rig.makeSQLite("archive/acme/cold.sqlite", rows: ["two"])
        // A hot journal: the rollback-journal magic, then a torn transaction.
        var hot = Data([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7])
        hot.append(Data(repeating: 0x42, count: 600))
        try hot.write(to: rig.url("archive/acme/rollback.sqlite-journal"))
        try Data().write(to: rig.url("archive/acme/cold.sqlite-journal"))     // an empty (cold) journal is no reason to refuse
        let result = try HomeSnapshot.take(paths: rig.paths, now: rig.clock.next())
        #expect(result.problems.contains { $0.hasPrefix("archive/acme/rollback.sqlite") && $0.contains("journal") }, "\(result.problems)")
        let manifest = try HomeSnapshot.manifest(of: result.info)
        #expect(manifest.files["archive/acme/rollback.sqlite"] == nil)
        #expect(manifest.files["archive/acme/cold.sqlite"] != nil)
        // On restore, a journal left next to a database the snapshot puts back is moved aside with it (SQLite would otherwise
        // "roll back" the restored file with it).
        let outcome = try HomeSnapshot.restore(result.info, paths: rig.paths, now: rig.clock.next())
        #expect(!FileManager.default.fileExists(atPath: rig.url("archive/acme/cold.sqlite-journal").path))
        #expect(FileManager.default.fileExists(atPath: outcome.preRestore.appending(path: "archive/acme/cold.sqlite-journal").path))
        let queue = try BackupService.openForReading(rig.url("archive/acme/cold.sqlite"))
        #expect(try queue.read { db in try String.fetchAll(db, sql: "SELECT text FROM note") } == ["two"])
        try queue.close()
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
