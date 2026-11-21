import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A reader that hands back the members it was built with (what a real unzip would have inflated), for archives whose stored
/// bytes hold none of them: the gate must find a secret in a member, not in the archive's raw bytes.
struct StubArchiveReader: ArchiveReader {
    var members: [(name: String, data: Data)]
    var error: ArchiveReadError? = nil

    func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
        if let error { throw error }
        return members.filter { wanted($0.name) }
    }
}

/// Plan C Task C2b: the one secret gate (`SecretGate`) over ML's `ContentScan` at every read point — encoded forms, archive
/// members, a per-version scan cache, redacted copies instead of raw blobs, the owner's "view original", and an engine alert
/// that never carries the value.
@Suite(.scratch) struct SecretGateTests {
    static let value = "sk_test_51abcdefgh"
    /// A value that percent-encoding changes (the first one has only unreserved characters).
    static let pass = "pa ss/w@rd:42!"
    static let known: [(name: String, value: String)] = [("STRIPE_KEY", value), ("DB_PASS", pass)]
    static let aws = "AKIA" + "ABCDEFGHIJKLMNOP"   // split so this file does not itself trip a scanner

    static func refusal(_ canonical: String, line: Int?) -> WorkError {
        WorkError.invalid("\(canonical) contains a stored secret\(line.map { " (line \($0))" } ?? ""); remove it before sharing")
    }

    /// Every 6-character piece of a value: none may appear in anything the gate says or writes.
    static func pieces(_ v: String) -> [String] {
        let chars = Array(v)
        return (0...(chars.count - 6)).map { String(chars[$0..<$0 + 6]) }
    }

    static func zip(_ build: (inout ZipBuilder) -> Void) throws -> Data {
        var z = ZipBuilder()
        build(&z)
        let url = try tempDir().appending(path: "a.zip")
        try z.write(to: url)
        return try Data(contentsOf: url)
    }

    static func base64(_ s: String, offset: Int) -> String {
        Data((String(repeating: "x", count: offset) + s + "tail!").utf8).base64EncodedString()
    }

    func check(_ cf: CollabFixture, _ data: Data, ext: String = "txt", canonical: String = "src/x.txt",
               archives: any ArchiveReader = UnavailableArchiveReader(), known: [(name: String, value: String)] = Self.known,
               chunk: Int = ContentScan.chunkBytes) throws -> ScanVerdict {
        try SecretGate.check(data, ext: ext, canonical: canonical, archives: archives, knownValues: known, store: cf.store,
                             companyId: cf.c.id, chunk: chunk)
    }

    @Test(arguments: ["raw", "percent", "percent-lower", "hex", "HEX", "base64-0", "base64-1", "base64-2"])
    func knownValueFoundInEveryEncoding(_ form: String) throws {
        let cf = try CollabFixture()
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded: String
        switch form {
        case "raw": encoded = Self.value
        case "percent": encoded = try #require(Self.pass.addingPercentEncoding(withAllowedCharacters: unreserved))
        case "percent-lower": encoded = try #require(Self.pass.addingPercentEncoding(withAllowedCharacters: unreserved)).lowercased()
        case "hex": encoded = Data(Self.value.utf8).map { String(format: "%02x", $0) }.joined()
        case "HEX": encoded = Data(Self.value.utf8).map { String(format: "%02X", $0) }.joined()
        default: encoded = Self.base64(Self.value, offset: Int(form.dropFirst("base64-".count)) ?? 0)
        }
        #expect(!encoded.contains(Self.value) || form == "raw")
        let text = "first line\nconfig: \(encoded) end\n"
        // The same bytes are clean without the stored values.
        #expect(try check(cf, Data(text.utf8), known: []) == .clean)
        do {
            _ = try check(cf, Data(text.utf8))
            Issue.record("the \(form) form was not refused")
        } catch let e as WorkError {
            #expect(e == Self.refusal("src/x.txt", line: 2))
            for piece in Self.pieces(Self.value) + Self.pieces(Self.pass) { #expect(!e.message.contains(piece)) }
        }
        // The expansion itself: every form is filed under the original name.
        let forms = EncodedForms.expand([("STRIPE_KEY", Self.value)])
        #expect(forms.allSatisfy { $0.name == "STRIPE_KEY" })
        #expect(forms.first?.value == Self.value)
        #expect(forms.count >= 6)
    }

    @Test func secretInZipMemberRefused() throws {
        let cf = try CollabFixture()
        // The stored bytes hold a placeholder; the member as inflated holds the value. Each case gets bytes of its own (the
        // gate caches a verdict by the bytes' hash, and a real reader inflates the same bytes the same way).
        func makeDocx(_ tag: String) throws -> Data {
            try Self.zip {
                $0.add("[Content_Types].xml", "<Types/>")
                $0.add("word/document.xml", "<w:document>compressed \(tag)</w:document>")
            }
        }
        let docx = try makeDocx("whole")
        #expect(!String(decoding: docx, as: UTF8.self).contains(Self.value))
        let inflated: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", Data("<w:document><w:p><w:r><w:t>key \(Self.value)</w:t></w:r></w:p></w:document>".utf8)),
        ]
        do {
            _ = try check(cf, docx, ext: "docx", canonical: "report.docx", archives: StubArchiveReader(members: inflated))
            Issue.record("the member's value was not refused")
        } catch let e as WorkError {
            #expect(e == Self.refusal("report.docx", line: nil))
            for piece in Self.pieces(Self.value) { #expect(!e.message.contains(piece)) }
        }
        // A value split across Office text runs is found too.
        let split: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", Data("<w:p><w:r><w:t>sk_test_</w:t></w:r><w:r><w:t>51abcdefgh</w:t></w:r></w:p>".utf8)),
        ]
        #expect(throws: Self.refusal("report.docx", line: nil)) {
            try check(cf, try makeDocx("split"), ext: "docx", canonical: "report.docx", archives: StubArchiveReader(members: split))
        }
        // A zip by its bytes is an archive whatever its name says.
        #expect(throws: Self.refusal("notes.txt", line: nil)) {
            try check(cf, try makeDocx("renamed"), ext: "txt", canonical: "notes.txt", archives: StubArchiveReader(members: inflated))
        }
        // Clean members pass.
        let clean: [(name: String, data: Data)] = [("[Content_Types].xml", Data("<Types/>".utf8)), ("word/document.xml", Data("<w:t>hi</w:t>".utf8))]
        #expect(try check(cf, try makeDocx("clean"), ext: "docx", canonical: "report.docx", archives: StubArchiveReader(members: clean)) == .clean)
        // Fail closed: no reader, an archive that expands too much, or a member the reader did not hand back.
        #expect(throws: WorkError.invalid("archives can't be scanned on this machine")) {
            try check(cf, try makeDocx("no reader"), ext: "docx", canonical: "report.docx")
        }
        #expect(throws: WorkError.invalid("this archive expands too much to preview safely")) {
            try check(cf, try makeDocx("bomb"), ext: "docx", canonical: "report.docx",
                      archives: StubArchiveReader(members: [], error: .refused("this archive expands too much to preview safely")))
        }
        #expect(throws: WorkError.invalid("this archive can't be scanned for secrets")) {
            try check(cf, try makeDocx("skipped"), ext: "docx", canonical: "report.docx", archives: StubArchiveReader(members: [clean[0]]))
        }
        // A name that says archive but bytes that aren't one: refused, not passed.
        #expect(throws: WorkError.invalid("this archive can't be read")) {
            try check(cf, Data("plain text\n".utf8), ext: "docx", canonical: "fake.docx", archives: StubArchiveReader(members: clean))
        }
        // A zip inside the zip is opened too.
        let inner = try Self.zip { $0.add("secret.txt", "placeholder") }
        let outer = try Self.zip { $0.add("inner.zip", "placeholder") }
        struct Nested: ArchiveReader {
            let inner: Data
            func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
                if data == inner { return [("secret.txt", Data("v=\(SecretGateTests.value)\n".utf8))] }
                return [("inner.zip", inner)]
            }
        }
        #expect(throws: Self.refusal("bundle.zip", line: nil)) {
            try check(cf, outer, ext: "zip", canonical: "bundle.zip", archives: Nested(inner: inner))
        }

        // The pin of such a worktree file is refused before git sees a byte.
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try makeDocx("pin").write(to: wt.appending(path: "report.docx"))
        #expect(throws: Self.refusal("ENG-1:report.docx@worktree", line: nil)) {
            try cf.store.pinRef(try cf.fx.ref("ENG-1:report.docx@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                messageRefId: "mr-z", knownValues: Self.known, paths: cf.paths, archives: StubArchiveReader(members: inflated))
        }
        #expect((try? cf.fx.git.git(["rev-parse", "--verify", "--quiet", "refs/brahma/shares/mr-z"])) == nil)

        // The real sandboxed unzip on a deflated Office file (its `[Content_Types].xml` member included).
        guard Toolchain.seatbeltAvailable, FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else { return }
        let home = try Scratch.homeDir().resolvedForSandbox
        let sbPaths = BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
        let sbVault = Vault(paths: sbPaths, companyId: cf.c.id, content: ContentVault(paths: sbPaths))
        let sandboxed = SandboxedUnzipReader(runner: SeatbeltRunner(baseline: {
            SandboxBaseline.current(paths: sbPaths, otherWorkspaces: [], backupTargets: [])
        }, proxies: EgressProxyPool()), scratch: { try sbVault.makeTempDir() })
        func deflated(_ files: [String: String]) throws -> Data {
            let dir = try tempDir()
            for (name, text) in files { try GitFixture(existing: dir).write(name, text) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            p.arguments = ["-q", "-X", "-9", "out.zip"] + files.keys.sorted()
            try p.run(); p.waitUntilExit()
            return try Data(contentsOf: dir.appending(path: "out.zip"))
        }
        let padding = String(repeating: "lorem ipsum ", count: 40)
        let real = try deflated(["[Content_Types].xml": "<Types>\(Self.value)\(padding)</Types>", "word/document.xml": "<w:t>hi \(padding)</w:t>"])
        #expect(!String(decoding: real, as: UTF8.self).contains(Self.value))
        #expect(throws: Self.refusal("real.docx", line: nil)) {
            try check(cf, real, ext: "docx", canonical: "real.docx", archives: sandboxed)
        }
        let fine = try deflated(["[Content_Types].xml": "<Types>\(padding)</Types>", "word/document.xml": "<w:t>hi \(padding)</w:t>"])
        #expect(try check(cf, fine, ext: "docx", canonical: "fine.docx", archives: sandboxed) == .clean)
    }

    @Test func laterSecretValueCaughtOnOpen() throws {
        let cf = try CollabFixture()
        let vault = MemoryVault()
        try Data("token \(Self.value)\n".utf8).write(to: cf.workspace.appending(path: ".brahma/labs/eng-1/old.txt"))
        // Shared while no secret is stored: clean.
        let shared = try cf.store.snapshotPrivateFile(companyId: cf.c.id, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/eng-1/old.txt",
                                                      readers: [cf.fx.qa2.id], knownValues: try cf.store.knownSecretValues(companyId: cf.c.id, vault: vault),
                                                      paths: cf.paths, now: cf.now)
        func open() throws -> OpenRefResult {
            try cf.store.openRef(companyId: cf.c.id, reader: .agent(cf.fx.qa2.id), ref: shared.canonical, lines: nil, copy: false,
                                 turnId: nil, context: cf.fx.ctx, knownValues: try cf.store.knownSecretValues(companyId: cf.c.id, vault: vault),
                                 paths: cf.paths, now: cf.now)
        }
        #expect(try open().text.contains("token \(Self.value)"))
        // The owner stores that value as a secret later: the next read of the old content refuses (a new secrets version).
        try cf.store.setSecret(companyId: cf.c.id, name: "STRIPE_KEY", value: Self.value, isTest: false, vault: vault)
        #expect(throws: Self.refusal(shared.canonical, line: 1)) { try open() }
        // A copy is refused the same way, and nothing lands in the lab.
        #expect(throws: Self.refusal(shared.canonical, line: 1)) {
            try cf.store.openRef(companyId: cf.c.id, reader: .agent(cf.fx.qa2.id), ref: shared.canonical, lines: nil, copy: true,
                                 turnId: nil, context: cf.fx.ctx, knownValues: try cf.store.knownSecretValues(companyId: cf.c.id, vault: vault),
                                 paths: cf.paths, now: cf.now)
        }
        let inbox = cf.workspace.appending(path: ".brahma/labs/qa-2/in").path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: inbox)) ?? []).isEmpty)
        // The app's render point says the same.
        let bytes = Data("token \(Self.value)\n".utf8)
        let verdict = try cf.store.scanForRender(companyId: cf.c.id, sha256: SHA256.hex(bytes), data: bytes, ext: "txt",
                                                 knownValues: try cf.store.knownSecretValues(companyId: cf.c.id, vault: vault))
        guard case .knownValue(let finding) = verdict else { Issue.record("render was not refused: \(verdict)"); return }
        #expect(finding.label == "stored secret STRIPE_KEY" && finding.line == 1)
        // A wrong hash is refused (the cache is keyed by it).
        #expect(throws: WorkError.self) {
            try cf.store.scanForRender(companyId: cf.c.id, sha256: String(repeating: "0", count: 64), data: bytes, ext: "txt", knownValues: [])
        }
    }

    @Test func redactedShareWritesNoRawBlob() throws {
        let cf = try CollabFixture()
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/conf.ts", "const region = 'eu'\nconst key = '\(Self.aws)'\n", in: wt)
        let pinned = try cf.store.pinRef(try cf.fx.ref("ENG-1:src/conf.ts@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                         messageRefId: "mr-r", knownValues: Self.known, paths: cf.paths)
        // The share is a redacted copy F-<n> in the vault, never a git blob.
        #expect(pinned.kind == .resource)
        #expect(pinned.params["source"] == "ENG-1:src/conf.ts@worktree")
        let n = try #require(Int(pinned.id))
        let r = try #require(try cf.store.resource(companyId: cf.c.id, number: n))
        #expect(r.secretScan == .redacted && r.addedVia == "share" && r.scopeKind == "company")
        let stored = String(decoding: try cf.vault.read(try #require(r.vaultPath), sha256: try #require(r.sha256), maxBytes: Int(r.bytes)), as: UTF8.self)
        #expect(stored == "const region = 'eu'\nconst key = '[redacted aws-key]'\n")
        #expect((try? cf.fx.git.git(["rev-parse", "--verify", "--quiet", "refs/brahma/shares/mr-r"])) == nil)
        let objects = try cf.fx.git.git(["cat-file", "--batch-all-objects", "--batch"])
        #expect(!objects.contains(Self.aws))
        // Its chip is REDACTED, and it opens redacted.
        let resolved = try cf.store.resolveRef(pinned, for: .agent(cf.fx.qa2.id), companyId: cf.c.id)
        #expect(resolved.visibility == .full && resolved.state == .redacted)
        let out = try cf.open(.qa2, pinned: pinned)
        #expect(out.text.contains("    | const key = '[redacted aws-key]'") && !out.text.contains(Self.aws))
        // A binary with a pattern can't be redacted: refused, nothing written.
        var bin = Data([0, 1, 2]); bin.append(Data(Self.aws.utf8))
        try bin.write(to: wt.appending(path: "blob.bin"))
        #expect(throws: WorkError.self) {
            try cf.store.pinRef(try cf.fx.ref("ENG-1:blob.bin@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                messageRefId: "mr-b", knownValues: Self.known, paths: cf.paths)
        }
        #expect(try cf.store.resource(companyId: cf.c.id, number: n + 1) == nil)
        #expect((try? cf.fx.git.git(["rev-parse", "--verify", "--quiet", "refs/brahma/shares/mr-b"])) == nil)
    }

    @Test func viewOriginalLogsRead() throws {
        let cf = try CollabFixture()
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        let original = "const key = '\(Self.aws)'\n"
        try cf.fx.git.write("src/conf.ts", original, in: wt)
        let pinned = try cf.store.pinRef(try cf.fx.ref("ENG-1:src/conf.ts@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                         messageRefId: "mr-v", knownValues: Self.known, paths: cf.paths)
        // The owner sees the original (for a worktree file, the worktree file itself), and the read is logged.
        let bytes = try cf.store.viewOriginal(companyId: cf.c.id, ref: pinned, knownValues: Self.known, paths: cf.paths, now: cf.now)
        #expect(bytes == Data(original.utf8))
        let read = try #require(try cf.reads(pinned.canonical).first)
        #expect(read.via == "viewOriginal" && read.readerKind == "owner" && read.readerId == nil && read.bytes == original.utf8.count)
        // A committed file with a pattern: its unredacted bytes.
        try cf.commit(["src/aws.ts": Data("k = \(Self.aws)\n".utf8)])
        #expect(try cf.store.viewOriginal(companyId: cf.c.id, ref: try cf.fx.ref("src/aws.ts"), knownValues: [], paths: cf.paths, now: cf.now)
            == Data("k = \(Self.aws)\n".utf8))
        #expect(try cf.reads("src/aws.ts").first?.via == "viewOriginal")
        // A stored secret's value is never shown, not even to the owner.
        try cf.commit(["src/known.ts": Data("k = \(Self.value)\n".utf8)])
        #expect(throws: Self.refusal("src/known.ts", line: 1)) {
            try cf.store.viewOriginal(companyId: cf.c.id, ref: try cf.fx.ref("src/known.ts"), knownValues: Self.known, paths: cf.paths, now: cf.now)
        }
    }

    @Test func scanCachedPerVersion() throws {
        let cf = try CollabFixture()
        let vault = MemoryVault()
        let data = Data("token \(Self.value)\n".utf8)
        let sha = SHA256.hex(data)
        let v1 = try #require(SecretGate.cacheVersion(store: cf.store, companyId: cf.c.id, ext: "txt", knownValues: []))
        #expect(try check(cf, data, known: []) == .clean)
        #expect(ScanCache.shared.result(sha256: sha, version: v1) == .clean)
        // A cached verdict is what the gate answers for the same bytes and version.
        ScanCache.shared.store(sha256: sha, version: v1, verdict: .pattern(label: "cached", line: 9))
        #expect(try check(cf, data, known: []) == .pattern(label: "cached", line: 9))
        // A new secret is a new version: nothing cached for it, and the next scan refuses.
        try cf.store.setSecret(companyId: cf.c.id, name: "STRIPE_KEY", value: Self.value, isTest: false, vault: vault)
        let known = try cf.store.knownSecretValues(companyId: cf.c.id, vault: vault)
        let v2 = try #require(SecretGate.cacheVersion(store: cf.store, companyId: cf.c.id, ext: "txt", knownValues: known))
        #expect(v2 != v1)
        #expect(ScanCache.shared.result(sha256: sha, version: v2) == nil)
        #expect(throws: Self.refusal("src/x.txt", line: 1)) { try check(cf, data, known: known) }
        guard case .knownValue(let f)? = ScanCache.shared.result(sha256: sha, version: v2) else {
            Issue.record("the refusal was not cached"); return
        }
        #expect(f.label == "stored secret STRIPE_KEY")
        // Another company never shares a cached verdict.
        let other = try #require(SecretGate.cacheVersion(store: cf.store, companyId: cf.fx.d.id, ext: "txt", knownValues: []))
        #expect(other != v1)
        #expect(ScanCache.shared.result(sha256: sha, version: other) == nil)
    }

    @Test func chunkBoundaryHitFound() throws {
        let cf = try CollabFixture()
        let chunk = 1024
        let form = Self.base64(Self.value, offset: 1)
        // The form starts 7 bytes before the 6th chunk edge (past the 4096-byte overlap), so it straddles it.
        let start = 6 * chunk - 7
        var text = String(repeating: "a", count: start - 1) + "\n"
        text += form + "\n" + String(repeating: "b", count: 3 * chunk) + "\n"
        let data = Data(text.utf8)
        #expect(try check(cf, data, known: [], chunk: chunk) == .clean)
        #expect(throws: Self.refusal("src/x.txt", line: 2)) { try check(cf, data, chunk: chunk) }
        // A binary straddle too (line 0: no line is named).
        var bin = Data(repeating: 0, count: start)
        bin.append(Data(form.utf8)); bin.append(Data(repeating: 0, count: 3 * chunk))
        #expect(throws: Self.refusal("src/x.bin", line: nil)) { try check(cf, bin, ext: "bin", canonical: "src/x.bin", chunk: chunk) }
    }

    @Test func artifactReadPointsGated() throws {
        let cf = try CollabFixture()
        // 4a's AR-<n> (published before the value was stored): open, copy and the app's render all go through the gate.
        let a = try cf.publishCommitted("site/index.html", "<p>key \(Self.value)</p>\n")
        func open(copy: Bool) throws -> OpenRefResult {
            try cf.store.openRef(companyId: cf.c.id, reader: .agent(cf.fx.qa2.id), ref: a.ref, lines: nil, copy: copy, turnId: nil,
                                 context: cf.fx.ctx, knownValues: Self.known, paths: cf.paths, now: cf.now)
        }
        #expect(try cf.store.openRef(companyId: cf.c.id, reader: .agent(cf.fx.qa2.id), ref: a.ref, lines: nil, copy: false, turnId: nil,
                                     context: cf.fx.ctx, knownValues: [], paths: cf.paths, now: cf.now).text.contains(Self.value))
        #expect(throws: Self.refusal(a.ref, line: 1)) { try open(copy: false) }
        #expect(throws: Self.refusal(a.ref, line: 1)) { try open(copy: true) }
        let inbox = cf.workspace.appending(path: ".brahma/labs/qa-2/in").path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: inbox)) ?? []).isEmpty)
        // The owner's view of the original refuses the value too.
        #expect(throws: Self.refusal(a.ref, line: 1)) {
            try cf.store.viewOriginal(companyId: cf.c.id, ref: try cf.fx.ref(a.ref), knownValues: Self.known, paths: cf.paths, now: cf.now)
        }
    }

    @Test func engineAlertNeverEchoesValue() throws {
        let cf = try CollabFixture()
        try cf.commit(["src/conf.ts": Data("token = \(Self.value)\n".utf8)])
        func open() throws -> OpenRefResult {
            try cf.store.openRef(companyId: cf.c.id, reader: .agent(cf.fx.eng1.id), ref: "src/conf.ts", lines: nil, copy: false,
                                 turnId: nil, context: cf.fx.ctx, knownValues: Self.known, paths: cf.paths, now: cf.now)
        }
        #expect(throws: Self.refusal("src/conf.ts", line: 1)) { try open() }
        #expect(throws: Self.refusal("src/conf.ts", line: 1)) { try open() }
        let cId = cf.c.id
        let (alerts, dms, activity, notices) = try cf.store.writer.read { db -> ([Ask], [String], [String], [String]) in
            (try Ask.fetchAll(db, sql: "SELECT * FROM ask WHERE companyId = ? AND kind = 'engineAlert'", arguments: [cId]),
             try String.fetchAll(db, sql: "SELECT text FROM message WHERE companyId = ? AND senderId = 'system'", arguments: [cId]),
             try String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE companyId = ?", arguments: [cId]),
             try String.fetchAll(db, sql: "SELECT title || ' ' || body FROM ownerNotice"))
        }
        // One alert (a repeat for the same ref raises nothing new), naming the ref and the secret's name only.
        #expect(alerts.count == 1)
        let alert = try #require(alerts.first)
        #expect(alert.title.contains("src/conf.ts") && alert.title.contains("STRIPE_KEY"))
        #expect(dms.filter { $0.contains("stored secret") }.count == 1)
        for text in [alert.title, alert.summary] + dms + activity + notices {
            for piece in Self.pieces(Self.value) { #expect(!text.contains(piece)) }
        }
    }
}
