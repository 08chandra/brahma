// brahma-pdf: the PDF extraction helper (Plan C task C2b, fix rounds 2 and 3, controller ruling 33).
//
// The engine never parses a PDF. It runs this helper under Seatbelt (`SandboxedPDFReader`: a deny-default profile that lets
// it read the system's libraries, this binary and the one input file, write only its two outputs, and nothing else; a hard
// time limit; a memory watchdog; the output cut at a byte cap) and scans what it hands back under the gate's one budget.
//
//     brahma-pdf <input.pdf> <max output bytes> [<memory limit in bytes>]
//
// What it does, with Apple's own reader (CoreGraphics, PDFKit):
// 1. Counts every `stream` keyword in the file (a `stream` that no regular character comes before, whatever follows it),
//    notes every `<n> <g> obj` header and every `/Size` (the highest object number the file can use), and where each
//    revision ends (every `%%EOF`).
// 2. For EVERY revision (the file cut after each `%%EOF`, and the whole file): opens it (an encrypted one is refused);
//    appends an incremental update (in memory) whose catalog lists every object number up to that highest one (and every
//    non-zero generation seen), in the same kind of cross-reference section as the revision's last one, then opens that.
//    The reader's own parse then reaches every object that revision holds, used or not: objects in object streams, the
//    cross-reference and object streams themselves, objects nothing refers to. A revision the reader can't open adds
//    nothing (step 5 still has to account for its streams).
// 3. Walks every object from that list: every stream decoded (`CGPDFStreamCopyData`; a stream that does not decode is
//    refused), every string (its bytes, and as text), every name. A cross-reference stream naming objects past the
//    highest number is refused. Each decoded stream is kept once, by its digest (round 3: two object numbers that name
//    one object are one stream, never two).
// 4. Runs CoreGraphics' content-stream scanner over every content stream (page contents, every annotation appearance and
//    appearance state, every Form XObject, Type 3 glyph procedures, tiling patterns) and keeps every string a text or
//    marked-content operator takes (`Tj`, `TJ`, `'`, `"`, `BDC`, `DP`), escapes decoded. A content stream it can't scan
//    is refused.
// 5. Refuses unless the distinct streams decoded across all revisions are exactly the `stream` keywords the file holds: a
//    stray stream, or a second body of one object in one revision, is data no walk reaches. An object whose stream reads
//    differently in a later revision must have a new body in that revision's bytes, else it is refused.
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
// Exit status: 0 done; 2 usage; 3 encrypted; 4 a stream (or content stream) that can't be decoded; 5 data no walk
// reaches; 6 the output cap; 7 not a PDF this reader can open; 8 too many objects or revisions; 9 the memory limit.
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

/// One run over one file (steps 1–6 above).
final class Extraction {
    /// At most this many object numbers are listed (a larger file is refused).
    static let maxObjects = 500_000
    /// At most this many objects are visited in one revision's walk.
    static let maxVisits = 5_000_000
    /// At most this many revisions are read.
    static let maxRevisions = 64

    let original: Data
    let bytes: [UInt8]
    let output: Output
    var streamTokens = 0
    var headers: [(number: Int, offset: Int)] = []
    var generations = Set<[Int]>()   // (number, generation) of every header with a generation other than 0
    /// The numbers of the generations listed after objects 1…highest, in the update's order.
    var generationNumbers: [Int] { generations.sorted { $0.lexicographicallyPrecedes($1) }.map { $0[0] } }
    var highest = 0                  // the highest object number the file can use
    var revisionEnds: [Int] = []
    var strings = Data(), texts = Data(), names = Data()
    var keptEntries = Set<Data>()    // every string, text and name kept once
    var digests = Set<Data>()        // every decoded stream, across every revision, written once
    var streamObjects = Set<String>() // every stream object read: its number and its digest, across every revision
    var numbersAt: [Int: Set<Int>] = [:]   // every offset a cross-reference section names, and the numbers it names there

    init(original: Data, cap: Int) {
        self.original = original
        bytes = [UInt8](original)
        output = Output(cap: cap)
    }

    func run() -> Never {
        lex()
        guard highest < Self.maxObjects else { fail(.tooMany) }
        var ends = revisionEnds
        if ends.last != bytes.count { ends.append(bytes.count) }
        guard ends.count <= Self.maxRevisions else { fail(.tooMany) }
        var opened = false
        var previous: (end: Int, streams: [Int: Data])?
        for end in ends {
            let prefix = original.prefix(end)
            guard let provider = CGDataProvider(data: prefix as CFData), let document = CGPDFDocument(provider) else { continue }
            if document.isEncrypted { fail(.encrypted) }
            guard let walked = Revision(of: self, prefix: prefix)?.read() else { continue }
            opened = true
            // An object whose stream reads differently from the revision before must have a new body in this revision.
            if let previous {
                let rewritten = Set(headers.filter { $0.offset >= previous.end && $0.offset < end }.map(\.number))
                for (number, digest) in walked where previous.streams[number].map({ $0 != digest }) == true && !rewritten.contains(number) {
                    fail(.unaccounted)
                }
            }
            previous = (end, walked)
        }
        guard opened else { fail(.unreadable) }
        // Two object numbers naming one object (the offset where its `n g obj` header starts) would let one stream stand in
        // for another: refused (round 3, C-1). Entries naming offsets where no object starts name nothing.
        let bodies = Set(headers.map(\.offset))
        guard numbersAt.allSatisfy({ !bodies.contains($0.key) || $0.value.count == 1 }) else { fail(.unaccounted) }
        // Every stream keyword in the file is a distinct stream object (number and content) some revision's walk decoded.
        guard streamObjects.count == streamTokens else { fail(.unaccounted) }
        // The page text of the last revision.
        guard let pdf = PDFDocument(data: original) else { fail(.unreadable) }
        if pdf.isEncrypted || pdf.isLocked { fail(.encrypted) }
        var pages = Data()
        for i in 0..<pdf.pageCount {
            if let text = pdf.page(at: i)?.string, !text.isEmpty { pages += Data(text.utf8); pages.append(0x0A) }
        }
        for (kind, data) in [(UInt8(0x53), strings), (0x55, texts), (0x4E, names), (0x54, pages)] where !data.isEmpty {
            output.record(kind, data)
        }
        output.finish()
        exit(0)
    }

    /// Step 1: the `stream` keywords, the object headers, the `/Size` values and the revision ends in the file's bytes.
    func lex() {
        let streamWord = Array("stream".utf8), objWord = Array("obj".utf8), sizeWord = Array("/Size".utf8), eofWord = Array("%%EOF".utf8)
        let xrefWord = Array("xref".utf8)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x73, matches(streamWord, at: i, in: bytes), i == 0 || !isRegular(bytes[i - 1]) {
                // Round 3 (m-B): whatever follows it, data straight after the keyword included.
                streamTokens += 1
            } else if c == 0x6F, i > 0, matches(objWord, at: i, in: bytes), !isRegular(bytes[i - 1]),
                      i + objWord.count == bytes.count || !isRegular(bytes[i + objWord.count]) {
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
                    headers.append((number, j + 1))
                    if generation != 0 { generations.insert([number, generation]) }
                }
            } else if c == 0x2F, matches(sizeWord, at: i, in: bytes) {
                var j = i + sizeWord.count
                if j == bytes.count || !isRegular(bytes[j]) || isDigit(bytes[j]) {
                    while j < bytes.count, isWhite(bytes[j]) { j += 1 }
                    var size = 0, digits = 0
                    while j < bytes.count, isDigit(bytes[j]), digits < 9 { size = size * 10 + Int(bytes[j] - 0x30); j += 1; digits += 1 }
                    if digits > 0 { highest = max(highest, size - 1) }
                }
            } else if c == 0x78, matches(xrefWord, at: i, in: bytes), i == 0 || !isRegular(bytes[i - 1]),
                      i + xrefWord.count < bytes.count, isWhite(bytes[i + xrefWord.count]) {
                classicSection(at: i + xrefWord.count)
            } else if c == 0x25, matches(eofWord, at: i, in: bytes) {
                var end = i + eofWord.count
                while end < bytes.count, bytes[end] == 0x0D || bytes[end] == 0x0A { end += 1 }
                revisionEnds.append(end)
            }
            i += 1
        }
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
                guard number() != nil else { return }
                skipWhite()
                guard i < bytes.count else { return }
                if bytes[i] == 0x6E { record(number: first + k, offset: offset) }   // n
                i += 1
                rows += 1
                guard rows <= Self.maxObjects * 4 else { fail(.tooMany) }
            }
        }
    }

    func record(number: Int, offset: Int) { numbersAt[offset, default: []].insert(number) }

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

    /// A decoded stream, kept once by its digest; true when it is new.
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

    /// The revision `prefix` with the update that lists every object; nil when the reader can't open that.
    init?(of owner: Extraction, prefix: Data) {
        self.owner = owner
        guard let augmented = Self.augmented(prefix, highest: owner.highest, generations: owner.generations),
              let provider = CGDataProvider(data: augmented as CFData), let document = CGPDFDocument(provider),
              let catalog = document.catalog else { return nil }
        if document.isEncrypted { fail(.encrypted) }
        var listed: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(catalog, "BrahmaAll", &listed), let listed else { return nil }
        self.document = document
        self.listed = listed
    }

    /// The prefix plus an update whose catalog (`/BrahmaAll`) lists objects 1…`highest` and every non-zero generation seen,
    /// in the same kind of cross-reference section as the prefix's last; nil when it ends with no `startxref`.
    static func augmented(_ prefix: Data, highest: Int, generations: Set<[Int]>) -> Data? {
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
        let first = highest + 1
        var refs = highest >= 1 ? (1...highest).map { "\($0) 0 R" } : []
        refs += generations.sorted { $0.lexicographicallyPrecedes($1) }.map { "\($0[0]) \($0[1]) R" }
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
        if classic {
            var table = "xref\n\(first) 3\n"
            for o in offsets { table += String(repeating: "0", count: max(0, 10 - String(o).count)) + "\(o) 00000 n \n" }
            table += "trailer\n<< /Size \(first + 3) /Root \(first) 0 R /Prev \(previous) >>\nstartxref\n\(xref)\n%%EOF\n"
            update += Data(table.utf8)
        } else {
            var rows = Data()
            func bigEndian(_ v: Int, _ n: Int) { for k in (0..<n).reversed() { rows.append(UInt8((v >> (8 * k)) & 0xFF)) } }
            for o in offsets + [xref] { rows.append(1); bigEndian(o, 8); bigEndian(0, 2) }
            update += Data(("\(first + 3) 0 obj\n<< /Type /XRef /Size \(first + 4) /Index [\(first) 4] /W [1 8 2] /Root \(first) 0 R "
                            + "/Prev \(previous) /Length \(rows.count) >>\nstream\n").utf8)
            update += rows
            update += Data("\nendstream\nendobj\nstartxref\n\(xref)\n%%EOF\n".utf8)
        }
        return prefix + update
    }

    /// Walks every listed object, then scans every content stream; returns the digest of the stream each listed object
    /// number names (object streams can't hold streams, so every stream has a number of its own).
    func read() -> [Int: Data] {
        var byNumber: [Int: Data] = [:]
        var digestOf: [Int: Data] = [:]
        let count = CGPDFArrayGetCount(listed)
        for i in 0..<count {
            var o: CGPDFObjectRef? = nil
            guard CGPDFArrayGetObject(listed, i, &o), let o else { continue }
            var s: CGPDFStreamRef? = nil
            let root = CGPDFObjectGetValue(o, .stream, &s) ? s : nil
            walk(o, digests: &digestOf)
            guard let root, let digest = digestOf[unsafeBitCast(root, to: Int.self)] else { continue }
            let number = i < owner.highest ? i + 1 : owner.generationNumbers[i - owner.highest]
            if i < owner.highest { byNumber[number] = digest }
            owner.streamObjects.insert("\(number) \(digest.base64EncodedString())")
        }
        for key in contentStreams.sorted() {
            guard let stream = streams[key] else { continue }
            scanContent(stream)
        }
        return byNumber
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
    /// Its rows (decoded) record which number each in-use (type 1) entry's offset is.
    func checkCrossReference(_ d: CGPDFDictionaryRef, rows: Data) {
        var type: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(d, "Type", &type), let type, String(cString: type) == "XRef" else { return }
        var size: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(d, "Size", &size), size >= 0 else { fail(.unaccounted) }
        if size - 1 > owner.highest { fail(.unaccounted) }
        var ranges: [(start: Int, count: Int)] = []
        var index: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetArray(d, "Index", &index), let index {
            var k = 0
            while k + 1 < CGPDFArrayGetCount(index) {
                var start: CGPDFInteger = 0, count: CGPDFInteger = 0
                guard CGPDFArrayGetInteger(index, k, &start), CGPDFArrayGetInteger(index, k + 1, &count), start >= 0, count >= 0,
                      count <= Extraction.maxObjects * 4 else { fail(.unaccounted) }
                if count > 0, start.addingReportingOverflow(count - 1).partialValue > owner.highest { fail(.unaccounted) }
                ranges.append((start, count))
                k += 2
            }
        } else {
            ranges = [(0, size)]
        }
        // The field widths: each at most 8 bytes; a row is their sum.
        var widths: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(d, "W", &widths), let widths, CGPDFArrayGetCount(widths) == 3 else { fail(.unaccounted) }
        var w = [0, 0, 0]
        for k in 0..<3 {
            var v: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(widths, k, &v), v >= 0, v <= 8 else { fail(.unaccounted) }
            w[k] = v
        }
        let row = w[0] + w[1] + w[2]
        guard row > 0 else { fail(.unaccounted) }
        let b = [UInt8](rows)
        var at = 0
        func field(_ width: Int) -> Int {
            var v = 0
            for _ in 0..<width { v = v << 8 | Int(b[at]); at += 1 }
            return v
        }
        for range in ranges {
            for k in 0..<range.count {
                guard b.count - at >= row else { fail(.unaccounted) }
                let kind = w[0] == 0 ? 1 : field(w[0])
                let offset = field(w[1])
                _ = field(w[2])
                if kind == 1 { owner.record(number: range.start + k, offset: offset) }
            }
        }
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
                digests[key] = owner.keepStream(decoded, format: format)
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
