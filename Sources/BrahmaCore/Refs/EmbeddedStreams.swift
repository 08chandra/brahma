import Foundation
#if canImport(Compression)
import Compression
#endif

/// C2b fix round 1, R1-9 (controller ruling 31): compressed data inside formats the gate recognises is decoded and scanned,
/// within the same shared budget as nested archives (`ArchiveScanBudget`), never passed unseen.
/// - PDF (a `%PDF-` header in the first 1024 bytes, or the `pdf` extension): an `/Encrypt` anywhere refuses; every stream is
///   decoded through its filter chain (FlateDecode with PNG/TIFF predictors, LZWDecode, ASCIIHexDecode, ASCII85Decode,
///   RunLengthDecode; image codecs — DCT, JPX, JBIG2, CCITTFax — end the chain, their bytes are pixels and stay raw-scanned),
///   and the decoded bytes are scanned, plus the text of their string literals joined (`[(sk_)-20(…)]TJ`). An unknown
///   filter, `/Crypt`, more than one `/Filter` in a stream's dictionary, or a stream that does not decode refuses.
/// - PNG: every `zTXt`, compressed `iTXt` and `iCCP` chunk is inflated and scanned; one that does not inflate, or a chunk
///   structure that does not hold together, refuses.
/// Inflating is bounded: each stream's output at most `ArchiveLimits.maxRatio` × its input (and at least 64 KiB), and every
/// output byte is spent from the budget (`ArchiveMemberScan.overBudget` past it). Where the platform has no bounded inflate
/// (no `Compression` framework), a compressed stream can't be decoded and refuses.
enum EmbeddedStreams {
    static let maxStreams = 20_000
    static let minOutput = 65_536

    static func undecodable(_ filter: String) -> ArchiveReadError {
        .refused("this PDF has a stream that can't be decoded for scanning (\(filter))")
    }
    static let encrypted = ArchiveReadError.refused("this PDF is encrypted, so it can't be scanned for secrets")
    static let badPNG = ArchiveReadError.refused("this PNG has a compressed chunk that can't be decoded for scanning")

    /// Every finding in the decoded streams of `data` (line 0). Throws `ArchiveReadError`.
    static func scan(_ data: Data, ext: String, expanded: [(name: String, value: String)], budget: ArchiveScanBudget,
                     chunk: Int) throws -> [ScanFinding] {
        var found: [ScanFinding] = []
        func add(_ decoded: Data) throws {
            found += try ArchiveMemberScan.scanBytes(decoded, expanded: expanded, chunk: chunk)
        }
        if isPDF(data, ext: ext) {
            for decoded in try pdfStreams(data, budget: budget) {
                try add(decoded)
                let text = literalText(decoded)
                if !text.isEmpty { try add(text) }
            }
        } else if isPNG(data) {
            for decoded in try pngChunks(data, budget: budget) { try add(decoded) }
        }
        var seen = Set<String>()
        return found.map { ScanFinding(label: $0.label, line: 0, isKnownValue: $0.isKnownValue) }
            .filter { seen.insert("\($0.label)\n\($0.isKnownValue)").inserted }
    }

    // MARK: PDF

    static func isPDF(_ data: Data, ext: String) -> Bool {
        ext.lowercased() == "pdf" || data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    static let imageCodecs: Set<String> = ["DCTDecode", "DCT", "JPXDecode", "JBIG2Decode", "CCITTFaxDecode", "CCF"]

    /// The decoded bytes of every stream of the PDF `data`.
    static func pdfStreams(_ data: Data, budget: ArchiveScanBudget) throws -> [Data] {
        let bytes = [UInt8](data)
        if data.range(of: Data("/Encrypt".utf8)) != nil { throw encrypted }
        var out: [Data] = []
        var search = 0
        let keyword = Array("stream".utf8)
        while let at = find(bytes, keyword, from: search) {
            search = at + keyword.count
            // Not the tail of `endstream`, and after the dictionary's `>>`.
            if at >= 3, Array(bytes[(at - 3)..<at]) == Array("end".utf8) { continue }
            var back = at - 1
            while back >= 0, isWhite(bytes[back]) { back -= 1 }
            guard back >= 1, bytes[back] == 0x3E, bytes[back - 1] == 0x3E else { continue }
            // The data starts after the keyword's end of line (CR LF, LF, or a lone CR some writers use).
            var start = at + keyword.count
            if start + 1 < bytes.count, bytes[start] == 0x0D, bytes[start + 1] == 0x0A {
                start += 2
            } else if start < bytes.count, bytes[start] == 0x0A || bytes[start] == 0x0D {
                start += 1
            } else {
                continue
            }
            guard out.count < maxStreams else { throw ArchiveMemberScan.overBudget }
            guard !budget.expired else { throw ArchiveMemberScan.overBudget }
            let dictionary = String(decoding: bytes[max(0, objectStart(bytes, before: back))..<(back + 1)], as: UTF8.self)
            let end = streamEnd(bytes, start: start, dictionary: dictionary)
            guard let end else { throw undecodable("unterminated") }
            var payload = Data(bytes[start..<end])
            let filters = try filterChain(dictionary)
            let parms = decodeParms(dictionary)
            for filter in filters {
                if imageCodecs.contains(filter) { break }
                payload = try decode(payload, filter: filter, parms: parms, budget: budget)
            }
            out.append(payload)
            search = end
        }
        return out
    }

    /// Where the object holding the stream starts (its `obj` keyword), at most 4096 bytes back.
    static func objectStart(_ b: [UInt8], before: Int) -> Int {
        let floor = max(0, before - 4096)
        var i = before - 3
        while i >= floor {
            if b[i] == 0x6F, b[i + 1] == 0x62, b[i + 2] == 0x6A { return i + 3 }   // "obj"
            i -= 1
        }
        return floor
    }

    /// The end of the stream's data: `/Length` when it is a direct number followed by `endstream`, else the first
    /// `endstream` (an end of line before it trimmed).
    static func streamEnd(_ b: [UInt8], start: Int, dictionary: String) -> Int? {
        if let length = directLength(dictionary), length >= 0, start + length <= b.count {
            var i = start + length
            while i < b.count, isWhite(b[i]) { i += 1 }
            if i + 9 <= b.count, Array(b[i..<(i + 9)]) == Array("endstream".utf8) { return start + length }
        }
        guard var end = find(b, Array("endstream".utf8), from: start) else { return nil }
        if end > start, b[end - 1] == 0x0A { end -= 1 }
        if end > start, b[end - 1] == 0x0D { end -= 1 }
        return end
    }

    static func directLength(_ dictionary: String) -> Int? {
        guard let r = dictionary.range(of: "/Length") else { return nil }
        let rest = dictionary[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = rest.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "/" || $0 == ">" }).prefix(3).map(String.init)
        guard let first = parts.first, let n = Int(first) else { return nil }
        if parts.count >= 3, Int(parts[1]) != nil, parts[2] == "R" { return nil }   // an indirect length
        return n
    }

    /// The stream's filters, in order. More than one `/Filter` key, `/Crypt`, or a name the gate can't decode refuses.
    static func filterChain(_ dictionary: String) throws -> [String] {
        let occurrences = dictionary.components(separatedBy: "/Filter").count - 1
        guard occurrences <= 1 else { throw undecodable("Filter") }
        guard let r = dictionary.range(of: "/Filter") else { return [] }
        var rest = dictionary[r.upperBound...].drop { $0 == " " || $0 == "\n" || $0 == "\r" }
        var names: [String] = []
        if rest.first == "[" {
            rest = rest.dropFirst()
            guard let close = rest.firstIndex(of: "]") else { throw undecodable("Filter") }
            names = rest[..<close].split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if rest.first == "/" {
            let name = rest.dropFirst().prefix { !" \n\r/<>[]".contains($0) }
            names = [String(name)]
        } else {
            throw undecodable("Filter")
        }
        let known: Set<String> = ["FlateDecode", "Fl", "LZWDecode", "LZW", "ASCIIHexDecode", "AHx", "ASCII85Decode", "A85",
                                  "RunLengthDecode", "RL"]
        for name in names where !known.contains(name) && !imageCodecs.contains(name) { throw undecodable(name) }
        return names
    }

    /// `/Predictor`, `/Columns`, `/Colors`, `/BitsPerComponent` and `/EarlyChange` of the stream's decode parameters.
    struct Parms { var predictor = 1; var columns = 1; var colors = 1; var bits = 8; var earlyChange = 1 }

    static func decodeParms(_ dictionary: String) -> Parms {
        var p = Parms()
        func int(_ key: String) -> Int? {
            guard let r = dictionary.range(of: "/\(key)") else { return nil }
            let rest = dictionary[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(rest.prefix { $0.isNumber })
        }
        if let v = int("Predictor") { p.predictor = v }
        if let v = int("Columns") { p.columns = v }
        if let v = int("Colors") { p.colors = v }
        if let v = int("BitsPerComponent") { p.bits = v }
        if let v = int("EarlyChange") { p.earlyChange = v }
        return p
    }

    static func decode(_ data: Data, filter: String, parms: Parms, budget: ArchiveScanBudget) throws -> Data {
        let cap = outputCap(input: data.count, budget: budget)
        let out: Data
        switch filter {
        case "FlateDecode", "Fl":
            out = try predictor(try inflateZlib(data, cap: cap, failure: undecodable("FlateDecode")), parms, name: "FlateDecode")
        case "LZWDecode", "LZW":
            out = try predictor(try lzw(data, earlyChange: parms.earlyChange, cap: cap), parms, name: "LZWDecode")
        case "ASCIIHexDecode", "AHx": out = try asciiHex(data)
        case "ASCII85Decode", "A85": out = try ascii85(data, cap: cap)
        case "RunLengthDecode", "RL": out = try runLength(data, cap: cap)
        default: throw undecodable(filter)
        }
        try spend(out.count, budget)
        return out
    }

    static func outputCap(input: Int, budget: ArchiveScanBudget) -> Int {
        min(budget.bytes, max(minOutput, input.multipliedReportingOverflow(by: Int(ArchiveLimits.maxRatio)).partialValue))
    }

    static func spend(_ n: Int, _ budget: ArchiveScanBudget) throws {
        budget.bytes -= n
        guard budget.bytes >= 0, !budget.expired else { throw ArchiveMemberScan.overBudget }
    }

    /// Undoes a PNG (10–15) or TIFF (2) predictor; 1 is none. Anything else refuses.
    static func predictor(_ data: Data, _ p: Parms, name: String) throws -> Data {
        if p.predictor <= 1 { return data }
        guard p.bits == 8, (1...32).contains(p.colors), p.columns >= 1, p.columns <= 1 << 20 else { throw undecodable(name) }
        let bpp = p.colors
        let row = p.columns * p.colors
        let b = [UInt8](data)
        if p.predictor == 2 {
            var out = b
            var i = 0
            while i < out.count {
                for j in bpp..<min(row, out.count - i) { out[i + j] = out[i + j] &+ out[i + j - bpp] }
                i += row
            }
            return Data(out)
        }
        guard (10...15).contains(p.predictor) else { throw undecodable(name) }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var prior = [UInt8](repeating: 0, count: row)
        var i = 0
        while i < b.count {
            let type = b[i]
            let line = Array(b[(i + 1)..<min(i + 1 + row, b.count)])
            var cur = [UInt8](repeating: 0, count: line.count)
            for x in 0..<line.count {
                let a: Int = x >= bpp ? Int(cur[x - bpp]) : 0
                let up = Int(prior[x])
                let c: Int = x >= bpp ? Int(prior[x - bpp]) : 0
                let add: Int
                switch type {
                case 0: add = 0
                case 1: add = a
                case 2: add = up
                case 3: add = (a + up) / 2
                case 4:
                    let pp = a + up - c, pa = abs(pp - a), pb = abs(pp - up), pc = abs(pp - c)
                    add = pa <= pb && pa <= pc ? a : pb <= pc ? up : c
                default: throw undecodable(name)
                }
                cur[x] = UInt8(truncatingIfNeeded: Int(line[x]) + add)
            }
            out += cur
            for x in 0..<cur.count { prior[x] = cur[x] }
            i += 1 + row
        }
        return Data(out)
    }

    static func asciiHex(_ data: Data) throws -> Data {
        var out = Data()
        var high: UInt8?
        for c in data {
            if c == 0x3E { break }
            if isWhite(c) { continue }
            let v: UInt8
            switch c {
            case 0x30...0x39: v = c - 0x30
            case 0x41...0x46: v = c - 0x37
            case 0x61...0x66: v = c - 0x57
            default: throw undecodable("ASCIIHexDecode")
            }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        if let h = high { out.append(h << 4) }
        return out
    }

    static func ascii85(_ data: Data, cap: Int) throws -> Data {
        var out = Data()
        var group: [UInt32] = []
        func flush(_ count: Int) {
            var value: UInt32 = 0
            for d in group + [UInt32](repeating: 84, count: 5 - group.count) { value = value &* 85 &+ d }
            let bytes: [UInt8] = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
            out.append(contentsOf: bytes.prefix(count))
        }
        var i = data.startIndex
        if data.starts(with: Data("<~".utf8)) { i += 2 }
        while i < data.endIndex {
            let c = data[i]
            i += 1
            if c == 0x7E { break }
            if isWhite(c) { continue }
            if c == 0x7A, group.isEmpty { out.append(contentsOf: [0, 0, 0, 0]); continue }
            guard (0x21...0x75).contains(c) else { throw undecodable("ASCII85Decode") }
            group.append(UInt32(c - 0x21))
            if group.count == 5 { flush(4); group = [] }
            if out.count > cap { throw ArchiveMemberScan.overBudget }
        }
        if !group.isEmpty {
            guard group.count >= 2 else { throw undecodable("ASCII85Decode") }
            flush(group.count - 1)
        }
        return out
    }

    static func runLength(_ data: Data, cap: Int) throws -> Data {
        let b = [UInt8](data)
        var out = Data()
        var i = 0
        while i < b.count {
            let n = Int(b[i])
            i += 1
            if n == 128 { break }
            if n < 128 {
                guard i + n + 1 <= b.count else { throw undecodable("RunLengthDecode") }
                out.append(contentsOf: b[i..<(i + n + 1)])
                i += n + 1
            } else {
                guard i < b.count else { throw undecodable("RunLengthDecode") }
                out.append(contentsOf: [UInt8](repeating: b[i], count: 257 - n))
                i += 1
            }
            if out.count > cap { throw ArchiveMemberScan.overBudget }
        }
        return out
    }

    /// PDF's LZW (9–12-bit codes, 256 clear, 257 end).
    static func lzw(_ data: Data, earlyChange: Int, cap: Int) throws -> Data {
        let b = [UInt8](data)
        var table: [[UInt8]] = (0..<256).map { [UInt8($0)] } + [[], []]
        var width = 9
        var bitPos = 0
        var out: [UInt8] = []
        var previous: [UInt8]?
        func next() -> Int? {
            guard bitPos + width <= b.count * 8 else { return nil }
            var v = 0
            for k in 0..<width {
                let bit = (b[(bitPos + k) / 8] >> (7 - UInt8((bitPos + k) % 8))) & 1
                v = v << 1 | Int(bit)
            }
            bitPos += width
            return v
        }
        while let code = next() {
            if code == 256 { table = Array(table.prefix(258)); width = 9; previous = nil; continue }
            if code == 257 { break }
            let entry: [UInt8]
            if code < table.count, code != 256, code != 257 {
                entry = table[code]
            } else if code == table.count, let p = previous {
                entry = p + [p[0]]
            } else {
                throw undecodable("LZWDecode")
            }
            out += entry
            guard out.count <= cap else { throw ArchiveMemberScan.overBudget }
            if let p = previous, table.count < 4096 { table.append(p + [entry[0]]) }
            previous = entry
            let limit = (1 << width) - (earlyChange == 0 ? 0 : 1)
            if table.count >= limit, width < 12 { width += 1 }
        }
        return Data(out)
    }

    /// The text of the PDF string literals in `content`, joined (`[(sk_)-20(…)]TJ` reads as one string): `(…)` with its
    /// escapes and nesting, and `<hex>` strings.
    static func literalText(_ content: Data) -> Data {
        let b = [UInt8](content)
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            if b[i] == 0x28 {   // (
                var depth = 1
                i += 1
                while i < b.count, depth > 0 {
                    let c = b[i]
                    if c == 0x5C, i + 1 < b.count {
                        let e = b[i + 1]
                        switch e {
                        case 0x6E: out.append(0x0A)
                        case 0x72: out.append(0x0D)
                        case 0x74: out.append(0x09)
                        case 0x0A, 0x0D: break
                        default: out.append(e)
                        }
                        i += 2
                        continue
                    }
                    if c == 0x28 { depth += 1 }
                    if c == 0x29 { depth -= 1; if depth == 0 { break } }
                    out.append(c)
                    i += 1
                }
            } else if b[i] == 0x3C, i + 1 < b.count, b[i + 1] != 0x3C {   // <hex>, not <<
                var j = i + 1
                var hex: [UInt8] = []
                while j < b.count, b[j] != 0x3E { hex.append(b[j]); j += 1 }
                if let decoded = try? asciiHex(Data(hex)) { out += decoded }
                i = j
            }
            i += 1
        }
        return Data(out)
    }

    // MARK: PNG

    static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func isPNG(_ data: Data) -> Bool { [UInt8](data.prefix(8)) == pngMagic }

    /// The inflated text of every `zTXt`, compressed `iTXt` and `iCCP` chunk.
    static func pngChunks(_ data: Data, budget: ArchiveScanBudget) throws -> [Data] {
        let b = [UInt8](data)
        var out: [Data] = []
        var i = 8
        while i < b.count {
            guard i + 8 <= b.count else { throw badPNG }
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            guard length >= 0, i + 12 + length <= b.count else { throw badPNG }
            let body = Array(b[(i + 8)..<(i + 8 + length)])
            i += 12 + length
            guard !budget.expired else { throw ArchiveMemberScan.overBudget }
            switch type {
            case "zTXt", "iCCP":
                guard let nul = body.firstIndex(of: 0), nul + 1 < body.count, body[nul + 1] == 0 else { throw badPNG }
                out.append(try inflateChunk(Data(body[(nul + 2)...]), budget: budget))
            case "iTXt":
                guard let nul = body.firstIndex(of: 0), nul + 2 < body.count else { throw badPNG }
                let compressed = body[nul + 1] == 1
                guard !compressed || body[nul + 2] == 0 else { throw badPNG }
                var j = nul + 3
                for _ in 0..<2 {   // language tag, translated keyword
                    guard let z = body[j...].firstIndex(of: 0) else { throw badPNG }
                    j = z + 1
                }
                if compressed { out.append(try inflateChunk(Data(body[j...]), budget: budget)) }
            case "IEND":
                return out
            default:
                break
            }
        }
        return out
    }

    static func inflateChunk(_ data: Data, budget: ArchiveScanBudget) throws -> Data {
        let out = try inflateZlib(data, cap: outputCap(input: data.count, budget: budget), failure: badPNG)
        try spend(out.count, budget)
        return out
    }

    // MARK: Inflate

    /// zlib (RFC 1950) data inflated to at most `cap` bytes (`ArchiveMemberScan.overBudget` past it); `failure` when it is
    /// not zlib, does not decode, or ends before its last block.
    static func inflateZlib(_ data: Data, cap: Int, failure: ArchiveReadError) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 2, b[0] & 0x0F == 8, (Int(b[0]) << 8 | Int(b[1])) % 31 == 0, b[1] & 0x20 == 0 else { throw failure }
        return try inflateRaw(Data(b[2...]), cap: cap, failure: failure)
    }

    static func inflateRaw(_ data: Data, cap: Int, failure: ArchiveReadError) throws -> Data {
        #if canImport(Compression)
        guard !data.isEmpty else { throw failure }
        let chunk = 65_536
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw failure }
        defer { compression_stream_destroy(&stream) }
        var out = Data()
        return try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: chunk - stream.dst_size)
                if out.count > cap { throw ArchiveMemberScan.overBudget }
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK:
                    // No progress with all input given: it ended before its last block.
                    if stream.dst_size == chunk && stream.src_size == 0 { throw failure }
                default: throw failure
                }
            }
        }
        #else
        throw failure
        #endif
    }

    // MARK: Bytes

    static func isWhite(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }

    static func find(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, from >= 0, haystack.count - needle.count >= from else { return nil }
        var i = from
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}
