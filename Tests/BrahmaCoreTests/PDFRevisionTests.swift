import Testing
import Foundation
@testable import BrahmaCore

/// C2b fix round 5 (controller Ruling 37, R5-1; Ruling 35 (b), R5-2): every revision of a PDF is opened and walked by the
/// sandboxed `brahma-pdf` helper, or the file is refused as unverifiable, unless it is positively a linearized file (whose
/// first-page section is walked through the whole file's view, every stream accounted for); and objects held in object
/// streams (cross-reference type-2 rows) are accounted like headers: a number with a header and a type-2 row, type-2 rows
/// that differ between revisions, and a member the reader does not decode are refused. The reviewer's crafted files
/// (re-review 4: `noprev.pdf`, `h_arr.pdf`, `h_arr_ctrl.pdf`) are rebuilt here.
@Suite(.scratch) struct PDFRevisionTests {
    static let aws = SecretGateTests.aws

    func check(_ cf: CollabFixture, _ data: Data, canonical: String, archives: any ArchiveReader) throws -> ScanVerdict {
        try SecretGate.check(data, ext: "pdf", canonical: canonical, archives: archives, knownValues: SecretGateTests.known,
                             store: cf.store, companyId: cf.c.id)
    }

    /// Whether `body` is refused as a PDF whose structure couldn't be verified (Ruling 35's refusal).
    func unverifiable(_ body: () throws -> ScanVerdict) -> Bool {
        do { _ = try body(); return false } catch let e as WorkError {
            return e.message.hasPrefix("this PDF's structure couldn't be verified")
        } catch { return false }
    }

    func outcome(_ body: () throws -> ScanVerdict) -> String {
        do { return "\(try body())" } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    /// Ruling 37 (R5-1): a revision the reader can't open is refused, never skipped.
    /// - `noprev.pdf`: revision A holds the page content under `/Filter 8 0 R` (object 8 is `/FlateDecode`), an exact table
    ///   and a bogus `startxref 0`; revision C's full table without `/Prev` leaves object 8 out, so the only view the reader
    ///   could open decodes nothing and the key stays compressed. Refused (it read clean before).
    /// - `h_arr.pdf`: the object-stream flavour (revision C moves object 8 into an object stream as `[]`): refused.
    /// - Three revisions, the second one unopenable, holding a key behind an indirect `/Length`: refused as unverifiable
    ///   (before, the key was found only because the third revision's chain happened to reach it).
    /// - Two revisions, the second (the whole file) unopenable: refused.
    /// Control: `noprev_ctrl.pdf` (revision A's `startxref` right): the key is caught.
    @Test func unopenableRevisionRefused() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let noprev = R37Build.noPrev(bogus: true)
        #expect(!String(decoding: noprev, as: UTF8.self).contains(Self.aws))
        #expect(unverifiable { try check(cf, noprev, canonical: "noprev.pdf", archives: reader) },
                "\(outcome { try check(cf, noprev, canonical: "noprev.pdf", archives: reader) })")
        let hArr = R37Build.hybrid("[]", bogus: true)
        #expect(unverifiable { try check(cf, hArr, canonical: "h_arr.pdf", archives: reader) },
                "\(outcome { try check(cf, hArr, canonical: "h_arr.pdf", archives: reader) })")
        let control = R37Build.noPrev(bogus: false)
        let caught = outcome { try check(cf, control, canonical: "noprev_ctrl.pdf", archives: reader) }
        #expect(caught.contains("looks like it contains a secret") || unverifiable { try check(cf, control, canonical: "noprev_ctrl.pdf", archives: reader) },
                "\(caught)")
        #expect(!caught.contains("clean"))
        let three = R37Build.indirectLength(thirdRevision: true)
        #expect(!String(decoding: three, as: UTF8.self).contains(Self.aws))
        #expect(unverifiable { try check(cf, three, canonical: "three.pdf", archives: reader) },
                "\(outcome { try check(cf, three, canonical: "three.pdf", archives: reader) })")
        let two = R37Build.indirectLength(thirdRevision: false)
        #expect(unverifiable { try check(cf, two, canonical: "two.pdf", archives: reader) },
                "\(outcome { try check(cf, two, canonical: "two.pdf", archives: reader) })")
    }

    /// Ruling 37's exception: a file positively linearized (its first object a `/Linearized` dictionary whose `/L` is the
    /// file's length and whose `/H` names the hint stream exactly; two sections, the first holding only that dictionary and
    /// the first-page cross-reference, the final `startxref` naming it) is read through the whole file's view, which must
    /// reach every object any section names. A built one reads clean and its key is caught; the linearized PDFs on this Mac
    /// read clean. Look-alikes are refused: `/L` wrong; an incremental update after it; an extra object in the first-page
    /// section; an object the first-page section frees but the main section uses.
    @Test func linearizedPDFsRead() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let lin = LinearizedBuild.build()
        #expect(outcome { try check(cf, lin, canonical: "lin.pdf", archives: reader) } == "clean")
        let secret = LinearizedBuild.build(content: "BT /F1 12 Tf 10 100 Td (\(Self.aws)) Tj ET")
        #expect(outcome { try check(cf, secret, canonical: "lin_secret.pdf", archives: reader) }.contains("looks like it contains a secret"))
        for (name, file) in [("lin_badL.pdf", LinearizedBuild.build(length: 12_345)),
                             ("lin_updated.pdf", LinearizedBuild.updated(lin)),
                             ("lin_extra.pdf", LinearizedBuild.build(extraInFirstSection: true)),
                             ("lin_free.pdf", LinearizedBuild.build(freeInFirstSection: 6))] {
            #expect(unverifiable { try check(cf, file, canonical: name, archives: reader) },
                    "\(name): \(outcome { try check(cf, file, canonical: name, archives: reader) })")
        }
        // Real linearized PDFs (Acrobat Distiller, Illustrator, Photoshop and Xcode's license, classic and cross-reference
        // stream flavours), where this Mac has them.
        var seen = 0
        for path in LinearizedBuild.realLinearized where FileManager.default.isReadableFile(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            seen += 1
            let name = (path as NSString).lastPathComponent
            #expect(!unverifiable { try check(cf, data, canonical: name, archives: reader) },
                    "\(path): \(outcome { try check(cf, data, canonical: name, archives: reader) })")
        }
        print("linearizedPDFsRead: \(seen) real linearized PDFs read")
    }

    /// Ruling 35 (b) (R5-2): objects in object streams are accounted. `h_arr_ctrl.pdf` (object 8 a header in revision A, a
    /// type-2 row into an object stream in revision C): refused (the helper passed it before). Type-2 rows naming different
    /// places for one number in two revisions: refused. A type-2 row naming a member the object stream does not hold (the
    /// reader decodes nothing for it): refused. Control: an ordinary object-stream file reads clean.
    @Test func objectStreamMembersAccounted() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let ctrl = R37Build.hybrid("[]", bogus: false)
        #expect(unverifiable { try check(cf, ctrl, canonical: "h_arr_ctrl.pdf", archives: reader) },
                "\(outcome { try check(cf, ctrl, canonical: "h_arr_ctrl.pdf", archives: reader) })")
        let moved = R37Build.compressedTwice()
        #expect(unverifiable { try check(cf, moved, canonical: "moved.pdf", archives: reader) },
                "\(outcome { try check(cf, moved, canonical: "moved.pdf", archives: reader) })")
        let missing = R37Build.compressedMissingMember()
        #expect(unverifiable { try check(cf, missing, canonical: "missing.pdf", archives: reader) },
                "\(outcome { try check(cf, missing, canonical: "missing.pdf", archives: reader) })")
        #expect(outcome { try check(cf, PDFBuild.objectStreams(), canonical: "objstm.pdf", archives: reader) } == "clean")
        #expect(outcome { try check(cf, R37Build.compressedOnce(), canonical: "objstm2.pdf", archives: reader) } == "clean")
    }

    /// Breaker B-1 (Ruling 35 b; the class of Ruling 37): a view that mixes revisions. Each revision was walked on its own,
    /// but nothing required an object to resolve in the view that refers to it, so a reader that rebuilds a broken view by
    /// scanning the file (poppler) takes an object from another revision. The reviewer's files (re-review 5, `mk4.py`,
    /// `mk.py`) are rebuilt here:
    /// - `split.pdf`: revision A is a complete document holding object 8 (`/FlateDecode`); revision C (no `/Prev`) adds a
    ///   page whose content (the key, Flate) says `/Filter 8 0 R`, and its table leaves 8 out. `split_free.pdf`: C marks 8
    ///   free. Both read clean before (the key stayed compressed), while `pdftotext` prints it.
    /// - `norev.pdf` / `norev_notrailer.pdf`: a table naming 8 (with or without a trailer) that no `startxref` names, then the
    ///   only revision, whose table leaves 8 out.
    /// - `norev_chained.pdf` (the reviewer's `norev_ctrl.pdf`): that table reached by `/Prev` but still with no `startxref`
    ///   of its own: refused too (a table with no `startxref` is an anomaly, whatever names it).
    /// All refused with Ruling 35's refusal. Controls, the same files with a consistent chain (C's `/Prev` naming A; A ending
    /// with its own `startxref`): the key is caught.
    @Test func mixedRevisionViewsRefused() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        for (name, file) in [("split.pdf", SplitBuild.split(.split)), ("split_free.pdf", SplitBuild.split(.free)),
                             ("norev.pdf", SplitBuild.norev(.trailer)), ("norev_notrailer.pdf", SplitBuild.norev(.noTrailer)),
                             ("norev_chained.pdf", SplitBuild.norev(.chainedWithoutStartxref))] {
            #expect(!String(decoding: file, as: UTF8.self).contains(Self.aws))
            #expect(unverifiable { try check(cf, file, canonical: name, archives: reader) },
                    "\(name): \(outcome { try check(cf, file, canonical: name, archives: reader) })")
        }
        for (name, file) in [("split_ctrl.pdf", SplitBuild.split(.control)), ("norev_ctrl.pdf", SplitBuild.norev(.control))] {
            let caught = outcome { try check(cf, file, canonical: name, archives: reader) }
            #expect(caught.contains("looks like it contains a secret"), "\(name): \(caught)")
        }
    }

    /// Breaker B-1, rule by rule. Refused (Ruling 35's refusal), each read clean before:
    /// - a reference to an object past every number the file uses; to an object its view marks free; with the wrong
    ///   generation; one hidden after an `endobj` inside a string; one whose three tokens are split by comments; one with a
    ///   signed number (`+7 0 R`, which readers take as 7);
    /// - a cross-reference stream's update with no `/Prev` (the first stream off the chain);
    /// - a reference inside an object-stream member that resolves nowhere;
    /// - an object a later revision frees while its bytes stay (its revision's prefix holds a header that view doesn't
    ///   resolve); an object-stream member no cross-reference row names;
    /// - a `trailer` that belongs to no table on the chain.
    /// Controls read clean: three additive revisions; two additive cross-reference-stream revisions; a hybrid file (a
    /// table with `/XRefStm`); an object-stream file.
    @Test func everyReferenceResolvesInItsView() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let refused: [(String, Data)] = [
            ("past.pdf", SplitBuild.referring("<< /See 12 0 R >>")),
            ("free.pdf", SplitBuild.referring("<< /See 7 0 R >>")),
            ("generation.pdf", SplitBuild.referring("<< /See 5 1 R >>")),
            ("endobj.pdf", SplitBuild.referring("<< /T (a endobj b) /See 7 0 R >>")),
            ("comments.pdf", SplitBuild.referring("<< /See 7 % one\n0 % two\nR >>")),
            ("signed.pdf", SplitBuild.referring("<< /See +7 0 R >>")),
            ("streams_split.pdf", SplitBuild.additiveStreams(chained: false)),
            ("member.pdf", PDFBuild.objectStreams(hidden: "<< /See 12 0 R >>")),
            ("freed.pdf", SplitBuild.freedButLeft()),
            ("orphan.pdf", SplitBuild.orphanMember()),
            ("trailer.pdf", SplitBuild.strayTrailer()),
        ]
        for (name, file) in refused {
            #expect(unverifiable { try check(cf, file, canonical: name, archives: reader) },
                    "\(name): \(outcome { try check(cf, file, canonical: name, archives: reader) })")
        }
        let clean: [(String, Data)] = [
            ("three.pdf", SplitBuild.additive(3)),
            ("streams.pdf", SplitBuild.additiveStreams()),
            ("hybrid.pdf", SplitBuild.hybridOnce()),
            ("objstm.pdf", PDFBuild.objectStreams()),
            ("seen.pdf", SplitBuild.referring("<< /See 5 0 R >>")),
        ]
        for (name, file) in clean {
            #expect(outcome { try check(cf, file, canonical: name, archives: reader) } == "clean", "\(name)")
        }
    }

    /// C2b-carry (a), the last breaker review's Critical: a number padded with leading zeros is read in full, as poppler
    /// reads it (its lexer takes leading zeros without limit, and its table rebuild reads a header's number with atoi).
    /// The reviewer's `mkh.py` files, rebuilt here:
    /// - `hid_ref9.pdf`: the page content (the key, Flate) says `/Filter 0000000000008 0 R`, and `0000000008 0 obj
    ///   /FlateDecode endobj` sits in the body, named by no table row (`/Size 9`). The helper read it clean and `pdftotext`
    ///   printed the key.
    /// - `hid_gen9.pdf`: the generation padded instead (`/Filter 8 0000000000000 R`).
    /// - `hid_plainref9.pdf`: the plain reference to the same padded header (rule (b) refused it already; it still must).
    /// - a padded header placed after the real object of the same number (poppler's rebuild takes the last header for a
    ///   number), and a padded reference inside an object-stream member.
    /// All refused (Ruling 35's refusal). Controls (`lin_ok` and the rest in the tests above) are unchanged; here a padded
    /// reference to an object the table does name reads clean, as it reads the same for every reader.
    @Test func paddedNumbersRefused() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let refused: [(String, Data)] = [
            ("hid_ref9.pdf", PaddedBuild.hidden(filter: "0000000000008 0 R", header: "0000000008 0 obj")),
            ("hid_gen9.pdf", PaddedBuild.hidden(filter: "8 0000000000000 R", header: "0000000008 0 obj")),
            ("hid_plainref9.pdf", PaddedBuild.hidden(filter: "8 0 R", header: "0000000008 0 obj")),
            ("hid_ref_noh9.pdf", PaddedBuild.hidden(filter: "0000000000008 0 R", header: nil)),
            ("hid_after.pdf", PaddedBuild.paddedAfterReal()),
            ("member_padded.pdf", PDFBuild.objectStreams(hidden: "<< /See 0000000000012 0 R >>")),
            ("huge_ref.pdf", SplitBuild.referring("<< /See 99999999999999999999999 0 R >>")),
        ]
        for (name, file) in refused {
            #expect(!String(decoding: file, as: UTF8.self).contains(Self.aws))
            #expect(unverifiable { try check(cf, file, canonical: name, archives: reader) },
                    "\(name): \(outcome { try check(cf, file, canonical: name, archives: reader) })")
        }
        #expect(outcome { try check(cf, SplitBuild.referring("<< /See 0000000000005 0 R >>"), canonical: "padded_seen.pdf", archives: reader) }
                == "clean")
        let control = PaddedBuild.hidden(filter: "8 0 R", header: "8 0 obj", listed: true)
        let caught = outcome { try check(cf, control, canonical: "hid_ctrl.pdf", archives: reader) }
        #expect(caught.contains("looks like it contains a secret"), "\(caught)")
    }
}

/// C2b-carry (a): the last breaker review's `mkh.py`.
enum PaddedBuild {
    /// One revision: catalog, pages, a page whose content 4 (the key, Flate) says `/Filter <filter>`, a font, then (with
    /// `header`) object 8 `/FlateDecode` under that header text; the table names 1–5 (and 8 when `listed`), `/Size 9`.
    static func hidden(filter: String, header: String?, listed: Bool = false) -> Data {
        let secret = PDFBuild.zlib(Data("BT /F1 24 Tf 20 100 Td (\(SecretGateTests.aws)) Tj ET".utf8))
        var w = SplitBuild.Writer()
        w.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        w.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        w.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        w.obj(4, "<< /Length \(secret.count) /Filter \(filter) >>", stream: secret)
        w.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        if let header {
            w.offsets[8] = w.out.count
            w.out += Data("\(header)\n/FlateDecode\nendobj\n".utf8)
        }
        w.table(listed ? [1, 2, 3, 4, 5, 8] : [1, 2, 3, 4, 5], size: 9)
        return w.out
    }

    /// `SplitBuild.referring` with a clean object 6, then `0000000006 0 obj` (a note whose string, hex, holds the key) after
    /// it, named by no row: the lexer saw no header there, poppler's rebuild takes it for object 6.
    static func paddedAfterReal() -> Data {
        var w = SplitBuild.Writer()
        w.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        w.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        w.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        let clean = PDFBuild.zlib(PDFBuild.text("hello"))
        w.obj(4, "<< /Length \(clean.count) /Filter /FlateDecode >>", stream: clean)
        w.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        w.obj(6, "<< /Note (real) >>")
        let hex = Data(SecretGateTests.aws.utf8).map { String(format: "%02X", $0) }.joined()
        w.out += Data("0000000006 0 obj\n<< /Note <\(hex)> >>\nendobj\n".utf8)
        w.table([1, 2, 3, 4, 5, 6], size: 7)
        return w.out
    }
}

/// Breaker B-1: the reviewer's `mk4.py` (split) and `mk.py` (norev) of re-review 5, and the rule-by-rule files.
enum SplitBuild {
    /// A file written object by object, with the offsets kept.
    struct Writer {
        var out = R37Build.head
        var offsets: [Int: Int] = [:]

        mutating func obj(_ n: Int, _ body: String, stream: Data? = nil) {
            offsets[n] = out.count
            if let stream {
                out += Data("\(n) 0 obj\n\(body)\nstream\n".utf8) + stream + Data("\nendstream\nendobj\n".utf8)
            } else {
                out += Data("\(n) 0 obj\n\(body)\nendobj\n".utf8)
            }
        }

        /// A classic table, one subsection per number (`free` marked free), then the trailer and `startxref` (each left
        /// out when asked). Returns the table's offset.
        @discardableResult
        mutating func table(_ numbers: [Int], size: Int, free: [Int] = [], prev: Int? = nil, root: Int = 1, trailer: Bool = true,
                            startxref: Bool = true) -> Int {
            let x = out.count
            var t = "xref\n0 1\n0000000000 65535 f \n"
            for n in Set(numbers).union(free).sorted() {
                t += free.contains(n) ? "\(n) 1\n0000000000 00001 f \n" : "\(n) 1\n\(PDFBuild.pad10(offsets[n]!)) 00000 n \n"
            }
            if trailer { t += "trailer\n<< /Size \(size) /Root \(root) 0 R" + (prev.map { " /Prev \($0)" } ?? "") + " >>\n" }
            if startxref { t += "startxref\n\(x)\n%%EOF\n" }
            out += Data(t.utf8)
            return x
        }
    }

    enum Split { case split, free, control }

    /// `split.pdf`: revision A a complete document (a blank page, object 8 `/FlateDecode`); revision C a new catalog,
    /// pages and page 7 whose content 4 (the key, Flate) says `/Filter 8 0 R`, its table without 8 and without `/Prev`
    /// (`free`: 8 marked free; `control`: `/Prev` naming A).
    static func split(_ variant: Split) -> Data {
        let secret = PDFBuild.zlib(Data("BT /F1 24 Tf 20 100 Td (\(SecretGateTests.aws)) Tj ET".utf8))
        var w = Writer()
        w.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        w.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        w.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 200] /Contents 6 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        w.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        w.obj(6, "<< /Length 0 >>", stream: Data())
        w.obj(8, "/FlateDecode")
        let a = w.table([1, 2, 3, 5, 6, 8], size: 9)
        w.obj(4, "<< /Length \(secret.count) /Filter 8 0 R >>", stream: secret)
        w.obj(7, "<< /Type /Page /Parent 9 0 R /MediaBox [0 0 600 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        w.obj(9, "<< /Type /Pages /Kids [7 0 R] /Count 1 >>")
        w.obj(10, "<< /Type /Catalog /Pages 9 0 R >>")
        w.table([4, 5, 7, 9, 10], size: 11, free: variant == .free ? [8] : [], prev: variant == .control ? a : nil, root: 10)
        return w.out
    }

    enum Norev { case trailer, noTrailer, chainedWithoutStartxref, control }

    /// `norev.pdf`: one page whose content 4 (the key, Flate) says `/Filter 8 0 R`; a first table naming 8 that no
    /// `startxref` names (with a trailer, or none), then the file's only revision, its table without 8.
    /// `chainedWithoutStartxref`: the last table's `/Prev` names the first, which still has no `startxref` of its own (the
    /// reviewer's `norev_ctrl.pdf`). `control`: the first table ends with its own `startxref`, and the last names it.
    static func norev(_ variant: Norev) -> Data {
        let secret = PDFBuild.zlib(Data("BT /F1 24 Tf 20 100 Td (\(SecretGateTests.aws)) Tj ET".utf8))
        var w = Writer()
        w.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        w.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        w.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        w.obj(4, "<< /Length \(secret.count) /Filter 8 0 R >>", stream: secret)
        w.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        w.obj(8, "/FlateDecode")
        let a = w.table([1, 2, 3, 4, 5, 8], size: 9, trailer: variant != .noTrailer, startxref: variant == .control)
        let chained = variant == .control || variant == .chainedWithoutStartxref
        w.table([1, 2, 3, 4, 5], size: chained ? 9 : 6, prev: chained ? a : nil)
        return w.out
    }

    /// One revision: catalog, pages, a page (content 4, font 5) and object 6 `body`; its table names 1–6 and marks 7 free.
    static func referring(_ body: String) -> Data {
        var w = Writer()
        w.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        w.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        w.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        let clean = PDFBuild.zlib(PDFBuild.text("hello"))
        w.obj(4, "<< /Length \(clean.count) /Filter /FlateDecode >>", stream: clean)
        w.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        w.obj(6, body)
        w.table([1, 2, 3, 4, 5, 6], size: 8, free: [7])
        return w.out
    }

    /// `referring` with a clean object 6, then an update that marks 6 free and leaves its bytes.
    static func freedButLeft() -> Data {
        var w = Writer()
        w.out = Data()
        let first = referring("<< /Note (soon freed) >>")
        w.out = first
        let previous = PDFBuild.lastStartxref(first)
        w.table([], size: 8, free: [6], prev: previous)
        return w.out
    }

    /// `n` additive revisions (`RevisionBuild`), each after the first adding one note.
    static func additive(_ n: Int) -> Data {
        typealias B = RevisionBuild
        var file = B.build(B.base(B.stream(4, PDFBuild.zlib(PDFBuild.text("hello")))))
        for k in 1..<n {
            file = B.update(file, objects: [B.obj(5 + k, "<< /Note (revision \(k)) >>")], entries: [(5 + k, 0, { $0[0] })], size: 6 + k)
        }
        return file.data
    }

    /// Two revisions of cross-reference streams: `R37Build.compressedBase`, then an update adding object 9 (`chained`: its
    /// cross-reference stream's `/Prev` names the first; else it has none, and the first is off the chain).
    static func additiveStreams(chained: Bool = true) -> Data {
        let a = R37Build.compressedBase()
        var out = a.data
        let o9 = out.count
        out += R37Build.obj(9, "<< /Note (two) >>")
        let o11 = out.count
        out += R37Build.xrefStream(11, [9: R37Build.row(1, o9, 0), 11: R37Build.row(1, o11, 0)], size: 12, prev: chained ? a.xref : nil)
        out += Data("startxref\n\(o11)\n%%EOF\n".utf8)
        return out
    }

    /// One revision, hybrid: a classic table naming 1–5, object stream 6 and cross-reference stream 7 (the trailer's
    /// `/XRefStm`), which names 8 as a member of 6 and 6 and 7 themselves; 3 refers to 8.
    static func hybridOnce() -> Data {
        var w = Writer()
        w.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        w.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        w.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Note 8 0 R >>")
        let clean = PDFBuild.zlib(PDFBuild.text("hello"))
        w.obj(4, "<< /Length \(clean.count) /Filter /FlateDecode >>", stream: clean)
        w.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        w.offsets[6] = w.out.count
        w.out += R37Build.objectStream(6, [(8, "<< /Note (member) >>")])
        let o7 = w.out.count
        w.offsets[7] = o7
        w.out += R37Build.xrefStream(7, [6: R37Build.row(1, w.offsets[6]!, 0), 7: R37Build.row(1, o7, 0), 8: R37Build.row(2, 6, 0)],
                                     size: 9, prev: nil)
        let x = w.out.count
        var t = "xref\n0 6\n0000000000 65535 f \n"
        for n in 1...5 { t += PDFBuild.pad10(w.offsets[n]!) + " 00000 n \n" }
        t += "trailer\n<< /Size 9 /Root 1 0 R /XRefStm \(o7) >>\nstartxref\n\(x)\n%%EOF\n"
        w.out += Data(t.utf8)
        return w.out
    }

    /// `R37Build.compressedBase` with its object stream also holding object 9, which no row names.
    static func orphanMember() -> Data {
        let clean = R37Build.content("hello")
        var out = R37Build.head, offsets: [Int: Int] = [:]
        for (n, body) in R37Build.page { offsets[n] = out.count; out += R37Build.obj(n, body) }
        offsets[4] = out.count
        out += R37Build.obj(4, Data("<< /Filter /FlateDecode /Length \(clean.count) >>\nstream\n".utf8) + clean + Data("\nendstream".utf8))
        offsets[6] = out.count
        out += R37Build.objectStream(6, [(8, "<< /Note (named) >>"), (9, "<< /Note (orphan) >>")])
        let xref = out.count
        var entries: [Int: Data] = [8: R37Build.row(2, 6, 0), 7: R37Build.row(1, xref, 0)]
        for (n, o) in offsets { entries[n] = R37Build.row(1, o, 0) }
        out += R37Build.xrefStream(7, entries, size: 10, prev: nil)
        out += Data("startxref\n\(xref)\n%%EOF\n".utf8)
        return out
    }

    /// `referring` (a clean object 6) with a `trailer` naming another root between objects 5 and 6 (no table owns it).
    static func strayTrailer() -> Data {
        var w = Writer()
        w.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        w.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        w.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        let clean = PDFBuild.zlib(PDFBuild.text("hello"))
        w.obj(4, "<< /Length \(clean.count) /Filter /FlateDecode >>", stream: clean)
        w.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        w.out += Data("trailer\n<< /Size 8 /Root 6 0 R >>\n".utf8)
        w.obj(6, "<< /Type /Catalog /Pages 2 0 R >>")
        w.table([1, 2, 3, 4, 5, 6], size: 7)
        return w.out
    }
}

/// The reviewer's `r37*.py` (re-review 4) in Swift.
enum R37Build {
    static let head = Data("%PDF-1.7\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
    static func obj(_ n: Int, _ body: Data) -> Data { RevisionBuild.obj(n, body) }
    static func obj(_ n: Int, _ body: String) -> Data { RevisionBuild.obj(n, body) }
    static func pad(_ n: Int) -> String { PDFBuild.pad10(n) }
    static func content(_ secret: String) -> Data { PDFBuild.zlib(Data("BT /F1 12 Tf 10 100 Td (\(secret)) Tj ET".utf8)) }

    static let page: [(Int, String)] = [
        (1, "<< /Type /Catalog /Pages 2 0 R >>"), (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"),
        (5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
    ]

    /// Revision A: objects 1–5 and 8 (`/FlateDecode`), object 4 the page content under `/Filter 8 0 R`; a classic table of
    /// 0–8 (6 and 7 free); `startxref 0` when `bogus`.
    static func revisionA(bogus: Bool) -> (data: Data, xref: Int, offsets: [Int: Int]) {
        let secret = content(SecretGateTests.aws)
        var parts: [Int: Data] = [:]
        for (n, body) in page { parts[n] = obj(n, body) }
        parts[4] = obj(4, Data("<< /Filter 8 0 R /Length \(secret.count) >>\nstream\n".utf8) + secret + Data("\nendstream".utf8))
        parts[8] = obj(8, "/FlateDecode")
        var out = head, offsets: [Int: Int] = [:]
        for n in parts.keys.sorted() { offsets[n] = out.count; out += parts[n]! }
        let xref = out.count
        var table = "xref\n0 9\n0000000000 65535 f \n"
        for n in 1...8 { table += offsets[n].map { pad($0) + " 00000 n \n" } ?? "0000000000 00001 f \n" }
        table += "trailer\n<< /Size 9 /Root 1 0 R >>\nstartxref\n\(bogus ? 0 : xref)\n%%EOF\n"
        return (out + Data(table.utf8), xref, offsets)
    }

    /// `noprev.pdf`: revision A, then a full table of 1–5 with no `/Prev`.
    static func noPrev(bogus: Bool) -> Data {
        let a = revisionA(bogus: bogus)
        var table = "xref\n0 6\n0000000000 65535 f \n"
        for n in 1...5 { table += pad(a.offsets[n]!) + " 00000 n \n" }
        table += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(a.data.count)\n%%EOF\n"
        return a.data + Data(table.utf8)
    }

    /// `h_<value>.pdf`: revision A, then a hybrid update (a classic table with `/XRefStm`) moving object 8 into object stream
    /// 10 as `value`.
    static func hybrid(_ value: String, bogus: Bool) -> Data {
        let a = revisionA(bogus: bogus)
        var out = a.data
        let header = "8 0 ", body = Data((header + value).utf8)
        let o10 = out.count
        out += obj(10, Data("<< /Type /ObjStm /N 1 /First \(header.utf8.count) /Length \(body.count) >>\nstream\n".utf8) + body + Data("\nendstream".utf8))
        let o11 = out.count
        let rows = row(2, 10, 0)
        out += obj(11, Data("<< /Type /XRef /Size 12 /Index [8 1] /W [1 4 2] /Length \(rows.count) >>\nstream\n".utf8) + rows + Data("\nendstream".utf8))
        let xc = out.count
        out += Data(("xref\n0 1\n0000000000 65535 f \n10 2\n\(pad(o10)) 00000 n \n\(pad(o11)) 00000 n \n"
                     + "trailer\n<< /Size 12 /Root 1 0 R /Prev \(a.xref) /XRefStm \(o11) >>\nstartxref\n\(xc)\n%%EOF\n").utf8)
        return out
    }

    static func row(_ type: Int, _ f2: Int, _ f3: Int) -> Data {
        Data([UInt8(type), UInt8((f2 >> 24) & 0xFF), UInt8((f2 >> 16) & 0xFF), UInt8((f2 >> 8) & 0xFF), UInt8(f2 & 0xFF),
              UInt8((f3 >> 8) & 0xFF), UInt8(f3 & 0xFF)])
    }

    /// A cross-reference stream object `n` naming `entries` (number → row), in contiguous `/Index` runs.
    static func xrefStream(_ n: Int, _ entries: [Int: Data], size: Int, prev: Int?) -> Data {
        var index: [(Int, Int)] = [], rows = Data()
        for k in entries.keys.sorted() {
            if let last = index.last, last.0 + last.1 == k { index[index.count - 1].1 += 1 } else { index.append((k, 1)) }
            rows += entries[k]!
        }
        let runs = index.map { "\($0.0) \($0.1)" }.joined(separator: " ")
        return obj(n, Data(("<< /Type /XRef /Size \(size) /Index [\(runs)] /W [1 4 2] /Root 1 0 R"
                            + (prev.map { " /Prev \($0)" } ?? "") + " /Length \(rows.count) >>\nstream\n").utf8) + rows + Data("\nendstream".utf8))
    }

    /// An object stream `n` holding `members` (number, body).
    static func objectStream(_ n: Int, _ members: [(Int, String)]) -> Data {
        var header = "", body = ""
        for (m, o) in members { header += "\(m) \(body.utf8.count) "; body += o + "\n" }
        let data = Data((header + body).utf8)
        return obj(n, Data("<< /Type /ObjStm /N \(members.count) /First \(header.utf8.count) /Length \(data.count) >>\nstream\n".utf8)
                   + data + Data("\nendstream".utf8))
    }

    /// One revision: objects 1–5 (4 a clean content stream), object stream 6 holding object 8, cross-reference stream 7
    /// naming 8 as member `index` of 6. Returns the file and its cross-reference stream's offset.
    static func compressedBase(index: Int = 0) -> (data: Data, xref: Int, offsets: [Int: Int]) {
        let clean = content("hello")
        var out = head, offsets: [Int: Int] = [:]
        for (n, body) in page { offsets[n] = out.count; out += obj(n, body) }
        offsets[4] = out.count
        out += obj(4, Data("<< /Filter /FlateDecode /Length \(clean.count) >>\nstream\n".utf8) + clean + Data("\nendstream".utf8))
        offsets[6] = out.count
        out += objectStream(6, [(8, "<< /Note (first) >>")])
        let xref = out.count
        var entries: [Int: Data] = [8: row(2, 6, index), 7: row(1, xref, 0)]
        for (n, o) in offsets { entries[n] = row(1, o, 0) }
        out += xrefStream(7, entries, size: 9, prev: nil)
        out += Data("startxref\n\(xref)\n%%EOF\n".utf8)
        return (out, xref, offsets)
    }

    /// Control: the base alone.
    static func compressedOnce() -> Data { compressedBase().data }

    /// Object 8 a member of object stream 6 in revision A and of object stream 9 in revision B.
    static func compressedTwice() -> Data {
        let a = compressedBase()
        var out = a.data
        let o9 = out.count
        out += objectStream(9, [(8, "<< /Note (second) >>")])
        let o11 = out.count
        out += xrefStream(11, [8: row(2, 9, 0), 9: row(1, o9, 0), 11: row(1, o11, 0)], size: 12, prev: a.xref)
        out += Data("startxref\n\(o11)\n%%EOF\n".utf8)
        return out
    }

    /// Object 8 named as member 5 of an object stream that holds one.
    static func compressedMissingMember() -> Data { compressedBase(index: 5).data }

    /// Revision 1 a clean page; revision 2 adds object 6 (the key, Flate, `/Length 7 0 R`) and 7 (its length), its table
    /// exact but its `startxref` 0; with `thirdRevision`, a third revision adds object 9, its `/Prev` naming revision 2's
    /// table.
    static func indirectLength(thirdRevision: Bool) -> Data {
        let one = RevisionBuild.build(RevisionBuild.base(RevisionBuild.stream(4, content("hello"))))
        var out = one.data
        let secret = content("key \(SecretGateTests.aws)")
        let o6 = out.count
        out += obj(6, Data("<< /Filter /FlateDecode /Length 7 0 R >>\nstream\n".utf8) + secret + Data("\nendstream".utf8))
        let o7 = out.count
        out += obj(7, "\(secret.count)")
        let x2 = out.count
        out += Data(("xref\n0 1\n0000000000 65535 f \n6 2\n\(pad(o6)) 00000 n \n\(pad(o7)) 00000 n \n"
                     + "trailer\n<< /Size 8 /Root 1 0 R /Prev \(one.xref) >>\nstartxref\n0\n%%EOF\n").utf8)
        guard thirdRevision else { return out }
        let o9 = out.count
        out += obj(9, "<< /Producer (three) >>")
        let x3 = out.count
        out += Data(("xref\n0 1\n0000000000 65535 f \n9 1\n\(pad(o9)) 00000 n \n"
                     + "trailer\n<< /Size 10 /Root 1 0 R /Prev \(x2) >>\nstartxref\n\(x3)\n%%EOF\n").utf8)
        return out
    }
}

/// Linearized PDFs built as Acrobat-style writers lay them out (PDF 32000-1, Annex F): the linearization dictionary first,
/// then the first-page cross-reference section and trailer (`startxref 0`), the hint stream, the objects, and the main
/// section, whose `startxref` names the first-page section. Numbers: 1 an info dictionary (main section), 2 the
/// linearization dictionary, 3–7 the catalog, pages, page, content and font, 8 the hint stream (first-page section).
enum LinearizedBuild {
    static let realLinearized = [
        "/System/Library/Audio/MIDI Devices/Generic/Images/Interface1.pdf",
        "/System/Library/Audio/MIDI Devices/Generic/Images/InterfaceMIDI2.pdf",
        "/System/Library/Audio/MIDI Devices/Generic/Images/KeyboardMIDI2.pdf",
        "/Applications/Xcode.app/Contents/Resources/en.lproj/License.pdf",
        "/Library/Developer/DeviceKit/FramebufferMasks/1D05B7BF-7313-48A6-B2DF-964AAE76A0DC.pdf",
        "/Applications/Compressor Creator Studio.app/Contents/Resources/Icon_ChainedJobs.pdf",
    ]

    static func p10(_ v: Int) -> String { PDFBuild.pad10(v) }

    static func build(content: String = "BT /F1 12 Tf 10 100 Td (hello) Tj ET", length: Int? = nil, extraInFirstSection: Bool = false,
                      freeInFirstSection: Int? = nil) -> Data {
        let z = PDFBuild.zlib(Data(content.utf8))
        var lValue = 0, hOffset = 0, hLength = 0, mainXref = 0
        var result = Data()
        for _ in 0..<3 {
            var out = R37Build.head
            let lin = RevisionBuild.obj(2, "<< /Linearized 1 /L \(p10(length ?? lValue)) /H [ \(p10(hOffset)) \(p10(hLength)) ] /O 5 "
                                           + "/E 0000000000 /N 1 /T \(p10(mainXref)) >>")
            out += lin
            var extra = Data()
            if extraInFirstSection { extra = RevisionBuild.obj(9, "/FlateDecode") }
            let extraOffset = out.count
            out += extra
            let firstXref = out.count
            let count = extraInFirstSection ? 8 : 7
            let tableLength = "xref\n2 \(count)\n".utf8.count + count * 20
                + "trailer\n<< /Size \(extraInFirstSection ? 10 : 9) /Root 3 0 R /Prev \(p10(0)) >>\nstartxref\n0\n%%EOF\n".utf8.count
            var offsets: [Int: Int] = [2: R37Build.head.count]
            if extraInFirstSection { offsets[9] = extraOffset }
            var cursor = firstXref + tableLength
            var body = Data()
            let hint = RevisionBuild.obj(8, Data("<< /Length 4 /S 0 >>\nstream\n".utf8) + Data([0, 0, 0, 0]) + Data("\nendstream".utf8))
            offsets[8] = cursor; body += hint; cursor += hint.count
            let objects: [(Int, Data)] = [
                (3, Data("<< /Type /Catalog /Pages 4 0 R >>".utf8)), (4, Data("<< /Type /Pages /Kids [5 0 R] /Count 1 >>".utf8)),
                (5, Data("<< /Type /Page /Parent 4 0 R /MediaBox [0 0 300 200] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>".utf8)),
                (6, Data("<< /Filter /FlateDecode /Length \(z.count) >>\nstream\n".utf8) + z + Data("\nendstream".utf8)),
                (7, Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)),
                (1, Data("<< /Producer (linearized) >>".utf8)),
            ]
            for (n, d) in objects { let o = RevisionBuild.obj(n, d); offsets[n] = cursor; body += o; cursor += o.count }
            var table = "xref\n2 \(count)\n"
            for n in 2...(extraInFirstSection ? 9 : 8) {
                table += n == freeInFirstSection ? "0000000000 00001 f \n" : p10(offsets[n]!) + " 00000 n \n"
            }
            table += "trailer\n<< /Size \(extraInFirstSection ? 10 : 9) /Root 3 0 R /Prev \(p10(cursor)) >>\nstartxref\n0\n%%EOF\n"
            out += Data(table.utf8)
            out += body
            mainXref = out.count
            // The main section; an object the first-page section frees is listed here in use.
            let freed = freeInFirstSection.map { "\($0) 1\n\(p10(offsets[$0]!)) 00000 n \n" } ?? ""
            out += Data(("xref\n0 2\n0000000000 65535 f \n\(p10(offsets[1]!)) 00000 n \n\(freed)trailer\n<< /Size \(extraInFirstSection ? 10 : 9) >>\n"
                         + "startxref\n\(firstXref)\n%%EOF\n").utf8)
            // `/H`: the hint stream's offset and length, through the end of line after its `endobj`.
            lValue = out.count; hOffset = offsets[8]!; hLength = hint.count
            result = out
        }
        return result
    }

    /// `linearized` plus an incremental update adding object 9.
    static func updated(_ linearized: Data) -> Data {
        var out = linearized
        let o9 = out.count
        out += RevisionBuild.obj(9, "<< /Producer (edited) >>")
        let x = out.count
        let previous = EmbeddedContentTests.lastStartxrefValue(linearized)
        out += Data(("xref\n0 1\n0000000000 65535 f \n9 1\n\(p10(o9)) 00000 n \ntrailer\n<< /Size 10 /Root 3 0 R /Prev \(previous) >>\n"
                     + "startxref\n\(x)\n%%EOF\n").utf8)
        return out
    }
}

extension EmbeddedContentTests {
    /// The offset the last `startxref` of `pdf` names.
    static func lastStartxrefValue(_ pdf: Data) -> Int { PDFBuild.lastStartxref(pdf) }
}
