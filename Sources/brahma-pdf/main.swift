// brahma-pdf: the PDF extraction helper (Plan C task C2b, fix rounds 2–5, controller rulings 33–35, 37 and 38).
//
// The engine never parses a PDF. It runs this helper directly under Seatbelt (`SandboxedPDFReader`: a deny-default profile
// that lets it read the system's libraries, this binary and the one input file, and nothing else: no other program, no
// fork, no file written; the leader of its own session; a hard time limit; a memory watchdog; its standard output read by
// the engine up to a byte cap, past which it is killed) and scans what it hands back under the gate's one budget.
//
//     brahma-pdf <input.pdf> <max output bytes> [<memory limit in bytes>]
//
// What it does, with Apple's own reader (CoreGraphics, PDFKit):
// 1. Lexes the file: every `<n> <g> obj` header (its exact byte offset) and the `endobj` that closes it, every `stream`
//    keyword (one that no regular character comes before, whatever follows it) and the header whose object it is in, every
//    `/Size` (the highest object number the file can use), every in-use entry of every classic cross-reference section
//    (number, generation, offset), and where each revision ends: after every `startxref <offset>` (and its `%%EOF`, when
//    one follows) and every `%%EOF` (round 4, R4-1: a revision need not end with `%%EOF`).
// 2. For EVERY revision (the file cut at each of those ends, and the whole file): opens it (an encrypted one is refused);
//    appends an incremental update (in memory) whose catalog lists every object number up to that highest one (and every
//    non-zero generation seen), and, under fresh numbers, every object holding a stream whose body lies inside that cut,
//    each pinned at its header's exact offset; in the same kind of cross-reference section as the revision's last one;
//    then opens that. The reader's own parse then reaches every object that revision holds, used or not (objects in object
//    streams, the cross-reference and object streams themselves, objects nothing refers to), and every stream body by its
//    place in the file. Round 5 (R5-1, ruling 37): a revision the reader can't open is an anomaly, unless the file is
//    positively linearized (`positivelyLinearized`: its first-page section, which ends `startxref 0`, holds only the
//    linearization dictionary and its cross-reference, and the whole file's view reaches every object any section names).
// 3. Walks every object from that list: every stream decoded (`CGPDFStreamCopyData`; a stream that does not decode is
//    refused), every string (its bytes, and as text), every name. A cross-reference stream naming objects past the
//    highest number is refused; its in-use rows (number, generation, offset) are kept. Each decoded stream is written once,
//    by its digest.
// 4. Runs CoreGraphics' content-stream scanner over every content stream (page contents, every annotation appearance and
//    appearance state, every Form XObject, Type 3 glyph procedures, tiling patterns) and keeps every string a text or
//    marked-content operator takes (`Tj`, `TJ`, `'`, `"`, `BDC`, `DP`), escapes decoded. A content stream it can't scan
//    is refused, and so is one marked that the walk never decoded.
// 5. Places every stream (round 4, R4-1, ruling 34): each `stream` keyword must sit in exactly one object (a header, no
//    `endobj` between), one per object; that header must be named at its EXACT offset, with its number and generation, by
//    an in-use entry of some cross-reference section; and some revision's walk must have decoded, under that number and
//    generation, exactly what the body pinned at that offset decodes to in the same revision. Every in-use entry of every
//    section must name exactly the offset of a header with its own number and generation (an offset one byte off, offset
//    0, another number or generation: refused). Anything else is data no walk is known to reach: refused.
//    Round 4 (R4-6, ruling 35): the rule is detection only, never a model of what a reader would do. Every anomaly refuses
//    the same way (exit 5, which the engine reports as "this PDF's structure couldn't be verified", round 5 adding the
//    owner's vouch command): besides the above, more than 8 revisions, one object number with two bodies (an object rewritten
//    across revisions, or twice in one), and any object header (stream or not) no in-use entry names exactly.
//    Round 5 (R5-2, ruling 35 b): every type-2 row (an object in an object stream) is kept per number with its stream and
//    index; a number that has a header and a type-2 row, rows that name two places, a row whose object stream is no
//    stream object, and a member no revision's reader resolved are anomalies too. An anomaly no longer stops the read:
//    everything readable is still read and written out in full, and the exit status is 5 (the engine refuses it unless
//    the owner vouched for these exact bytes, ruling 38, and then scans every part as usual).
// 6. Adds the page text of the last revision as PDFKit extracts it.
// A thread checks the process's own memory footprint every 20 ms and exits (status 9) past the limit (default 1 GiB);
// the engine's watchdog kills the whole run at its own limit too.
//
// Output (stdout): "BRAHMA-PDF/1\n", then records (a kind byte, a 4-byte big-endian length, the payload), then an `E`
// record whose 8-byte big-endian payload is the number of records before it. Kinds: `D` a decoded stream, `J` a stream
// left in JPEG form, `P` one left in JPEG 2000 form, `S` every string's bytes, `U` every string as text, `N` every name,
// `T` the page text (each of the last four one record, entries separated by line feeds). The whole output, framing
// included, stays within the byte cap, or the run fails.
//
// Exit status: 0 done; 2 usage; 3 encrypted; 4 a stream (or content stream) that can't be decoded; 5 a structural
// anomaly (step 5; the output is complete when it parses, empty for a file with more than 64 revisions); 6 the output
// cap; 7 not a PDF this reader can open; 8 too many objects; 9 the memory limit.
// Anything but 0 is a refusal.
import Foundation
#if canImport(PDFKit) && canImport(CoreGraphics)
import CoreGraphics
import CryptoKit
import PDFKit

enum Status: Int32 { case usage = 2, encrypted = 3, undecodable = 4, unaccounted = 5, cap = 6, unreadable = 7, tooMany = 8, memory = 9 }

func fail(_ status: Status) -> Never { exit(status.rawValue) }

/// White space and delimiters end a token; every other byte is a regular character (PDF 32000-1, 7.2.2).
func isRegular(_ c: UInt8) -> Bool {
    switch c {
    case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20, 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return false
    default: return true
    }
}
func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
func isWhite(_ c: UInt8) -> Bool { c == 0x00 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20 }
func matches(_ word: [UInt8], at i: Int, in b: [UInt8]) -> Bool {
    guard i >= 0, word.count <= b.count - i else { return false }
    for k in 0..<word.count where b[i + k] != word[k] { return false }
    return true
}

/// This process's physical memory footprint (what the system charges it), or 0 when it can't be read.
func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let task = mach_task_self_
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(task, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// The output stream: records within `cap` bytes in all.
final class Output {
    let cap: Int
    var written = 0
    var records = 0
    let out = FileHandle.standardOutput

    init(cap: Int) {
        self.cap = cap
        write(Data("BRAHMA-PDF/1\n".utf8))
    }

    private func write(_ data: Data) {
        guard data.count <= cap - written else { fail(.cap) }
        written += data.count
        out.write(data)
    }

    func record(_ kind: UInt8, _ payload: Data) {
        guard payload.count <= Int(UInt32.max) else { fail(.cap) }
        let n = UInt32(payload.count)
        write(Data([kind, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) + payload)
        records += 1
    }

    func finish() {
        let n = UInt64(records)
        write(Data([0x45, 0, 0, 0, 8] + (0..<8).reversed().map { UInt8((n >> (8 * UInt64($0))) & 0xFF) }))
    }
}

/// An object by its number and generation (round 4, ruling 34: identity is always both).
struct ObjectKey: Hashable, Comparable {
    let number: Int
    let generation: Int
    static func < (a: ObjectKey, b: ObjectKey) -> Bool { (a.number, a.generation) < (b.number, b.generation) }
}

/// Where a type-2 cross-reference row says an object lives: the object stream's number and the index in it.
struct Compressed: Equatable {
    let stream: Int
    let index: Int
}

/// An in-use cross-reference entry: which object it says starts at `offset`.
struct Entry: Hashable {
    let key: ObjectKey
    let offset: Int
}

/// A lexed `<n> <g> obj` header: where it starts, where its object ends (its `endobj`, or the next header), and how many
/// `stream` keywords lie between.
struct Header {
    let key: ObjectKey
    let offset: Int
    var end: Int?
    var streams = 0
}

/// One run over one file (steps 1–6 above).
final class Extraction {
    /// At most this many object numbers are listed (a larger file is refused).
    static let maxObjects = 500_000
    /// At most this many objects are visited in one revision's walk.
    static let maxVisits = 5_000_000
    /// Round 4 (R4-6, ruling 35): more revisions than this is itself an anomaly (refused as unverifiable).
    static let maxRevisions = 8
    /// Round 5: at most this many revisions are walked at all; a file with more is refused with nothing read.
    static let maxWalks = 64

    let original: Data
    let bytes: [UInt8]
    let output: Output
    var headers: [Header] = []
    var headerAt: [Int: Int] = [:]   // a header's offset → its index
    var stray = false                // a `stream` keyword outside every object
    var generations = Set<ObjectKey>()   // every header with a generation other than 0
    /// The non-zero generations, listed after objects 1…highest in the update's order.
    lazy var generationList: [ObjectKey] = generations.sorted()
    var highest = 0                  // the highest object number the file can use
    var revisionEnds = Set<Int>()
    var strings = Data(), texts = Data(), names = Data()
    var keptEntries = Set<Data>()    // every string, text and name kept once
    var digests = Set<Data>()        // every decoded stream, across every revision, written once
    var entries = Set<Entry>()       // every in-use entry of every cross-reference section (classic and stream)
    /// Round 5 (R5-2, ruling 35 b): every object a cross-reference stream says lives in an object stream (a type-2 row):
    /// its number → the object stream's number and its index there (its generation is 0).
    var compressed: [Int: Compressed] = [:]
    /// Every `startxref` value, in file order (the last one names the whole file's newest section).
    var startxrefs: [Int] = []
    /// Round 5: a structural anomaly was found. The helper still reads everything it can and writes it out in full, then
    /// exits 5 (`unaccounted`): the engine refuses it, unless the owner vouched for these exact bytes (ruling 38).
    var anomalous = false
    /// Every number some cross-reference section marks free (classic `f`, type-0 rows).
    var freed = Set<Int>()
    /// Round 5 (R5-2): the object numbers each decoded object stream's header lists, in order, by the stream's digest (nil:
    /// a header that doesn't parse).
    var objectStreamHeaders: [Data: [Int]?] = [:]
    /// Every digest each listed object (generation 0) decoded to as a stream, in any revision.
    var streamDigests: [Int: Set<Data>] = [:]

    func anomaly() { anomalous = true }

    init(original: Data, cap: Int) {
        self.original = original
        bytes = [UInt8](original)
        output = Output(cap: cap)
    }

    func run() -> Never {
        lex()
        guard highest < Self.maxObjects else { fail(.tooMany) }
        var ends = revisionEnds.sorted()
        if ends.last != bytes.count { ends.append(bytes.count) }
        // More revisions than the reader could ever walk: refused outright (nothing is read).
        guard ends.count <= Self.maxWalks else { fail(.unaccounted) }
        if ends.count > Self.maxRevisions { anomaly() }
        // R4-6 (ruling 35): one object number with two bodies (an object rewritten across revisions, or twice in one) is
        // an anomaly, refused without modelling which body a reader would take.
        var numbers = Set<Int>()
        if !headers.allSatisfy({ numbers.insert($0.key.number).inserted }) { anomaly() }
        let bodies = headers.filter { $0.streams == 1 }
        var placed = Set<Int>()   // the header offsets of the stream bodies some revision placed
        var resolved = Set<ObjectKey>()   // every listed object some revision's reader resolved to something (not null)
        var unopened: [Int] = []          // the revisions (indices into `ends`) the reader could not open
        var linearized = false            // the whole file is positively linearized (Ruling 37's exception)
        var opened = false
        for (index, end) in ends.enumerated() {
            let prefix = original.prefix(end)
            if let provider = CGDataProvider(data: prefix as CFData), let document = CGPDFDocument(provider), document.isEncrypted {
                fail(.encrypted)
            }
            // Every stream body wholly inside this revision, pinned at its offset (a generation a cross-reference row
            // can't carry is never pinned, so it is never placed).
            let pins = bodies.filter { ($0.end ?? bytes.count) <= end && $0.key.generation <= 65_535 }
            // Round 5 (R5-1, ruling 37): a revision the reader can't open is never skipped: unless the file is positively
            // linearized and this is its first-page section (below), the file is unverifiable.
            guard let revision = Revision(of: self, prefix: prefix, pins: pins) else { unopened.append(index); continue }
            let walked = revision.read()
            opened = true
            resolved.formUnion(walked.resolved)
            for pin in pins {
                if let digest = walked.pinned[pin.offset], walked.byKey[pin.key] == digest { placed.insert(pin.offset) }
            }
            if index == ends.count - 1, index == 1, unopened == [0] {
                linearized = positivelyLinearized(revision, resolved: walked.resolved, firstEnd: ends[0])
            }
        }
        guard opened else { fail(.unreadable) }
        if !unopened.isEmpty && !(unopened == [0] && linearized) { anomaly() }
        // Step 5 (after the walks, so a stream that can't be decoded says so first): every `stream` keyword in one object,
        // one per object; every stream body named exactly and placed by some revision's walk; every in-use entry exactly a
        // header.
        if stray || !headers.allSatisfy({ $0.streams <= 1 }) { anomaly() }
        // R4-6: every object header, stream or not, named exactly by an in-use entry (an unknown object is an anomaly).
        if headers.contains(where: { !entries.contains(Entry(key: $0.key, offset: $0.offset)) }) { anomaly() }
        for body in bodies where !placed.contains(body.offset) || !entries.contains(Entry(key: body.key, offset: body.offset)) {
            anomaly()
        }
        for entry in entries {
            guard let i = headerAt[entry.offset], headers[i].key == entry.key else { anomaly(); break }
        }
        // Round 5 (R5-2, ruling 35 b): an object in an object stream is accounted like a header. No number both a header
        // and a type-2 row (an object rewritten from one into the other); every type-2 row of one number names the same
        // place (checked as rows are read); its object stream a lexed stream object of generation 0, not itself; and the
        // member decoded by the reader in some revision.
        for (number, place) in compressed {
            let container = headers.first { $0.key == ObjectKey(number: place.stream, generation: 0) }
            if numbers.contains(number) || place.stream == number || container?.streams != 1
                || !resolved.contains(ObjectKey(number: number, generation: 0)) {
                anomaly()
            }
            // The object stream's own header (as every revision decoded it) lists this number exactly once, at the row's
            // index: readers that go by the index and readers that go by the number find the same member.
            let decodedAs = streamDigests[place.stream] ?? []
            if decodedAs.isEmpty { anomaly() }
            for digest in decodedAs {
                guard let listed = objectStreamHeaders[digest] ?? nil, place.index < listed.count, listed[place.index] == number,
                      listed.filter({ $0 == number }).count == 1 else { anomaly(); break }
            }
        }
        // The page text of the last revision (none when that revision is itself what can't be verified).
        if let pdf = PDFDocument(data: original) {
            if pdf.isEncrypted || pdf.isLocked { fail(.encrypted) }
            var pages = Data()
            for i in 0..<pdf.pageCount {
                if let text = pdf.page(at: i)?.string, !text.isEmpty { pages += Data(text.utf8); pages.append(0x0A) }
            }
            keepPages(pages)
        } else if !anomalous {
            fail(.unreadable)
        }
        for (kind, data) in [(UInt8(0x53), strings), (0x55, texts), (0x4E, names), (0x54, pageText)] where !data.isEmpty {
            output.record(kind, data)
        }
        output.finish()
        exit(anomalous ? Status.unaccounted.rawValue : 0)
    }

    var pageText = Data()
    func keepPages(_ data: Data) { pageText = data }

    /// Round 5 (R5-1, ruling 37): whether the file is positively linearized (PDF 32000-1, Annex F), so that its first
    /// section, which the reader can't open on its own (its `startxref` is 0), is walked through the whole file's view
    /// (`whole`, the last revision's walk; `resolved` what it resolved). All of:
    /// - exactly two revisions, the first ending at `firstEnd`;
    /// - the first object of the file (within its first 1024 bytes, holding no stream, wholly in the first section) a
    ///   dictionary with `/Linearized`, whose `/L` is the file's exact length, and whose `/H` names 1 or 2 hint streams,
    ///   each exactly: an object header at that offset holding one stream, after the first section, its length running to
    ///   the end of line after its `endobj`;
    /// - the first section holds nothing but that dictionary and its cross-reference: a classic table, or one
    ///   cross-reference stream; the file's final `startxref` names exactly that table (or stream);
    /// - the whole file's view reaches every object any section names in use (classic, type 1 or type 2): no section can
    ///   hide what another holds, so the walk of the whole file is a walk of every view.
    func positivelyLinearized(_ whole: Revision, resolved: Set<ObjectKey>, firstEnd: Int) -> Bool {
        guard let first = headers.min(by: { $0.offset < $1.offset }), first.offset < 1024, first.streams == 0,
              let firstObjectEnd = first.end, firstObjectEnd <= firstEnd,
              let dictionary = whole.dictionary(number: first.key.number), first.key.generation == 0 else { return false }
        var version: CGPDFReal = 0, length: CGPDFInteger = 0
        guard CGPDFDictionaryGetNumber(dictionary, "Linearized", &version), CGPDFDictionaryGetInteger(dictionary, "L", &length),
              length == bytes.count else { return false }
        var hints: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(dictionary, "H", &hints), let hints else { return false }
        let count = CGPDFArrayGetCount(hints)
        guard count == 2 || count == 4 else { return false }
        for pair in stride(from: 0, to: count, by: 2) {
            var offset: CGPDFInteger = 0, size: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(hints, pair, &offset), CGPDFArrayGetInteger(hints, pair + 1, &size), offset >= firstEnd, size > 0,
                  let i = headerAt[offset], headers[i].streams == 1, let end = headers[i].end else { return false }
            let (stop, overflow) = offset.addingReportingOverflow(size)
            guard !overflow, stop >= end, stop <= end + 2 else { return false }
        }
        let inFirst = headers.filter { $0.offset < firstEnd }
        guard let finalStart = startxrefs.last else { return false }
        switch inFirst.count {
        case 1:
            guard finalStart >= firstObjectEnd, finalStart < firstEnd, matches(Array("xref".utf8), at: finalStart, in: bytes) else { return false }
        case 2:
            guard let table = inFirst.first(where: { $0.offset != first.offset }), table.streams == 1, table.offset == finalStart,
                  (table.end ?? bytes.count) <= firstEnd, whole.isCrossReferenceStream(number: table.key.number) else { return false }
        default:
            return false
        }
        if entries.contains(where: { !resolved.contains($0.key) }) { return false }
        // No section frees what another uses (object 0 aside): every view agrees on what exists.
        if entries.contains(where: { $0.key.number != 0 && freed.contains($0.key.number) })
            || compressed.keys.contains(where: freed.contains) { return false }
        if compressed.keys.contains(where: { !resolved.contains(ObjectKey(number: $0, generation: 0)) }) { return false }
        return true
    }

    /// Step 1: the object headers and their ends, the `stream` keywords and their objects, the `/Size` values, the classic
    /// cross-reference entries and the revision ends in the file's bytes.
    func lex() {
        let streamWord = Array("stream".utf8), objWord = Array("obj".utf8), sizeWord = Array("/Size".utf8), eofWord = Array("%%EOF".utf8)
        let xrefWord = Array("xref".utf8), endobjWord = Array("endobj".utf8), startxrefWord = Array("startxref".utf8)
        var open: Int?   // the header whose object the lexer is in
        func endsToken(_ k: Int) -> Bool { k == bytes.count || !isRegular(bytes[k]) }
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            let starts = i == 0 || !isRegular(bytes[i - 1])
            if c == 0x73, starts, matches(streamWord, at: i, in: bytes) {
                // Round 3 (m-B): whatever follows it, data straight after the keyword included.
                if let open { headers[open].streams += 1 } else { stray = true }
            } else if c == 0x73, starts, matches(startxrefWord, at: i, in: bytes), endsToken(i + startxrefWord.count) {
                // Round 4 (R4-1): a revision ends after `startxref <offset>` (and after its `%%EOF`, when one follows).
                var j = i + startxrefWord.count
                while j < bytes.count, isWhite(bytes[j]) { j += 1 }
                var digits = 0, value = 0
                while j < bytes.count, isDigit(bytes[j]), digits < 12 { value = value * 10 + Int(bytes[j] - 0x30); j += 1; digits += 1 }
                if digits > 0 {
                    startxrefs.append(value)
                    var k = j
                    while k < bytes.count, isWhite(bytes[k]) { k += 1 }
                    revisionEnds.insert(matches(eofWord, at: k, in: bytes) ? afterEOF(k + eofWord.count) : j)
                }
            } else if c == 0x65, starts, matches(endobjWord, at: i, in: bytes), endsToken(i + endobjWord.count) {
                if let o = open { headers[o].end = i + endobjWord.count }
                open = nil
            } else if c == 0x6F, i > 0, matches(objWord, at: i, in: bytes), !isRegular(bytes[i - 1]), endsToken(i + objWord.count) {
                // Back over white space, the generation, white space, the number.
                var j = i - 1
                while j >= 0, isWhite(bytes[j]) { j -= 1 }
                var generation = 0, scale = 1, gDigits = 0
                while j >= 0, isDigit(bytes[j]), gDigits < 6 { generation += Int(bytes[j] - 0x30) * scale; scale *= 10; j -= 1; gDigits += 1 }
                let afterNumber = j
                while j >= 0, isWhite(bytes[j]) { j -= 1 }
                var number = 0, nDigits = 0
                scale = 1
                while j >= 0, isDigit(bytes[j]), nDigits < 9 { number += Int(bytes[j] - 0x30) * scale; scale *= 10; j -= 1; nDigits += 1 }
                if gDigits > 0, nDigits > 0, afterNumber > j, j < 0 || !isRegular(bytes[j]) {
                    highest = max(highest, number)
                    // An object left open ends where the next header starts.
                    if let o = open { headers[o].end = j + 1 }
                    let key = ObjectKey(number: number, generation: generation)
                    headerAt[j + 1] = headers.count
                    headers.append(Header(key: key, offset: j + 1))
                    open = headers.count - 1
                    if generation != 0 { generations.insert(key) }
                }
            } else if c == 0x2F, matches(sizeWord, at: i, in: bytes) {
                var j = i + sizeWord.count
                if j == bytes.count || !isRegular(bytes[j]) || isDigit(bytes[j]) {
                    while j < bytes.count, isWhite(bytes[j]) { j += 1 }
                    var size = 0, digits = 0
                    while j < bytes.count, isDigit(bytes[j]), digits < 9 { size = size * 10 + Int(bytes[j] - 0x30); j += 1; digits += 1 }
                    if digits > 0 { highest = max(highest, size - 1) }
                }
            } else if c == 0x78, starts, matches(xrefWord, at: i, in: bytes),
                      i + xrefWord.count < bytes.count, isWhite(bytes[i + xrefWord.count]) {
                classicSection(at: i + xrefWord.count)
            } else if c == 0x25, matches(eofWord, at: i, in: bytes) {
                revisionEnds.insert(afterEOF(i + eofWord.count))
            }
            i += 1
        }
    }

    /// Where a revision ends after a `%%EOF` ending at `end`: past its line ends.
    func afterEOF(_ end: Int) -> Int {
        var end = end
        while end < bytes.count, bytes[end] == 0x0D || bytes[end] == 0x0A { end += 1 }
        return end
    }

    /// The rows of a classic cross-reference section starting at `i` (after `xref`): `<first> <count>` subsections of
    /// `<offset> <generation> n|f` entries, read until anything else. Each in-use entry records which number its offset is.
    func classicSection(at start: Int) {
        var i = start
        func skipWhite() { while i < bytes.count, isWhite(bytes[i]) { i += 1 } }
        func number() -> Int? {
            var n = 0, digits = 0
            while i < bytes.count, isDigit(bytes[i]), digits < 12 { n = n * 10 + Int(bytes[i] - 0x30); i += 1; digits += 1 }
            return digits > 0 ? n : nil
        }
        var rows = 0
        while true {
            skipWhite()
            guard let first = number() else { return }
            skipWhite()
            guard let count = number(), count <= Self.maxObjects * 4 else { return }
            for k in 0..<count {
                skipWhite()
                guard let offset = number() else { return }
                skipWhite()
                guard let generation = number() else { return }
                skipWhite()
                guard i < bytes.count else { return }
                if bytes[i] == 0x6E { record(number: first + k, generation: generation, offset: offset) }   // n
                if bytes[i] == 0x66 { freed.insert(first + k) }   // f
                i += 1
                rows += 1
                guard rows <= Self.maxObjects * 4 else { fail(.tooMany) }
            }
        }
    }

    func record(number: Int, generation: Int, offset: Int) {
        entries.insert(Entry(key: ObjectKey(number: number, generation: generation), offset: offset))
    }

    /// Round 5 (R5-2): a type-2 row. Two rows for one number that name different places are an anomaly.
    func recordCompressed(number: Int, _ place: Compressed) {
        if let known = compressed[number], known != place { anomaly() }
        compressed[number] = place
    }

    /// Strings, texts and names, each kept once.
    func keep(_ data: Data, in kind: UInt8) {
        guard keptEntries.insert(Data([kind]) + data).inserted else { return }
        guard data.count <= output.cap - output.written - strings.count - texts.count - names.count else { fail(.cap) }
        switch kind {
        case 0x53: strings += data; strings.append(0x0A)
        case 0x55: texts += data; texts.append(0x0A)
        default: names += data; names.append(0x0A)
        }
    }

    func keepString(_ s: CGPDFStringRef) {
        if let p = CGPDFStringGetBytePtr(s) { keep(Data(bytes: p, count: CGPDFStringGetLength(s)), in: 0x53) }
        if let t = CGPDFStringCopyTextString(s) { keep(Data((t as String).utf8), in: 0x55) }
    }

    /// A decoded stream, written once by its digest; returns the digest.
    @discardableResult
    func keepStream(_ data: Data, format: CGPDFDataFormat) -> Data {
        let kind: UInt8 = format == .raw ? 0x44 : format == .jpegEncoded ? 0x4A : 0x50
        let digest = Data(SHA256.hash(data: Data([kind]) + data))
        if digests.insert(digest).inserted { output.record(kind, data) }
        return digest
    }
}

/// One revision's walk (steps 2–4).
final class Revision {
    let owner: Extraction
    let document: CGPDFDocument
    let listed: CGPDFArrayRef
    let pins: [Header]
    var seen = Set<Int>()
    var visits = 0
    var contentStreams = Set<Int>()
    var streams: [Int: CGPDFStreamRef] = [:]

    /// What is left to walk: only the document's own containers (an object ref handed to a callback may be a temporary that
    /// dies when the callback returns, so values are read where they are met).
    enum Item {
        case array(CGPDFArrayRef)
        case dictionary(CGPDFDictionaryRef)
        case stream(CGPDFStreamRef)
    }

    var pending: [Item] = []
    let lock = NSLock()

    /// The revision `prefix` with the update that lists every object and pins every body in `pins`; nil when the reader
    /// can't open that.
    init?(of owner: Extraction, prefix: Data, pins: [Header]) {
        self.owner = owner
        self.pins = pins
        guard let augmented = Self.augmented(prefix, highest: owner.highest, generations: owner.generationList,
                                             pins: pins.map { ($0.offset, $0.key.generation) }),
              let provider = CGDataProvider(data: augmented as CFData), let document = CGPDFDocument(provider),
              let catalog = document.catalog else { return nil }
        if document.isEncrypted { fail(.encrypted) }
        var listed: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(catalog, "BrahmaAll", &listed), let listed else { return nil }
        self.document = document
        self.listed = listed
    }

    /// The prefix plus an update whose catalog (`/BrahmaAll`) lists objects 1…`highest`, every non-zero generation seen,
    /// and then fresh numbers whose entries name exactly each pinned body's offset (with its generation), in the same kind
    /// of cross-reference section as the prefix's last; nil when it ends with no `startxref`.
    static func augmented(_ prefix: Data, highest: Int, generations: [ObjectKey], pins: [(offset: Int, generation: Int)]) -> Data? {
        let bytes = [UInt8](prefix)
        let tail = Array(bytes.suffix(1024))
        let key = Array("startxref".utf8)
        var at = tail.count - key.count
        while at >= 0, !matches(key, at: at, in: tail) { at -= 1 }
        guard at >= 0 else { return nil }
        var j = at + key.count
        while j < tail.count, isWhite(tail[j]) { j += 1 }
        var previous = 0, digits = 0
        while j < tail.count, isDigit(tail[j]), digits < 12 { previous = previous * 10 + Int(tail[j] - 0x30); j += 1; digits += 1 }
        guard digits > 0, previous < bytes.count else { return nil }
        let classic = matches(Array("xref".utf8), at: previous, in: bytes)
        let first = highest + 1, firstPin = highest + 4
        var refs = highest >= 1 ? (1...highest).map { "\($0) 0 R" } : []
        refs += generations.map { "\($0.number) \($0.generation) R" }
        refs += pins.enumerated().map { "\(firstPin + $0.offset) \($0.element.generation) R" }
        var update = Data("\n".utf8)
        var offsets: [Int] = []
        func object(_ n: Int, _ body: String) {
            offsets.append(prefix.count + update.count)
            update += Data("\(n) 0 obj\n\(body)\nendobj\n".utf8)
        }
        object(first, "<< /Type /Catalog /Pages \(first + 1) 0 R /BrahmaAll [\(refs.joined(separator: " "))] >>")
        object(first + 1, "<< /Type /Pages /Kids [\(first + 2) 0 R] /Count 1 >>")
        object(first + 2, "<< /Type /Page /Parent \(first + 1) 0 R /MediaBox [0 0 1 1] >>")
        let xref = prefix.count + update.count
        func padded(_ v: Int, _ width: Int) -> String { String(repeating: "0", count: max(0, width - String(v).count)) + "\(v)" }
        if classic {
            var table = "xref\n\(first) 3\n"
            for o in offsets { table += padded(o, 10) + " 00000 n \n" }
            if !pins.isEmpty {
                table += "\(firstPin) \(pins.count)\n"
                for pin in pins { table += padded(pin.offset, 10) + " " + padded(pin.generation, 5) + " n \n" }
            }
            table += "trailer\n<< /Size \(firstPin + pins.count) /Root \(first) 0 R /Prev \(previous) >>\nstartxref\n\(xref)\n%%EOF\n"
            update += Data(table.utf8)
        } else {
            var rows = Data()
            func bigEndian(_ v: Int, _ n: Int) { for k in (0..<n).reversed() { rows.append(UInt8((v >> (8 * k)) & 0xFF)) } }
            let me = firstPin + pins.count
            for o in offsets { rows.append(1); bigEndian(o, 8); bigEndian(0, 2) }
            for pin in pins { rows.append(1); bigEndian(pin.offset, 8); bigEndian(pin.generation, 2) }
            rows.append(1); bigEndian(xref, 8); bigEndian(0, 2)
            let index = pins.isEmpty ? "\(first) 3 \(me) 1" : "\(first) 3 \(firstPin) \(pins.count + 1)"
            update += Data(("\(me) 0 obj\n<< /Type /XRef /Size \(me + 1) /Index [\(index)] /W [1 8 2] /Root \(first) 0 R "
                            + "/Prev \(previous) /Length \(rows.count) >>\nstream\n").utf8)
            update += rows
            update += Data("\nendstream\nendobj\nstartxref\n\(xref)\n%%EOF\n".utf8)
        }
        return prefix + update
    }

    /// Walks every listed object, then scans every content stream; returns the digest of the stream each listed object
    /// (number, generation) names, and of the body pinned at each offset.
    func read() -> (byKey: [ObjectKey: Data], pinned: [Int: Data], resolved: Set<ObjectKey>) {
        var byKey: [ObjectKey: Data] = [:], pinned: [Int: Data] = [:]
        var resolved = Set<ObjectKey>()
        var digestOf: [Int: Data] = [:]
        let generations = owner.generationList
        let count = CGPDFArrayGetCount(listed)
        for i in 0..<count {
            var o: CGPDFObjectRef? = nil
            guard CGPDFArrayGetObject(listed, i, &o), let o else { continue }
            // Round 5: which listed objects this revision's reader resolved to something (an object it has no place for
            // reads as null).
            if CGPDFObjectGetType(o) != .null {
                if i < owner.highest {
                    resolved.insert(ObjectKey(number: i + 1, generation: 0))
                } else if i - owner.highest < generations.count {
                    resolved.insert(generations[i - owner.highest])
                }
            }
            var s: CGPDFStreamRef? = nil
            let root = CGPDFObjectGetValue(o, .stream, &s) ? s : nil
            walk(o, digests: &digestOf)
            guard let root, let digest = digestOf[unsafeBitCast(root, to: Int.self)] else { continue }
            if i < owner.highest {
                byKey[ObjectKey(number: i + 1, generation: 0)] = digest
                owner.streamDigests[i + 1, default: []].insert(digest)
            } else if i - owner.highest < generations.count {
                byKey[generations[i - owner.highest]] = digest
            } else if i - owner.highest - generations.count < pins.count {
                pinned[pins[i - owner.highest - generations.count].offset] = digest
            }
        }
        for key in contentStreams.sorted() {
            // Round 4: a content stream marked but never decoded is refused, never skipped (round 5: an anomaly; the rest is
            // still read).
            guard let stream = streams[key] else { owner.anomaly(); continue }
            scanContent(stream)
        }
        return (byKey, pinned, resolved)
    }

    /// The dictionary object `number` (generation 0) is in this revision, if it is one.
    func dictionary(number: Int) -> CGPDFDictionaryRef? {
        guard number >= 1, number <= owner.highest else { return nil }
        var d: CGPDFDictionaryRef? = nil
        return CGPDFArrayGetDictionary(listed, number - 1, &d) ? d : nil
    }

    /// Whether object `number` (generation 0) is a cross-reference stream in this revision.
    func isCrossReferenceStream(number: Int) -> Bool {
        guard number >= 1, number <= owner.highest else { return false }
        var s: CGPDFStreamRef? = nil, type: UnsafePointer<CChar>? = nil
        guard CGPDFArrayGetStream(listed, number - 1, &s), let s, let d = CGPDFStreamGetDictionary(s),
              CGPDFDictionaryGetName(d, "Type", &type), let type else { return false }
        return String(cString: type) == "XRef"
    }

    // MARK: The walk

    /// One value, read now: a string's bytes and text, a name, or a container queued once.
    func visit(_ object: CGPDFObjectRef) {
        switch CGPDFObjectGetType(object) {
        case .string:
            var s: CGPDFStringRef? = nil
            if CGPDFObjectGetValue(object, .string, &s), let s { owner.keepString(s) }
        case .name:
            var n: UnsafePointer<CChar>? = nil
            if CGPDFObjectGetValue(object, .name, &n), let n { owner.keep(Data(String(cString: n).utf8), in: 0x4E) }
        case .array:
            var a: CGPDFArrayRef? = nil
            if CGPDFObjectGetValue(object, .array, &a), let a, seen.insert(unsafeBitCast(a, to: Int.self)).inserted { pending.append(.array(a)) }
        case .dictionary:
            var d: CGPDFDictionaryRef? = nil
            if CGPDFObjectGetValue(object, .dictionary, &d), let d, seen.insert(unsafeBitCast(d, to: Int.self)).inserted { pending.append(.dictionary(d)) }
        case .stream:
            var s: CGPDFStreamRef? = nil
            if CGPDFObjectGetValue(object, .stream, &s), let s, seen.insert(unsafeBitCast(s, to: Int.self)).inserted { pending.append(.stream(s)) }
        default:
            break
        }
    }

    /// Marks the content streams `value` holds under `key`: a page's `/Contents` (a stream or an array of them), every
    /// appearance stream under `/AP` (`/N`, `/R`, `/D`, each a stream or a dictionary of states), every `/CharProcs` glyph.
    func markContent(key: String, _ value: CGPDFObjectRef) {
        func mark(_ s: CGPDFStreamRef) { contentStreams.insert(unsafeBitCast(s, to: Int.self)) }
        func markAll(_ d: CGPDFDictionaryRef) {
            let box = Unmanaged.passRetained(StreamBox())
            defer { box.release() }
            CGPDFDictionaryApplyFunction(d, { _, value, info in
                guard let info else { return }
                var s: CGPDFStreamRef? = nil
                if CGPDFObjectGetValue(value, .stream, &s), let s { Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue().streams.append(s) }
            }, box.toOpaque())
            box.takeUnretainedValue().streams.forEach(mark)
        }
        var s: CGPDFStreamRef? = nil, a: CGPDFArrayRef? = nil, d: CGPDFDictionaryRef? = nil
        switch key {
        case "Contents":
            if CGPDFObjectGetValue(value, .stream, &s), let s { mark(s) }
            if CGPDFObjectGetValue(value, .array, &a), let a {
                for i in 0..<CGPDFArrayGetCount(a) {
                    var e: CGPDFStreamRef? = nil
                    if CGPDFArrayGetStream(a, i, &e), let e { mark(e) }
                }
            }
        case "AP":
            guard CGPDFObjectGetValue(value, .dictionary, &d), let d else { return }
            for state in ["N", "R", "D"] {
                var one: CGPDFStreamRef? = nil, many: CGPDFDictionaryRef? = nil
                if CGPDFDictionaryGetStream(d, state, &one), let one { mark(one) }
                if CGPDFDictionaryGetDictionary(d, state, &many), let many { markAll(many) }
            }
        case "CharProcs":
            if CGPDFObjectGetValue(value, .dictionary, &d), let d { markAll(d) }
        default:
            break
        }
    }

    final class StreamBox { var streams: [CGPDFStreamRef] = [] }

    /// Every key and value of `d`, read inside the (synchronous) applier.
    func entries(_ d: CGPDFDictionaryRef) {
        let context = Unmanaged.passRetained(self)
        defer { context.release() }
        CGPDFDictionaryApplyFunction(d, { key, value, info in
            guard let info else { return }
            let me = Unmanaged<Revision>.fromOpaque(info).takeUnretainedValue()
            me.lock.lock()
            defer { me.lock.unlock() }
            let name = String(cString: key)
            me.owner.keep(Data(name.utf8), in: 0x4E)
            me.markContent(key: name, value)
            me.visit(value)
        }, context.toOpaque())
    }

    /// A cross-reference stream may only describe objects up to the highest number the update listed.
    /// Its rows (decoded) record which object (number, generation) each in-use (type 1) entry says starts at its offset.
    func checkCrossReference(_ d: CGPDFDictionaryRef, rows: Data) {
        var type: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(d, "Type", &type), let type, String(cString: type) == "XRef" else { return }
        // Round 5: a section that can't be read is an anomaly (the rest of the file is still read).
        var size: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(d, "Size", &size), size >= 0, size - 1 <= owner.highest else { owner.anomaly(); return }
        var ranges: [(start: Int, count: Int)] = []
        var index: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetArray(d, "Index", &index), let index {
            var k = 0
            while k + 1 < CGPDFArrayGetCount(index) {
                var start: CGPDFInteger = 0, count: CGPDFInteger = 0
                guard CGPDFArrayGetInteger(index, k, &start), CGPDFArrayGetInteger(index, k + 1, &count), start >= 0, count >= 0,
                      count <= Extraction.maxObjects * 4 else { owner.anomaly(); return }
                if count > 0, start.addingReportingOverflow(count - 1).partialValue > owner.highest { owner.anomaly(); return }
                ranges.append((start, count))
                k += 2
            }
        } else {
            ranges = [(0, size)]
        }
        // The field widths: each at most 8 bytes; a row is their sum.
        var widths: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(d, "W", &widths), let widths, CGPDFArrayGetCount(widths) == 3 else { owner.anomaly(); return }
        var w = [0, 0, 0]
        for k in 0..<3 {
            var v: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(widths, k, &v), v >= 0, v <= 8 else { owner.anomaly(); return }
            w[k] = v
        }
        let row = w[0] + w[1] + w[2]
        guard row > 0 else { owner.anomaly(); return }
        let b = [UInt8](rows)
        var at = 0
        func field(_ width: Int) -> Int {
            var v = 0
            for _ in 0..<width { v = v << 8 | Int(b[at]); at += 1 }
            return v
        }
        for range in ranges {
            for k in 0..<range.count {
                guard b.count - at >= row else { owner.anomaly(); return }
                let kind = w[0] == 0 ? 1 : field(w[0])
                let offset = field(w[1])
                let generation = field(w[2])
                switch kind {
                case 0: owner.freed.insert(range.start + k)
                case 1: owner.record(number: range.start + k, generation: generation, offset: offset)
                // Round 5 (R5-2): an object in an object stream (field 2 the stream's number, field 3 the index).
                case 2: owner.recordCompressed(number: range.start + k, Compressed(stream: offset, index: generation))
                // A row of a type the format does not define: nothing a reader agrees on (fail closed).
                default: owner.anomaly()
                }
            }
        }
    }

    /// Round 5 (R5-2): for an object stream (`/Type /ObjStm`), the object numbers its header lists, in order: `/N` pairs of
    /// non-negative integers (number, offset) in the decoded bytes before `/First`; `.some(nil)` when that does not parse.
    /// Nil for any other stream.
    func objectStreamHeader(_ d: CGPDFDictionaryRef, _ decoded: Data) -> [Int]?? {
        var type: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(d, "Type", &type), let type, String(cString: type) == "ObjStm" else { return nil }
        var count: CGPDFInteger = 0, first: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(d, "N", &count), CGPDFDictionaryGetInteger(d, "First", &first), count >= 0,
              count <= Extraction.maxObjects, first >= 0, first <= decoded.count else { return .some(nil) }
        let b = [UInt8](decoded.prefix(first))
        var values: [Int] = [], i = 0
        while values.count < 2 * count {
            while i < b.count, isWhite(b[i]) { i += 1 }
            var v = 0, digits = 0
            while i < b.count, isDigit(b[i]), digits < 12 { v = v * 10 + Int(b[i] - 0x30); i += 1; digits += 1 }
            guard digits > 0, i == b.count || isWhite(b[i]) else { return .some(nil) }
            values.append(v)
        }
        return .some(stride(from: 0, to: values.count, by: 2).map { values[$0] })
    }

    /// Form XObjects and tiling patterns are content streams whatever refers to them.
    func isContentByType(_ d: CGPDFDictionaryRef) -> Bool {
        var subtype: UnsafePointer<CChar>? = nil
        if CGPDFDictionaryGetName(d, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" { return true }
        var patternType: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(d, "PatternType", &patternType) && patternType == 1
    }

    func walk(_ root: CGPDFObjectRef, digests: inout [Int: Data]) {
        lock.withLock { visit(root) }
        while let item = lock.withLock({ pending.popLast() }) {
            visits += 1
            guard visits <= Extraction.maxVisits else { fail(.tooMany) }
            switch item {
            case .array(let a):
                for i in 0..<CGPDFArrayGetCount(a) {
                    var o: CGPDFObjectRef? = nil
                    if CGPDFArrayGetObject(a, i, &o), let o { lock.withLock { visit(o) } }
                }
            case .dictionary(let d):
                entries(d)
            case .stream(let s):
                guard let d = CGPDFStreamGetDictionary(s) else { fail(.undecodable) }
                var format = CGPDFDataFormat.raw
                guard let decoded = CGPDFStreamCopyData(s, &format) as Data? else { fail(.undecodable) }
                // A filtered stream that decodes to nothing from more bytes than an empty zlib stream holds did not decode.
                var length: CGPDFInteger = 0
                _ = CGPDFDictionaryGetInteger(d, "Length", &length)
                var filter: CGPDFObjectRef? = nil
                if CGPDFDictionaryGetObject(d, "Filter", &filter), decoded.isEmpty, length > 8 { fail(.undecodable) }
                checkCrossReference(d, rows: decoded)
                let key = unsafeBitCast(s, to: Int.self)
                let digest = owner.keepStream(decoded, format: format)
                digests[key] = digest
                if owner.objectStreamHeaders[digest] == nil, let header = objectStreamHeader(d, decoded) {
                    owner.objectStreamHeaders[digest] = .some(header)
                }
                streams[key] = s
                if format == .raw, isContentByType(d) { contentStreams.insert(key) }
                if seen.insert(unsafeBitCast(d, to: Int.self)).inserted { entries(d) }
            }
        }
    }

    // MARK: Content streams (round 3, C-2)

    /// The operators whose operands are shown or attached text.
    nonisolated(unsafe) static let operators: CGPDFOperatorTableRef? = {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        let string: CGPDFOperatorCallback = { scanner, info in
            guard let info else { return }
            var s: CGPDFStringRef? = nil
            if CGPDFScannerPopString(scanner, &s), let s { Unmanaged<Revision>.fromOpaque(info).takeUnretainedValue().owner.keepString(s) }
        }
        let array: CGPDFOperatorCallback = { scanner, info in
            guard let info else { return }
            var a: CGPDFArrayRef? = nil
            guard CGPDFScannerPopArray(scanner, &a), let a else { return }
            let me = Unmanaged<Revision>.fromOpaque(info).takeUnretainedValue()
            for i in 0..<CGPDFArrayGetCount(a) {
                var s: CGPDFStringRef? = nil
                if CGPDFArrayGetString(a, i, &s), let s { me.owner.keepString(s) }
            }
        }
        let properties: CGPDFOperatorCallback = { scanner, info in
            guard let info else { return }
            var o: CGPDFObjectRef? = nil
            guard CGPDFScannerPopObject(scanner, &o), let o else { return }
            Unmanaged<Revision>.fromOpaque(info).takeUnretainedValue().keepStrings(in: o, depth: 0)
        }
        for op in ["Tj", "'", "\""] { CGPDFOperatorTableSetCallback(table, op, string) }
        CGPDFOperatorTableSetCallback(table, "TJ", array)
        for op in ["BDC", "DP"] { CGPDFOperatorTableSetCallback(table, op, properties) }
        return table
    }()

    /// Every string in a marked-content property list (nested up to 8 levels).
    func keepStrings(in object: CGPDFObjectRef, depth: Int) {
        guard depth < 8 else { return }
        var s: CGPDFStringRef? = nil, a: CGPDFArrayRef? = nil, d: CGPDFDictionaryRef? = nil
        if CGPDFObjectGetValue(object, .string, &s), let s { owner.keepString(s) }
        if CGPDFObjectGetValue(object, .array, &a), let a {
            for i in 0..<CGPDFArrayGetCount(a) {
                var e: CGPDFObjectRef? = nil
                if CGPDFArrayGetObject(a, i, &e), let e { keepStrings(in: e, depth: depth + 1) }
            }
        }
        if CGPDFObjectGetValue(object, .dictionary, &d), let d {
            final class Box { var me: Revision; var depth: Int; init(_ me: Revision, _ depth: Int) { self.me = me; self.depth = depth } }
            let box = Unmanaged.passRetained(Box(self, depth))
            defer { box.release() }
            CGPDFDictionaryApplyFunction(d, { _, value, info in
                guard let info else { return }
                let b = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                b.me.keepStrings(in: value, depth: b.depth + 1)
            }, box.toOpaque())
        }
    }

    /// The scanner over one content stream; one it can't scan is refused.
    func scanContent(_ stream: CGPDFStreamRef) {
        // The scanner wants a parent content stream and resources: the update's own blank page, and the stream's own
        // `/Resources` (or its dictionary; the scanner only reads operands).
        guard let table = Self.operators, let page = document.page(at: 1), let streamDictionary = CGPDFStreamGetDictionary(stream) else {
            fail(.undecodable)
        }
        var resources: CGPDFDictionaryRef? = nil
        _ = CGPDFDictionaryGetDictionary(streamDictionary, "Resources", &resources)
        let parent = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(parent) }
        let content = CGPDFContentStreamCreateWithStream(stream, resources ?? streamDictionary, parent)
        let context = Unmanaged.passRetained(self)
        defer { context.release(); CGPDFContentStreamRelease(content) }
        let scanner = CGPDFScannerCreate(content, table, context.toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        guard CGPDFScannerScan(scanner) else { fail(.undecodable) }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4, let cap = Int(arguments[2]), cap > 0 else { fail(.usage) }
/// The memory self-check: past `limit` the process exits at once (a decompression bomb needs no exploit to get there).
func watchMemory(limit: Int) {
    Thread.detachNewThread {
        while true {
            if footprint() > limit { _exit(Status.memory.rawValue) }
            usleep(20_000)
        }
    }
}
guard let limit = arguments.count == 4 ? Int(arguments[3]) : 1 << 30, limit > 0 else { fail(.usage) }
watchMemory(limit: limit)
guard let original = FileManager.default.contents(atPath: arguments[1]), !original.isEmpty else { fail(.unreadable) }
Extraction(original: original, cap: cap).run()
#else
// No PDFKit (Linux): nothing can be read here.
exit(7)
#endif
