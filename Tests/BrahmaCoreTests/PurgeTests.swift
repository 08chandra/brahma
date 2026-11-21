import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C2b: the owner's purge of shared content (`Store.purge`) — vault bytes through `Vault` and ML's
/// `purgeResource`, share refs and their objects through `SafeGit` (`deleteShareRef`, `expireAndPrune`), a tombstone that
/// resolves as purged, the backups and transcripts that may still hold it, and no agent path to any of it.
@Suite(.scratch) struct PurgeTests {
    /// A `messageRef` row for `pinned` (what C3b writes when a message carries it).
    static func record(_ cf: CollabFixture, _ pinned: WorkRef, id: String, at date: Date) throws {
        let params = String(decoding: try JSONEncoder().encode(pinned.params), as: UTF8.self)
        let row = MessageRef(id: id, companyId: cf.c.id, messageId: cf.fx.engMessage.id, position: 0, canonical: pinned.canonical,
                             kind: pinned.kind.rawValue, refId: pinned.id, branch: pinned.branch, rev: pinned.rev, params: params,
                             accessKind: "company", createdAt: date)
        try cf.store.writer.write { db in try row.insert(db) }
    }

    static func state(_ cf: CollabFixture, _ id: String) throws -> String? {
        let cId = cf.c.id
        return try cf.store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM messageRef WHERE companyId = ? AND id = ?", arguments: [cId, id])
        }
    }

    /// A DB backup file named for `date` (what `BackupService.list` reads).
    static func fakeBackup(_ cf: CollabFixture, at date: Date) throws -> String {
        try FileManager.default.createDirectory(at: cf.paths.dbBackups, withIntermediateDirectories: true)
        let name = "brahma-\(BackupService.stamp(date))-manual.sqlite"
        try Data("not really a database".utf8).write(to: cf.paths.dbBackups.appending(path: name))
        return name
    }

    static func day(_ store: Store, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = store.ownerTimeZone()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func notices(_ cf: CollabFixture) throws -> [OwnerNotice] {
        let cId = cf.c.id
        return try cf.store.writer.read { db in
            try OwnerNotice.fetchAll(db, sql: "SELECT * FROM ownerNotice WHERE companyId = ? ORDER BY id", arguments: [cId])
        }
    }

    func purge(_ cf: CollabFixture, _ ref: WorkRef, now: Date) throws -> RefPurgeReport {
        try cf.store.purge(companyId: cf.c.id, ref: ref, contentVault: ContentVault(paths: cf.paths), paths: cf.paths, now: now)
    }

    @Test func purgeRemovesObjectAndFlagsBackups() throws {
        let cf = try CollabFixture()
        let cId = cf.c.id
        // A worktree file pinned as a blob under its share ref, carried by a message.
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/leak.ts", "export const leaked = 'only here'\n", in: wt)
        let pinned = try cf.store.pinRef(try cf.fx.ref("ENG-1:src/leak.ts@worktree"), for: .agent(cf.fx.eng1.id), companyId: cId,
                                         messageRefId: "mr-p", knownValues: [], paths: cf.paths)
        let blob = try #require(pinned.rev)
        try Self.record(cf, pinned, id: "mr-p", at: cf.now)
        try cf.fx.git.git(["cat-file", "-e", blob])   // there before the purge
        // A backup taken after the pin, and one before it.
        let after = cf.now.addingTimeInterval(60)
        let backup = try Self.fakeBackup(cf, at: after)
        _ = try Self.fakeBackup(cf, at: cf.now.addingTimeInterval(-3600))

        let report = try purge(cf, pinned, now: cf.now.addingTimeInterval(120))
        #expect(report.gitRefs == ["refs/brahma/shares/mr-p"])
        #expect(report.backupsFlagged == [backup])
        #expect(!report.stillInHistory)
        // The share ref and its object are gone from the repository.
        #expect((try? cf.fx.git.git(["rev-parse", "--verify", "--quiet", "refs/brahma/shares/mr-p"])) == nil)
        #expect(throws: (any Error).self) { try cf.fx.git.git(["cat-file", "-e", blob]) }
        #expect(!(try cf.fx.git.git(["cat-file", "--batch-all-objects", "--batch"])).contains("only here"))
        // The card is a tombstone, the purge is logged, and the owner hears about the backup.
        #expect(try Self.state(cf, "mr-p") == "purged")
        let log = try #require(try cf.store.writer.read { db in
            try PurgeLog.fetchOne(db, sql: "SELECT * FROM purgeLog WHERE companyId = ?", arguments: [cId])
        })
        #expect(log.canonical == "ENG-1:src/leak.ts@worktree")
        #expect(log.gitRefs.contains("refs/brahma/shares/mr-p") && log.backupsFlagged.contains(backup))
        let notices = try Self.notices(cf)
        #expect(notices.contains { $0.body == "backup \(Self.day(cf.store, after)) contains purged content · delete or re-create" })
        #expect(try cf.store.events(afterId: 0, companyId: cId).contains { $0.kind == .access && $0.text.hasPrefix("Purged ENG-1:src/leak.ts@worktree") })

        // A vaulted share (a lab snapshot F-<n>): its vault file and its index text go through ML's purge.
        try Data("lab secret notes\n".utf8).write(to: cf.workspace.appending(path: ".brahma/labs/eng-1/notes.txt"))
        let snap = try cf.store.snapshotPrivateFile(companyId: cId, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/eng-1/notes.txt",
                                                    readers: [cf.fx.qa2.id], knownValues: [], paths: cf.paths, now: cf.now)
        let snapNumber = try #require(Int(snap.id))
        let row = try #require(try cf.store.resource(companyId: cId, number: snapNumber))
        let file = cf.vault.root.appending(path: try #require(row.vaultPath))
        #expect(FileManager.default.fileExists(atPath: file.path))
        let snapReport = try purge(cf, snap, now: cf.now.addingTimeInterval(180))
        #expect(snapReport.vaultPaths == [row.vaultPath])
        #expect(snapReport.backupsFlagged == [backup])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let doc = try #require(try cf.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT title, body, removedAt FROM memoryDoc WHERE companyId = ? AND source = 'resource' AND sourceId = ?",
                             arguments: [cId, row.id])
        })
        #expect(doc["title"] as String == "[purged]" && doc["body"] as String == "" && (doc["removedAt"] as Date?) != nil)
        #expect(try cf.store.resource(companyId: cId, number: row.number)?.purgedAt != nil)
    }

    @Test func purgedRefResolvesAsTombstone() throws {
        let cf = try CollabFixture()
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\n", in: wt)
        let file = try cf.store.pinRef(try cf.fx.ref("ENG-1:src/a.ts@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                       messageRefId: "mr-f", knownValues: [], paths: cf.paths)
        let diff = try cf.store.pinRef(try cf.fx.ref("ENG-1:diff@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                       messageRefId: "mr-d", knownValues: [], paths: cf.paths)
        try Self.record(cf, file, id: "mr-f", at: cf.now)
        try Self.record(cf, diff, id: "mr-d", at: cf.now)
        let snapId = try #require(diff.params["snapshot"])
        let cId = cf.c.id
        let snapshot = try #require(try cf.store.writer.read { db in
            try RefSnapshot.fetchOne(db, sql: "SELECT * FROM refSnapshot WHERE companyId = ? AND id = ?", arguments: [cId, snapId])
        })
        _ = try purge(cf, file, now: cf.now)
        let report = try purge(cf, diff, now: cf.now)
        #expect(report.vaultPaths == [snapshot.vaultPath])
        #expect(!FileManager.default.fileExists(atPath: cf.vault.root.appending(path: snapshot.vaultPath).path))
        #expect(try cf.store.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT purgedAt FROM refSnapshot WHERE companyId = ? AND id = ?", arguments: [cId, snapId])
        } != nil)
        for pinned in [file, diff] {
            let r = try cf.store.resolveRef(pinned, for: .agent(cf.fx.qa2.id), companyId: cId)
            #expect(r.visibility == .full && r.state == .purged && r.bytes == nil)
            #expect(try cf.open(.qa2, pinned: pinned).text == "that ref was purged by the owner")
            // Nothing is copied or shown to the owner either.
            #expect(throws: WorkError.self) { try cf.store.viewOriginal(companyId: cId, ref: pinned, knownValues: [], paths: cf.paths, now: cf.now) }
        }
        // Another company's reader still sees nothing at all.
        let outsider = try cf.store.hire(companyId: cf.fx.d.id, name: "d-eng", role: "engineer", model: "sonnet")
        #expect(try cf.store.resolveRef(file, for: .agent(outsider.id), companyId: cId).visibility != .full)
        // A purged resource resolves the same way (bytes nil).
        try Data("x\n".utf8).write(to: cf.workspace.appending(path: ".brahma/labs/eng-1/x.txt"))
        let snap = try cf.store.snapshotPrivateFile(companyId: cId, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/eng-1/x.txt",
                                                    readers: [cf.fx.qa2.id], knownValues: [], paths: cf.paths, now: cf.now)
        _ = try purge(cf, snap, now: cf.now)
        let r = try cf.store.resolveRef(snap, for: .owner, companyId: cId)
        #expect(r.state == .purged && r.bytes == nil)
    }

    @Test func committedContentReportsHistory() throws {
        let cf = try CollabFixture()
        let cId = cf.c.id
        let sha = try cf.commit(["src/shared.ts": Data("committed text\n".utf8)])
        let pinned = try cf.store.pinRef(try cf.fx.ref("src/shared.ts"), for: .agent(cf.fx.eng1.id), companyId: cId,
                                         messageRefId: "mr-c", knownValues: [], paths: cf.paths)
        #expect(pinned.rev == sha)
        // A share ref for the commit (C3b makes one for non-main commits), and a taint row the purge must not touch.
        var shared = pinned
        shared.params["share"] = "mr-c"
        try SafeGit(workspace: cf.workspace, runner: LiveGitRunner(tempRoot: nil)).updateShareRef("mr-c", to: sha)
        try Self.record(cf, shared, id: "mr-c", at: cf.now)
        try cf.store.writer.write { db in
            try TaintedCommit(companyId: cId, sha: sha, itemId: nil, agentId: nil, turnId: nil, source: "docs.example", createdAt: cf.now).insert(db)
        }
        let report = try purge(cf, shared, now: cf.now)
        #expect(report.gitRefs == ["refs/brahma/shares/mr-c"])
        #expect(report.stillInHistory)
        #expect((try? cf.fx.git.git(["rev-parse", "--verify", "--quiet", "refs/brahma/shares/mr-c"])) == nil)
        // History keeps the commit (the owner is told), and the taint row stays.
        #expect(try cf.fx.git.git(["cat-file", "-t", sha]) == "commit")
        #expect(try cf.store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taintedCommit WHERE companyId = ? AND sha = ?", arguments: [cId, sha])
        } == 1)
        #expect(try Self.state(cf, "mr-c") == "purged")
        #expect(try Self.notices(cf).contains { $0.body.contains("still in the company's git history") })
    }

    @Test func purgeIsOwnerOnly() throws {
        // No tool path reaches it: no company tool is a purge, and none is in either taint set.
        #expect(!CompanyToolNames.all.contains { $0.contains("purge") })
        #expect(!TaintPolicy.taintSafeTools.contains { $0.contains("purge") })
        let cf = try CollabFixture()
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/a.ts", "pinned\n", in: wt)
        let pinned = try cf.store.pinRef(try cf.fx.ref("ENG-1:src/a.ts@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                         messageRefId: "mr-o", knownValues: [], paths: cf.paths)
        try Self.record(cf, pinned, id: "mr-o", at: cf.now)
        // While a turn of the company runs, git is not pruned under it: refused, nothing changed.
        let turn = Turn(id: UUID().uuidString, agentId: cf.fx.eng1.id, companyId: cf.c.id, startedAt: cf.now, endedAt: nil,
                        outcome: .inProgress, summary: nil, costUSD: nil)
        try cf.store.writer.write { db in try turn.insert(db) }
        #expect(throws: WorkError.self) { try purge(cf, pinned, now: cf.now) }
        #expect(try Self.state(cf, "mr-o") == "ok")
        #expect(try cf.fx.git.git(["rev-parse", "refs/brahma/shares/mr-o"]) == pinned.rev)
        // A ref of another company is not found, and the vault must be this data home's.
        #expect(throws: (any Error).self) {
            try cf.store.purge(companyId: cf.fx.d.id, ref: pinned, contentVault: ContentVault(paths: cf.paths), paths: cf.paths, now: cf.now)
        }
        let elsewhere = BrahmaPaths(home: try tempDir(), workspaces: try tempDir())
        #expect(throws: (any Error).self) {
            try cf.store.purge(companyId: cf.c.id, ref: pinned, contentVault: ContentVault(paths: elsewhere), paths: cf.paths, now: cf.now)
        }
    }

    @Test func purgeOtherKinds() throws {
        let cf = try CollabFixture()
        let cId = cf.c.id
        // A memory entry goes through ML's secure delete (`ownerDeleteMemory`, `purgeMemoryDocs`).
        let mem = try cf.fx.ref("mem:\(cf.fx.hrMemory)")
        let report = try purge(cf, mem, now: cf.now)
        #expect(!report.stillInHistory && report.gitRefs.isEmpty)
        let entry = try cf.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT fact, purgedAt FROM memoryEntry WHERE companyId = ? AND number = ?", arguments: [cId, cf.fx.hrMemory])
        }
        #expect((entry?["purgedAt"] as Date?) != nil && (entry?["fact"] as String?) != "eng-3 had a rough review")
        // A live record is not content this purge removes: refused with the reason, never reported as done.
        let why = WorkError.invalid("items, asks, kb pages, messages and the like are live records, not shared content: there are no "
                                    + "stored bytes to purge. Purge the file or resource they carry, or edit the record itself")
        #expect(throws: why) { try purge(cf, try cf.fx.ref("ENG-1"), now: cf.now) }
        #expect(throws: why) { try purge(cf, try cf.fx.ref("#eng"), now: cf.now) }
        // A file nothing shared is not found.
        #expect(throws: WorkError.notFound("that ref isn't available to you")) { try purge(cf, try cf.fx.ref("src/a.ts"), now: cf.now) }
    }

    /// R1-8: the running-turn check and the git prune are atomic with respect to a turn starting: while a purge holds the
    /// company's purge fence no turn starts, and a turn that started after the first check refuses the purge.
    @Test func purgeFencedAgainstTurnStart() throws {
        let cf = try CollabFixture()
        cf.store.refHooks.setFenceHome(cf.paths.home)
        let cId = cf.c.id, eng1 = cf.fx.eng1.id
        // A turn start while the fence is held: refused (the agent stays ready), and it starts once the fence is gone.
        let store = cf.store, now = cf.now
        let (started, lifecycle) = try PurgeFence.withExclusive(home: cf.paths.home, companyId: cId) { () throws -> (Bool, Bool) in
            let begun = try store.beginTurn(agentId: eng1, now: now) != nil
            let direct = (try? store.startTurn(agentId: eng1, now: now, fenceWait: .milliseconds(50))) != nil
            return (begun, direct)
        }
        #expect(!started && !lifecycle)
        #expect(try cf.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM turn WHERE companyId = ?", arguments: [cId]) } == 0)
        // A turn that starts between the purge's first check and its fence: the purge re-checks under the fence and refuses.
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/a.ts", "pinned\n", in: wt)
        let pinned = try cf.store.pinRef(try cf.fx.ref("ENG-1:src/a.ts@worktree"), for: .agent(eng1), companyId: cId,
                                         messageRefId: "mr-f", knownValues: [], paths: cf.paths)
        try Self.record(cf, pinned, id: "mr-f", at: cf.now)
        cf.store.refHooks.setAfterPurgeTurnCheck { _ = try store.beginTurn(agentId: eng1, now: now) }
        #expect(throws: WorkError.self) { try purge(cf, pinned, now: cf.now) }
        #expect(try Self.state(cf, "mr-f") == "ok")
        #expect(try cf.fx.git.git(["rev-parse", "refs/brahma/shares/mr-f"]) == pinned.rev)
        cf.store.refHooks.setAfterPurgeTurnCheck(nil)
    }

    @Test func purgeIncompleteAlertsOwner() throws {
        let cf = try CollabFixture()
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/staged.ts", "staged bytes\n", in: wt)
        let pinned = try cf.store.pinRef(try cf.fx.ref("ENG-1:src/staged.ts@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                         messageRefId: "mr-i", knownValues: [], paths: cf.paths)
        try Self.record(cf, pinned, id: "mr-i", at: cf.now)
        // The agent staged the same bytes: the worktree's index still holds the object, so prune can't remove it.
        try cf.fx.git.git(["add", "src/staged.ts"], in: wt)
        #expect(throws: WorkError.self) { try purge(cf, pinned, now: cf.now) }
        // Loud, not silent: the share ref is gone, the card is a tombstone, and the owner is alerted that it is incomplete.
        #expect((try? cf.fx.git.git(["rev-parse", "--verify", "--quiet", "refs/brahma/shares/mr-i"])) == nil)
        #expect(try Self.state(cf, "mr-i") == "purged")
        let cId = cf.c.id
        let alerts = try cf.store.writer.read { db in
            try Ask.fetchAll(db, sql: "SELECT * FROM ask WHERE companyId = ? AND kind = 'engineAlert'", arguments: [cId])
        }
        #expect(alerts.contains { $0.title.contains("purge") && $0.title.contains("incomplete") })
    }

    /// R2-6: the purge log keeps the ref's name with every stored value redacted (it is a log), like every message does.
    @Test func purgeLogNeverHoldsAValue() throws {
        let cf = try CollabFixture()
        let cId = cf.c.id
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        let file = "src/\(SecretGateTests.value).ts"
        try cf.fx.git.write(file, "export const fine = 1\n", in: wt)
        let pinned = try cf.store.pinRef(try cf.fx.ref("ENG-1:\(file)@worktree"), for: .agent(cf.fx.eng1.id), companyId: cId,
                                         messageRefId: "mr-n", knownValues: [], paths: cf.paths)
        try Self.record(cf, pinned, id: "mr-n", at: cf.now)
        _ = try cf.store.purge(companyId: cId, ref: pinned, contentVault: ContentVault(paths: cf.paths), paths: cf.paths,
                               knownValues: SecretGateTests.known, now: cf.now)
        let log = try #require(try cf.store.writer.read { db in
            try PurgeLog.fetchOne(db, sql: "SELECT * FROM purgeLog WHERE companyId = ?", arguments: [cId])
        })
        #expect(log.canonical == "ENG-1:src/[redacted stored secret STRIPE_KEY].ts@worktree")
        let texts = try cf.store.events(afterId: 0, companyId: cId).map(\.text) + [log.canonical]
        for text in texts { for piece in SecretGateTests.pieces(SecretGateTests.value) { #expect(!text.contains(piece)) } }
        // The tombstone still answers for the ref (the share is found by its ref, not by the logged name).
        #expect(try Self.state(cf, "mr-n") == "purged")
    }
}

/// R4-6 (c): a purge holding a company's purge fence exclusively, on its own thread, until `release`.
final class ExclusiveFence: @unchecked Sendable {
    private let held = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    init(home: URL, companyId: String) {
        Thread.detachNewThread { [held, done, finished] in   // scope-escape: holds the fence lock only; no scratch dirs
            _ = try? PurgeFence.withExclusive(home: home, companyId: companyId) { held.signal(); done.wait() }
            finished.signal()
        }
        held.wait()
    }

    func release() {
        done.signal()
        finished.wait()
    }
}
