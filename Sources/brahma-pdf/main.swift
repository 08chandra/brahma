// brahma-pdf: the PDF extraction helper (Plan C task C2b, fix round 2, controller ruling 33).
//
// The engine never parses a PDF. It runs this helper under Seatbelt (`SandboxedPDFReader`, the same pattern as the sandboxed
// unzip: no network, read access to the one input file and this binary, write access to one output directory, a hard time
// limit, output cut at a byte cap) and scans what it hands back under the gate's one shared budget.
//
//     brahma-pdf <input.pdf> <max output bytes>
//
// What it does, with Apple's own reader (CoreGraphics, PDFKit):
// 1. Counts every `stream` keyword in the file as a lexer sees it (a token of its own), and notes every `<n> <g> obj` header
//    and every `/Size` (the highest object number the file can use).
// 2. Opens the file; an encrypted one is refused.
// 3. Appends an incremental update (in memory) whose catalog lists every object number up to that highest one (and every
//    non-zero generation seen), in the same kind of cross-reference section as the file's last one, then opens that. The
//    reader's own parse now reaches every object the file holds, used or not: objects in object streams, cross-reference
//    and object streams themselves, objects nothing refers to.
// 4. Walks every object from that list: every stream decoded (`CGPDFStreamCopyData`), every string (its bytes, and as text),
//    every name. A stream that does not decode is refused. A cross-reference stream naming objects past the highest number
//    is refused.
// 5. Refuses unless the streams it reached are exactly the `stream` keywords the file holds: a stray stream, or an earlier
//    revision's stream that an update replaced, is data no walk reaches.
// 6. Adds the page text as PDFKit extracts it.
//
// Output (stdout): "BRAHMA-PDF/1\n", then records (a kind byte, a 4-byte big-endian length, the payload), then an `E`
// record whose 8-byte big-endian payload is the number of records before it. Kinds: `D` a decoded stream, `J` a stream
// left in JPEG form, `P` one left in JPEG 2000 form, `S` every string's bytes, `U` every string as text, `N` every name,
// `T` the page text (each of the last four one record, entries separated by line feeds). The whole output, framing
// included, stays within the byte cap, or the run fails.
//
// Exit status: 0 done; 2 usage; 3 encrypted; 4 a stream that does not decode; 5 data no walk reaches (or objects past the
// declared ones); 6 the output cap; 7 not a PDF this reader can open; 8 too many objects. Anything but 0 is a refusal.
import Foundation
#if canImport(PDFKit) && canImport(CoreGraphics)
import CoreGraphics
import PDFKit

enum Status: Int32 { case usage = 2, encrypted = 3, undecodable = 4, unaccounted = 5, cap = 6, unreadable = 7, tooMany = 8 }

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
    /// At most this many objects are visited in the walk.
    static let maxVisits = 5_000_000

    let original: Data
    let bytes: [UInt8]
    let output: Output
    var streamTokens = 0
    var generations = Set<[Int]>()   // (number, generation) of every header with a generation other than 0
    var highest = 0                  // the highest object number the file can use
    var strings = Data(), texts = Data(), names = Data()
    var seen = Set<Int>()
    var streams = 0
    var visits = 0

    init(original: Data, cap: Int) {
        self.original = original
        bytes = [UInt8](original)
        output = Output(cap: cap)
    }

    func run() -> Never {
        lex()
        guard highest < Self.maxObjects else { fail(.tooMany) }
        guard let originalProvider = CGDataProvider(data: original as CFData), let originalDocument = CGPDFDocument(originalProvider) else {
            fail(.unreadable)
        }
        if originalDocument.isEncrypted { fail(.encrypted) }
        guard let provider = CGDataProvider(data: augmented() as CFData), let document = CGPDFDocument(provider),
              let catalog = document.catalog else { fail(.unreadable) }
        if document.isEncrypted { fail(.encrypted) }
        var listed: CGPDFArrayRef? = nil
        guard CGPDFDictionaryGetArray(catalog, "BrahmaAll", &listed), let listed else { fail(.unreadable) }
        for i in 0..<CGPDFArrayGetCount(listed) {
            var o: CGPDFObjectRef? = nil
            if CGPDFArrayGetObject(listed, i, &o), let o { walk(o) }
        }
        // Every stream keyword in the file is a stream the walk reached; anything else is data no reader ties to an object.
        guard streams == streamTokens else { fail(.unaccounted) }
        // The page text.
        guard let pdf = PDFDocument(data: original) else { fail(.unreadable) }
        if pdf.isEncrypted || pdf.isLocked { fail(.encrypted) }
        var pages = Data()
        for i in 0..<pdf.pageCount {
            if let text = pdf.page(at: i)?.string, !text.isEmpty { collect(&pages, Data(text.utf8)) }
        }
        for (kind, data) in [(UInt8(0x53), strings), (0x55, texts), (0x4E, names), (0x54, pages)] where !data.isEmpty {
            output.record(kind, data)
        }
        output.finish()
        exit(0)
    }

    /// Step 1: the `stream` keywords, the object headers and the `/Size` values in the file's bytes.
    func lex() {
        let streamWord = Array("stream".utf8), objWord = Array("obj".utf8), sizeWord = Array("/Size".utf8)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x73, matches(streamWord, at: i, in: bytes), i == 0 || !isRegular(bytes[i - 1]),
               i + streamWord.count == bytes.count || !isRegular(bytes[i + streamWord.count]) {
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
            }
            i += 1
        }
    }

    /// The file plus an update whose catalog (`/BrahmaAll`) lists objects 1…`highest` and every non-zero generation seen.
    func augmented() -> Data {
        let tail = Array(bytes.suffix(1024))
        let key = Array("startxref".utf8)
        var at = tail.count - key.count
        while at >= 0, !matches(key, at: at, in: tail) { at -= 1 }
        guard at >= 0 else { fail(.unreadable) }
        var j = at + key.count
        while j < tail.count, isWhite(tail[j]) { j += 1 }
        var previous = 0, digits = 0
        while j < tail.count, isDigit(tail[j]), digits < 12 { previous = previous * 10 + Int(tail[j] - 0x30); j += 1; digits += 1 }
        guard digits > 0, previous < bytes.count else { fail(.unreadable) }
        let classic = matches(Array("xref".utf8), at: previous, in: bytes)
        let first = highest + 1
        var refs = highest >= 1 ? (1...highest).map { "\($0) 0 R" } : []
        refs += generations.sorted { $0.lexicographicallyPrecedes($1) }.map { "\($0[0]) \($0[1]) R" }
        var update = Data("\n".utf8)
        var offsets: [Int] = []
        func object(_ n: Int, _ body: String) {
            offsets.append(original.count + update.count)
            update += Data("\(n) 0 obj\n\(body)\nendobj\n".utf8)
        }
        object(first, "<< /Type /Catalog /Pages \(first + 1) 0 R /BrahmaAll [\(refs.joined(separator: " "))] >>")
        object(first + 1, "<< /Type /Pages /Kids [\(first + 2) 0 R] /Count 1 >>")
        object(first + 2, "<< /Type /Page /Parent \(first + 1) 0 R /MediaBox [0 0 1 1] >>")
        let xref = original.count + update.count
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
        return original + update
    }

    func collect(_ into: inout Data, _ data: Data) {
        guard data.count <= output.cap - output.written - into.count else { fail(.cap) }
        into += data
        into.append(0x0A)
    }

    /// What is left to walk: only the document's own containers (an object ref handed to a callback may be a temporary that
    /// dies when the callback returns, so values are read where they are met).
    enum Item {
        case array(CGPDFArrayRef)
        case dictionary(CGPDFDictionaryRef)
        case stream(CGPDFStreamRef)
    }

    var pending: [Item] = []
    let lock = NSLock()

    /// One value, read now: a string's bytes and text, a name, or a container queued once.
    func visit(_ object: CGPDFObjectRef) {
        switch CGPDFObjectGetType(object) {
        case .string:
            var s: CGPDFStringRef? = nil
            guard CGPDFObjectGetValue(object, .string, &s), let s else { return }
            if let p = CGPDFStringGetBytePtr(s) { collect(&strings, Data(bytes: p, count: CGPDFStringGetLength(s))) }
            if let t = CGPDFStringCopyTextString(s) { collect(&texts, Data((t as String).utf8)) }
        case .name:
            var n: UnsafePointer<CChar>? = nil
            if CGPDFObjectGetValue(object, .name, &n), let n { collect(&names, Data(String(cString: n).utf8)) }
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

    /// Every key and value of `d`, read inside the (synchronous) applier.
    func entries(_ d: CGPDFDictionaryRef) {
        let context = Unmanaged.passRetained(self)
        defer { context.release() }
        CGPDFDictionaryApplyFunction(d, { key, value, info in
            guard let info else { return }
            let me = Unmanaged<Extraction>.fromOpaque(info).takeUnretainedValue()
            me.lock.lock()
            defer { me.lock.unlock() }
            me.collect(&me.names, Data(String(cString: key).utf8))
            me.visit(value)
        }, context.toOpaque())
    }

    /// A cross-reference stream may only describe objects up to the highest number the update listed.
    func checkCrossReference(_ d: CGPDFDictionaryRef) {
        var type: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(d, "Type", &type), let type, String(cString: type) == "XRef" else { return }
        var size: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(d, "Size", &size), size - 1 > highest { fail(.unaccounted) }
        var index: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetArray(d, "Index", &index), let index {
            var k = 0
            while k + 1 < CGPDFArrayGetCount(index) {
                var start: CGPDFInteger = 0, count: CGPDFInteger = 0
                guard CGPDFArrayGetInteger(index, k, &start), CGPDFArrayGetInteger(index, k + 1, &count) else { fail(.unaccounted) }
                if count > 0, start + count - 1 > highest { fail(.unaccounted) }
                k += 2
            }
        }
    }

    func walk(_ root: CGPDFObjectRef) {
        lock.withLock { visit(root) }
        while let item = lock.withLock({ pending.popLast() }) {
            visits += 1
            guard visits <= Self.maxVisits else { fail(.tooMany) }
            switch item {
            case .array(let a):
                for i in 0..<CGPDFArrayGetCount(a) {
                    var o: CGPDFObjectRef? = nil
                    if CGPDFArrayGetObject(a, i, &o), let o { lock.withLock { visit(o) } }
                }
            case .dictionary(let d):
                entries(d)
            case .stream(let s):
                streams += 1
                guard let d = CGPDFStreamGetDictionary(s) else { fail(.undecodable) }
                var format = CGPDFDataFormat.raw
                guard let decoded = CGPDFStreamCopyData(s, &format) as Data? else { fail(.undecodable) }
                // A filtered stream that decodes to nothing from more bytes than an empty zlib stream holds did not decode.
                var length: CGPDFInteger = 0
                _ = CGPDFDictionaryGetInteger(d, "Length", &length)
                var filter: CGPDFObjectRef? = nil
                if CGPDFDictionaryGetObject(d, "Filter", &filter), decoded.isEmpty, length > 8 { fail(.undecodable) }
                checkCrossReference(d)
                output.record(format == .raw ? 0x44 : format == .jpegEncoded ? 0x4A : 0x50, decoded)
                if seen.insert(unsafeBitCast(d, to: Int.self)).inserted { entries(d) }
            }
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let cap = Int(arguments[2]), cap > 0 else { fail(.usage) }
guard let original = FileManager.default.contents(atPath: arguments[1]), !original.isEmpty else { fail(.unreadable) }
Extraction(original: original, cap: cap).run()
#else
// No PDFKit (Linux): nothing can be read here.
exit(7)
#endif
