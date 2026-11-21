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
        let pinned = try cf.store.pinRef(ref, for: .agent(cf.fx.eng1.id), companyId: cf.c.id, messageRefId: "mr-w", knownValues: [], paths: cf.paths)
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
            try cf.store.pinRef(ref, for: .agent(cf.fx.eng1.id), companyId: cf.c.id, messageRefId: "mr-x", knownValues: [])
        }
        let pinned = try cf.store.pinRef(ref, for: .agent(cf.fx.eng1.id), companyId: cf.c.id, messageRefId: "mr-d", knownValues: [], paths: cf.paths)
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
        // The mismatch is in the activity log (not on stderr).
        #expect(try cf.store.events(afterId: 0, companyId: cId).contains {
            $0.kind == .error && $0.text == "ENG-1:diff@worktree's vault copy no longer matches the hash recorded for it"
        })

        // A committed diff's pin keeps its patch in the diff cache, verified on every read.
        let committed = try cf.store.pinRef(try cf.fx.ref("ENG-1:diff"), for: .agent(cf.fx.eng1.id), companyId: cId,
                                            messageRefId: "mr-c", knownValues: [], paths: cf.paths)
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
                                messageRefId: "mr-l", knownValues: [], paths: cf.paths)
        }
    }

    // MARK: Fix round 1 (I5): nothing is vaulted, cached or hashed into git without a secret scan.
    // (C2b: the scan is `SecretGate`; a stored value is `WorkError.invalid`, a pattern in a text pin is a redacted copy.)

    static let known: [(name: String, value: String)] = [("STRIPE_KEY", "sk_test_51abcdefgh")]
    static let aws = "AKIA" + "ABCDEFGHIJKLMNOP"   // split so this file does not itself trip a scanner

    @Test func snapshotsAreSecretScanned() throws {
        let cf = try CollabFixture()
        let lab = cf.workspace.appending(path: ".brahma/labs/eng-1")
        try Data("key = sk_test_51abcdefgh\n".utf8).write(to: lab.appending(path: "known.txt"))
        try Data("aws = \(Self.aws)\nok\n".utf8).write(to: lab.appending(path: "pattern.txt"))
        var bin = Data([0, 1, 2]); bin.append(Data(Self.aws.utf8))
        try bin.write(to: lab.appending(path: "blob.dat"))
        func snapshot(_ name: String) throws -> WorkRef {
            try cf.store.snapshotPrivateFile(companyId: cf.c.id, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/eng-1/\(name)",
                                             readers: [cf.fx.qa2.id], knownValues: Self.known, paths: cf.paths, now: cf.now)
        }
        // A stored secret's value refuses the snapshot; nothing is written.
        #expect(throws: WorkError.invalid("known.txt contains a stored secret (line 1); remove it before sharing")) { try snapshot("known.txt") }
        #expect(try cf.store.resource(companyId: cf.c.id, number: 4) == nil)
        #expect(!FileManager.default.fileExists(atPath: cf.vault.root.appending(path: "resources/F-4.txt").path))
        // A secret pattern in text: a redacted copy (REDACTED), never the original bytes.
        let redacted = try snapshot("pattern.txt")
        let r = try #require(try cf.store.resource(companyId: cf.c.id, number: Int(redacted.id) ?? 0))
        #expect(r.secretScan == .redacted)
        let stored = String(decoding: try cf.vault.read(try #require(r.vaultPath), sha256: try #require(r.sha256), maxBytes: Int(r.bytes)), as: UTF8.self)
        #expect(!stored.contains(Self.aws) && stored.contains("[redacted") && stored.contains("ok"))
        // A secret pattern in a binary can't be redacted: refused.
        #expect(throws: WorkError.self) { try snapshot("blob.dat") }
    }

    @Test func pinsAreSecretScanned() throws {
        let cf = try CollabFixture()
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/a.ts", "const k = 'sk_test_51abcdefgh'\n", in: wt)
        func pin(_ s: String, _ id: String) throws -> WorkRef {
            try cf.store.pinRef(try cf.fx.ref(s), for: .agent(cf.fx.eng1.id), companyId: cf.c.id, messageRefId: id,
                                knownValues: Self.known, paths: cf.paths)
        }
        // The file is never hashed into git, and no share ref is made.
        #expect(throws: WorkError.invalid("ENG-1:src/a.ts@worktree contains a stored secret (line 1); remove it before sharing")) {
            try pin("ENG-1:src/a.ts@worktree", "mr-s1")
        }
        #expect((try? cf.fx.git.git(["rev-parse", "--verify", "--quiet", "refs/brahma/shares/mr-s1"])) == nil)
        // A secret pattern: a redacted copy in the vault (C2b), and still no share ref.
        try cf.fx.git.write("src/a.ts", "const k = '\(Self.aws)'\n", in: wt)
        let copy = try pin("ENG-1:src/a.ts@worktree", "mr-s2")
        #expect(copy.kind == .resource && copy.params["source"] == "ENG-1:src/a.ts@worktree")
        #expect((try? cf.fx.git.git(["rev-parse", "--verify", "--quiet", "refs/brahma/shares/mr-s2"])) == nil)
        // A worktree diff holding a stored value is refused; one with a pattern keeps only its redacted text.
        try cf.fx.git.write("src/a.ts", "one\nTWO\nthree\nsk_test_51abcdefgh\n\(Self.aws)\n", in: wt)
        #expect(throws: WorkError.self) { try pin("ENG-1:diff@worktree", "mr-s4") }
        try cf.fx.git.write("src/a.ts", "one\nTWO\nthree\n\(Self.aws)\n", in: wt)
        let diff = try pin("ENG-1:diff@worktree", "mr-s3")
        #expect(diff.params["redacted"] == "1")
        let cId = cf.c.id, id = try #require(diff.params["snapshot"])
        let row = try #require(try cf.store.writer.read { db in
            try RefSnapshot.fetchOne(db, sql: "SELECT * FROM refSnapshot WHERE companyId = ? AND id = ?", arguments: [cId, id])
        })
        let patch = String(decoding: try cf.vault.read(row.vaultPath, sha256: row.sha256, maxBytes: row.bytes), as: UTF8.self)
        #expect(patch.contains("src/a.ts") && !patch.contains("sk_test_51abcdefgh") && !patch.contains(Self.aws))
        #expect(patch.contains("[redacted aws-key]"))
        #expect(try cf.store.resolveRef(diff, for: .agent(cf.fx.qa2.id), companyId: cId).state == .redacted)
    }

    @Test func openRefRedactsSecrets() throws {
        let cf = try CollabFixture()
        try cf.commit(["src/conf.ts": Data("token = sk_test_51abcdefgh\naws = \(Self.aws)\n".utf8),
                       "src/aws.ts": Data("region = eu\naws = \(Self.aws)\n".utf8)])
        func open(_ ref: String, copy: Bool = false) throws -> OpenRefResult {
            try cf.store.openRef(companyId: cf.c.id, reader: .agent(cf.fx.eng1.id), ref: ref, lines: nil, copy: copy,
                                 turnId: nil, context: cf.fx.ctx, knownValues: Self.known, paths: cf.paths, now: cf.now)
        }
        // A stored secret's value refuses the read (C2b's gate) and the copy; a pattern is redacted in what is shown.
        #expect(throws: WorkError.invalid("src/conf.ts contains a stored secret (line 1); remove it before sharing")) { try open("src/conf.ts") }
        #expect(throws: WorkError.self) { try open("src/conf.ts", copy: true) }
        let inbox = cf.workspace.appending(path: ".brahma/labs/eng-1/in").path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: inbox)) ?? []).isEmpty)
        let out = try open("src/aws.ts")
        #expect(!out.text.contains(Self.aws) && out.text.contains("    | aws = [redacted aws-key]"))
        // A copy of text with a pattern is the redacted copy.
        let copied = try open("src/aws.ts", copy: true)
        let path = try #require(copied.materializedPath)
        #expect(try String(contentsOf: cf.workspace.appending(path: path), encoding: .utf8) == "region = eu\naws = [redacted aws-key]\n")
    }
}
