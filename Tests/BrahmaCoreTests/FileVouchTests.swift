import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A PDF reader whose helper found a structural anomaly but read everything it could (`UnverifiedPDF`): the parts it read.
/// C2b-carry (c): it flattens too (`copyParts` nil: it can't), into a stand-in copy (`copyMark` and the original's hash)
/// that it then reads as a verified PDF holding `copyParts`.
struct UnverifiedPDFReader: ArchiveReader {
    var parts: [PDFPart]
    var copyParts: [PDFPart]? = [PDFPart(kind: .pageText, data: Data("hello".utf8))]
    static let copyMark = Data("%PDF-1.3 the flattened copy of ".utf8)

    func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
        throw ArchiveReadError.unavailable
    }

    func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] {
        if data.starts(with: Self.copyMark), let copyParts { return copyParts }
        throw UnverifiedPDF(parts: parts)
    }

    func flattenPDF(of data: Data, maxBytes: Int, timeout: Duration) throws -> Data {
        guard copyParts != nil else { throw SandboxedPDFReader.flattenFailed }
        return Self.copyMark + Data(SHA256.hex(data).utf8)
    }
}

/// C2b fix round 5 (controller Ruling 38, R5-3): the owner's path for a file the gate refuses for its STRUCTURE (a PDF whose
/// structure couldn't be verified, a format or archive method the engine can't scan). The owner vouches for that exact file
/// (`brahma vouch file <company> <path>`, owner-gated like `brahma vouch restore`, or the refusal alert's Inbox action);
/// the vouch is pinned to the bytes' SHA-256, the company and the ref's canonical name. A vouched file passes the structure
/// refusals only: every byte the gate can read is still scanned (a stored value or a secret pattern in it refuses as
/// before), taint is untouched, and any change to the bytes ends the vouch. The refusal names the exact command.
@Suite(.scratch) struct FileVouchTests {
    static let known = SecretGateTests.known
    static let value = SecretGateTests.value

    /// The suffix every structure refusal ends with: the exact command for `canonical` in `company`, naming the refused
    /// bytes' full sha256 (breaker B-2, Ruling 40 (B-4): all 64 hex digits, which the command requires).
    static func command(_ company: Company, _ canonical: String, _ data: Data) -> String {
        " — the owner can vouch for this exact file: brahma vouch file \(company.slug) --id \(Store.canonicalHash(canonical)) --sha256 "
            + "\(SHA256.hex(data)) \(SecretGate.shellQuoted(canonical))"
    }

    /// `error` without the vouch command for `canonical` in `company` (for `data`) when it ends with exactly that command
    /// (the tests of the refusals themselves compare the rest).
    static func withoutCommand(_ error: WorkError, _ company: Company, _ canonical: String, _ data: Data) -> WorkError {
        let suffix = command(company, canonical, data)
        guard case .invalid(let message) = error, message.hasSuffix(suffix) else { return error }
        return .invalid(String(message.dropLast(suffix.count)))
    }

    /// The gate's verdict for what is served for `data` (C2b-carry (c): `Store.gatedBytes`, which serves a vouched PDF as its
    /// flattened copy and never the original).
    func check(_ cf: CollabFixture, _ data: Data, ext: String = "pdf", canonical: String = "doc.pdf", companyId: String? = nil,
               archives: any ArchiveReader) throws -> ScanVerdict {
        let served = try cf.store.gatedBytes(data, ext: ext, canonical: canonical, companyId: companyId ?? cf.c.id, archives: archives,
                                             knownValues: Self.known, paths: cf.paths)
        #expect(served.data != data || !served.isFlattenedCopy, "a flattened copy is the original")
        if served.isFlattenedCopy { #expect(!served.data.contains(data), "the original went out inside the copy") }
        return served.verdict
    }

    func outcome(_ body: () throws -> ScanVerdict) -> String {
        do { return "\(try body())" } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    func vouchRows(_ cf: CollabFixture, _ companyId: String) throws -> [Row] {
        try cf.store.writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM fileVouch WHERE companyId = ?", arguments: [companyId]) }
    }

    /// A PDF with one structural anomaly (object 5 rewritten by an update) and, when given, object 6 holding `hidden` under
    /// FlateDecode (seen only decoded).
    static func anomalous(hidden: String? = nil) -> Data {
        typealias B = RevisionBuild
        let base = B.build(B.base(B.stream(4, PDFBuild.zlib(PDFBuild.text("hello")))))
        var objects = [B.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>")]
        var entries: [(Int, Int, ([Int]) -> Int)] = [(5, 0, { $0[0] })]
        if let hidden {
            objects.append(B.stream(6, PDFBuild.zlib(Data(hidden.utf8))))
            entries.append((6, 0, { $0[1] }))
        }
        return B.update(base, objects: objects, entries: entries, size: 7).data
    }

    /// The refusal names the exact command; the gate records the refused bytes and alerts the owner (once while open); the
    /// owner's vouch (pinned to the bytes) lets the same bytes past the structure check with the real helper, and every
    /// part it read is still scanned: a stored value or a secret pattern seen only decoded still refuses. A changed byte
    /// is refused again; company B's same bytes are not vouched; the vouch touches no taint.
    @Test func vouchedFileSkipsOnlyTheStructureRefusal() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let file = Self.anomalous()
        let refused = outcome { try check(cf, file, archives: reader) }
        #expect(refused == "this PDF's structure couldn't be verified" + Self.command(cf.c, "doc.pdf", file), "\(refused)")
        let rows = try vouchRows(cf, cf.c.id)
        #expect(rows.count == 1 && (rows.first?["sha256"] as String?) == SHA256.hex(file) && (rows.first?["vouchedAt"] as Date?) == nil)
        let cId = cf.c.id
        let alerts = { try cf.store.writer.read { db in
            try Ask.fetchAll(db, sql: "SELECT * FROM ask WHERE companyId = ? AND kind = 'engineAlert' AND status = 'pendingOwner'", arguments: [cId])
        } }
        #expect(try alerts().filter { Store.isFileVouchAlert($0) }.count == 1)
        // A second refusal of the same bytes raises no second alert.
        _ = outcome { try check(cf, file, archives: reader) }
        #expect(try alerts().filter { Store.isFileVouchAlert($0) }.count == 1)
        let taintBefore = try dumpTaint(cf)

        let vouch = try cf.store.vouchFile(companyId: cId, canonical: "doc.pdf", sha256: Self.full(file), now: cf.now)
        #expect(vouch.sha256 == SHA256.hex(file))
        #expect(outcome { try check(cf, file, archives: reader) } == "clean")
        #expect(try alerts().filter { Store.isFileVouchAlert($0) }.isEmpty, "the refusal alert is still open after the vouch")
        let lines = try cf.store.events(afterId: 0, companyId: cId).map(\.text)
        #expect(lines.contains { $0.contains("Owner vouched for doc.pdf") }, "\(lines)")
        #expect(try dumpTaint(cf) == taintBefore, "the vouch changed taint")

        // Any byte changed: no longer vouched.
        let changed = file + Data("% one more byte\n".utf8)
        #expect(outcome { try check(cf, changed, archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
        // Another canonical name, or the same name and bytes in company B: not vouched.
        #expect(outcome { try check(cf, file, canonical: "other.pdf", archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
        let other = outcome { try check(cf, file, companyId: cf.fx.d.id, archives: reader) }
        #expect(other == "this PDF's structure couldn't be verified" + Self.command(cf.fx.d, "doc.pdf", file), "\(other)")

        // C2b-carry (c), Ruling 42: what is served is the flattened copy of the visible pages. A stored value or a secret
        // pattern in an object no page draws is not in it (and the original, which holds it, is never served).
        for (name, hidden) in [("value.pdf", "key \(Self.value)"), ("pattern.pdf", "key \(SecretGateTests.aws)")] {
            let pdf = Self.anomalous(hidden: hidden)
            #expect(!String(decoding: pdf, as: UTF8.self).contains(hidden))
            #expect(outcome { try check(cf, pdf, canonical: name, archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
            _ = try cf.store.vouchFile(companyId: cId, canonical: name, sha256: Self.full(pdf), now: cf.now)
            let served = try cf.store.gatedBytes(pdf, ext: "pdf", canonical: name, companyId: cId, archives: reader, knownValues: Self.known,
                                                 paths: cf.paths)
            #expect(served.isFlattenedCopy && served.data != pdf && served.verdict == .clean, "\(name)")
            let parts = try reader.pdfParts(of: served.data, maxBytes: 16_000_000, timeout: .seconds(60))
            #expect(!parts.contains { String(decoding: $0.data, as: UTF8.self).contains(hidden) }, "\(name): the hidden object is in the copy")
            #expect(outcome { try SecretGate.check(pdf, ext: "pdf", canonical: name, archives: reader, knownValues: Self.known, store: cf.store,
                                                   companyId: cId) }.contains("only its flattened copy"))
        }
    }

    /// The same rule without the helper: the parts an unverified read returns are scanned once the file is vouched (and
    /// refused before); bytes compressed in a format the engine can't open (gzip) pass once vouched, their own bytes still
    /// scanned; an archive with a member it can't decode (encrypted) passes once vouched, the members it can read scanned.
    @Test func vouchCoversFormatsAndArchives() throws {
        let cf = try CollabFixture()
        let cId = cf.c.id
        let clean = UnverifiedPDFReader(parts: [PDFPart(kind: .decodedStream, data: Data("hello".utf8))])
        let pdf = Data("%PDF-1.7 a file the helper flagged".utf8)
        #expect(outcome { try check(cf, pdf, archives: clean) } == "this PDF's structure couldn't be verified" + Self.command(cf.c, "doc.pdf", pdf))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "doc.pdf", sha256: Self.full(pdf), now: cf.now)
        #expect(outcome { try check(cf, pdf, archives: clean) } == "clean")
        // (Other bytes: verdicts are cached by the bytes, and a real reader reads the same bytes the same way.)
        let held = Data("%PDF-1.7 another flagged file".utf8)
        let holding = UnverifiedPDFReader(parts: [PDFPart(kind: .decodedStream, data: Data("key \(Self.value)".utf8))],
                                          copyParts: [PDFPart(kind: .pageText, data: Data("key \(Self.value)".utf8))])
        #expect(outcome { try check(cf, held, canonical: "held.pdf", archives: holding) }.hasPrefix("this PDF's structure couldn't be verified"))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "held.pdf", sha256: Self.full(held), now: cf.now)
        #expect(outcome { try check(cf, held, canonical: "held.pdf", archives: holding) }.contains("contains a stored secret"))

        let gz = Data([0x1F, 0x8B, 0x08, 0x00]) + Data("compressed bytes".utf8)
        let gzRefusal = "logs.gz is compressed as gzip, which can't be scanned for secrets; share the files inside instead"
        #expect(outcome { try check(cf, gz, ext: "gz", canonical: "logs.gz", archives: UnavailableArchiveReader()) }
                == gzRefusal + Self.command(cf.c, "logs.gz", gz))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "logs.gz", sha256: Self.full(gz), now: cf.now)
        #expect(outcome { try check(cf, gz, ext: "gz", canonical: "logs.gz", archives: UnavailableArchiveReader()) } == "clean")
        let gzKey = Data([0x1F, 0x8B, 0x08, 0x00]) + Data(" key \(SecretGateTests.aws) ".utf8)
        #expect(outcome { try check(cf, gzKey, ext: "gz", canonical: "key.gz", archives: UnavailableArchiveReader()) }.hasPrefix("key.gz is compressed as gzip"))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "key.gz", sha256: Self.full(gzKey), now: cf.now)
        // (C2b-carry fix round 1, F2: the serve-bytes API refuses a pattern in bytes that can't be redacted.)
        #expect(outcome { try check(cf, gzKey, ext: "gz", canonical: "key.gz", archives: UnavailableArchiveReader()) }
                    .contains("looks like it contains a secret"))

        // The stored member's bytes are a stand-in of the same length; the reader hands back what it would inflate.
        let zip = try SecretGateTests.zip {
            $0.add("secret.bin", "cipher text", flags: 1)
            $0.add("readme.txt", "key " + String(repeating: "x", count: Self.value.count))
        }
        let members = StubArchiveReader(members: [("readme.txt", Data("key \(Self.value)".utf8))])
        let method = "this archive uses compression or encryption that can't be scanned for secrets"
        #expect(outcome { try check(cf, zip, ext: "zip", canonical: "bundle.zip", archives: members) } == method + Self.command(cf.c, "bundle.zip", zip))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "bundle.zip", sha256: Self.full(zip), now: cf.now)
        #expect(outcome { try check(cf, zip, ext: "zip", canonical: "bundle.zip", archives: members) }.contains("contains a stored secret"))
        let cleanZip = try SecretGateTests.zip {
            $0.add("secret.bin", "cipher text", flags: 1)
            $0.add("readme.txt", "hello")
        }
        let cleanMembers = StubArchiveReader(members: [("readme.txt", Data("hello".utf8))])
        #expect(outcome { try check(cf, cleanZip, ext: "zip", canonical: "clean.zip", archives: cleanMembers) }.hasPrefix(method))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "clean.zip", sha256: Self.full(cleanZip), now: cf.now)
        #expect(outcome { try check(cf, cleanZip, ext: "zip", canonical: "clean.zip", archives: cleanMembers) } == "clean")

        // One name refused as two versions: the vouch takes the one refused last, by its sha256 (breaker B-2: always given).
        let v1 = Data("%PDF-1.7 version one".utf8), v2 = Data("%PDF-1.7 version two".utf8)
        for v in [v1, v2] { _ = outcome { try check(cf, v, canonical: "multi.pdf", archives: clean) } }
        #expect(throws: WorkError.self) { try cf.store.vouchFile(companyId: cId, canonical: "multi.pdf", sha256: "abc", now: cf.now) }
        #expect(throws: WorkError.self) { try cf.store.vouchFile(companyId: cId, canonical: "multi.pdf", sha256: "zz" + Self.full(v2), now: cf.now) }
        let picked = try cf.store.vouchFile(companyId: cId, canonical: "multi.pdf", sha256: Self.full(v2), now: cf.now)
        #expect(picked.sha256 == SHA256.hex(v2))
        #expect(outcome { try check(cf, v2, canonical: "multi.pdf", archives: clean) } == "clean")
        #expect(outcome { try check(cf, v1, canonical: "multi.pdf", archives: clean) }.hasPrefix("this PDF's structure couldn't be verified"))

        // Nothing refused under that name: nothing to vouch for. A refusal that isn't about structure records nothing.
        #expect(throws: WorkError.self) { try cf.store.vouchFile(companyId: cId, canonical: "never.pdf", sha256: Self.full(pdf), now: cf.now) }
        let unread = Data("%PDF-1.7 a file no helper read".utf8)
        #expect(outcome { try check(cf, unread, canonical: "no-helper.pdf", archives: UnavailableArchiveReader()) } == "PDFs can't be scanned on this machine")
        #expect(throws: WorkError.self) { try cf.store.vouchFile(companyId: cId, canonical: "no-helper.pdf", sha256: Self.full(unread), now: cf.now) }
        // A name that holds a stored value is never echoed: not in the refusal, the alert, or the record.
        let named = "src/\(Self.value).pdf"
        let message = outcome { try check(cf, pdf, canonical: named, archives: clean) }
        #expect(message.hasPrefix("this PDF's structure couldn't be verified"))
        let dump = try dumpDatabase(cf.store)
        for piece in SecretGateTests.pieces(Self.value) {
            #expect(!message.contains(piece))
            #expect(!dump.contains(piece), "the database holds a piece of the value")
        }
    }

    /// `data`'s full sha256 (64 hex digits), as the refusal prints it (Ruling 40, B-4).
    static func full(_ data: Data) -> String { SHA256.hex(data) }

    func fileAlerts(_ cf: CollabFixture) throws -> [Ask] {
        let cId = cf.c.id
        return try cf.store.writer.read { db in
            try Ask.fetchAll(db, sql: "SELECT * FROM ask WHERE companyId = ? AND kind = 'engineAlert' AND status = 'pendingOwner'", arguments: [cId])
        }.filter { Store.isFileVouchAlert($0) }
    }

    func vouchRefusal(_ body: () throws -> FileVouch) -> String? {
        do { _ = try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    /// Breaker B-2 (Ruling 28's class, a stale action): the command printed in the refusal and in the alert names the
    /// refused bytes' sha256 (12 hex digits), and the vouch needs it. It vouches only the version the gate refused LAST under
    /// that name: the command printed for an earlier version (the file rewritten since, and refused again) is refused, and
    /// the message shows the version refused last and its command; that one vouches it. When the old version comes back
    /// (refused again), its own command vouches it. The reviewer's order too: v1 vouched in the Inbox, v2 refused, v1's
    /// command pasted: refused (never a "vouched" that leaves v2 refused without saying so).
    @Test func staleVouchCommandRefused() throws {
        let cf = try CollabFixture()
        let cId = cf.c.id
        let reader = UnverifiedPDFReader(parts: [PDFPart(kind: .decodedStream, data: Data("hello".utf8))])
        let structure = "this PDF's structure couldn't be verified"
        let v1 = Data("%PDF-1.7 spec, version one".utf8), v2 = Data("%PDF-1.7 spec, version two".utf8)
        let (p1, p2) = (Self.full(v1), Self.full(v2))
        let first = outcome { try check(cf, v1, canonical: "spec.pdf", archives: reader) }
        #expect(first == structure + Self.command(cf.c, "spec.pdf", v1), "\(first)")
        let summaries = try fileAlerts(cf).map(\.summary)
        #expect(summaries.contains { $0.contains("brahma vouch file \(cf.c.slug) --id \(Store.canonicalHash("spec.pdf")) --sha256 \(p1) spec.pdf") }, "\(summaries)")
        // An agent rewrites the file: v2 is refused too, its own command printed.
        #expect(outcome { try check(cf, v2, canonical: "spec.pdf", archives: reader) } == structure + Self.command(cf.c, "spec.pdf", v2))
        // v1's command, pasted now: refused, naming v2 and its command; nothing vouched.
        let stale = vouchRefusal { try cf.store.vouchFile(companyId: cId, canonical: "spec.pdf", sha256: p1, now: cf.now) }
        #expect(stale?.contains("brahma vouch file \(cf.c.slug) --id \(Store.canonicalHash("spec.pdf")) --sha256 \(p2) spec.pdf") == true, "\(stale ?? "vouched")")
        #expect(try vouchRows(cf, cId).allSatisfy { ($0["vouchedAt"] as Date?) == nil })
        #expect(outcome { try check(cf, v2, canonical: "spec.pdf", archives: reader) }.hasPrefix(structure))
        // v2's command vouches v2 (and only v2).
        #expect(try cf.store.vouchFile(companyId: cId, canonical: "spec.pdf", sha256: p2, now: cf.now).sha256 == SHA256.hex(v2))
        #expect(outcome { try check(cf, v2, canonical: "spec.pdf", archives: reader) } == "clean")
        #expect(outcome { try check(cf, v1, canonical: "spec.pdf", archives: reader) }.hasPrefix(structure))
        // v1 came back and was refused again just now: it is the version refused last; its command vouches it.
        #expect(try cf.store.vouchFile(companyId: cId, canonical: "spec.pdf", sha256: p1, now: cf.now).sha256 == SHA256.hex(v1))
        #expect(outcome { try check(cf, v1, canonical: "spec.pdf", archives: reader) } == "clean")

        // The reviewer's order.
        let n1 = Data("%PDF-1.7 notes, version one".utf8), n2 = Data("%PDF-1.7 notes, version two".utf8)
        _ = outcome { try check(cf, n1, canonical: "notes.pdf", archives: reader) }
        let alert = try #require(try fileAlerts(cf).first { $0.summary.contains("notes.pdf") })
        #expect(try cf.store.vouchFile(alertAskId: alert.id, now: cf.now).sha256 == SHA256.hex(n1))
        #expect(outcome { try check(cf, n2, canonical: "notes.pdf", archives: reader) } == structure + Self.command(cf.c, "notes.pdf", n2))
        let pasted = vouchRefusal { try cf.store.vouchFile(companyId: cId, canonical: "notes.pdf", sha256: Self.full(n1), now: cf.now) }
        #expect(pasted?.contains("--sha256 \(Self.full(n2))") == true, "\(pasted ?? "vouched")")
        #expect(outcome { try check(cf, n2, canonical: "notes.pdf", archives: reader) }.hasPrefix(structure))
        #expect(outcome { try check(cf, n1, canonical: "notes.pdf", archives: reader) } == "clean")
    }

    /// Ruling 40 (B-4): the vouch binds the exact file. Only the full 64-hex sha256 vouches (a 12-hex prefix is refused,
    /// nothing vouched). The name is matched by its canonical identity only: two files whose names show the same (here two
    /// long names cut at the same place) make the shown name ambiguous: refused, both listed, neither vouched; one file's
    /// name with the other's sha256 vouches nothing. Each alert's Inbox action vouches exactly the (name, bytes) it showed.
    @Test func vouchBindsTheExactFileAndFullHash() throws {
        let cf = try CollabFixture()
        let cId = cf.c.id
        let reader = UnverifiedPDFReader(parts: [PDFPart(kind: .decodedStream, data: Data("hello".utf8))])
        let structure = "this PDF's structure couldn't be verified"
        // A prefix never vouches; the full hash does.
        let doc = Data("%PDF-1.7 a flagged report".utf8)
        _ = outcome { try check(cf, doc, canonical: "report.pdf", archives: reader) }
        let short = vouchRefusal { try cf.store.vouchFile(companyId: cId, canonical: "report.pdf", sha256: String(SHA256.hex(doc).prefix(12)), now: cf.now) }
        #expect(short?.contains("64") == true, "\(short ?? "vouched")")
        #expect(try vouchRows(cf, cId).allSatisfy { ($0["vouchedAt"] as Date?) == nil })
        #expect(try cf.store.vouchFile(companyId: cId, canonical: "report.pdf", sha256: Self.full(doc), now: cf.now).sha256 == SHA256.hex(doc))
        #expect(outcome { try check(cf, doc, canonical: "report.pdf", archives: reader) } == "clean")

        // Two files whose names show the same (C2b-carry (b): a vouch binds the id and the full hash; any name collision
        // refuses as ambiguous, listing both, until the exact acknowledged form names one).
        let stem = "docs/" + String(repeating: "a", count: 260)
        let (nameA, nameB) = (stem + "-one.pdf", stem + "-two.pdf")
        let shownA = SecretGate.shown(nameA, knownValues: Self.known)
        #expect(shownA == SecretGate.shown(nameB, knownValues: Self.known) && shownA != nameA)
        let a = Data("%PDF-1.7 file A".utf8), b = Data("%PDF-1.7 file B".utf8)
        #expect(outcome { try check(cf, a, canonical: nameA, archives: reader) }.hasPrefix(structure))
        #expect(outcome { try check(cf, b, canonical: nameB, archives: reader) }.hasPrefix(structure))
        func vouched(_ data: Data) throws -> Bool {
            try vouchRows(cf, cId).contains { ($0["sha256"] as String?) == SHA256.hex(data) && ($0["vouchedAt"] as Date?) != nil }
        }
        let (idA, idB) = (Store.canonicalHash(nameA), Store.canonicalHash(nameB))
        let ambiguous = vouchRefusal { try cf.store.vouchFile(companyId: cId, fileId: idA, sha256: Self.full(a), name: shownA, now: cf.now) }
        #expect(ambiguous?.contains("could be taken for one another") == true && ambiguous?.contains(String(SHA256.hex(a).prefix(12))) == true
                && ambiguous?.contains(String(SHA256.hex(b).prefix(12))) == true && ambiguous?.contains(idA) == true
                && ambiguous?.contains(idB) == true, "\(ambiguous ?? "vouched")")
        // (Even without a typed name: the shown names collide.)
        #expect(vouchRefusal { try cf.store.vouchFile(companyId: cId, fileId: idA, sha256: Self.full(a), now: cf.now) }?
                    .contains("could be taken for one another") == true)
        #expect(try !vouched(a) && !vouched(b))
        // A's id with B's bytes: nothing (B is not a version of A), even acknowledged.
        #expect(vouchRefusal { try cf.store.vouchFile(companyId: cId, fileId: idA, sha256: Self.full(b), acknowledgeAmbiguity: true, now: cf.now) } != nil)
        // A's id with a name that is neither A's shown nor canonical name: nothing.
        #expect(vouchRefusal { try cf.store.vouchFile(companyId: cId, fileId: idA, sha256: Self.full(a), name: nameB, acknowledgeAmbiguity: true,
                                                      now: cf.now) } != nil)
        #expect(try !vouched(a) && !vouched(b))
        // B's alert: ambiguous too until the owner confirms; then it vouches B, exactly.
        let alertB = try #require(try fileAlerts(cf).first { $0.summary.contains(SHA256.hex(b)) })
        let choice = try #require(try cf.store.fileVouchChoice(alertAskId: alertB.id))
        #expect(choice.file.canonicalHash == idB && choice.colliding.map(\.canonicalHash) == [idA])
        #expect(vouchRefusal { try cf.store.vouchFile(alertAskId: alertB.id, now: cf.now) }?.contains("confirm in the Inbox") == true)
        #expect(try !vouched(a) && !vouched(b))
        let rowB = try cf.store.vouchFile(alertAskId: alertB.id, acknowledgeAmbiguity: true, now: cf.now)
        #expect(rowB.sha256 == SHA256.hex(b) && rowB.canonicalHash == idB)
        #expect(try vouched(b) && !vouched(a))
        #expect(outcome { try check(cf, b, canonical: nameB, archives: reader) } == "clean")
        #expect(outcome { try check(cf, a, canonical: nameA, archives: reader) }.hasPrefix(structure))
        // A by its id, full hash and acknowledgement.
        #expect(try cf.store.vouchFile(companyId: cId, fileId: idA, sha256: Self.full(a), name: shownA, acknowledgeAmbiguity: true,
                                       now: cf.now).canonicalHash == idA)
        #expect(outcome { try check(cf, a, canonical: nameA, archives: reader) } == "clean")
        // B's vouch is B's name's: B's bytes under A's name are refused.
        #expect(outcome { try check(cf, b, canonical: nameA, archives: reader) }.hasPrefix(structure))
    }

    /// Breaker B-3: a PDF the helper could not read back at all (more than 64 revisions, so nothing was read; or an
    /// unverified read whose output does not hold together) is refused, and the refusal says it can't be vouched for and
    /// why: never the vouch command, nothing recorded, no alert, even when the owner already vouched for those bytes.
    @Test func unreadableUnverifiedPDFsCantBeVouched() throws {
        let cf = try CollabFixture()
        let cId = cf.c.id
        let pdf = Data("%PDF-1.7 a file the helper flagged".utf8)
        _ = outcome { try check(cf, pdf, archives: UnverifiedPDFReader(parts: [])) }
        _ = try cf.store.vouchFile(companyId: cId, canonical: "doc.pdf", sha256: Self.full(pdf), now: cf.now)
        func scripted(_ code: Int32, _ output: Data) -> SandboxedUnzipReader {
            SandboxedUnzipReader(runner: ScriptedRunner(parts: output, outcome: CheckOutcome(exitCode: code, timedOut: false, tail: "")),
                                 scratch: { try cf.vault.makeTempDir() }, pdfHelper: URL(fileURLWithPath: "/usr/bin/true"))
        }
        // (C2b-carry (c): the vouched file is served only as its flattened copy; a scripted helper that makes none refuses it,
        // saying the vouch can't lift that.)
        let unflattened = outcome { try check(cf, pdf, archives: scripted(5, Data("BRAHMA-PDF/1\n".utf8))) }
        #expect(unflattened.contains("can't be flattened") && unflattened.contains("print it to PDF") && !unflattened.contains("brahma vouch file"),
                "\(unflattened)")
        let garbled = outcome { try check(cf, pdf + Data(" garbled".utf8), archives: scripted(5, Data("BRAHMA-PDF/1\n".utf8))) }
        #expect(garbled == SandboxedPDFReader.unverifiedUnread.message, "\(garbled)")
        #expect(garbled.contains("can't be vouched for") && !garbled.contains("brahma vouch file"))
        // (Other bytes: the refusal above is cached by the bytes.)
        let tooMany = outcome { try check(cf, pdf + Data(" more".utf8), archives: scripted(10, Data("BRAHMA-PDF/1\n".utf8))) }
        #expect(tooMany == SandboxedPDFReader.tooManyRevisions.message, "\(tooMany)")
        #expect(tooMany.contains("more than 64 revisions") && tooMany.contains("can't be vouched for"))
        // With the real helper: 65 revisions, not vouched; nothing is recorded for it, and no alert is raised.
        guard EmbeddedContentTests.helperReady else { return }
        let reader = try EmbeddedContentTests.reader(cf)
        let many = SplitBuild.additive(65)
        let refused = outcome { try check(cf, many, canonical: "many.pdf", archives: reader) }
        #expect(refused == SandboxedPDFReader.tooManyRevisions.message, "\(refused)")
        #expect(try vouchRows(cf, cId).count == 1 && !(try fileAlerts(cf).contains { $0.summary.contains("many.pdf") }))
    }

    func dumpTaint(_ cf: CollabFixture) throws -> String {
        try cf.store.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM taintedCommit") + (try Row.fetchAll(db, sql: "SELECT id, tainted FROM resource"))
            return rows.map(\.description).joined(separator: "\n")
        }
    }

    /// `brahma vouch file <company> <path>` is the owner's: refused without the owner key and from an agent's shell
    /// (`BRAHMA_AGENT_ID`), changing nothing; as the owner it vouches for the refused bytes (an owner activity line, the
    /// alert closed) and the gate then passes them. No agent tool reaches it.
    @Test func cliVouchFileOwnerOnly() throws {
        func home(initOwner: Bool) throws -> (home: OwnerTestHome, company: Company, pdf: Data) {
            let home = try OwnerTestHome(initOwner: initOwner)
            let paths = ownerPaths(home.url)
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            defer { try? store.close() }
            let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            let pdf = Data("%PDF-1.7 flagged".utf8)
            #expect(throws: WorkError.self) {
                try SecretGate.check(pdf, ext: "pdf", canonical: "docs/spec.pdf", archives: UnverifiedPDFReader(parts: []), knownValues: [],
                                     store: store, companyId: company.id)
            }
            return (home, company, pdf)
        }
        func vouched(_ h: (home: OwnerTestHome, company: Company, pdf: Data)) throws -> (vouched: Bool, passes: Bool, lines: [String]) {
            let paths = ownerPaths(h.home.url)
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            defer { try? store.close() }
            let at = try store.writer.read { db in
                try Date.fetchOne(db, sql: "SELECT vouchedAt FROM fileVouch WHERE companyId = ?", arguments: [h.company.id])
            }
            let passes = (try? store.gatedBytes(h.pdf, ext: "pdf", canonical: "docs/spec.pdf", companyId: h.company.id,
                                                archives: UnverifiedPDFReader(parts: []), knownValues: [], paths: paths))?.verdict == .clean
            return (at != nil, passes, try store.events(afterId: 0, companyId: h.company.id).map(\.text))
        }
        let noKey = try home(initOwner: false)
        let sha = Self.full(noKey.pdf)
        let id = Store.canonicalHash("docs/spec.pdf")
        let refusedNoKey = try runBrahma(["vouch", "file", "acme", "docs/spec.pdf", "--id", id, "--sha256", sha], home: noKey.home.url)
        #expect(refusedNoKey.status != 0 && refusedNoKey.stderr.contains("owner key missing"), "\(refusedNoKey.stderr)")
        #expect(try vouched(noKey).vouched == false)

        let h = try home(initOwner: true)
        let agent = try runBrahma(["vouch", "file", "acme", "docs/spec.pdf", "--id", id, "--sha256", sha], home: h.home.url, extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agent.status != 0 && agent.stderr.contains("owner commands can't run inside an agent turn"), "\(agent.stderr)")
        let afterAgent = try vouched(h)
        #expect(!afterAgent.vouched && !afterAgent.passes)
        #expect(try runBrahma(["vouch", "file", "nosuch", "docs/spec.pdf", "--id", id, "--sha256", sha], home: h.home.url).status != 0)
        // Breaker B-2: the sha256 is required; without it nothing is vouched.
        let bare = try runBrahma(["vouch", "file", "acme", "docs/spec.pdf", "--id", id], home: h.home.url)
        #expect(bare.status != 0 && bare.stderr.contains("--sha256"), "\(bare.stderr)")
        // Ruling 40 (B-4): the full hash, never a prefix.
        let prefixed = try runBrahma(["vouch", "file", "acme", "docs/spec.pdf", "--id", id, "--sha256", String(sha.prefix(12))], home: h.home.url)
        #expect(prefixed.status != 0, "\(prefixed.stdout)")
        #expect(try vouched(h).vouched == false)
        let unknown = try runBrahma(["vouch", "file", "acme", "docs/other.pdf", "--id", Store.canonicalHash("docs/other.pdf"), "--sha256", sha],
                                    home: h.home.url)
        #expect(unknown.status != 0, "\(unknown.stdout)")
        // Breaker B-4 / C2b-carry (b): the id is required; the file's id with another file's name vouches nothing.
        #expect(try runBrahma(["vouch", "file", "acme", "docs/spec.pdf", "--sha256", sha], home: h.home.url).status != 0)
        #expect(try runBrahma(["vouch", "file", "acme", "docs/other.pdf", "--id", id, "--sha256", sha], home: h.home.url).status != 0)
        #expect(try vouched(h).vouched == false)

        let owner = try runBrahma(["vouch", "file", "acme", "docs/spec.pdf", "--id", id, "--sha256", sha], home: h.home.url)
        #expect(owner.status == 0, "\(owner.stderr)")
        #expect(owner.stdout.contains("docs/spec.pdf") && owner.stdout.contains(String(SHA256.hex(h.pdf).prefix(12))), "\(owner.stdout)")
        let after = try vouched(h)
        #expect(after.vouched && after.passes)
        #expect(after.lines.contains { $0.contains("Owner vouched for docs/spec.pdf") }, "\(after.lines)")
    }

    /// The words of the first `brahma vouch file …` command in `text` (after `brahma`), as a shell reads them: single
    /// quotes, `\` outside them; the command ends at the end of the text or an unquoted `;`.
    static func pastedCommand(_ text: String, containing: String? = nil) -> [String]? {
        var rest = Substring(text)
        while let r = rest.range(of: "brahma vouch file ") {
            var words: [String] = [], word = "", inWord = false, quoted = false
            var chars = rest[r.upperBound...].makeIterator()
            loop: while let c = chars.next() {
                if quoted {
                    if c == "'" { quoted = false } else { word.append(c) }
                    continue
                }
                switch c {
                case "'": quoted = true; inWord = true
                case "\\": if let n = chars.next() { word.append(n); inWord = true }
                case ";": break loop
                case " ", "\t", "\n":
                    if inWord { words.append(word); word = ""; inWord = false }
                default: word.append(c); inWord = true
                }
            }
            if inWord { words.append(word) }
            let command = ["vouch", "file"] + words
            if containing.map({ command.contains($0) }) ?? true { return command }
            rest = rest[r.upperBound...]
        }
        return nil
    }

    /// C2b-carry (b), the last breaker review's `rrbrkShownCollidesWithCanonical` through the owner's own path: the
    /// command a refusal printed, pasted into `brahma vouch file`. A vouch binds to the file's id (its canonical name's
    /// hash) and the full sha256 only; no name decides which file is vouched.
    /// - B is named exactly as A's refusal shows A (`SecretGate.shown(A)`, 200 characters ending `…`). Pasting A's
    ///   command never vouches B and never steers to B alone: it is refused as ambiguous, listing both (id, sha256,
    ///   refused at), each with its own exact command carrying `--ambiguous-ok`; nothing is vouched. A's acknowledged
    ///   command then vouches A, and only A.
    /// - The same bytes under C and D = shown(C): pasting C's command vouches nothing (before, it vouched D).
    /// - A prefix of the hash is refused; the full hash of a file no other file collides with vouches it.
    @Test func rrbrkShownCollidesWithCanonical() throws {
        let home = try OwnerTestHome(initOwner: true)
        let paths = ownerPaths(home.url)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let nameA = "docs/" + String(repeating: "a", count: 260) + "-one.pdf"
        let nameB = SecretGate.shown(nameA, knownValues: [])
        let nameC = "docs/" + String(repeating: "c", count: 260) + "-x.pdf"
        let nameD = SecretGate.shown(nameC, knownValues: [])
        #expect(nameB != nameA && nameB.hasSuffix("…") && SecretGate.shown(nameB, knownValues: []) == nameB)
        let a = Data("%PDF-1.7 file A".utf8), b = Data("%PDF-1.7 file B".utf8), same = Data("%PDF-1.7 the same bytes".utf8)
        let plain = Data("%PDF-1.7 a report".utf8)
        var messages: [String: String] = [:]
        let companyId: String
        do {
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            defer { try? store.close() }
            companyId = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces).id
            for (name, data) in [(nameA, a), (nameB, b), (nameC, same), (nameD, same), ("report.pdf", plain)] {
                do {
                    _ = try SecretGate.check(data, ext: "pdf", canonical: name, archives: UnverifiedPDFReader(parts: []), knownValues: [],
                                             store: store, companyId: companyId)
                    Issue.record("\(name) was not refused")
                } catch let e as WorkError { messages[name] = e.message }
            }
        }
        func vouched() throws -> [(canonicalHash: String, sha256: String)] {
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            defer { try? store.close() }
            return try store.writer.read { db in
                try Row.fetchAll(db, sql: "SELECT canonicalHash, sha256 FROM fileVouch WHERE companyId = ? AND vouchedAt IS NOT NULL",
                                 arguments: [companyId]).map { (canonicalHash: $0["canonicalHash"] as String, sha256: $0["sha256"] as String) }
            }
        }
        // A's printed command, pasted: ambiguous, both listed, nothing vouched.
        let commandA = try #require(Self.pastedCommand(messages[nameA] ?? ""), "\(messages[nameA] ?? "")")
        let pastedA = try runBrahma(commandA, home: home.url)
        let listing = pastedA.stderr + pastedA.stdout
        #expect(pastedA.status != 0, "\(listing)")
        #expect(listing.contains(String(SHA256.hex(a).prefix(12))) && listing.contains(String(SHA256.hex(b).prefix(12))), "\(listing)")
        #expect(listing.contains(Store.canonicalHash(nameA)) && listing.contains(Store.canonicalHash(nameB)), "\(listing)")
        #expect(try vouched().isEmpty)
        // A's acknowledged command from the listing vouches A, and only A.
        guard let ackA = Self.pastedCommand(listing, containing: SHA256.hex(a)) else {
            Issue.record("no command for A in the listing: \(listing)")
            return
        }
        #expect(ackA.contains("--ambiguous-ok") && ackA.contains(Store.canonicalHash(nameA)), "\(ackA)")
        let ackB = try #require(Self.pastedCommand(listing, containing: SHA256.hex(b)))
        #expect(ackB.contains("--ambiguous-ok") && ackB.contains(Store.canonicalHash(nameB)), "\(ackB)")
        // The acknowledgement alone, without the file's id, vouches nothing.
        var withoutId = ackA
        if let i = withoutId.firstIndex(of: "--id"), i + 1 < withoutId.count { withoutId.removeSubrange(i...(i + 1)) }
        #expect(try runBrahma(withoutId, home: home.url).status != 0)
        #expect(try vouched().isEmpty)
        let ran = try runBrahma(ackA, home: home.url)
        #expect(ran.status == 0, "\(ran.stderr)")
        let afterA = try vouched()
        #expect(afterA.count == 1 && afterA.first?.canonicalHash == Store.canonicalHash(nameA) && afterA.first?.sha256 == SHA256.hex(a), "\(afterA)")

        // The same bytes under C and D: C's command vouches nothing.
        let commandC = try #require(Self.pastedCommand(messages[nameC] ?? ""))
        let pastedC = try runBrahma(commandC, home: home.url)
        #expect(pastedC.status != 0, "\(pastedC.stdout)")
        #expect((pastedC.stderr + pastedC.stdout).contains(Store.canonicalHash(nameD)), "\(pastedC.stderr)")
        #expect(try vouched().count == 1)

        // No collision: a 12-hex prefix is refused; the printed command (the full hash) vouches.
        let commandR = try #require(Self.pastedCommand(messages["report.pdf"] ?? ""))
        let sha = SHA256.hex(plain)
        let prefixed = commandR.map { $0 == sha ? String(sha.prefix(12)) : $0 }
        #expect(try runBrahma(prefixed, home: home.url).status != 0)
        #expect(try vouched().count == 1)
        let full = try runBrahma(commandR, home: home.url)
        #expect(full.status == 0, "\(full.stderr)")
        #expect(try vouched().contains { $0.canonicalHash == Store.canonicalHash("report.pdf") && $0.sha256 == sha })
    }

    /// No agent tool reaches the file vouch: no company tool is named for it, and no tool source calls it or writes it.
    @Test func noAgentToolReachesTheFileVouch() throws {
        #expect(!CompanyToolNames.all.contains { $0.contains("vouch") })
        var reaches: [String] = []
        for (path, text) in try EngineGitGuardTests.sources(under: "Sources/BrahmaCore/MCP") {
            let code = EngineGitGuardTests.code(text)
            if code.range(of: #"\bvouchFile\b|fileVouch"#, options: .regularExpression) != nil { reaches.append(path) }
        }
        #expect(reaches.isEmpty, "a tool path reaches the file vouch: \(reaches)")
    }
}

extension Store {
    /// Tests: the vouch for the file named `canonical` by its id (its canonical name's hash) and full hash, as the printed
    /// command gives them (C2b-carry (b): the id and the hash bind the vouch).
    @discardableResult
    func vouchFile(companyId: String, canonical: String, sha256: String, now: Date) throws -> FileVouch {
        try vouchFile(companyId: companyId, fileId: Store.canonicalHash(canonical), sha256: sha256, now: now)
    }
}
