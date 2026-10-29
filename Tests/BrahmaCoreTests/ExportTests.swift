import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite(.scratch) struct ExportTests {
    private struct Fixture {
        let env: BackupEnv
        let acme: Company
        let beta: Company
        let vault = MemoryVault()

        init() throws {
            env = try BackupEnv()
            acme = try env.company("Acme")
            beta = try env.company("Beta")
            _ = try env.store.hire(companyId: acme.id, name: "alice", role: "dev", model: "sonnet")
            _ = try env.store.hire(companyId: beta.id, name: "bob", role: "dev", model: "sonnet")
            try env.post(acme, "acme plans the zebra launch")
            try env.post(beta, "beta keeps the giraffe secret")
            try SystemTimers.ensure(store: env.store, now: Date(timeIntervalSince1970: 1_781_107_200))
            // Task 13a: captured work records travel with the company (already redacted when they were captured).
            try Self.put(env.paths.transcriptsDir.appending(path: "\(acme.id)/a-1/s-1/t-1.jsonl.gz"), "acme transcript")
            try Self.put(env.paths.transcriptsDir.appending(path: "\(beta.id)/b-1/s-2/t-2.jsonl.gz"), "beta transcript")
            try Self.put(env.paths.archiveDir.appending(path: "\(acme.slug)/memo.md"), "acme archive")
            try Self.put(env.paths.archiveDir.appending(path: "\(beta.slug)/memo.md"), "beta archive")
            try env.store.writer.write { db in
                try db.execute(sql: "INSERT INTO engineProbe(id, report, checkedAt) VALUES (1, '{}', '2026-06-10 12:00:00.000')")
                try db.execute(sql: "INSERT INTO usageState(id, status, isUsingOverage, observedAt) VALUES (1, 'allowed', 0, '2026-06-10 12:00:00.000')")
            }
        }

        static func put(_ url: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func export(_ company: Company, includeWorkspace: Bool = true) throws -> ExportResult {
            let destination = env.root.appending(path: "export-\(company.slug)", directoryHint: .isDirectory)
            return try CompanyExporter.export(store: env.store, paths: env.paths, company: company, to: destination,
                                              includeWorkspace: includeWorkspace)
        }
    }

    @Test func exportContainsOnlyThatCompany() throws {
        let f = try Fixture()
        let result = try f.export(f.acme)
        let queue = try BackupService.openForReading(result.database)
        defer { try? queue.close() }
        try queue.read { db in
            #expect(try String.fetchAll(db, sql: "SELECT name FROM company") == ["Acme"])
            #expect(try String.fetchAll(db, sql: "SELECT name FROM agent") == ["alice"])
            // No table keeps a row of any other company, or a global (NULL company) row.
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            var checked = 0
            for table in tables {
                let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)", arguments: [table])
                guard columns.contains("companyId") else { continue }
                checked += 1
                let strangers = try Int.fetchOne(db, sql: "SELECT count(*) FROM \"\(table)\" WHERE companyId IS NULL OR companyId <> ?",
                                                 arguments: [f.acme.id])
                #expect(strangers == 0, "\(table) still holds rows of another company")
            }
            #expect(checked > 10)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM timer WHERE companyId IS NULL") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM timer WHERE companyId = ?", arguments: [f.acme.id]) == 1)
            // Global tables are emptied.
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM engineProbe") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM usageState") == 0)
            // The database is sound and its search index finds only this company's messages.
            #expect(try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"])
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM messageFts WHERE messageFts MATCH 'zebra'") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM messageFts WHERE messageFts MATCH 'giraffe'") == 0)
            try db.execute(sql: "SELECT 1")
        }
        // The live database is untouched.
        #expect(try f.env.store.companies().count == 2)
        // Staging is gone from <home>/tmp.
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.env.paths.tmpDir.path).isEmpty)
    }

    @Test func exportHasRepoBundleAndManifest() throws {
        let f = try Fixture()
        let head = try f.env.commit(f.acme, file: "notes.txt", text: "hello")
        let result = try f.export(f.acme)
        let bundle = try #require(result.bundle)
        #expect(bundle.lastPathComponent == "repo.bundle")
        _ = try GitFixture.plainGit(["bundle", "verify", bundle.path], in: URL(fileURLWithPath: f.acme.workspacePath))
        let heads = try GitFixture.plainGit(["bundle", "list-heads", bundle.path], in: URL(fileURLWithPath: f.acme.workspacePath))
        #expect(heads.contains(head) && heads.contains("refs/heads/main"))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: result.directory.appending(path: "MANIFEST.json"))) as? [String: Any]
        let company = try #require(manifest?["company"] as? [String: String])
        #expect(company["id"] == f.acme.id && company["name"] == "Acme")
        #expect(manifest?["repo"] as? String == "repo.bundle")

        let bare = try f.export(f.beta, includeWorkspace: false)
        #expect(bare.bundle == nil)
        #expect(!FileManager.default.fileExists(atPath: bare.directory.appending(path: "repo.bundle").path))
        #expect(FileManager.default.fileExists(atPath: bare.database.path))
        // An export never overwrites: the destination must be new.
        #expect(throws: ExportError.destinationExists(result.directory.path)) { try f.export(f.acme) }
    }

    @Test func exportSkipsWorktreesAndCaches() throws {
        let f = try Fixture()
        let data = f.env.paths.companyDir(f.acme.id)
        let fixture = GitFixture(existing: data)
        try fixture.write("files/keep.txt", "keep")
        try fixture.write("files/sub/deep.txt", "deep")
        try fixture.write("files/.cache/junk.bin", "junk")
        try fixture.write("files/node_modules/pkg/index.js", "js")
        try fixture.write("files/wt/ITEM-1/checkout.txt", "worktree")
        try fixture.write("files/.brahma/state.json", "{}")
        try fixture.write("roles/alice.md", "# alice")
        try FileManager.default.createSymbolicLink(atPath: data.appending(path: "files/link").path, withDestinationPath: "/etc/hosts")
        try FileManager.default.createSymbolicLink(atPath: data.appending(path: "files/dirlink").path, withDestinationPath: "/etc")
        // A worktree in the workspace itself never travels either (the bundle holds refs, not checkouts).
        let ws = URL(fileURLWithPath: f.acme.workspacePath)
        try GitFixture(existing: ws).write(".brahma/wt/ITEM-1/secret-in-worktree.txt", "wt")

        let result = try f.export(f.acme)
        let names = try FileManager.default.subpathsOfDirectory(atPath: result.directory.path).sorted()
        #expect(names.contains("files/keep.txt") && names.contains("files/sub/deep.txt") && names.contains("roles/alice.md"))
        for unwanted in [".cache", "node_modules", "wt", ".brahma", "link", "dirlink", "secret-in-worktree"] {
            #expect(!names.contains { $0.contains(unwanted) }, "\(unwanted) must not be exported: \(names)")
        }
        #expect(result.copied.sorted() == ["archive", "files", "roles", "transcripts"])
        var st = stat()
        #expect(stat(result.directory.appending(path: "files/keep.txt").path, &st) == 0 && st.st_mode & 0o777 == 0o600)
    }

    @Test func exportCopiesTranscriptsAndArchive() throws {
        let f = try Fixture()
        let result = try f.export(f.acme)
        let dir = result.directory
        func text(_ rel: String) -> String? { try? String(contentsOf: dir.appending(path: rel), encoding: .utf8) }
        #expect(text("transcripts/\(f.acme.id)/a-1/s-1/t-1.jsonl.gz") == "acme transcript")
        #expect(text("archive/\(f.acme.slug)/memo.md") == "acme archive")
        // Nothing of the other company.
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "transcripts/\(f.beta.id)").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "archive/\(f.beta.slug)").path))
        #expect(result.copied.contains("transcripts") && result.copied.contains("archive"))
        var st = stat()
        #expect(stat(dir.appending(path: "transcripts/\(f.acme.id)/a-1/s-1/t-1.jsonl.gz").path, &st) == 0 && st.st_mode & 0o777 == 0o600)
    }

    /// m4 (13a fix round 1): a live SQLite archive (WAL mode, a writer still open, nothing checkpointed) is exported as one
    /// consistent `VACUUM INTO` copy that passes its integrity check, never as raw bytes plus sidecars. A `.sqlite` name that
    /// is not a database is copied as it is.
    @Test func exportCopiesArchiveSQLiteConsistently() throws {
        let f = try Fixture()
        let live = f.env.paths.archiveDir.appending(path: "\(f.acme.slug)/notes.sqlite")
        let queue = try DatabaseQueue(path: live.path)
        defer { try? queue.close() }
        try queue.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "CREATE TABLE note (text TEXT)")
            for n in 0..<50 { try db.execute(sql: "INSERT INTO note VALUES (?)", arguments: ["row \(n)"]) }
        }
        #expect(FileManager.default.fileExists(atPath: live.path + "-wal"))
        try Fixture.put(f.env.paths.archiveDir.appending(path: "\(f.acme.slug)/fake.sqlite"), "not a database")

        let result = try f.export(f.acme)
        let exported = result.directory.appending(path: "archive/\(f.acme.slug)/notes.sqlite")
        let names = try FileManager.default.contentsOfDirectory(atPath: exported.deletingLastPathComponent().path).sorted()
        #expect(names == ["fake.sqlite", "memo.md", "notes.sqlite"], "\(names)")
        #expect(BackupService.integrity(of: exported) == ["ok"])
        let copy = try BackupService.openForReading(exported)
        #expect(try copy.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note") } == 50)
        try copy.close()
        #expect(try String(contentsOf: exported.deletingLastPathComponent().appending(path: "fake.sqlite"), encoding: .utf8)
                == "not a database")
        var st = stat()
        #expect(stat(exported.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
    }

    /// S4 #2: the exporter copies an archive database from a private, descriptor-made copy: a directory swapped for a link
    /// between the walk and the copy is refused (listed as skipped), and the outside database never reaches the export.
    @Test func exportSwapSeamRefused() throws {
        let f = try Fixture()
        let archive = f.env.paths.archiveDir.appending(path: f.acme.slug, directoryHint: .isDirectory)
        let inside = try DatabaseQueue(path: archive.appending(path: "notes.sqlite").path)
        try inside.write { db in try db.execute(sql: "CREATE TABLE note (text TEXT); INSERT INTO note VALUES ('inside')") }
        try inside.close()
        let outside = f.env.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let other = try DatabaseQueue(path: outside.appending(path: "notes.sqlite").path)
        try other.write { db in try db.execute(sql: "CREATE TABLE note (text TEXT); INSERT INTO note VALUES ('OUTSIDE')") }
        try other.close()
        let before = try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted()
        let result = try HomeSnapshot.$sqliteCopyProbe.withValue({ relative in
            guard relative.hasSuffix("notes.sqlite") else { return }
            try? FileManager.default.moveItem(at: archive, to: archive.deletingLastPathComponent().appending(path: "moved"))
            try? FileManager.default.createSymbolicLink(at: archive, withDestinationURL: outside)
        }) { try f.export(f.acme) }
        #expect(result.skipped.contains { $0.contains("notes.sqlite") }, "\(result.skipped)")
        let exported = result.directory.appending(path: "archive/\(f.acme.slug)/notes.sqlite")
        if let data = try? Data(contentsOf: exported) { #expect(data.range(of: Data("OUTSIDE".utf8)) == nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() == before)
    }

    /// Re-review: an unhealthy archive database is skipped and listed; the rest of the export goes on.
    @Test func exportSkipsUnhealthyArchiveDB() throws {
        let f = try Fixture()
        let bad = f.env.paths.archiveDir.appending(path: "\(f.acme.slug)/broken.sqlite")
        let queue = try DatabaseQueue(path: bad.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE note (text TEXT)")
            for n in 0..<400 { try db.execute(sql: "INSERT INTO note VALUES (?)", arguments: [String(repeating: "x", count: 200) + "\(n)"]) }
        }
        try queue.close()
        // Damage the pages after the first one (the header stays valid, so it is still "a database").
        let handle = try FileHandle(forWritingTo: bad)
        try handle.seek(toOffset: 4096 + 100)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 8192))
        try handle.close()
        let result = try f.export(f.acme)
        #expect(result.skipped.contains { $0.contains("broken.sqlite") }, "\(result.skipped)")
        #expect(!FileManager.default.fileExists(atPath: result.directory.appending(path: "archive/\(f.acme.slug)/broken.sqlite").path))
        #expect(try String(contentsOf: result.directory.appending(path: "archive/\(f.acme.slug)/memo.md"), encoding: .utf8) == "acme archive")
    }

    /// S4 #2: the exporter's tree walk never follows a link (a linked directory or file inside a copied tree is left out).
    @Test func exportTreeWalkDoesNotFollowLinks() throws {
        let f = try Fixture()
        let outside = f.env.root.appending(path: "outside-tree", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside secret".utf8).write(to: outside.appending(path: "secret.txt"))
        let archive = f.env.paths.archiveDir.appending(path: f.acme.slug, directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: archive.appending(path: "linked-dir"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: archive.appending(path: "linked.txt"), withDestinationURL: outside.appending(path: "secret.txt"))
        let result = try f.export(f.acme)
        let names = try FileManager.default.contentsOfDirectory(atPath: result.directory.appending(path: "archive/\(f.acme.slug)").path)
        #expect(names.sorted() == ["memo.md"])
    }

    /// X1 + X3: an export never carries the owner-key file store or the file vault, and skips a hot-journal archive database.
    @Test func exportNeverCopiesOwnerKeyOrVault() throws {
        let f = try Fixture()
        let plain = "sk-plain-secret-0123456789"
        try Fixture.put(f.env.paths.home.appending(path: "owner.key"), "owner key bytes")
        try Fixture.put(f.env.paths.home.appending(path: "owner/keyhash"), "owner hash")
        try Fixture.put(f.env.paths.home.appending(path: "secrets/vault.json"), #"{"STRIPE_KEY":"\#(plain)"}"#)
        let archive = f.env.paths.archiveDir.appending(path: f.acme.slug, directoryHint: .isDirectory)
        let rollback = try DatabaseQueue(path: archive.appending(path: "rollback.sqlite").path)
        try rollback.write { db in try db.execute(sql: "CREATE TABLE note (text TEXT); INSERT INTO note VALUES ('x')") }
        try rollback.close()
        var hot = Data([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7])
        hot.append(Data(repeating: 0x42, count: 600))
        try hot.write(to: archive.appending(path: "rollback.sqlite-journal"))
        let result = try f.export(f.acme)
        #expect(result.skipped.contains { $0.contains("rollback.sqlite") && $0.contains("journal") }, "\(result.skipped)")
        let walker = try #require(FileManager.default.enumerator(at: result.directory, includingPropertiesForKeys: nil))
        for case let url as URL in walker {
            #expect(!["owner.key", "keyhash", "vault.json"].contains(url.lastPathComponent), "\(url.path)")
            if let data = try? Data(contentsOf: url) { #expect(data.range(of: Data(plain.utf8)) == nil, "\(url.path)") }
        }
    }

    @Test func exportHasNoSecretValues() throws {
        let f = try Fixture()
        let value = "sk-live-SUPERSECRET-9f8e7d6c5b4a"
        try f.env.store.setSecret(companyId: f.acme.id, name: "STRIPE_KEY", value: value, isTest: false, vault: f.vault)
        // A token hash the engine keeps for a running turn: must not leave the machine either.
        try f.env.store.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
                INSERT INTO turnCredential(turnId, companyId, agentId, kind, tokenHash, createdAt)
                VALUES ('t-1', ?, 'a-1', 'work', 'tokenhash-should-not-travel', '2026-06-10 12:00:00.000')
                """, arguments: [f.acme.id])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let result = try f.export(f.acme)
        let queue = try BackupService.openForReading(result.database)
        let names = try queue.read { db in try String.fetchAll(db, sql: "SELECT name FROM secret") }
        #expect(names == ["STRIPE_KEY"])                               // the name travels, the value never does
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM turnCredential") } == 0)
        try queue.close()
        #expect(try SecretLeak.findings(of: value, under: result.directory).isEmpty)
        #expect(try SecretLeak.findings(of: "tokenhash-should-not-travel", under: result.directory).isEmpty)
        // The vault is not an input to the export at all.
        #expect(try f.vault.value(companyId: f.acme.id, name: "STRIPE_KEY") == value)
        #expect(CompanyExporter.globalTables.contains("turnCredential"))
    }
}

enum SecretLeak {
    /// Files under `root` whose bytes contain `needle`.
    static func findings(of needle: String, under root: URL) throws -> [String] {
        let bytes = Data(needle.utf8)
        var hits: [String] = []
        for rel in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appending(path: rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if (try Data(contentsOf: url)).range(of: bytes) != nil { hits.append(rel) }
        }
        return hits
    }
}
