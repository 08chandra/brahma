import Testing
import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// Plan C Task C2a: what a share keeps — `@worktree` files as git blobs under `refs/brahma/shares/<id>`, worktree diffs as
/// vault snapshots, committed diffs in the vault's diff cache, and private lab files as `F-<n>` snapshots with fixed readers.
@Suite(.scratch) struct RefPinTests {
    @Test func worktreePinSurvivesWorktreeRemoval() throws {
        let cf = try CollabFixture()
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/a.ts", "pinned bytes\n", in: wt)
        let ref = try cf.fx.ref("ENG-1:src/a.ts@worktree")
        let pinned = try cf.store.pinRef(ref, for: .agent(cf.fx.eng1.id), companyId: cf.c.id, messageRefId: "mr-w", paths: cf.paths)
        let blob = try #require(pinned.rev)
        #expect(pinned.canonical == "ENG-1:src/a.ts@worktree")
        #expect(pinned.params["share"] == "mr-w")
        #expect(pinned.params["taint"] == nil)
        #expect(try cf.fx.git.git(["rev-parse", "refs/brahma/shares/mr-w"]) == blob)
        #expect(try cf.fx.git.git(["cat-file", "-p", blob]) == "pinned bytes")
        // The worktree and the branch go (the item merged): the pin still opens the shared bytes.
        try cf.fx.git.git(["worktree", "remove", "--force", wt.path])
        try cf.fx.git.git(["branch", "-D", "item/ENG-1"])
        #expect(try cf.fx.resolve(.qa2, ref).visibility == .missing)
        let resolved = try cf.store.resolveRef(pinned, for: .agent(cf.fx.qa2.id), companyId: cf.c.id)
        #expect(resolved.visibility == .full && resolved.subtitle.hasPrefix("1 line · TypeScript"))
        let out = try cf.open(.qa2, pinned: pinned)
        #expect(out.text.components(separatedBy: "\n").dropFirst() == ["    | pinned bytes"])
        #expect(try cf.reads("ENG-1:src/a.ts@worktree").first?.rev == blob)
        // A pin naming a blob its share ref does not point at opens nothing.
        var forged = pinned
        forged.rev = try cf.fx.git.git(["rev-parse", "main:src/checkout.tsx"])
        #expect(cf.failure { try cf.open(.qa2, pinned: forged) } == "that ref isn't available to you")
        forged = pinned
        forged.params["share"] = "mr-other"
        #expect(cf.failure { try cf.open(.qa2, pinned: forged) } == "that ref isn't available to you")
    }

    @Test func worktreeDiffPinIsVaultSnapshot() throws {
        let cf = try CollabFixture()
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\n", in: wt)
        let ref = try cf.fx.ref("ENG-1:diff@worktree")
        // Without the data home there is nowhere to keep it.
        #expect(throws: WorkError.self) {
            try cf.store.pinRef(ref, for: .agent(cf.fx.eng1.id), companyId: cf.c.id, messageRefId: "mr-x")
        }
        let pinned = try cf.store.pinRef(ref, for: .agent(cf.fx.eng1.id), companyId: cf.c.id, messageRefId: "mr-d", paths: cf.paths)
        let id = try #require(pinned.params["snapshot"])
        #expect(pinned.canonical == "ENG-1:diff@worktree")
        let cId = cf.c.id
        let row = try #require(try cf.store.writer.read { db in
            try RefSnapshot.fetchOne(db, sql: "SELECT * FROM refSnapshot WHERE companyId = ? AND id = ?", arguments: [cId, id])
        })
        #expect(row.kind == "worktreeDiff" && row.cacheKey == "mr-d" && row.vaultPath == "snapshots/\(id).patch")
        #expect(!row.tainted && row.purgedAt == nil)
        let patch = try cf.vault.read(row.vaultPath, sha256: row.sha256, maxBytes: row.bytes)
        #expect(row.bytes == patch.count && String(decoding: patch, as: UTF8.self).contains("+four"))
        // The worktree goes; the snapshot is what opens.
        try cf.fx.git.git(["worktree", "remove", "--force", wt.path])
        let out = try cf.open(.qa2, pinned: pinned)
        #expect(out.text.contains("    | +four"))
        #expect(try cf.store.resolveRef(pinned, for: .agent(cf.fx.qa2.id), companyId: cId).visibility == .full)
        // A changed byte in the vault fails the read.
        let file = cf.vault.root.appending(path: row.vaultPath)
        #expect(chmod(file.path, 0o644) == 0)
        var tampered = patch
        tampered[tampered.count - 2] ^= 0x01
        try tampered.write(to: file)
        #expect(cf.failure { try cf.open(.qa2, pinned: pinned) } == "that ref isn't available to you")

        // A committed diff's pin keeps its patch in the diff cache, verified on every read.
        let committed = try cf.store.pinRef(try cf.fx.ref("ENG-1:diff"), for: .agent(cf.fx.eng1.id), companyId: cId,
                                            messageRefId: "mr-c", paths: cf.paths)
        let head = try cf.fx.head("item/ENG-1"), base = try cf.fx.git.git(["merge-base", "main", "item/ENG-1"])
        #expect(committed.rev == head)
        let cached = try #require(try cf.store.writer.read { db in
            try RefSnapshot.fetchOne(db, sql: "SELECT * FROM refSnapshot WHERE companyId = ? AND kind = 'diffCache'", arguments: [cId])
        })
        #expect(cached.cacheKey == "\(base)..\(head)" && cached.vaultPath.hasPrefix("diffcache/"))
        let diffText = try cf.open(.qa2, pinned: committed).text
        #expect(diffText.hasPrefix("[diff ENG-1:diff @\(head.prefix(7)) · +3 \u{2212}1 in 2 files]"))
        #expect(diffText.contains("    | +TWO"))
        // Opening it again reuses the one cache row.
        _ = try cf.open(.eng1, "ENG-1:diff")
        #expect(try cf.store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM refSnapshot WHERE companyId = ? AND kind = 'diffCache'", arguments: [cId])
        } == 1)
    }

    @Test func labSnapshotHasFixedReaders() throws {
        let cf = try CollabFixture()
        let ref = try cf.store.snapshotPrivateFile(companyId: cf.c.id, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/eng-1/mine.txt",
                                                   readers: [cf.fx.qa2.id], knownValues: [], paths: cf.paths, now: cf.now)
        #expect(ref == WorkRef(kind: .resource, id: "4"))
        let r = try #require(try cf.store.resource(companyId: cf.c.id, number: 4))
        #expect(r.readerSet == [cf.fx.qa2.id])
        #expect(r.provenance == Provenance.agent(cf.fx.eng1.id).raw)
        #expect(!r.tainted && r.taintReason == nil)
        #expect(r.addedVia == "share" && r.kind == .file && r.ext == "txt" && r.displayName == "mine.txt")
        #expect(r.vaultPath == "resources/F-4.txt" && r.bytes == 8)
        #expect(try cf.vault.read("resources/F-4.txt", sha256: try #require(r.sha256), maxBytes: 8) == Data("eng lab\n".utf8))
        // Only the fixed readers (and the owner) open it.
        #expect(try cf.open(.qa2, "F-4").text.contains("    | eng lab"))
        #expect(try cf.open(.owner, "F-4").text.contains("    | eng lab"))
        #expect(cf.failure { try cf.open(.cto, "F-4") } == "that ref isn't available to you")
        #expect(cf.failure { try cf.open(.eng1, "F-4") } == "that ref isn't available to you")
        // The next snapshot takes the next number of the same sequence.
        let again = try cf.store.snapshotPrivateFile(companyId: cf.c.id, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/eng-1/mine.txt",
                                                     readers: [cf.fx.qa2.id, cf.fx.cto.id], knownValues: [], paths: cf.paths, now: cf.now)
        #expect(again.id == "5")
        #expect(try cf.store.resource(companyId: cf.c.id, number: 5)?.readerSet == [cf.fx.qa2.id, cf.fx.cto.id])
        // Only the agent's own lab or notes: another agent's lab, a worktree or main file, a reader of another company.
        #expect(throws: (any Error).self) {
            try cf.store.snapshotPrivateFile(companyId: cf.c.id, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/qa-2/x",
                                             readers: [cf.fx.qa2.id], knownValues: [], paths: cf.paths, now: cf.now)
        }
        #expect(throws: (any Error).self) {
            try cf.store.snapshotPrivateFile(companyId: cf.c.id, agentId: cf.fx.eng1.id, workspacePath: "src/a.ts",
                                             readers: [cf.fx.qa2.id], knownValues: [], paths: cf.paths, now: cf.now)
        }
        let outsider = try cf.store.hire(companyId: cf.fx.d.id, name: "d-eng", role: "engineer", model: "sonnet")
        #expect(throws: (any Error).self) {
            try cf.store.snapshotPrivateFile(companyId: cf.c.id, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/eng-1/mine.txt",
                                             readers: [outsider.id], knownValues: [], paths: cf.paths, now: cf.now)
        }
        #expect(try cf.store.resource(companyId: cf.c.id, number: 6) == nil)
        // A private file is never pinned into git: it is shared as a snapshot.
        #expect(throws: WorkError.self) {
            try cf.store.pinRef(try cf.fx.ref(".brahma/labs/eng-1/mine.txt"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                messageRefId: "mr-l", paths: cf.paths)
        }
    }
}
