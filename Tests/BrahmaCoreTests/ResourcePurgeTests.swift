import Testing
import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// Plan ML Task 6c: vouch, scope changes with the folder cascade, the secure purge (bytes, index, freed pages and WAL; the
/// backups and transcripts that still hold it), the `.brahma/resources` mirror repair sweep, the owner CLI and the export.
@Suite(.scratch) struct ResourcePurgeTests {
    typealias W = ResourceStoreTests.W

    /// A store on disk (the purge's secure delete, checkpoint and the export need a real file).
    static func onDisk() throws -> (W, URL) {
        let dir = try tempDir()
        let db = dir.appending(path: "brahma.sqlite")
        return (try W(store: try Store(path: db.path)), db)
    }

    /// A folder drop: `<name>/` with the given files.
    static func folder(_ w: W, _ name: String, _ files: [(String, String)]) throws -> URL {
        let dir = w.drops.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (file, text) in files { try w.file(file, text, in: dir) }
        return dir
    }

    static func running(_ w: W, _ a: Agent) throws -> String {
        let t = Turn(id: UUID().uuidString, agentId: a.id, companyId: w.company.id, startedAt: Store.now(), endedAt: nil,
                     outcome: .inProgress, summary: nil, costUSD: nil)
        try w.store.writer.write { db in try t.insert(db) }
        return t.id
    }

    static func endTurn(_ w: W, _ id: String) throws {
        try w.store.writer.write { db in
            try db.execute(sql: "UPDATE turn SET endedAt = ?, outcome = 'completed' WHERE id = ?", arguments: [Store.now(), id])
        }
    }

    static func captured(_ w: W, _ turnId: String, _ a: Agent) throws {
        try w.store.writer.write { db in
            try TurnTranscript(turnId: turnId, companyId: w.company.id, agentId: a.id, sessionId: "s-\(turnId)",
                               path: "transcripts/\(w.company.id)/\(a.id)/s/\(turnId).jsonl.gz", byteStart: 0, byteEnd: 10,
                               codec: "gz", sha: "0", capturedAt: Store.now()).insert(db)
        }
    }

    /// Moves everything into the database file, so freed pages there are what the purge must clear.
    static func checkpoint(_ w: W) throws {
        try w.store.writer.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    static func bytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    static func contains(_ data: Data, _ token: String) -> Bool { data.range(of: Data(token.utf8)) != nil }

    func vouch(_ w: W, _ n: Int) throws {
        try w.store.vouchResource(companyId: w.company.id, number: n, contentVault: w.contentVault, paths: w.paths, owner: .test)
    }

    func rescope(_ w: W, _ n: Int, _ scope: AccessClass, futureHolders: Bool = false) throws {
        try w.store.setResourceScope(companyId: w.company.id, number: n, scope: scope, futureHolders: futureHolders,
                                     contentVault: w.contentVault, paths: w.paths, owner: .test)
    }

    func purge(_ w: W, _ n: Int, backups: [(name: String, takenAt: Date)] = [], now: Date = Store.now()) throws -> PurgeReport {
        try w.store.purgeResource(companyId: w.company.id, number: n, backups: backups, contentVault: w.contentVault,
                                  paths: w.paths, now: now, owner: .test)
    }

    func sweep(_ w: W) -> ResourceMirrorResult {
        w.store.syncResourceMirror(companyId: w.company.id, contentVault: w.contentVault)
    }

    func mirrorNames(_ w: W) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: w.mirror.path)) ?? []).sorted()
    }

    // MARK: Vouch

    @Test func vouchClearsTaintAndMirrors() throws {
        let w = try W()
        let text = "# vendor brief\nThe PELICAN rollout starts Monday.\n"
        let r = try #require(try w.add([try w.file("brief.md", text)], ResourceDrop(trust: .untrusted)).first)
        #expect(r.tainted); #expect(r.mirrorPath == nil); #expect(mirrorNames(w).isEmpty)
        #expect(try w.doc(r)?["tainted"] as Bool? == true)

        try vouch(w, 1)
        let v = try #require(try w.store.resource(companyId: w.company.id, number: 1))
        #expect(!v.tainted); #expect(v.taintReason == nil); #expect(v.provenance == Provenance.owner.raw); #expect(v.vouchedAt != nil)
        // Re-ingested untainted, with its text kept.
        let doc = try #require(try w.doc(v))
        #expect(doc["tainted"] as Bool? == false); #expect(doc["provenance"] as String? == Provenance.owner.raw)
        #expect((doc["body"] as String?)?.contains("PELICAN") == true)
        // Mirrored read-only with the vault's bytes.
        #expect(v.mirrorPath == ".brahma/resources/company/F-1.md"); #expect(v.mirrorSha256 == v.sha256)
        #expect(try Data(contentsOf: w.mirror.appending(path: "F-1.md")) == Data(text.utf8))
        // An untainted session reads it without being tainted; it is logged.
        let read = w.recall(w.eng1, "F-1")
        #expect(read.contains("PELICAN")); #expect(!(try w.agent(w.eng1)).sessionTainted)
        #expect(try w.activity().contains { $0.kind == .resource && $0.text.contains("You vouched for F-1") })

        // A folder: every file is vouched for, and each file of the folder is mirrored.
        let kit = try Self.folder(w, "kit", [("a.md", "alpha OSPREY\n"), ("b.md", "beta\n")])
        let rows = try w.add([kit], ResourceDrop(trust: .untrusted))
        #expect(rows.map(\.ref) == ["F-2", "F-3", "F-4"]); #expect(rows.allSatisfy { $0.tainted })
        try vouch(w, 2)
        for n in 2...4 {
            let row = try #require(try w.store.resource(companyId: w.company.id, number: n))
            #expect(!row.tainted, "F-\(n)"); #expect(row.vouchedAt != nil, "F-\(n)")
            #expect(try w.doc(row)?["tainted"] as Bool? == false, "F-\(n)")
        }
        #expect(mirrorNames(w) == ["F-1.md", "F-3.md", "F-4.md"])
        // A purged resource can't be vouched for.
        _ = try purge(w, 1)
        #expect(throws: ResourceError.invalid("F-1 was purged")) { try vouch(w, 1) }
    }

    // MARK: Scope

    @Test func scopeChangeLoggedAndUnmirrors() throws {
        let w = try W()
        let r = try #require(try w.add([try w.file("plan.md", "the HERON plan\n")]).first)
        #expect(r.mirrorPath != nil); #expect(mirrorNames(w) == ["F-1.md"])
        #expect(w.recall(w.eng2, "F-1").contains("HERON"))

        try rescope(w, 1, .agent(w.eng1.id))
        let s = try #require(try w.store.resource(companyId: w.company.id, number: 1))
        #expect(s.scope == .agent(w.eng1.id)); #expect(s.readerSet == [w.eng1.id])
        #expect(s.mirrorPath == nil); #expect(s.mirrorSha256 == nil); #expect(mirrorNames(w).isEmpty)
        // The doc follows: eng-1 reads it, eng-2 and the manager get nothing.
        let doc = try #require(try w.doc(s))
        #expect(doc["accessKind"] as String? == "agent"); #expect(doc["accessId"] as String? == w.eng1.id)
        #expect(w.recall(w.eng1, "F-1").contains("HERON"))
        #expect(w.recall(w.eng2, "F-1") == w.notFound("F-1")); #expect(try w.search(w.eng2, "heron").isEmpty)
        #expect(try w.search(w.mgr, "heron").isEmpty)
        #expect(try w.activity().contains {
            $0.kind == .resource && $0.text == "You changed the scope of F-1 \"plan.md\" from company to agent @eng-1"
        })
        // Back to the company: mirrored again, everyone reads it.
        try rescope(w, 1, .company)
        #expect(mirrorNames(w) == ["F-1.md"]); #expect(w.recall(w.eng2, "F-1").contains("HERON"))
        #expect(try w.store.resource(companyId: w.company.id, number: 1)?.readerSet == nil)
        // Item scope: the computed set, with future holders kept; another company's object is refused.
        let i = try w.item(owner: w.eng3)
        try rescope(w, 1, .item(i.id), futureHolders: true)
        let item = try #require(try w.store.resource(companyId: w.company.id, number: 1))
        #expect(item.readerSet == [w.eng3.id]); #expect(item.futureHolders)
        let other = try W(name: "Beta")
        #expect(throws: ResourceError.self) { try rescope(w, 1, .agent(other.eng1.id)) }
        #expect(throws: ResourceError.notFound("no resource F-9")) { try rescope(w, 9, .company) }
    }

    @Test func folderScopeChangeCascadesToChildren() throws {
        let w = try W()
        let kit = try Self.folder(w, "kit", [("a.md", "alpha IBIS\n"), ("b.md", "beta IBIS\n")])
        let rows = try w.add([kit])
        #expect(rows.map(\.ref) == ["F-1", "F-2", "F-3"]); #expect(mirrorNames(w) == ["F-2.md", "F-3.md"])

        try rescope(w, 1, .agent(w.eng1.id))
        for n in 1...3 {
            let r = try #require(try w.store.resource(companyId: w.company.id, number: n))
            #expect(r.scope == .agent(w.eng1.id), "F-\(n)"); #expect(r.readerSet == [w.eng1.id], "F-\(n)")
            #expect(r.mirrorPath == nil, "F-\(n)")
            let doc = try #require(try w.doc(r))
            #expect(doc["accessKind"] as String? == "agent", "F-\(n)"); #expect(doc["accessId"] as String? == w.eng1.id, "F-\(n)")
            #expect(doc["readerSet"] as String? == "[\"\(w.eng1.id)\"]", "F-\(n)")
        }
        #expect(mirrorNames(w).isEmpty)
        #expect(try w.search(w.eng2, "ibis").isEmpty); #expect(try w.search(w.eng1, "ibis").count == 2)
        // Channel scope: its members now, never wider.
        try rescope(w, 1, .channel(w.design.id))
        for n in 1...3 {
            #expect(try w.store.resource(companyId: w.company.id, number: n)?.readerSet == [w.eng1.id, w.eng2.id], "F-\(n)")
        }
        #expect(try w.search(w.eng3, "ibis").isEmpty); #expect(try w.search(w.eng2, "ibis").count == 2)
    }

    @Test func childCannotBeRescopedAlone() throws {
        let w = try W()
        let kit = try Self.folder(w, "kit", [("a.md", "alpha\n"), ("b.md", "beta\n")])
        try w.add([kit], ResourceDrop(trust: .untrusted))
        let refusal = ResourceError.invalid("F-2 is part of folder F-1; change the folder")
        #expect(throws: refusal) { try rescope(w, 2, .agent(w.eng1.id)) }
        #expect(throws: refusal) { try vouch(w, 2) }
        // Nothing changed (purge of a single file is allowed: `purgeOneFileOfAFolder`).
        let child = try #require(try w.store.resource(companyId: w.company.id, number: 2))
        #expect(child.scope == .company); #expect(child.tainted); #expect(child.purgedAt == nil)
        #expect(w.vaultNames() == ["F-2.md", "F-3.md"])
    }

    // MARK: Purge

    @Test func purgeRemovesBytesIndexAndFlagsBackups() throws {
        let w = try W()
        let t0 = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 86_400).rounded(.down))
        let r = try #require(try w.add([try w.file("plan.md", "the MARMOT launch plan\n")], now: t0).first)
        #expect(w.vaultNames() == ["F-1.md"]); #expect(mirrorNames(w) == ["F-1.md"])

        // eng-1 recalls it in a captured turn; eng-2 in a turn without a transcript; eng-3 never.
        let captured = try Self.running(w, w.eng1)
        #expect(w.recall(w.eng1, "F-1").contains("MARMOT"))
        try Self.captured(w, captured, w.eng1)
        try Self.endTurn(w, captured)
        let uncaptured = try Self.running(w, w.eng2)
        #expect(try !w.search(w.eng2, "marmot").isEmpty)
        try Self.endTurn(w, uncaptured)

        let now = t0.addingTimeInterval(7200)
        let backups: [(name: String, takenAt: Date)] = [
            ("brahma-before-hourly.sqlite", t0.addingTimeInterval(-60)),
            ("brahma-after-hourly.sqlite", t0.addingTimeInterval(3600)),
            ("home-after", t0.addingTimeInterval(3601)),
            ("brahma-future-manual.sqlite", now.addingTimeInterval(60)),
        ]
        let report = try purge(w, 1, backups: backups, now: now)
        #expect(report.backups == ["brahma-after-hourly.sqlite", "home-after"])
        #expect(report.transcripts == [captured])

        // Bytes, mirror and index gone; the row stays as a tombstone with its report.
        #expect(w.vaultNames().isEmpty); #expect(mirrorNames(w).isEmpty)
        #expect(try w.search(w.eng1, "marmot").isEmpty)
        #expect(try MemoryIndex(store: w.store).search(companyId: w.company.id, scope: .owner, query: "marmot", now: Store.now()).isEmpty)
        let doc = try #require(try w.doc(r))
        #expect(doc["title"] as String? == "[purged]"); #expect(doc["body"] as String? == ""); #expect(doc["removedAt"] as Date? != nil)
        let tomb = try #require(try w.store.resource(companyId: w.company.id, number: 1))
        #expect(tomb.purgedAt == now); #expect(tomb.displayName == "plan.md"); #expect(tomb.mirrorPath == nil)
        let stored = try JSONDecoder().decode(PurgeReport.self, from: Data(try #require(tomb.purgeReport).utf8))
        #expect(stored == report)
        #expect(try w.activity().contains {
            $0.kind == .resource && $0.text == "Purged F-1 (2 backups and 1 transcripts made since it was added may still contain it; "
                + "reads through an agent's shell or the mirror are not tracked one by one)"
        })
        // Nothing brings it back: not the mirror sweep, not a re-ingest.
        _ = sweep(w)
        #expect(mirrorNames(w).isEmpty)
        let live = try #require(try w.store.resource(companyId: w.company.id, number: 1))
        #expect(try w.store.writer.write { db in try w.store.ingestResource(db: db, live, text: "MARMOT", now: Store.now()) } == false)
        #expect(try w.search(w.eng1, "marmot").isEmpty)
        #expect(throws: ResourceError.notFound("F-1 was purged")) {
            try w.store.readResource(companyId: w.company.id, number: 1, contentVault: w.contentVault)
        }
        // A purge can be run again (it finishes what a failed one left); the report is recomputed.
        #expect(try purge(w, 1, backups: backups, now: now).backups.count == 2)

        // A folder purge covers every file.
        let kit = try Self.folder(w, "kit", [("a.md", "alpha\n"), ("b.md", "beta\n")])
        try w.add([kit])
        #expect(w.vaultNames() == ["F-3.md", "F-4.md"])
        _ = try purge(w, 2)
        #expect(w.vaultNames().isEmpty); #expect(mirrorNames(w).isEmpty)
        #expect(try (2...4).allSatisfy { try w.store.resource(companyId: w.company.id, number: $0)?.purgedAt != nil })
    }

    /// Fix round 1, ruling A: purge is the owner's remedy for a leak, so one file of a folder can be purged on its own.
    @Test func purgeOneFileOfAFolder() throws {
        let w = try W()
        let kit = try Self.folder(w, "kit", [("a.md", "alpha LEAKWORD secret\n"), ("b.md", "beta BITTERN notes and more\n")])
        let rows = try w.add([kit])
        #expect(rows.map(\.ref) == ["F-1", "F-2", "F-3"]); #expect(mirrorNames(w) == ["F-2.md", "F-3.md"])
        let sibling = try #require(rows.last)

        let report = try purge(w, 2)
        #expect(report == PurgeReport())
        // The child is a tombstone: bytes, mirror and doc gone, its own report and activity line.
        let child = try #require(try w.store.resource(companyId: w.company.id, number: 2))
        #expect(child.purgedAt != nil); #expect(child.purgeReport != nil)
        #expect(w.vaultNames() == ["F-3.md"]); #expect(mirrorNames(w) == ["F-3.md"])
        #expect(try w.search(w.eng1, "leakword").isEmpty); #expect(w.recall(w.eng1, "F-2") == "F-2 was purged by the owner.")
        #expect(try w.activity().contains { $0.kind == .resource && $0.text.hasPrefix("Purged F-2 (") })
        // Its sibling and the folder stay readable; the folder now counts only its live file.
        #expect(w.recall(w.eng1, "F-3").contains("BITTERN")); #expect(try w.search(w.eng1, "bittern").count == 1)
        let folder = try #require(try w.store.resource(companyId: w.company.id, number: 1))
        #expect(folder.purgedAt == nil); #expect(folder.bytes == sibling.bytes)
        #expect(w.recall(w.eng1, "F-1").contains("is a folder (\(ResourceText.size(sibling.bytes)))"))
        #expect(try w.store.resource(companyId: w.company.id, number: 3)?.purgedAt == nil)
        // The folder's own actions skip the tombstone, and purging the folder later keeps the child's own report.
        try vouch(w, 1)
        #expect(try w.store.resource(companyId: w.company.id, number: 2)?.vouchedAt == nil)
        let childReport = child.purgeReport
        _ = try purge(w, 1, backups: [("brahma-later-manual.sqlite", Store.now())], now: Store.now().addingTimeInterval(1))
        #expect(try w.store.resource(companyId: w.company.id, number: 2)?.purgeReport == childReport)
        #expect(w.vaultNames().isEmpty)
    }

    /// Fix round 1, ruling B: a link's URL is its content; a purged link keeps only its ref and kind.
    @Test func purgedLinkKeepsOnlyRefAndKind() throws {
        let (w, _) = try Self.onDisk()
        try w.store.addLink(companyId: w.company.id, url: "https://vendor.example.com/deal?k=LINKTOKENQX", drop: ResourceDrop(),
                            contentVault: w.contentVault, owner: .test)
        #expect(try w.store.resource(companyId: w.company.id, number: 1)?.url?.contains("LINKTOKENQX") == true)
        _ = try purge(w, 1)
        let tomb = try #require(try w.store.resource(companyId: w.company.id, number: 1))
        #expect(tomb.url == nil); #expect(tomb.sourceDetail == nil); #expect(tomb.kind == .link); #expect(tomb.ref == "F-1")
        #expect(!tomb.displayName.contains("vendor")); #expect(tomb.purgedAt != nil)
        let row = try #require(try w.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM resource WHERE companyId = ? AND number = 1", arguments: [w.company.id])
        })
        #expect(!row.databaseValues.map { "\($0)" }.joined().contains("LINKTOKENQX"))
        #expect(!row.databaseValues.map { "\($0)" }.joined().contains("vendor.example.com"))
        let read = w.recall(w.eng1, "F-1")
        #expect(read == "F-1 was purged by the owner."); #expect(!read.contains("vendor"))
        let destination = try tempDir().appending(path: "export", directoryHint: .isDirectory)
        let result = try CompanyExporter.export(store: w.store, paths: w.paths, company: w.company, to: destination,
                                                includeWorkspace: false)
        let json = try Data(contentsOf: destination.appending(path: "resources/resources.json"))
        #expect(!Self.contains(json, "LINKTOKENQX")); #expect(!Self.contains(json, "vendor.example.com"))
        #expect(!Self.contains(Self.bytes(result.database), "LINKTOKENQX"))
    }

    @Test func purgedTokenAbsentFromDatabaseFile() throws {
        let (w, db) = try Self.onDisk()
        // Big enough to spill onto overflow pages; another resource's text must survive.
        let secret = (0..<400).map { "line \($0) ZEBRAQUOKKA holds the merger terms" }.joined(separator: "\n")
        try w.add([try w.file("terms.md", secret + "\n")])
        try w.add([try w.file("keep.md", "the OTTERHERON notes stay\n")])
        let wal = URL(fileURLWithPath: db.path + "-wal")
        func everything() -> Data { Self.bytes(db) + Self.bytes(wal) }
        func ftsData() throws -> [Data] {
            try w.store.writer.read { db in try Data.fetchAll(db, sql: "SELECT block FROM memoryFts_data WHERE block IS NOT NULL") }
        }
        // The test bites: once checkpointed, the token is in the database file's pages and in the FTS segments.
        try Self.checkpoint(w)
        #expect(Self.contains(Self.bytes(db), "ZEBRAQUOKKA"))
        #expect(try ftsData().contains { Self.contains($0, "zebraquokka") })
        let secureDelete = try w.store.writer.write { db in try Int.fetchOne(db, sql: "PRAGMA secure_delete") }

        _ = try purge(w, 1)
        #expect(try !ftsData().contains { Self.contains($0, "zebraquokka") || Self.contains($0, "ZEBRAQUOKKA") })
        let after = everything()
        #expect(!Self.contains(after, "ZEBRAQUOKKA")); #expect(!Self.contains(after, "zebraquokka"))
        // The other resource is untouched and still searchable.
        #expect(Self.contains(after, "OTTERHERON"))
        #expect(try w.search(w.eng1, "otterheron").count == 1)
        // secure_delete is back to what it was.
        let restored = try w.store.writer.write { db in try Int.fetchOne(db, sql: "PRAGMA secure_delete") }
        #expect(restored == secureDelete, "\(String(describing: restored)) vs \(String(describing: secureDelete))")
    }

    @Test func purgedRecallSaysPurged() throws {
        let w = try W()
        try w.add([try w.file("plan.md", "the CRANE plan\n")], ResourceDrop(scope: .agent(w.eng1.id)))
        _ = try purge(w, 1)
        #expect(w.recall(w.eng1, "F-1") == "F-1 was purged by the owner.")
        // A non-reader learns nothing, purged or not.
        #expect(w.recall(w.eng2, "F-1") == w.notFound("F-1"))
        #expect(try w.store.resources(companyId: w.company.id, reader: .agent(w.eng1.id), includePurged: false).isEmpty)
        #expect(try w.store.resources(companyId: w.company.id, reader: .owner, includePurged: true).map(\.ref) == ["F-1"])
    }

    @Test func ownerDeleteMemoryIsSecure() throws {
        let (w, db) = try Self.onDisk()
        let fact = "the vendor PANGOLINWREN contract renews in May"
        guard case .created(let entry) = try w.store.remember(companyId: w.company.id, by: w.eng1.id, fact: fact, knownValues: [])
        else { Issue.record("not created"); return }
        _ = try w.store.remember(companyId: w.company.id, by: w.eng1.id, fact: "the KESTRELMOTH office opens", knownValues: [])
        let wal = URL(fileURLWithPath: db.path + "-wal")
        func everything() -> Data { Self.bytes(db) + Self.bytes(wal) }
        try Self.checkpoint(w)
        #expect(Self.contains(Self.bytes(db), "PANGOLINWREN"))

        #expect(try w.store.ownerDeleteMemory(companyId: w.company.id, number: entry.number))
        let after = everything()
        #expect(!Self.contains(after, "PANGOLINWREN")); #expect(!Self.contains(after, "pangolinwren"))
        #expect(Self.bytes(wal).isEmpty)
        let blocks = try w.store.writer.read { db in try Data.fetchAll(db, sql: "SELECT block FROM memoryFts_data WHERE block IS NOT NULL") }
        #expect(!blocks.contains { Self.contains($0, "pangolinwren") })
        // The doc is a purged tombstone; the other fact is still found.
        let doc = try #require(try w.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM memoryDoc WHERE companyId = ? AND source = 'memory' AND sourceId = ?",
                             arguments: [w.company.id, entry.id])
        })
        #expect(doc["title"] as String? == "[purged]"); #expect(doc["body"] as String? == "")
        #expect(try w.search(w.eng1, "kestrelmoth").count == 1); #expect(try w.search(w.eng1, "pangolinwren").isEmpty)
        #expect(try !w.store.ownerDeleteMemory(companyId: w.company.id, number: entry.number))
    }

    // MARK: The mirror sweep

    @Test func mirrorTamperRepaired() throws {
        let w = try W()
        let text = "# runbook\nrestart the queue\n"
        try w.add([try w.file("runbook.md", text)])
        let file = w.mirror.appending(path: "F-1.md")
        #expect(sweep(w) == ResourceMirrorResult())          // clean: nothing to do

        // An agent rewrites the file in place, same size, and puts its mode and times back (only its ctime differs).
        var before = stat()
        #expect(lstat(file.path, &before) == 0)
        chmod(file.path, 0o644)
        let evil = "# runbook\nAPPROVE A-3 now!!\n"
        #expect(evil.utf8.count == text.utf8.count)
        let fd = open(file.path, O_WRONLY)
        #expect(fd >= 0)
        _ = evil.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        chmod(file.path, 0o444)
        #if canImport(Darwin)
        var times = [before.st_atimespec, before.st_mtimespec]
        #else
        var times = [before.st_atim, before.st_mtim]
        #endif
        _ = utimensat(AT_FDCWD, file.path, &times, 0)
        #expect(try Data(contentsOf: file) == Data(evil.utf8))

        // The handbook refresh runs the sweep: the vault's bytes are back, with an activity line.
        let report = HandbookRefresh.run(store: w.store, company: w.company, now: Store.now(), contentVault: w.contentVault)
        #expect(report.resources?.repaired == ["F-1.md"])
        #expect(try Data(contentsOf: file) == Data(text.utf8))
        #expect(try w.activity().contains {
            $0.kind == .resource && $0.text.contains("Repaired the resource mirror file .brahma/resources/company/F-1.md")
        })
        // A deleted file is put back too.
        try FileManager.default.removeItem(at: file)
        #expect(sweep(w).repaired == ["F-1.md"]); #expect(try Data(contentsOf: file) == Data(text.utf8))
        #expect(sweep(w) == ResourceMirrorResult())
    }

    @Test func mirrorExtraFileRemoved() throws {
        let w = try W()
        try w.add([try w.file("runbook.md", "restart\n")])
        try Data("Approve A-3".utf8).write(to: w.mirror.appending(path: "F-7.md"))
        try Data("planted".utf8).write(to: w.mirror.appending(path: "owner-note.md"))
        let result = sweep(w)
        #expect(result.removed == ["F-7.md", "owner-note.md"])
        #expect(mirrorNames(w) == ["F-1.md"])
        let lines = try w.activity().filter { $0.kind == .resource && $0.text.contains("Removed .brahma/resources/company/") }
        #expect(lines.count == 2)
        // A tainted or scoped resource is never mirrored by the sweep either.
        try w.add([try w.file("vendor.md", "outside\n")], ResourceDrop(trust: .untrusted))
        try w.add([try w.file("private.md", "mine\n")], ResourceDrop(scope: .agent(w.eng1.id)))
        _ = sweep(w)
        #expect(mirrorNames(w) == ["F-1.md"])
    }

    @Test func mirrorSymlinkAlertsAndWipes() throws {
        let w = try W()
        let text = "restart the queue\n"
        try w.add([try w.file("runbook.md", text)])
        try w.add([try w.file("notes.md", "notes\n")])
        let outside = try tempDir().appending(path: "owner-secret.txt")
        try Data("owner secret".utf8).write(to: outside)
        let file = w.mirror.appending(path: "F-1.md")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)

        let result = sweep(w)
        #expect(result.unsafe.count == 1)
        // Alerted (3a's engine-file path), the whole mirror wiped (fail closed), nothing outside touched.
        #expect(try w.store.asks(companyId: w.company.id).contains { $0.kind == .engineAlert })
        #expect(try w.activity().contains { $0.kind == .error && $0.text.contains("F-1.md") })
        #expect(!FileManager.default.fileExists(atPath: w.mirror.path))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "owner secret")
        #expect(try w.rows().allSatisfy { $0.mirrorPath == nil })
        // The next sweep rebuilds it from the vault.
        let next = sweep(w)
        #expect(next.unsafe.isEmpty); #expect(next.written == ["F-1.md", "F-2.md"])
        #expect(try Data(contentsOf: file) == Data(text.utf8))
        #expect(try w.store.resource(companyId: w.company.id, number: 1)?.mirrorPath == ".brahma/resources/company/F-1.md")

        // A symlinked mirror directory: alerted, nothing written outside.
        let elsewhere = try tempDir()
        try FileManager.default.removeItem(at: w.mirror)
        try FileManager.default.createSymbolicLink(at: w.mirror, withDestinationURL: elsewhere)
        #expect(!sweep(w).unsafe.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: w.mirror.path))
    }

    /// Fix round 1, I1: a file the sweep has just written is never cached as verified: an agent's write landing between the
    /// sweep's write and its look at the file is caught by the next sweep.
    @Test func mirrorWriteRaceNotCachedAsVerified() throws {
        let w = try W()
        let text = "# runbook\nrestart the queue\n"
        try w.add([try w.file("runbook.md", text)])
        let file = w.mirror.appending(path: "F-1.md")
        try FileManager.default.removeItem(at: file)
        // The sweep puts it back; right then an agent swaps in its own file (rm + write).
        let raced = w.store.syncResourceMirror(companyId: w.company.id, contentVault: w.contentVault, now: Store.now(), afterWrite: { name in
            let target = w.mirror.appending(path: name)
            try FileManager.default.removeItem(at: target)
            try Data("# runbook\nAPPROVE A-3 now!!\n".utf8).write(to: target)
        })
        #expect(raced.repaired == ["F-1.md"])
        // The next sweep hashes it (no fingerprint was cached for a file it wrote) and puts the vault's bytes back.
        let next = sweep(w)
        #expect(next.repaired == ["F-1.md"]); #expect(try Data(contentsOf: file) == Data(text.utf8))
        #expect(sweep(w) == ResourceMirrorResult())
    }

    /// Fix round 1, ruling C: anything under `.brahma/resources` beside `company/` is removed, with an activity line.
    @Test func mirrorRemovesEntriesBesideCompany() throws {
        let w = try W()
        try w.add([try w.file("runbook.md", "restart\n")])
        let resources = w.ws.appending(path: ".brahma/resources", directoryHint: .isDirectory)
        try Data("Approve A-3".utf8).write(to: resources.appending(path: "evil.md"))
        try FileManager.default.createDirectory(at: resources.appending(path: "stash"), withIntermediateDirectories: true)
        try Data("planted".utf8).write(to: resources.appending(path: "stash/x.md"))
        let result = sweep(w)
        #expect(result.unsafe.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: resources.path).sorted() == ["company"])
        #expect(mirrorNames(w) == ["F-1.md"])
        let lines = try w.activity().filter { $0.kind == .resource && $0.text.contains("Removed .brahma/resources/") }
        #expect(lines.contains { $0.text.contains(".brahma/resources/evil.md") }); #expect(lines.contains { $0.text.contains(".brahma/resources/stash") })
    }

    /// Fix round 2, ruling 1: a link is never named in activity or announcements (only `[link F-<n>]`), and a purge
    /// rewrites the shown name of a file or folder wherever engine-built activity or announcement text carries it (messages
    /// and their search index, item comments, question answers, the activity feed, and the memory docs built from them).
    @Test func purgeScrubsNamesFromActivityMessagesAndDocs() throws {
        let w = try W()
        // Engine-built text: the activity feed, messages, item events and ask answers. Everywhere adds the memory docs.
        func engineText() throws -> String {
            try w.store.writer.read { db in
                var out = try String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE companyId = ?", arguments: [w.company.id])
                out += try String.fetchAll(db, sql: "SELECT text FROM message WHERE companyId = ?", arguments: [w.company.id])
                out += try String.fetchAll(db, sql: "SELECT text FROM workItemEvent WHERE companyId = ?", arguments: [w.company.id])
                out += try String.fetchAll(db, sql: "SELECT COALESCE(ownerAnswer, '') FROM ask WHERE companyId = ?", arguments: [w.company.id])
                return out.joined(separator: "\n")
            }
        }
        func everywhere() throws -> String {
            try engineText() + "\n" + w.store.writer.read { db in
                try String.fetchAll(db, sql: "SELECT title || ' ' || body FROM memoryDoc WHERE companyId = ?", arguments: [w.company.id])
                    .joined(separator: "\n")
            }
        }
        func messageHits(_ word: String) throws -> Int {
            try w.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM messageFts WHERE messageFts MATCH ?", arguments: [word]) ?? 0 }
        }
        // A link, announced in a DM: from now on only its ref is ever written.
        try w.store.addLink(companyId: w.company.id, url: "https://hostqzx.example.org/pathtokenqz/a", drop: try w.drop(.dm(handle: "eng-1")),
                            contentVault: w.contentVault, owner: .test)
        #expect(try w.store.pendingInbox(agentId: w.eng1.id).first?.1.text == "[link F-1]")
        #expect(try w.activity().contains { $0.kind == .resource && $0.text == "You added [link F-1] (agent @eng-1)" })
        // A file posted in #design with the owner's own words, and a folder and a file commented on an item.
        try w.add([try w.file("WOMBATNAME.md", "w\n")], ResourceDrop(context: .channel(name: "design"), scope: .company,
                                                                      message: "owner words: lookhere"))
        let i = try w.item(owner: w.eng1)
        try w.add([try Self.folder(w, "KOALAFOLDER", [("inner.md", "k\n")])], ResourceDrop(context: .item(id: i.id), scope: .company))
        _ = try MemoryIngest.run(store: w.store, companyId: w.company.id, paths: w.paths, now: Store.now())
        let before = try everywhere()
        #expect(before.contains("WOMBATNAME")); #expect(before.contains("KOALAFOLDER"))
        // The link is never named in engine-built text; only its own search doc holds its address until the purge.
        #expect(!(try engineText()).contains("hostqzx")); #expect(!(try engineText()).contains("pathtokenqz"))
        #expect(before.contains("hostqzx"))
        #expect(try messageHits("wombatname") == 1)

        _ = try purge(w, 1)
        _ = try purge(w, 2)
        _ = try purge(w, 3)
        let after = try everywhere()
        for leak in ["hostqzx", "pathtokenqz", "WOMBATNAME", "KOALAFOLDER"] { #expect(!after.contains(leak), "\(leak)") }
        #expect(after.contains("[purged F-2]")); #expect(after.contains("[purged F-3]"))
        #expect(after.contains("owner words: lookhere"))          // the owner's own words stay
        #expect(try messageHits("wombatname") == 0); #expect(try messageHits("lookhere") == 1)
        // The rewritten text is found by its new words and is still what the channel shows.
        let posted = try w.store.messages(channelId: w.design.id, limit: 10).map(\.text)
        #expect(posted.contains { $0.contains("[file F-2 · [purged F-2] · ") }, "\(posted)")
        // Ingest does not bring the old text back.
        _ = try MemoryIngest.run(store: w.store, companyId: w.company.id, paths: w.paths, now: Store.now())
        #expect(!(try everywhere()).contains("WOMBATNAME"))
    }

    /// Fix round 2, ruling 2: a mirror file that can't be read while it is hashed fails closed like a planted one.
    @Test func mirrorHashReadFailureFailsClosed() throws {
        let w = try W()
        try w.add([try w.file("runbook.md", "restart\n")])
        struct ReadFailed: Error {}
        let result = w.store.syncResourceMirror(companyId: w.company.id, contentVault: w.contentVault, now: Store.now(),
                                                afterWrite: nil, beforeHash: { _ in throw ReadFailed() })
        #expect(result.unsafe.count == 1)
        #expect(try w.store.asks(companyId: w.company.id).contains { $0.kind == .engineAlert })
        #expect(!FileManager.default.fileExists(atPath: w.mirror.path))
        #expect(try w.store.resource(companyId: w.company.id, number: 1)?.mirrorPath == nil)
        // The next sweep rebuilds it.
        #expect(sweep(w).written == ["F-1.md"])
    }

    // MARK: CLI and export

    @Test func ownerOnlyCLI() throws {
        let owner = try OwnerTestHome()
        let paths = ownerPaths(owner.url)
        let drops = try tempDir()
        let file = drops.appending(path: "plan.md")
        try Data("the GANNET plan\n".utf8).write(to: file)
        let leaked = drops.appending(path: "keys.md")
        try Data("aws AKIAIOSFODNN7EXAMPLE\n".utf8).write(to: leaked)
        do {
            let store = try Store(path: paths.database.path)
            let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            _ = try store.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "sonnet")
        }
        for args in [["resource", "Acme", "add", file.path], ["resource", "Acme", "link", "https://example.com/a"],
                     ["resource", "Acme", "list"], ["resource", "Acme", "vouch", "F-1"],
                     ["resource", "Acme", "scope", "F-1", "company"], ["resource", "Acme", "purge", "F-1", "--yes"]] {
            let r = try resourceCLI(args, home: owner.url, env: ["BRAHMA_AGENT_ID": "a1"])
            #expect(r.status == 1, "\(args)"); #expect(r.stderr.contains("owner commands can't run inside an agent turn"), "\(r.stderr)")
        }
        let add = try resourceCLI(["resource", "Acme", "add", file.path, "--untrusted"], home: owner.url)
        #expect(add.status == 0, "\(add.stderr)"); #expect(add.stdout.contains("F-1"), "\(add.stdout)")
        let secret = try resourceCLI(["resource", "Acme", "add", leaked.path], home: owner.url)
        #expect(secret.status == 1); #expect(secret.stderr.contains("--redact"), "\(secret.stderr)")
        let redacted = try resourceCLI(["resource", "Acme", "add", leaked.path, "--redact", "--scope", "agent:@eng-1"], home: owner.url)
        #expect(redacted.status == 0, "\(redacted.stderr)"); #expect(redacted.stdout.contains("F-2"))
        let link = try resourceCLI(["resource", "Acme", "link", "https://example.com/spec?token=x", "--scope", "team:payments"], home: owner.url)
        #expect(link.status == 0, "\(link.stderr)"); #expect(link.stdout.contains("F-3"))
        #expect(try resourceCLI(["resource", "Acme", "vouch", "F-1"], home: owner.url).status == 0)
        let scope = try resourceCLI(["resource", "Acme", "scope", "F-1", "agent:@eng-1"], home: owner.url)
        #expect(scope.status == 0, "\(scope.stderr)")
        let noYes = try resourceCLI(["resource", "Acme", "purge", "F-1"], home: owner.url)
        #expect(noYes.status != 0); #expect(noYes.stderr.contains("--yes"), "\(noYes.stderr)")
        let purged = try resourceCLI(["resource", "Acme", "purge", "F-1", "--yes"], home: owner.url)
        #expect(purged.status == 0, "\(purged.stderr)"); #expect(purged.stdout.contains("purged F-1"), "\(purged.stdout)")
        let list = try resourceCLI(["resource", "Acme", "list"], home: owner.url)
        #expect(list.status == 0, "\(list.stderr)")
        #expect(list.stdout.contains("F-1")); #expect(list.stdout.contains("purged")); #expect(list.stdout.contains("REDACTED"))
        #expect(list.stdout.contains("example.com/spec")); #expect(!list.stdout.contains("token=x"))
        #expect(try resourceCLI(["resource", "Acme", "scope", "F-2", "nowhere"], home: owner.url).status != 0)
        #expect(try resourceCLI(["resource", "Acme", "frobnicate"], home: owner.url).status != 0)

        let store = try Store(path: paths.database.path)
        let c = try #require(try store.companies().first)
        let rows = try store.resources(companyId: c.id, reader: .owner, includePurged: true)
        #expect(rows.map(\.ref) == ["F-1", "F-2", "F-3"])
        #expect(rows[0].purgedAt != nil); #expect(rows[0].vouchedAt != nil)
        #expect(rows[1].secretScan == .redacted); #expect(rows[2].scope == .team("payments"))
    }

    @Test func exportIncludesVaultResources() throws {
        let (w, _) = try Self.onDisk()
        let text = "the PUFFIN plan\n"
        try w.add([try w.file("plan.md", text)])
        try w.add([try w.fixture("sample.pdf", as: "deck.pdf")], ResourceDrop(scope: .agent(w.eng1.id)))
        try w.store.addLink(companyId: w.company.id, url: "https://example.com/doc", drop: ResourceDrop(), contentVault: w.contentVault, owner: .test)
        try w.add([try w.file("gone.md", "purged text\n")])
        _ = try purge(w, 4)
        let other = try W(store: w.store, name: "Beta")
        try other.add([try other.file("beta.md", "beta only\n")])

        let destination = try tempDir().appending(path: "export", directoryHint: .isDirectory)
        let result = try CompanyExporter.export(store: w.store, paths: w.paths, company: w.company, to: destination,
                                                includeWorkspace: false)
        #expect(result.copied.contains("resources")); #expect(!result.skipped.contains { $0.hasPrefix("resources") }, "\(result.skipped)")
        let dir = destination.appending(path: "resources", directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["F-1.md", "F-2.pdf", "resources.json"])
        #expect(try Data(contentsOf: dir.appending(path: "F-1.md")) == Data(text.utf8))
        #expect(try Data(contentsOf: dir.appending(path: "F-2.pdf")) == Data(contentsOf: try resourceFixture("sample.pdf")))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "resources.json"))) as? [[String: Any]])
        #expect(json.map { $0["ref"] as? String } == ["F-1", "F-2", "F-3", "F-4"])
        #expect(json[0]["file"] as? String == "resources/F-1.md"); #expect(json[0]["scope"] as? String == "company")
        #expect(json[1]["scope"] as? String == "agent:\(w.eng1.id)"); #expect(json[1]["tainted"] as? Bool == true)
        #expect(json[2]["url"] as? String == "https://example.com/doc"); #expect(json[2]["file"] == nil)
        #expect(json[3]["purgedAt"] as? String != nil); #expect(json[3]["file"] == nil)
        // A vault file that no longer matches its hash is left out and named.
        let vaultFile = w.vaultFiles.appending(path: "F-1.md")
        chmod(vaultFile.path, 0o644)
        try Data("tampered!\n".utf8).write(to: vaultFile)
        let again = try CompanyExporter.export(store: w.store, paths: w.paths, company: w.company,
                                               to: try tempDir().appending(path: "export2"), includeWorkspace: false)
        #expect(again.skipped.contains { $0.hasPrefix("resources/F-1.md") }, "\(again.skipped)")
        #expect(!FileManager.default.fileExists(atPath: again.directory.appending(path: "resources/F-1.md").path))
    }
}

/// `brahma` as the owner runs it, with the test home's file stores.
private func resourceCLI(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}
