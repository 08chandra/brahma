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
