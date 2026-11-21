import Testing
import Foundation
@testable import BrahmaCore

/// C2b-carry (c), controller Ruling 42: vouching a PDF whose structure couldn't be verified never lets hidden content out.
/// What is pinned, shared or served for it is a FLATTENED COPY the sandboxed `brahma-pdf` helper re-renders (vector) from
/// CoreGraphics' view of the visible pages; the copy passes the whole gate as an ordinary, non-vouched file; the original
/// bytes are never served (`SecretGate.check` refuses them; `Store.gatedBytes` serves the copy).
@Suite(.scratch) struct FlattenedCopyTests {
    static let aws = SecretGateTests.aws
    static let value = SecretGateTests.value

    func outcome(_ body: () throws -> ScanVerdict) -> String {
        do { return "\(try body())" } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    func check(_ cf: CollabFixture, _ data: Data, canonical: String, archives: any ArchiveReader) throws -> ScanVerdict {
        try SecretGate.check(data, ext: "pdf", canonical: canonical, archives: archives, knownValues: SecretGateTests.known,
                             store: cf.store, companyId: cf.c.id)
    }

    /// `noprev.pdf` (re-review 4: the key sits in a revision CoreGraphics' view leaves out, which poppler recovers), refused
    /// for its structure, then vouched: the gate never passes the original bytes any more (before, it scanned what the
    /// helper read of them, found nothing, and passed them as clean, for a caller to serve as they are).
    @Test func vouchedPDFOriginalNeverPasses() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let noprev = R37Build.noPrev(bogus: true)
        #expect(outcome { try check(cf, noprev, canonical: "noprev.pdf", archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: "noprev.pdf", sha256: SHA256.hex(noprev), now: cf.now)
        let after = outcome { try check(cf, noprev, canonical: "noprev.pdf", archives: reader) }
        #expect(after != "clean", "the vouched original passed the gate as it is")
        #expect(after.contains("only its flattened copy"), "\(after)")
    }

    /// The served bytes of a vouched PDF are its flattened copy. `noprev.pdf` (the key in a revision CoreGraphics' view
    /// leaves out) and an unreferenced object holding a stored value: the copy holds neither (not in its bytes, not in
    /// anything the helper reads of it); the original is never returned; the copy is kept in the vault, keyed to the vouch
    /// row with its own hash recorded, read back on the next call, and made again when the vault's file is gone.
    @Test func vouchedPDFServesItsFlattenedCopy() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        for (name, pdf, hidden) in [("noprev.pdf", R37Build.noPrev(bogus: true), Self.aws),
                                    ("hidden.pdf", FileVouchTests.anomalous(hidden: "key \(Self.value)"), Self.value)] {
            #expect(outcome { try check(cf, pdf, canonical: name, archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
            let row = try cf.store.vouchFile(companyId: cf.c.id, canonical: name, sha256: SHA256.hex(pdf), now: cf.now)
            let served = try serve(cf, pdf, canonical: name, archives: reader)
            #expect(served.isFlattenedCopy && served.verdict == .clean && served.ext == "pdf", "\(name)")
            #expect(served.data != pdf && !served.data.contains(pdf) && served.originalSha256 == SHA256.hex(pdf) && served.sha256 == SHA256.hex(served.data))
            #expect(served.data.starts(with: Data("%PDF-".utf8)))
            #expect(!String(decoding: served.data, as: UTF8.self).contains(hidden), "\(name): the key is in the copy's bytes")
            let parts = try reader.pdfParts(of: served.data, maxBytes: 16_000_000, timeout: .seconds(60))
            #expect(!parts.contains { String(decoding: $0.data, as: UTF8.self).contains(hidden) }, "\(name): the key is in the copy")
            // Kept in the vault, keyed to the vouch row; read back, not made again.
            let recorded = try copySha(cf, row.id)
            #expect(served.flattenedPath == "flattened/\(row.id).pdf" && recorded == served.sha256)
            #expect(try cf.vault.read("flattened/\(row.id).pdf", sha256: served.sha256, maxBytes: 16_000_000) == served.data)
            #expect(try serve(cf, pdf, canonical: name, archives: reader).data == served.data)
            try cf.vault.remove("flattened/\(row.id).pdf")
            let again = try serve(cf, pdf, canonical: name, archives: reader)
            let remade = try copySha(cf, row.id)
            #expect(again.isFlattenedCopy && again.data != pdf && remade == again.sha256)
        }
    }

    /// The copy passes the whole gate as an ordinary file: a vouched PDF whose VISIBLE page text holds a stored value is
    /// refused (the copy holds it), and nothing is recorded for the copy (it can't be vouched: no new row, no alert).
    @Test func visibleKnownValueRefusesTheCopy() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let pdf = FlattenBuild.anomalous(page: "key \(Self.value)")
        #expect(!String(decoding: pdf, as: UTF8.self).contains(Self.value))
        #expect(outcome { try check(cf, pdf, canonical: "visible.pdf", archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: "visible.pdf", sha256: SHA256.hex(pdf), now: cf.now)
        let refused = outcome { try serve(cf, pdf, canonical: "visible.pdf", archives: reader).verdict }
        #expect(refused.contains("contains a stored secret"), "\(refused)")
        #expect(try rows(cf).count == 1)
    }

    /// A PDF with an attachment, an annotation (with an appearance), a form field, JavaScript, outlines, document metadata
    /// and XMP: the original holds them all; the flattened copy holds none of them, only the page's visible text.
    @Test func copyDropsEverythingButThePages() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let pdf = FlattenBuild.anomalous(page: "hello", extras: true)
        var original: [PDFPart] = []
        do { original = try reader.pdfParts(of: pdf, maxBytes: 16_000_000, timeout: .seconds(60)) } catch let u as UnverifiedPDF { original = u.parts }
        let read = original.map { String(decoding: $0.data, as: UTF8.self) }.joined(separator: "\n")
        for mark in FlattenBuild.marks { #expect(read.contains(mark) || String(decoding: pdf, as: UTF8.self).contains(mark), "the fixture lacks \(mark)") }
        #expect(outcome { try check(cf, pdf, canonical: "extras.pdf", archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: "extras.pdf", sha256: SHA256.hex(pdf), now: cf.now)
        let served = try serve(cf, pdf, canonical: "extras.pdf", archives: reader)
        #expect(served.isFlattenedCopy && served.verdict == .clean)
        let copy = try reader.pdfParts(of: served.data, maxBytes: 16_000_000, timeout: .seconds(60))
        let copied = copy.map { String(decoding: $0.data, as: UTF8.self) }.joined(separator: "\n") + String(decoding: served.data, as: UTF8.self)
        for mark in FlattenBuild.marks { #expect(!copied.contains(mark), "\(mark) is in the copy") }
        for name in ["/Annots", "/EmbeddedFile", "/JavaScript", "/Outlines", "/AcroForm", "/Metadata", "/OpenAction"] {
            #expect(!String(decoding: served.data, as: UTF8.self).contains(name), "\(name) is in the copy")
        }
        #expect(copy.contains { $0.kind == .pageText && String(decoding: $0.data, as: UTF8.self).contains("hello") }, "the page text is gone")
    }

    /// A vouched PDF CoreGraphics can't open or draw can't be flattened: refused, telling the owner to convert it; nothing
    /// is served. The helper itself refuses to flatten what isn't a PDF it can open.
    @Test func unflattenablePDFRefusedWithConvert() throws {
        let cf = try CollabFixture()
        let pdf = Data("%PDF-1.7 flagged and unflattenable".utf8)
        let cannot = UnverifiedPDFReader(parts: [], copyParts: nil)
        #expect(outcome { try check(cf, pdf, canonical: "broken.pdf", archives: cannot) }.hasPrefix("this PDF's structure couldn't be verified"))
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: "broken.pdf", sha256: SHA256.hex(pdf), now: cf.now)
        let refused = outcome { try serve(cf, pdf, canonical: "broken.pdf", archives: cannot).verdict }
        #expect(refused.contains("can't be flattened") && refused.contains("print it to PDF") && refused.contains("add it again"), "\(refused)")
        #expect(!refused.contains("brahma vouch file"))
        // Without the helper: refused as any PDF is there.
        #expect(outcome { try serve(cf, pdf, canonical: "broken.pdf", archives: UnavailableArchiveReader()).verdict } == "PDFs can't be scanned on this machine")
        guard EmbeddedContentTests.helperReady else { return }
        let reader = SandboxedPDFReader(runner: try EmbeddedContentTests.reader(cf).runner, helper: EmbeddedContentTests.helper,
                                        scratch: { try cf.vault.makeTempDir() })
        for junk in [Data("%PDF-1.7 not really a PDF".utf8), Data("plain text".utf8)] {
            #expect(throws: ArchiveReadError.self) { try reader.flatten(of: junk, maxBytes: 16_000_000) }
        }
        // A real one flattens.
        let real = try reader.flatten(of: PDFBuild.flate("hello"), maxBytes: 16_000_000)
        #expect(real.starts(with: Data("%PDF-".utf8)))
    }

    /// A copy that fails the gate's own structure check stays refused, saying no vouch lifts it; nothing is recorded or
    /// alerted for it (no loop).
    @Test func unverifiableCopyStaysRefused() throws {
        let cf = try CollabFixture()
        let pdf = Data("%PDF-1.7 flagged, and so is its copy".utf8)
        struct BadCopy: ArchiveReader {
            func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] { [] }
            func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] { throw UnverifiedPDF(parts: []) }
            func flattenPDF(of data: Data, maxBytes: Int, timeout: Duration) throws -> Data { Data("%PDF-1.3 a copy of \(SHA256.hex(data))".utf8) }
        }
        #expect(outcome { try check(cf, pdf, canonical: "loop.pdf", archives: BadCopy()) }.hasPrefix("this PDF's structure couldn't be verified"))
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: "loop.pdf", sha256: SHA256.hex(pdf), now: cf.now)
        let alerts = try openAlerts(cf)
        let refused = outcome { try serve(cf, pdf, canonical: "loop.pdf", archives: BadCopy()).verdict }
        #expect(refused.contains("flattened copy of loop.pdf couldn't be verified either") && refused.contains("print it to PDF"), "\(refused)")
        #expect(!refused.contains("brahma vouch file"))
        #expect(try rows(cf).count == 1 && openAlerts(cf) == alerts)
        // Again (a cached refusal): the same.
        #expect(outcome { try serve(cf, pdf, canonical: "loop.pdf", archives: BadCopy()).verdict } == refused)
        #expect(try rows(cf).count == 1)
    }

    /// The vouch of a NON-PDF structure refusal behaves as before (Ruling 38): bytes compressed in a format the engine can't
    /// open, and an archive with a member it can't decode, are served as they are once vouched, what can be read scanned.
    /// A PDF INSIDE a vouched archive that can't be verified stays refused (a vouch can't flatten it), and says so.
    @Test func nonPDFVouchUnchanged() throws {
        let cf = try CollabFixture()
        let gz = Data([0x1F, 0x8B, 0x08, 0x00]) + Data("compressed bytes".utf8)
        #expect(outcome { try check(cf, gz, ext: "gz", canonical: "logs.gz", archives: UnavailableArchiveReader()) }.hasPrefix("logs.gz is compressed as gzip"))
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: "logs.gz", sha256: SHA256.hex(gz), now: cf.now)
        let servedGz = try serve(cf, gz, ext: "gz", canonical: "logs.gz", archives: UnavailableArchiveReader())
        #expect(servedGz.data == gz && !servedGz.isFlattenedCopy && servedGz.verdict == .clean)
        #expect(try SecretGate.check(gz, ext: "gz", canonical: "logs.gz", archives: UnavailableArchiveReader(), knownValues: SecretGateTests.known,
                                     store: cf.store, companyId: cf.c.id) == .clean)

        let zip = try SecretGateTests.zip {
            $0.add("secret.bin", "cipher text", flags: 1)
            $0.add("readme.txt", "hello")
        }
        let members = StubArchiveReader(members: [("readme.txt", Data("hello".utf8))])
        #expect(outcome { try check(cf, zip, ext: "zip", canonical: "bundle.zip", archives: members) }.hasPrefix("this archive uses compression"))
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: "bundle.zip", sha256: SHA256.hex(zip), now: cf.now)
        let servedZip = try serve(cf, zip, ext: "zip", canonical: "bundle.zip", archives: members)
        #expect(servedZip.data == zip && !servedZip.isFlattenedCopy && servedZip.verdict == .clean)

        // An archive holding a PDF the helper can't verify: vouched for the archive's own refusal, the PDF inside stays refused.
        struct ZipWithUnverifiedPDF: ArchiveReader {
            func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
                [("doc.pdf", Data("%PDF-1.7 inside".utf8))].filter { wanted($0.0) }
            }
            func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] { throw UnverifiedPDF(parts: []) }
        }
        let holding = try SecretGateTests.zip {
            $0.add("secret.bin", "cipher text", flags: 1)
            $0.add("doc.pdf", "%PDF-1.7 inside")
        }
        #expect(outcome { try check(cf, holding, ext: "zip", canonical: "pdfs.zip", archives: ZipWithUnverifiedPDF()) }.hasPrefix("this archive uses compression"))
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: "pdfs.zip", sha256: SHA256.hex(holding), now: cf.now)
        let inner = outcome { try serve(cf, holding, ext: "zip", canonical: "pdfs.zip", archives: ZipWithUnverifiedPDF()).verdict }
        #expect(inner.hasPrefix("this PDF's structure couldn't be verified") && inner.contains("a vouch can't lift this")
                && !inner.contains("brahma vouch file"), "\(inner)")
    }

    /// Fix round 1, F1: the owner's purge of a ref removes every flattened copy derived from it (`flattened/<row id>.pdf`
    /// of each vouch row for its name), after the database retires those vouches (the copy's hash cleared, the vouch
    /// withdrawn: never served or reused again; a later vouch makes a fresh copy). No byte of the copy stays in the vault;
    /// the gate refuses the bytes again; a second purge is idempotent.
    @Test func purgeRemovesTheFlattenedCopy() throws {
        let cf = try CollabFixture()
        let ref = try cf.fx.ref("docs/spec.pdf")
        let canonical = ref.canonical
        let pdf = Data("%PDF-1.7 a vouched spec".utf8)
        let reader = UnverifiedPDFReader(parts: [])
        #expect(outcome { try check(cf, pdf, canonical: canonical, archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
        let row = try cf.store.vouchFile(companyId: cf.c.id, canonical: canonical, sha256: SHA256.hex(pdf), now: cf.now)
        let served = try serve(cf, pdf, canonical: canonical, archives: reader)
        #expect(served.isFlattenedCopy)
        let file = cf.vault.root.appending(path: "flattened/\(row.id).pdf")
        #expect(FileManager.default.fileExists(atPath: file.path))
        try PurgeTests.record(cf, ref, id: "mr-spec", at: cf.now)
        let report = try cf.store.purge(companyId: cf.c.id, ref: ref, contentVault: ContentVault(paths: cf.paths), paths: cf.paths, now: cf.now)
        #expect(report.vaultPaths.contains("flattened/\(row.id).pdf"), "\(report.vaultPaths)")
        #expect(!FileManager.default.fileExists(atPath: file.path), "the flattened copy is still in the vault")
        #expect(try vaultHolds(cf, served.data) == false, "bytes of the copy remain in the vault")
        let retired = try cf.store.writer.read { db in try FileVouch.fetchOne(db, key: row.id) }
        #expect(retired?.copySha256 == nil && retired?.vouchedAt == nil, "\(String(describing: retired))")
        let again = outcome { try serve(cf, pdf, canonical: canonical, archives: reader).verdict }
        #expect(again.hasPrefix("this PDF's structure couldn't be verified"), "\(again)")
        // Purged again: nothing left, nothing thrown.
        _ = try cf.store.purge(companyId: cf.c.id, ref: ref, contentVault: ContentVault(paths: cf.paths), paths: cf.paths, now: cf.now)
        // A later vouch makes a fresh copy.
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: canonical, sha256: SHA256.hex(pdf), now: cf.now)
        #expect(try serve(cf, pdf, canonical: canonical, archives: reader).isFlattenedCopy)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Fix round 1, F2: the serve-bytes API never hands out bytes with a secret-pattern hit that can't be redacted: a
    /// flattened copy whose raw bytes hold a pattern, and a binary with one, are refused; text with one still comes back
    /// as `.pattern` for the caller to redact (as `check` defines it).
    @Test func gatedBytesRefusesUnredactablePatterns() throws {
        let cf = try CollabFixture()
        struct PatternCopy: ArchiveReader {
            func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] { [] }
            func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] {
                if data.starts(with: Data("%PDF-1.3 copy".utf8)) { return [PDFPart(kind: .pageText, data: Data("hello".utf8))] }
                throw UnverifiedPDF(parts: [])
            }
            func flattenPDF(of data: Data, maxBytes: Int, timeout: Duration) throws -> Data {
                Data("%PDF-1.3 copy key \(SecretGateTests.aws) of \(SHA256.hex(data))".utf8)
            }
        }
        let pdf = Data("%PDF-1.7 flagged with a pattern in its copy".utf8)
        #expect(outcome { try check(cf, pdf, canonical: "pat.pdf", archives: PatternCopy()) }.hasPrefix("this PDF's structure couldn't be verified"))
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: "pat.pdf", sha256: SHA256.hex(pdf), now: cf.now)
        let copy = outcome { try serve(cf, pdf, canonical: "pat.pdf", archives: PatternCopy()).verdict }
        #expect(copy.contains("looks like it contains a secret"), "\(copy)")
        let binary = Data([0, 1, 2]) + Data(" key \(SecretGateTests.aws) ".utf8)
        let bin = outcome { try serve(cf, binary, ext: "bin", canonical: "blob.bin", archives: UnavailableArchiveReader()).verdict }
        #expect(bin.contains("looks like it contains a secret"), "\(bin)")
        let text = Data("key \(SecretGateTests.aws)\n".utf8)
        #expect(outcome { try serve(cf, text, ext: "txt", canonical: "notes.txt", archives: UnavailableArchiveReader()).verdict }.hasPrefix("pattern"))
    }

    /// Whether any file under the company's vault holds `bytes`.
    func vaultHolds(_ cf: CollabFixture, _ bytes: Data) throws -> Bool {
        guard let walker = FileManager.default.enumerator(at: cf.vault.root, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker {
            if let data = try? Data(contentsOf: url), data.range(of: bytes) != nil { return true }
        }
        return false
    }

    // MARK: Helpers

    func check(_ cf: CollabFixture, _ data: Data, ext: String = "pdf", canonical: String, archives: any ArchiveReader) throws -> ScanVerdict {
        try SecretGate.check(data, ext: ext, canonical: canonical, archives: archives, knownValues: SecretGateTests.known,
                             store: cf.store, companyId: cf.c.id)
    }

    func serve(_ cf: CollabFixture, _ data: Data, ext: String = "pdf", canonical: String, archives: any ArchiveReader) throws -> GatedBytes {
        try cf.store.gatedBytes(data, ext: ext, canonical: canonical, companyId: cf.c.id, archives: archives,
                                knownValues: SecretGateTests.known, paths: cf.paths)
    }

    func copySha(_ cf: CollabFixture, _ id: String) throws -> String? {
        try cf.store.writer.read { db in try String.fetchOne(db, sql: "SELECT copySha256 FROM fileVouch WHERE id = ?", arguments: [id]) }
    }

    func rows(_ cf: CollabFixture) throws -> [String] {
        let cId = cf.c.id
        return try cf.store.writer.read { db in try String.fetchAll(db, sql: "SELECT sha256 FROM fileVouch WHERE companyId = ?", arguments: [cId]) }
    }

    func openAlerts(_ cf: CollabFixture) throws -> Int {
        let cId = cf.c.id
        return try cf.store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ask WHERE companyId = ? AND kind = 'engineAlert' AND status = 'pendingOwner'",
                             arguments: [cId]) ?? 0
        }
    }
}

/// C2b-carry (c): PDFs whose structure the helper refuses (object 5 rewritten by an update: one number, two bodies), with
/// `page` as the visible text and, with `extras`, everything a flattened copy must drop.
enum FlattenBuild {
    static let marks = ["ANNOTMARK", "APPEARMARK", "ATTACHMARK", "FIELDMARK", "JSMARK", "OUTLINEMARK", "INFOMARK", "XMPMARK"]

    static func anomalous(page: String, extras: Bool = false) -> Data {
        typealias B = RevisionBuild
        let content = PDFBuild.zlib(Data("BT /F1 18 Tf 20 100 Td (\(page)) Tj ET".utf8))
        var objects: [Data] = []
        let catalog = extras
            ? "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles << /Names [(a.txt) 6 0 R] >> >> "
                + "/OpenAction << /S /JavaScript /JS (app.alert('JSMARK')) >> /Outlines 9 0 R /AcroForm << /Fields [10 0 R] >> /Metadata 13 0 R >>"
            : "<< /Type /Catalog /Pages 2 0 R >>"
        objects.append(B.obj(1, catalog))
        objects.append(B.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"))
        objects.append(B.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >>"
                                + (extras ? " /Annots [8 0 R 10 0 R]" : "") + " >>"))
        objects.append(B.stream(4, content))
        objects.append(B.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"))
        if extras {
            let attachment = PDFBuild.zlib(Data("ATTACHMARK".utf8))
            let appearance = Data("BT /F1 12 Tf 5 5 Td (APPEARMARK) Tj ET".utf8)
            let xmp = Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><dc:title>XMPMARK</dc:title></x:xmpmeta>".utf8)
            objects += [
                B.obj(6, "<< /Type /Filespec /F (a.txt) /EF << /F 7 0 R >> >>"),
                B.obj(7, Data("<< /Type /EmbeddedFile /Filter /FlateDecode /Length \(attachment.count) >>\nstream\n".utf8) + attachment + Data("\nendstream".utf8)),
                B.obj(8, "<< /Type /Annot /Subtype /FreeText /Rect [10 10 200 50] /Contents (ANNOTMARK) /DA (/F1 12 Tf) /AP << /N 11 0 R >> >>"),
                B.obj(9, "<< /Type /Outlines /First 12 0 R /Last 12 0 R /Count 1 >>"),
                B.obj(10, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (FIELDMARK) /V (FIELDMARK value) /Rect [10 60 200 90] /P 3 0 R >>"),
                B.obj(11, Data("<< /Type /XObject /Subtype /Form /BBox [0 0 190 40] /Resources << /Font << /F1 5 0 R >> >> /Length \(appearance.count) >>\nstream\n".utf8)
                    + appearance + Data("\nendstream".utf8)),
                B.obj(12, "<< /Title (OUTLINEMARK) /Parent 9 0 R /Dest [3 0 R /Fit] >>"),
                B.obj(13, Data("<< /Type /Metadata /Subtype /XML /Length \(xmp.count) >>\nstream\n".utf8) + xmp + Data("\nendstream".utf8)),
                B.obj(14, "<< /Title (INFOMARK) /Author (INFOMARK author) >>"),
            ]
        }
        var base = B.build(objects)
        if extras {
            // The trailer names the document information dictionary.
            base.data = PDFBuild.replacing(base.data, "/Root 1 0 R >>", "/Root 1 0 R /Info 14 0 R >>")
        }
        return B.update(base, objects: [B.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")], entries: [(5, 0, { $0[0] })],
                        size: extras ? 15 : 6).data
    }
}
