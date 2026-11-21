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

    // MARK: R1-9 (Ruling 31): compressed streams inside PDFs and PNGs are decoded and scanned

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

    /// A small PDF whose one content stream is `body` (already encoded) under `filter` (a PDF filter expression or nil).
    static func pdf(_ body: Data, filter: String?, extraTrailer: String = "") -> Data {
        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".utf8)
        out += Data("4 0 obj\n<< /Length \(body.count)\(filter.map { " /Filter \($0)" } ?? "") >>\nstream\n".utf8)
        out += body
        out += Data("\nendstream\nendobj\ntrailer\n<< /Root 1 0 R\(extraTrailer) >>\n%%EOF\n".utf8)
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

    @Test func pdfStreamsDecodedAndScanned() throws {
        let cf = try CollabFixture()
        let content = Data("BT /F1 12 Tf 72 700 Td (key \(Self.value)) Tj ET".utf8)
        let flate = Self.pdf(try Self.zlib(content), filter: "/FlateDecode")
        #expect(!String(decoding: flate, as: UTF8.self).contains(Self.value))
        #expect(throws: Self.refusal("doc.pdf", line: nil)) { try check(cf, flate, ext: "pdf", canonical: "doc.pdf") }
        // Split across TJ strings, behind a filter chain (hex over Flate).
        let split = Data("BT [(sk_test_) -20 (51abcdefgh)] TJ ET".utf8)
        let hex = Data((try Self.zlib(split)).map { String(format: "%02X", $0) }.joined().utf8) + Data(">".utf8)
        let chained = Self.pdf(hex, filter: "[/ASCIIHexDecode /FlateDecode]")
        #expect(throws: Self.refusal("chain.pdf", line: nil)) { try check(cf, chained, ext: "pdf", canonical: "chain.pdf") }
        // Named anything: a PDF by its header.
        #expect(throws: Self.refusal("notes.bin", line: nil)) { try check(cf, flate + Data(), ext: "bin", canonical: "notes.bin") }
        // A clean compressed PDF passes.
        let clean = Self.pdf(try Self.zlib(Data("BT (hello) Tj ET".utf8)), filter: "/FlateDecode")
        #expect(try check(cf, clean, ext: "pdf", canonical: "clean.pdf") == .clean)
        // Encrypted, an unknown filter, or a stream that does not decode: refused, never passed.
        let encrypted = Self.pdf(Data("opaque".utf8), filter: nil, extraTrailer: " /Encrypt 5 0 R")
        #expect(throws: WorkError.invalid("this PDF is encrypted, so it can't be scanned for secrets")) {
            try check(cf, encrypted, ext: "pdf", canonical: "locked.pdf")
        }
        let unknown = Self.pdf(Data("opaque".utf8), filter: "/MadeUpDecode")
        #expect(throws: WorkError.invalid("this PDF has a stream that can't be decoded for scanning (MadeUpDecode)")) {
            try check(cf, unknown, ext: "pdf", canonical: "odd.pdf")
        }
        let broken = Self.pdf(Data("not a zlib stream at all".utf8), filter: "/FlateDecode")
        #expect(throws: WorkError.invalid("this PDF has a stream that can't be decoded for scanning (FlateDecode)")) {
            try check(cf, broken, ext: "pdf", canonical: "broken.pdf")
        }
        // LZW (the PDF Reference's own example) and a PNG "Up" predictor under Flate decode to the plain bytes.
        #expect(try EmbeddedStreams.lzw(Data([0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01]), earlyChange: 1, cap: 1000)
            == Data("-----A---B".utf8))
        let rows = Array("key sk_test_".utf8), rows2 = Array("51abcdefgh  ".utf8)
        var predicted: [UInt8] = [2] + rows + [2]
        for (i, c) in rows2.enumerated() { predicted.append(c &- rows[i]) }
        let up = Self.pdf(try Self.zlib(Data(predicted)), filter: "/FlateDecode /DecodeParms << /Predictor 12 /Columns 12 >>")
        let lines = try EmbeddedStreams.pdfStreams(up, budget: ArchiveScanBudget())
        #expect(lines == [Data(rows + rows2)])
        // The decoding spends the same shared budget as nested archives.
        let big = Self.pdf(try Self.zlib(Data(repeating: 0x20, count: 50_000)), filter: "/FlateDecode")
        #expect(throws: ArchiveMemberScan.overBudget) {
            try EmbeddedStreams.scan(big, ext: "pdf", expanded: [], budget: ArchiveScanBudget(bytes: 10_000), chunk: ContentScan.chunkBytes)
        }
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
}
