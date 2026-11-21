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

    /// A zip whose stored bytes hold only placeholders while its directory declares `members` as deflate entries of their real
    /// sizes: what a real reader would inflate them to is what `StubArchiveReader(members:)` hands back. `tag` makes the
    /// bytes of each case its own (the gate caches a verdict by the bytes' hash).
    static func packed(_ members: [(name: String, data: Data)], tag: String) throws -> Data {
        try zip { z in
            for (i, m) in members.enumerated() { z.add(m.name, "packed \(tag) \(i)", declaredSize: m.data.count, method: 8) }
        }
    }

    static func base64(_ s: String, offset: Int) -> String {
        Data((String(repeating: "x", count: offset) + s + "tail!").utf8).base64EncodedString()
    }

    /// The gate's verdict; a structure refusal without the owner's vouch command when it names exactly the command for
    /// `canonical` in the fixture's company (round 5, ruling 38: `FileVouchTests` checks the command itself).
    func check(_ cf: CollabFixture, _ data: Data, ext: String = "txt", canonical: String = "src/x.txt",
               archives: any ArchiveReader = UnavailableArchiveReader(), known: [(name: String, value: String)] = Self.known,
               chunk: Int = ContentScan.chunkBytes) throws -> ScanVerdict {
        do {
            return try SecretGate.check(data, ext: ext, canonical: canonical, archives: archives, knownValues: known, store: cf.store,
                                        companyId: cf.c.id, chunk: chunk)
        } catch let e as WorkError { throw FileVouchTests.withoutCommand(e, cf.c, canonical) }
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
        let inflated: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", Data("<w:document><w:p><w:r><w:t>key \(Self.value)</w:t></w:r></w:p></w:document>".utf8)),
        ]
        let docx = try Self.packed(inflated, tag: "whole")
        #expect(!String(decoding: docx, as: UTF8.self).contains(Self.value))
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
            try check(cf, try Self.packed(split, tag: "split"), ext: "docx", canonical: "report.docx", archives: StubArchiveReader(members: split))
        }
        // A zip by its bytes is an archive whatever its name says.
        #expect(throws: Self.refusal("notes.txt", line: nil)) {
            try check(cf, try Self.packed(inflated, tag: "renamed"), ext: "txt", canonical: "notes.txt", archives: StubArchiveReader(members: inflated))
        }
        // Clean members pass.
        let clean: [(name: String, data: Data)] = [("[Content_Types].xml", Data("<Types/>".utf8)), ("word/document.xml", Data("<w:t>hi</w:t>".utf8))]
        #expect(try check(cf, try Self.packed(clean, tag: "clean"), ext: "docx", canonical: "report.docx", archives: StubArchiveReader(members: clean)) == .clean)
        // Fail closed: no reader, an archive that expands too much, or a member the reader did not hand back.
        #expect(throws: WorkError.invalid("archives can't be scanned on this machine")) {
            try check(cf, try Self.packed(clean, tag: "no reader"), ext: "docx", canonical: "report.docx")
        }
        #expect(throws: WorkError.invalid("this archive expands too much to preview safely")) {
            try check(cf, try Self.packed(clean, tag: "bomb"), ext: "docx", canonical: "report.docx",
                      archives: StubArchiveReader(members: [], error: .refused("this archive expands too much to preview safely")))
        }
        #expect(throws: WorkError.invalid("this archive can't be scanned for secrets")) {
            try check(cf, try Self.packed(clean, tag: "skipped"), ext: "docx", canonical: "report.docx", archives: StubArchiveReader(members: [clean[0]]))
        }
        // A name that says archive but bytes that aren't one: refused, not passed.
        #expect(throws: WorkError.invalid("this archive can't be read")) {
            try check(cf, Data("plain text\n".utf8), ext: "docx", canonical: "fake.docx", archives: StubArchiveReader(members: clean))
        }
        // A zip inside the zip is opened too.
        let innerMember = Data("v=\(SecretGateTests.value)\n".utf8)
        let inner = try Self.packed([("secret.txt", innerMember)], tag: "inner")
        let outer = try Self.packed([("inner.zip", inner)], tag: "outer")
        struct Nested: ArchiveReader {
            let inner: Data, innerMember: Data
            func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
                if data == inner { return [("secret.txt", innerMember)] }
                return [("inner.zip", inner)]
            }
        }
        #expect(throws: Self.refusal("bundle.zip", line: nil)) {
            try check(cf, outer, ext: "zip", canonical: "bundle.zip", archives: Nested(inner: inner, innerMember: innerMember))
        }

        // The pin of such a worktree file is refused before git sees a byte.
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try Self.packed(inflated, tag: "pin").write(to: wt.appending(path: "report.docx"))
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

    // MARK: Fix round 1

    static let methodRefusal = WorkError.invalid("this archive uses compression or encryption that can't be scanned for secrets")
    static let incomplete = WorkError.invalid("this archive can't be scanned for secrets")

    /// R1-2: a member unzip can't decode, an encrypted one, or one that comes back short is never read as empty and clean.
    @Test func undecodableMembersRefused() throws {
        let cf = try CollabFixture()
        let member = "<w:t>key \(Self.value)</w:t>"
        func members(_ name: String) -> [(name: String, data: Data)] { [(name, Data(member.utf8))] }
        // LZMA (method 14), and a stored member with the encryption flag: refused whatever the reader hands back.
        let lzma = try Self.zip { $0.add("word/document.xml", "lzma bytes", method: 14) }
        #expect(throws: Self.methodRefusal) {
            try check(cf, lzma, ext: "docx", canonical: "a.docx", archives: StubArchiveReader(members: members("word/document.xml")))
        }
        let encrypted = try Self.zip { $0.add("word/document.xml", "cipher text", flags: 1) }
        #expect(throws: Self.methodRefusal) {
            try check(cf, encrypted, ext: "docx", canonical: "b.docx", archives: StubArchiveReader(members: []))
        }
        // A member shorter than the central directory declares (what a failed inflate leaves) is refused.
        let short = try Self.zip { $0.add("word/document.xml", String(repeating: "z", count: 64), declaredSize: 4096, method: 8) }
        #expect(throws: Self.incomplete) {
            try check(cf, short, ext: "docx", canonical: "c.docx",
                      archives: StubArchiveReader(members: [("word/document.xml", Data())]))
        }
        // The real sandboxed unzip: a deflate member it can't decode is a failure, never an empty member.
        guard Toolchain.seatbeltAvailable else { return }
        let home = try Scratch.homeDir().resolvedForSandbox
        let sbPaths = BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
        let sbVault = Vault(paths: sbPaths, companyId: cf.c.id, content: ContentVault(paths: sbPaths))
        let sandboxed = SandboxedUnzipReader(runner: SeatbeltRunner(baseline: {
            SandboxBaseline.current(paths: sbPaths, otherWorkspaces: [], backupTargets: [])
        }, proxies: EgressProxyPool()), scratch: { try sbVault.makeTempDir() })
        let corrupt = try Self.zip { $0.add("doc.txt", "this is not a deflate stream at all \(Self.value)", method: 8) }
        #expect(throws: ArchiveReadError.self) {
            try sandboxed.members(of: corrupt, wanted: { _ in true }, limits: .standard)
        }
        #expect(throws: WorkError.self) { try check(cf, corrupt, ext: "zip", canonical: "d.zip", archives: sandboxed) }
    }

    /// R1-3 (Ruling 29): a zip found anywhere in the bytes is an archive; gzip, bzip2, xz, zstd, 7z and rar can't be scanned.
    @Test func polyglotsAndOtherFormatsRefused() throws {
        let cf = try CollabFixture()
        let secret: [(name: String, data: Data)] = [("secret.txt", Data("v=\(Self.value)\n".utf8))]
        let inner = try Self.packed(secret, tag: "poly")
        let reader = StubArchiveReader(members: secret)
        // Text, then a zip: named .txt, never only raw-scanned.
        let prefixed = Data(String(repeating: "notes\n", count: 200).utf8) + inner
        #expect(throws: WorkError.self) { try check(cf, prefixed, ext: "txt", canonical: "notes.txt", archives: reader) }
        // A PNG with a zip appended.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 64) + inner
        #expect(throws: WorkError.self) { try check(cf, png, ext: "png", canonical: "logo.png", archives: reader) }
        // A .txt that is really a zip is scanned as one.
        #expect(throws: Self.refusal("real.txt", line: nil)) {
            try check(cf, inner + Data(), ext: "txt", canonical: "real.txt", archives: reader)
        }
        // Compression formats the engine can't open: refused, whatever they are called.
        let formats: [(String, [UInt8])] = [
            ("gzip", [0x1F, 0x8B, 0x08, 0x00]), ("bzip2", Array("BZh9".utf8)), ("xz", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
            ("zstd", [0x28, 0xB5, 0x2F, 0xFD]), ("7z", [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]), ("rar", Array("Rar!".utf8) + [0x1A, 0x07, 0x00]),
        ]
        for (name, magic) in formats {
            let data = Data(magic) + Data(repeating: 0x41, count: 100)
            #expect(throws: WorkError.invalid("x.bin is compressed as \(name), which can't be scanned for secrets; share the files inside instead"),
                    "\(name)") {
                try check(cf, data, ext: "bin", canonical: "x.bin", archives: reader)
            }
        }
        // A real .tar.gz holding the value.
        let dir = try tempDir()
        try Data("v=\(Self.value)\n".utf8).write(to: dir.appending(path: "secret.txt"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.currentDirectoryURL = dir
        p.arguments = ["-czf", "out.tar.gz", "secret.txt"]
        try p.run(); p.waitUntilExit()
        let tgz = try Data(contentsOf: dir.appending(path: "out.tar.gz"))
        #expect(throws: WorkError.self) { try check(cf, tgz, ext: "gz", canonical: "out.tar.gz", archives: reader) }
        // A gzip member inside a zip is refused too.
        let zipOfGz = try Self.packed([("data.gz", tgz)], tag: "gz")
        #expect(throws: WorkError.self) {
            try check(cf, zipOfGz, ext: "zip", canonical: "bundle.zip", archives: StubArchiveReader(members: [("data.gz", tgz)]))
        }
        // Text that merely mentions PK is plain text.
        #expect(try check(cf, Data("PK is a primary key\n".utf8), ext: "md", canonical: "README.md", archives: reader) == .clean)
    }

    /// R1-4 (Ruling 30): an entry flagged as a directory that has data, or no trailing `/`, is a file the reader must return.
    @Test func directoryFlaggedEntriesScanned() throws {
        let cf = try CollabFixture()
        // A reader that, like the sandboxed unzip before the fix, skips what the inventory calls a directory.
        let skipsFlagged = StubArchiveReader(members: [])
        let unixDir = try Self.zip { $0.add("secret.txt", "placeholder", mode: 0o040755) }
        #expect(throws: Self.incomplete) { try check(cf, unixDir, ext: "zip", canonical: "u.zip", archives: skipsFlagged) }
        let dosDir = try Self.zip { $0.add("secret.txt", "data", external: 0x10) }
        #expect(throws: Self.incomplete) { try check(cf, dosDir, ext: "zip", canonical: "w.zip", archives: skipsFlagged) }
        // A slash-named "directory" with data is a file too.
        let slashed = try Self.zip { $0.add("dir/", "data", mode: 0o040755) }
        #expect(throws: Self.incomplete) { try check(cf, slashed, ext: "zip", canonical: "s.zip", archives: skipsFlagged) }
        // A real directory entry (name ends in /, no data) needs no member.
        let real = try Self.zip { $0.add("dir/", "", mode: 0o040755); $0.add("dir/a.txt", "placeholder") }
        #expect(try check(cf, real, ext: "zip", canonical: "r.zip",
                          archives: StubArchiveReader(members: [("dir/a.txt", Data("placeholder".utf8))])) == .clean)
    }

    /// R1-5: a ref named with a stored value (or an encoded form) never echoes it in the refusal or the alert.
    @Test func refNamedWithValueNeverEchoed() throws {
        let cf = try CollabFixture()
        let hex = Data(Self.value.utf8).map { String(format: "%02x", $0) }.joined()
        for name in ["src/\(Self.value).ts", "src/\(hex).ts"] {
            do {
                _ = try check(cf, Data("k = \(Self.value)\n".utf8), ext: "ts", canonical: name)
                Issue.record("not refused")
            } catch let e as WorkError {
                #expect(e.message.hasPrefix("src/[redacted stored secret STRIPE_KEY].ts contains a stored secret"))
                for piece in Self.pieces(Self.value) + Self.pieces(hex) { #expect(!e.message.contains(piece)) }
            }
        }
        let cId = cf.c.id
        let texts = try cf.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT title || ' ' || summary FROM ask WHERE companyId = ? AND kind = 'engineAlert'", arguments: [cId])
            + String.fetchAll(db, sql: "SELECT text FROM message WHERE companyId = ?", arguments: [cId])
            + String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE companyId = ?", arguments: [cId])
        }
        #expect(texts.contains { $0.contains("[redacted stored secret STRIPE_KEY]") })
        for text in texts { for piece in Self.pieces(Self.value) + Self.pieces(hex) { #expect(!text.contains(piece)) } }
    }

    /// R1-6: nested archives share one budget (bytes, entries, depth) across every level.
    @Test func nestedArchivesShareOneBudget() throws {
        let inner = try Self.packed([("a.txt", Data(repeating: 0x61, count: 600))], tag: "inner")
        let outer = try Self.packed([("1.zip", inner), ("2.zip", inner), ("3.zip", inner)], tag: "outer")
        struct Nested: ArchiveReader {
            let inner: Data
            func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
                if data == inner { return [("a.txt", Data(repeating: 0x61, count: 600))] }
                return [("1.zip", inner), ("2.zip", inner), ("3.zip", inner)]
            }
        }
        let reader = Nested(inner: inner)
        // Each level alone is under 1000 bytes; together they are not.
        #expect(try ArchiveMemberScan.scan(outer, archives: reader, knownValues: [],
                                           budget: ArchiveScanBudget(bytes: 10_000, entries: 200, depth: 3)).isEmpty)
        #expect(throws: ArchiveMemberScan.overBudget) {
            try ArchiveMemberScan.scan(outer, archives: reader, knownValues: [], budget: ArchiveScanBudget(bytes: 1000, entries: 200, depth: 3))
        }
        #expect(throws: ArchiveMemberScan.overBudget) {
            try ArchiveMemberScan.scan(outer, archives: reader, knownValues: [], budget: ArchiveScanBudget(bytes: 10_000, entries: 5, depth: 3))
        }
        // Deeper than the depth budget: refused.
        #expect(throws: ArchiveMemberScan.overBudget) {
            try ArchiveMemberScan.scan(outer, archives: reader, knownValues: [], budget: ArchiveScanBudget(bytes: 10_000, entries: 200, depth: 1))
        }
    }

    // MARK: R1-9 (Ruling 31): compressed PNG text chunks are decoded and scanned (PDFs: `EmbeddedContentTests`)

    /// zlib (RFC 1950) bytes of `data`: what a PDF's FlateDecode and a PNG's zTXt hold.
    static func zlib(_ data: Data) throws -> Data {
        let raw = try (data as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler: UInt32 = (b << 16) | a
        var out = Data([0x78, 0x9C])
        out.append(raw)
        let trailer: [UInt8] = [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
        out.append(contentsOf: trailer)
        return out
    }

    /// A PNG (signature, IHDR, `chunks`, IEND) with real CRCs.
    static func png(_ chunks: [(type: String, data: Data)]) -> Data {
        func chunk(_ type: String, _ data: Data) -> Data {
            let typed = Data(type.utf8) + data
            let crc = ZipBuilder.crc32(typed)
            func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
            var out = Data(be32(UInt32(data.count)))
            out.append(typed)
            out.append(contentsOf: be32(crc))
            return out
        }
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        out += chunk("IHDR", Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0]))
        for c in chunks { out += chunk(c.type, c.data) }
        out += chunk("IEND", Data())
        return out
    }

    @Test func pngTextChunksDecodedAndScanned() throws {
        let cf = try CollabFixture()
        let ztxt = Self.png([("zTXt", Data("Comment".utf8) + Data([0, 0]) + (try Self.zlib(Data("key \(Self.value)".utf8))))])
        #expect(!String(decoding: ztxt, as: UTF8.self).contains(Self.value))
        #expect(throws: Self.refusal("logo.png", line: nil)) { try check(cf, ztxt, ext: "png", canonical: "logo.png") }
        var itxtData = Data("Comment".utf8)
        itxtData.append(contentsOf: [0, 1, 0] as [UInt8])
        itxtData.append(Data("en".utf8))
        itxtData.append(contentsOf: [0, 0] as [UInt8])
        itxtData.append(try Self.zlib(Data("key \(Self.value)".utf8)))
        let itxt = Self.png([("iTXt", itxtData)])
        #expect(throws: Self.refusal("i.png", line: nil)) { try check(cf, itxt, ext: "png", canonical: "i.png") }
        let fine = Self.png([("zTXt", Data("Comment".utf8) + Data([0, 0]) + (try Self.zlib(Data("made with care".utf8))))])
        #expect(try check(cf, fine, ext: "png", canonical: "fine.png") == .clean)
        let broken = Self.png([("zTXt", Data("Comment".utf8) + Data([0, 0]) + Data("garbage, not zlib".utf8))])
        #expect(throws: WorkError.invalid("this PNG has a compressed chunk that can't be decoded for scanning")) {
            try check(cf, broken, ext: "png", canonical: "broken.png")
        }
    }

    @Test func svgzRefused() throws {
        let cf = try CollabFixture()
        let dir = try tempDir()
        try Data("<svg><text>\(Self.value)</text></svg>".utf8).write(to: dir.appending(path: "a.svg"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.currentDirectoryURL = dir
        p.arguments = ["-n", "a.svg"]
        try p.run(); p.waitUntilExit()
        let svgz = try Data(contentsOf: dir.appending(path: "a.svg.gz"))
        #expect(throws: WorkError.invalid("icon.svgz is compressed as gzip, which can't be scanned for secrets; share the files inside instead")) {
            try check(cf, svgz, ext: "svgz", canonical: "icon.svgz")
        }
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

    // MARK: Fix round 2

    /// The refusal of a secret pattern found only in decoded content (R2-3).
    static func decodedRefusal(_ canonical: String, _ label: String) -> WorkError {
        WorkError.invalid("\(canonical) looks like it contains a secret (\(label)) inside compressed or embedded content, which can't be "
                          + "redacted, so it can't be shared, copied or shown")
    }

    /// R2-3 (N-1): a secret found only in decoded content (here an ASCIIHex PDF: pure ASCII, the key only in its decoded
    /// stream) is refused at every read point, never stored or copied as a "redacted" copy that still holds it; and every
    /// redacted copy is checked again through the whole gate.
    @Test func decodedSecretNeverRedacted() throws {
        let cf = try CollabFixture()
        let content = Data("BT /F1 12 Tf 72 700 Td (key \(Self.aws)) Tj ET".utf8)
        let hex = Data(content.map { String(format: "%02X", $0) }.joined().utf8) + Data(">".utf8)
        let pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(hex.count) /Filter /ASCIIHexDecode >>", hex)))
        #expect(!pdf.prefix(OpenRefLimits.binarySniffBytes).contains(0))
        #expect(!String(decoding: pdf, as: UTF8.self).contains(Self.aws))
        // A PDF is never redacted as text.
        #expect(!SecretGate.isRedactable(pdf, ext: "pdf"))
        #expect(!SecretGate.isRedactable(pdf, ext: "txt"))
        guard EmbeddedContentTests.helperReady else { return }
        let reader = try EmbeddedContentTests.reader(cf)
        let cId = cf.c.id
        func resources() throws -> Int {
            try cf.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM resource WHERE companyId = ?", arguments: [cId]) ?? 0 }
        }
        let before = try resources()
        // The pin of a worktree PDF: refused, nothing stored, no share ref.
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try pdf.write(to: wt.appending(path: "doc.pdf"))
        #expect(throws: Self.decodedRefusal("ENG-1:doc.pdf@worktree", "aws-key")) {
            try cf.store.pinRef(try cf.fx.ref("ENG-1:doc.pdf@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                messageRefId: "mr-pdf", knownValues: Self.known, paths: cf.paths, archives: reader)
        }
        #expect(try resources() == before)
        #expect((try? cf.fx.git.git(["rev-parse", "--verify", "--quiet", "refs/brahma/shares/mr-pdf"])) == nil)
        // A lab snapshot: refused, nothing stored.
        try pdf.write(to: cf.workspace.appending(path: ".brahma/labs/eng-1/doc.pdf"))
        #expect(throws: Self.decodedRefusal("doc.pdf", "aws-key")) {
            try cf.store.snapshotPrivateFile(companyId: cf.c.id, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/eng-1/doc.pdf",
                                             readers: [cf.fx.qa2.id], knownValues: Self.known, paths: cf.paths, now: cf.now, archives: reader)
        }
        #expect(try resources() == before)
        // A copy of a committed PDF: refused, nothing in the reader's lab; a plain open is refused too.
        try cf.commit(["docs/doc.pdf": pdf])
        for copy in [true, false] {
            #expect(throws: Self.decodedRefusal("docs/doc.pdf", "aws-key")) {
                try cf.store.openRef(companyId: cf.c.id, reader: .agent(cf.fx.qa2.id), ref: "docs/doc.pdf", lines: nil, copy: copy, turnId: nil,
                                     context: cf.fx.ctx, knownValues: Self.known, paths: cf.paths, now: cf.now, archives: reader)
            }
        }
        let inbox = cf.workspace.appending(path: ".brahma/labs/qa-2/in").path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: inbox)) ?? []).isEmpty)

        // Every redacted copy goes through the whole gate again: a copy that still holds a secret (a redaction that missed
        // it) is refused, and nothing is stored.
        try cf.fx.git.write("src/conf.ts", "const key = '\(Self.aws)'\n", in: wt)
        cf.store.refHooks.setRedactedCopy { $0 }
        #expect(throws: WorkError.invalid("ENG-1:src/conf.ts@worktree still looks like it holds a secret after redaction, so no copy of it is made")) {
            try cf.store.pinRef(try cf.fx.ref("ENG-1:src/conf.ts@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                messageRefId: "mr-again", knownValues: Self.known, paths: cf.paths)
        }
        #expect(try resources() == before)
        cf.store.refHooks.setRedactedCopy(nil)
        let pinned = try cf.store.pinRef(try cf.fx.ref("ENG-1:src/conf.ts@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                         messageRefId: "mr-again", knownValues: Self.known, paths: cf.paths)
        #expect(pinned.kind == .resource)
    }

    /// R2-2 (Ruling 32): `PK\x03\x04` makes bytes an archive only where a plausible local header parses; an end record in
    /// the tail always does.
    @Test func archiveDetectionNeedsAPlausibleHeader() throws {
        let cf = try CollabFixture()
        var rng = SeededBytes(state: 0x5EED)
        // Bytes with PK\x03\x04 followed by garbage that is no local header: not an archive, scanned as bytes.
        let noise = rng.bytes(5000) + Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0xFF, count: 40) + rng.bytes(3000)
        #expect(!ArchiveMemberScan.isArchive(noise, ext: "bin"))
        #expect(try check(cf, noise, ext: "bin", canonical: "noise.bin") == .clean)
        // A name that runs past the end of the bytes is no header (amended ruling 32: only whether it fits counts).
        var header = Data([0x50, 0x4B, 0x03, 0x04, 20, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        header += Data([0x10, 0, 0, 0, 0x10, 0, 0, 0, 0x00, 0x08, 0, 0])   // sizes 16, name length 2048
        #expect(!ArchiveMemberScan.isArchive(rng.bytes(100) + header + rng.bytes(100), ext: "bin"))
        // A real zip is an archive, and its member is scanned.
        let secret: [(name: String, data: Data)] = [("s.txt", Data("v=\(Self.value)\n".utf8))]
        let real = try Self.packed(secret, tag: "plausible")
        #expect(throws: Self.refusal("real.bin", line: nil)) {
            try check(cf, real, ext: "bin", canonical: "real.bin", archives: StubArchiveReader(members: secret))
        }
        // The same zip inside other bytes, its end record pushed out of the tail: its local header is plausible, so the
        // bytes are an archive, and one that can't be scanned: refused.
        let buried = rng.bytes(100) + real + Data(repeating: 0x20, count: 70_000)
        #expect(ArchiveMemberScan.isArchive(buried, ext: "bin"))
        #expect(throws: WorkError.self) {
            try check(cf, buried, ext: "bin", canonical: "buried.bin", archives: StubArchiveReader(members: secret))
        }
    }

    /// R2-6: compress (.Z), lz4, lzip, lzma-alone, cab and xar can't be scanned: refused whole and as an archive member.
    @Test func moreCompressedFormatsRefused() throws {
        let cf = try CollabFixture()
        let formats: [(String, [UInt8])] = [
            ("compress", [0x1F, 0x9D, 0x90]), ("lz4", [0x04, 0x22, 0x4D, 0x18]), ("lzip", Array("LZIP".utf8) + [1]),
            ("lzma", [0x5D, 0x00, 0x00, 0x80, 0x00]), ("cab", Array("MSCF".utf8) + [0, 0, 0, 0]), ("xar", Array("xar!".utf8) + [0, 0x1C]),
        ]
        for (name, magic) in formats {
            let data = Data(magic) + Data(repeating: 0x41, count: 100)
            #expect(throws: WorkError.invalid("x.bin is compressed as \(name), which can't be scanned for secrets; share the files inside instead"),
                    "\(name)") {
                try check(cf, data, ext: "bin", canonical: "x.bin")
            }
            let member: [(name: String, data: Data)] = [("inner.bin", data)]
            #expect(throws: WorkError.invalid("this archive holds \(name) data, which can't be scanned for secrets"), "\(name) member") {
                try check(cf, try Self.packed(member, tag: "format \(name)"), ext: "zip", canonical: "m.zip", archives: StubArchiveReader(members: member))
            }
        }
    }

    /// R2-6 (m-1): a local header whose encryption bit differs from the central directory's is refused.
    @Test func localEncryptionBitMustMatch() throws {
        let cf = try CollabFixture()
        let member: [(name: String, data: Data)] = [("doc.txt", Data("hello there".utf8))]
        var zip = try Self.zip { $0.add("doc.txt", "hello there") }
        #expect(try check(cf, zip, ext: "zip", canonical: "ok.zip", archives: StubArchiveReader(members: member)) == .clean)
        zip[zip.startIndex + 6] |= 0x01   // the local header says encrypted; the central directory does not
        #expect(throws: Self.methodRefusal) {
            try check(cf, zip, ext: "zip", canonical: "mixed.zip", archives: StubArchiveReader(members: member))
        }
    }

    /// R2-6 (m-2): a name is flattened before it is redacted, so characters the flattening drops (U+2028, U+2029, zero-width
    /// ones) can't put a value back together in a refusal or an alert.
    @Test func namesFlattenedBeforeRedacting() throws {
        let cf = try CollabFixture()
        for split in ["\u{2028}", "\u{2029}", "\u{200B}"] {
            #expect(!SecretGate.shown("src/sk_test_\(split)51abcdefgh.ts", knownValues: Self.known).contains("51abcd"))
        }
        let name = "sk_test_\u{2028}51abcdefgh.txt"
        try Data("token \(Self.value)\n".utf8).write(to: cf.workspace.appending(path: ".brahma/labs/eng-1/\(name)"))
        do {
            _ = try cf.store.snapshotPrivateFile(companyId: cf.c.id, agentId: cf.fx.eng1.id, workspacePath: ".brahma/labs/eng-1/\(name)",
                                                 readers: [cf.fx.qa2.id], knownValues: Self.known, paths: cf.paths, now: cf.now)
            Issue.record("not refused")
        } catch let e as WorkError {
            #expect(e.message.contains("contains a stored secret"))
            for piece in Self.pieces(Self.value) { #expect(!e.message.contains(piece)) }
        }
        let cId = cf.c.id
        let texts = try cf.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT title || ' ' || summary FROM ask WHERE companyId = ? AND kind = 'engineAlert'", arguments: [cId])
            + String.fetchAll(db, sql: "SELECT text FROM message WHERE companyId = ?", arguments: [cId])
        }
        #expect(!texts.isEmpty)
        for text in texts { for piece in Self.pieces(Self.value) { #expect(!text.contains(piece)) } }
    }

    // MARK: Fix round 3

    /// A zip local header alone (no central directory), as the reviewer's `zipv.py` writes it: `version`, `name`, and the
    /// deflated `text`, then a line of notes.
    static func lone(version: UInt16, name: String, method: UInt16 = 8, text: String) -> Data {
        let data = Data(text.utf8)
        let comp = (try? (data as NSData).compressed(using: .zlib) as Data) ?? Data()   // raw DEFLATE
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        var out = Data([0x50, 0x4B, 0x03, 0x04] + le16(version) + le16(0) + le16(method) + le16(0) + le16(0))
        out += Data(le32(ZipBuilder.crc32(data)) + le32(UInt32(comp.count)) + le32(UInt32(data.count)) + le16(UInt16(name.utf8.count)) + le16(0))
        return out + Data(name.utf8) + comp + Data("\nmore notes\n".utf8)
    }

    /// R3-4 (amended ruling 32): a `PK\x03\x04` header is an archive when its method is a zip method, its name fits in the
    /// bytes and its data stays in them (or, deflated, decodes); the version and the name's length don't matter.
    @Test func archiveDetectionIgnoresVersionAndNameCaps() throws {
        let cf = try CollabFixture()
        let leak = "leak \(Self.aws) end\n"
        for (name, data) in [("ver.txt", Self.lone(version: 0xFFFF, name: "a.txt", text: leak)),
                             ("name4k.txt", Self.lone(version: 20, name: String(repeating: "n", count: 4096), text: leak)),
                             ("ok.txt", Self.lone(version: 20, name: "a.txt", text: leak))] {
            #expect(!String(decoding: data, as: UTF8.self).contains(Self.aws))
            #expect(ArchiveMemberScan.isArchive(data, ext: "txt"), "\(name)")
            #expect(throws: WorkError.self, "\(name)") { try check(cf, data, canonical: name) }
        }
        // A deflated entry whose declared size runs past the end still counts when its data decodes.
        var lying = Self.lone(version: 20, name: "a.txt", text: leak)
        lying[18] = 0xFF; lying[19] = 0xFF; lying[20] = 0xFF; lying[21] = 0x0F
        #expect(ArchiveMemberScan.isArchive(lying, ext: "txt"))
        // An unknown method is no zip: random bytes holding such a header are plain bytes.
        var rng = SeededBytes(state: 0x32)
        let unknown = rng.bytes(300) + Self.lone(version: 20, name: "a.txt", method: 0x7777, text: "x") + rng.bytes(300)
        #expect(!ArchiveMemberScan.isArchive(unknown, ext: "bin"))
        #expect(try check(cf, unknown, ext: "bin", canonical: "noise.bin") == .clean)
    }

    /// A reader that counts its launches.
    final class CountingReader: ArchiveReader, @unchecked Sendable {
        let lock = NSLock()
        var launches = 0
        let answer: @Sendable (Data) throws -> [(name: String, data: Data)]
        init(_ answer: @escaping @Sendable (Data) throws -> [(name: String, data: Data)]) { self.answer = answer }
        func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
            lock.withLock { launches += 1 }
            return try answer(data)
        }
    }

    /// R3-5 (m-A): one check launches at most `ArchiveScanBudget.maxLaunches` sandboxed readers; a refusal is cached like
    /// a verdict (the same bytes are not read again), except one that may pass later (no reader, a reader that could not
    /// run or ran out of time).
    @Test func readerLaunchesCappedAndRefusalsCached() throws {
        let cf = try CollabFixture()
        // Five nested levels of one zip each, with a cap of three launches.
        var levels: [Data] = [try Self.packed([("leaf.txt", Data("leaf".utf8))], tag: "level 0")]
        for i in 1...4 { levels.append(try Self.packed([("next.zip", levels[i - 1])], tag: "level \(i)")) }
        let all = levels
        let nested = CountingReader { data in
            guard let i = all.firstIndex(of: data) else { return [] }
            return i == 0 ? [("leaf.txt", Data("leaf".utf8))] : [("next.zip", all[i - 1])]
        }
        #expect(throws: ArchiveMemberScan.tooManyLaunches) {
            try ArchiveMemberScan.scan(levels[2], archives: nested, knownValues: [],
                                       budget: ArchiveScanBudget(bytes: 100_000, depth: 10, launches: 2))
        }
        #expect(nested.launches == 2)
        #expect(try ArchiveMemberScan.scan(levels[2], archives: nested, knownValues: [],
                                           budget: ArchiveScanBudget(bytes: 100_000, depth: 10, launches: 3)).isEmpty)
        // A refusal is cached: the second check of the same bytes launches nothing.
        let bomb = CountingReader { _ in throw ArchiveReadError.refused("this archive expands too much to preview safely") }
        let bytes = try Self.packed([("a.txt", Data("a".utf8))], tag: "cached refusal")
        for _ in 0..<3 {
            #expect(throws: WorkError.invalid("this archive expands too much to preview safely")) {
                try check(cf, bytes, ext: "zip", canonical: "bomb.zip", archives: bomb)
            }
        }
        #expect(bomb.launches == 1)
        // The cached refusal names the ref it is asked about, not the first one.
        let gz = Data([0x1F, 0x8B, 0x08, 0x00]) + Data("cached gzip".utf8)
        #expect(throws: WorkError.invalid("one.gz is compressed as gzip, which can't be scanned for secrets; share the files inside instead")) {
            try check(cf, gz, ext: "gz", canonical: "one.gz")
        }
        #expect(throws: WorkError.invalid("two.gz is compressed as gzip, which can't be scanned for secrets; share the files inside instead")) {
            try check(cf, gz, ext: "gz", canonical: "two.gz")
        }
        // No reader: refused, not cached; with a reader the same bytes pass.
        let fine = try Self.packed([("a.txt", Data("fine".utf8))], tag: "transient")
        #expect(throws: WorkError.invalid("archives can't be scanned on this machine")) { try check(cf, fine, ext: "zip", canonical: "f.zip") }
        let good = CountingReader { _ in [("a.txt", Data("fine".utf8))] }
        #expect(try check(cf, fine, ext: "zip", canonical: "f.zip", archives: good) == .clean)
    }

    /// R3-8 (m-D): a redacted copy whose re-check could not run (no reader, over the budget) says so.
    @Test func redactedCopyRecheckSaysWhy() throws {
        let cf = try CollabFixture()
        let wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        try cf.fx.git.write("src/conf.ts", "const key = '\(Self.aws)'\n", in: wt)
        let pdf = PDFBuild.flate("hello")
        cf.store.refHooks.setRedactedCopy { _ in pdf }
        #expect(throws: WorkError.invalid("no redacted copy of ENG-1:src/conf.ts@worktree is made: the copy couldn't be checked again "
                                          + "(PDFs can't be scanned on this machine)")) {
            try cf.store.pinRef(try cf.fx.ref("ENG-1:src/conf.ts@worktree"), for: .agent(cf.fx.eng1.id), companyId: cf.c.id,
                                messageRefId: "mr-why", knownValues: Self.known, paths: cf.paths)
        }
        cf.store.refHooks.setRedactedCopy(nil)
    }

    // MARK: Fix round 4

    /// A deflate local header at the start of `rest`: `method` 8, the declared compressed size `declared` (past the end of
    /// the bytes when large), the name `a.txt`.
    static func deflateHeader(declared: UInt32, uncompressed: UInt32 = 0) -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        return Data([0x50, 0x4B, 0x03, 0x04] + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0) + le32(declared)
                    + le32(uncompressed) + le16(5) + le16(0)) + Data("a.txt".utf8)
    }

    /// R4-2 (ruling 34, item 3): the deflate probe reads a bounded slice of the bytes in place (no copy of the rest), probes
    /// at most 64 headers in one call, and a cap hit means an archive: 50 MB holding 100,000 deflate headers whose sizes run
    /// past the end and whose data fails at once is an archive, in bounded time. Probing stops at the check's deadline (an
    /// archive then; the check's own deadline refuses it).
    @Test(.timeLimit(.minutes(3))) func archiveProbeIsBounded() throws {
        let one = Self.deflateHeader(declared: 0xFFFF_FFFE) + Data(repeating: 0xFF, count: 465)
        var big = Data()
        big.reserveCapacity(one.count * 100_000)
        for _ in 0..<100_000 { big.append(one) }
        #expect(big.count == 50_000_000)
        let started = AwakeTime.uptime()
        #expect(ArchiveMemberScan.isArchive(big, ext: "txt"))
        #expect(AwakeTime.uptime() - started < 30, "\(AwakeTime.uptime() - started) s")
        // One such header alone is no archive (its data fails at once), unless the deadline is already past.
        let lone = Data("notes\n".utf8) + Self.deflateHeader(declared: 0xFFFF_FFFE) + Data(repeating: 0xFF, count: 64)
        #expect(!ArchiveMemberScan.isArchive(lone, ext: "txt"))
        #expect(ArchiveMemberScan.isArchive(lone, ext: "txt", deadline: AwakeTime.uptime() - 1))
        #expect(!ArchiveMemberScan.isArchive(lone, ext: "txt", deadline: AwakeTime.uptime() + 60))
    }

    /// R4-3 (controller ruling, truncated deflate): only a deflate DATA error means "no archive". The reviewer's
    /// `trunc_small.txt` (20 KB of text deflated, half the data kept, the declared size past the end): the stream runs out
    /// before it ends, which a lenient reader (`bsdtar`) still prints, so it is an archive and refused. Random bytes holding a
    /// deflate header whose data hits a reserved block type at once: no archive, clean.
    @Test func truncatedDeflateIsAnArchive() throws {
        let cf = try CollabFixture()
        var rng = SeededBytes(state: 0x7C2B)
        var words: [String] = []
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        while words.joined(separator: " ").utf8.count < 20_000 {
            words.append(String((0..<(2 + rng.below(7))).map { _ in letters[rng.below(letters.count)] }))
            if words.count == 1500 { words.append("leak \(Self.aws) end") }
        }
        let text = Data(words.joined(separator: " ").utf8)
        let deflated = try (text as NSData).compressed(using: .zlib) as Data   // raw DEFLATE
        let trunc = Self.deflateHeader(declared: UInt32(deflated.count), uncompressed: UInt32(text.count)) + deflated.prefix(deflated.count / 2)
        #expect(!String(decoding: trunc, as: UTF8.self).contains(Self.aws))
        #expect(ArchiveMemberScan.isArchive(trunc, ext: "txt"))
        #expect(throws: WorkError.self) { try check(cf, trunc, canonical: "trunc_small.txt") }
        // A data error straight away (block type 3): plain bytes.
        let noise = Data(rng.bytes(200).map { $0 == 0x50 ? 0x51 : $0 })
        let broken = noise + Self.deflateHeader(declared: 0xFFFF_FFFE) + Data([0x07]) + Data(rng.bytes(100).map { $0 == 0x50 ? 0x51 : $0 })
        #expect(!ArchiveMemberScan.isArchive(broken, ext: "bin"))
        #expect(try check(cf, broken, ext: "bin", canonical: "noise.bin") == .clean)
    }

    /// R4-5: the cache keys a verdict by everything detection reads besides the bytes, the extension included: the same
    /// bytes as `.txt` (clean) and as `.docx` (an archive that can't be read, refused) each get their own verdict, in either
    /// order.
    @Test func cacheKeyedByExtension() throws {
        let cf = try CollabFixture()
        let first = Data("plain notes \(UUID().uuidString)\n".utf8), second = Data("plain notes \(UUID().uuidString)\n".utf8)
        #expect(try check(cf, first, ext: "txt", canonical: "notes.txt") == .clean)
        #expect(throws: WorkError.self) { try check(cf, first, ext: "docx", canonical: "notes.docx") }
        #expect(throws: WorkError.self) { try check(cf, second, ext: "docx", canonical: "other.docx") }
        #expect(try check(cf, second, ext: "txt", canonical: "other.txt") == .clean)
        #expect(SecretGate.cacheVersion(store: cf.store, companyId: cf.c.id, ext: "txt", knownValues: Self.known)
                != SecretGate.cacheVersion(store: cf.store, companyId: cf.c.id, ext: "docx", knownValues: Self.known))
    }

    /// R4-7 (ruling 36): a deflate stream that decodes text holding a secret and THEN hits a data error is an archive: a
    /// streaming reader (unzip, bsdtar) still prints what came before the error. The block's final bit cleared and an invalid
    /// block after it; the declared size past the end. Caught (refused), never "plain bytes". An error before any output
    /// stays plain bytes (`truncatedDeflateIsAnArchive`).
    @Test func deflateThatFailsAfterOutputIsAnArchive() throws {
        let cf = try CollabFixture()
        let text = Data(("notes " + String(repeating: "lorem ipsum dolor ", count: 40) + "leak \(Self.aws) end\n").utf8)
        var deflated = try (text as NSData).compressed(using: .zlib) as Data   // raw DEFLATE, one final block
        deflated[deflated.startIndex] &= 0xFE                                  // not the last block: a next one is read
        let corrupt = deflated + Data([6, 0, 0]) + Data(repeating: 0xFF, count: 32)
        let bytes = Data("readme\n".utf8) + Self.deflateHeader(declared: 0xFFFF_FFFE, uncompressed: UInt32(text.count)) + corrupt
        #expect(!String(decoding: bytes, as: UTF8.self).contains(Self.aws))
        #expect(ArchiveMemberScan.isArchive(bytes, ext: "txt"))
        #expect(throws: WorkError.self) { try check(cf, bytes, canonical: "partial.txt") }
    }
}
