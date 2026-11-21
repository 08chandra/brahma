import Foundation
#if canImport(Compression)
import Compression
#endif

/// C2b fix round 2 (controller ruling 33; R2-1, R2-4, R2-5): what the gate finds inside bytes that hold other data, on the
/// one shared budget (`ArchiveScanBudget`: decompressed bytes, entries, depth, time).
/// - A zip (`ArchiveMemberScan.isArchive`): its members, through the sandboxed unzip.
/// - A PDF (`isPDF`: the `pdf` extension, or a `%PDF-<digit>` header anywhere in the bytes, where lenient readers find it):
///   never parsed here. The reader's sandboxed `brahma-pdf` helper hands back every stream decoded, every string, name and
///   the page text (`ArchiveReader.pdfParts`); each part is scanned, and each decoded stream is checked again as below. Any
///   failure of the helper (no helper, encryption, a stream that does not decode, data no object holds, a cap, a crash, a
///   kill, a timeout) refuses.
/// - A PNG: its chunks walked strictly here (`pngTexts`); `zTXt`, `iCCP` and compressed `iTXt` inflated and scanned.
/// Every part decoded out of a container is refused when it is compressed in a format the engine can't open, else scanned
/// and, when it is itself a container, opened again one level deeper (`inner`). Findings have line 0. Nothing here traps
/// on any input: every length and offset is checked against what is left before it is used.
enum EmbeddedContent {
    /// The least each inflate may produce whatever its input's size (then at most `ArchiveLimits.maxRatio` × the input).
    static let minOutput = 65_536

    static let badPNG = ArchiveReadError.refused("this PNG has a chunk that can't be checked for secrets")
    static let badInflate = ArchiveReadError.refused("this PNG has a compressed chunk that can't be decoded for scanning")

    /// Every finding inside `data` (`level` levels down from the bytes the gate was given). Bytes that hold no container
    /// give none. Throws `ArchiveReadError`.
    static func scan(_ data: Data, ext: String, archives: any ArchiveReader, expanded: [(name: String, value: String)],
                     budget: ArchiveScanBudget, level: Int, chunk: Int) throws -> [ScanFinding] {
        let archive = ArchiveMemberScan.isArchive(data, ext: ext), pdf = isPDF(data, ext: ext), png = isPNG(data)
        guard archive || pdf || png else { return [] }
        try budget.ensure(level < budget.depth)
        var found: [ScanFinding] = []
        if archive {
            found += try ArchiveMemberScan.scan(data, archives: archives, expanded: expanded, budget: budget, level: level, chunk: chunk)
        }
        if pdf {
            found += try pdfFindings(data, archives: archives, expanded: expanded, budget: budget, level: level, chunk: chunk)
        }
        if png {
            for text in try pngTexts(data, budget: budget) {
                found += try inner(text, ext: "", container: "PNG", archives: archives, expanded: expanded, budget: budget, level: level, chunk: chunk)
            }
        }
        return found.map { ScanFinding(label: $0.label, line: 0, isKnownValue: $0.isKnownValue) }
    }

    /// A part decoded out of a container at `level`: refused when compressed in a format the engine can't open; else scanned
    /// as bytes, then opened one level deeper if it holds a container itself.
    static func inner(_ data: Data, ext: String, container: String, archives: any ArchiveReader, expanded: [(name: String, value: String)],
                      budget: ArchiveScanBudget, level: Int, chunk: Int) throws -> [ScanFinding] {
        if let format = ArchiveMemberScan.unscannableFormat(data) {
            throw ArchiveReadError.refused("this \(container) holds \(format) data, which can't be scanned for secrets")
        }
        var found = try ArchiveMemberScan.scanBytes(data, expanded: expanded, chunk: chunk)
        found += try scan(data, ext: ext, archives: archives, expanded: expanded, budget: budget, level: level + 1, chunk: chunk)
        return found
    }

    // MARK: PDF

    static let pdfMagic = Data("%PDF-".utf8)

    /// A PDF by its name, or by a `%PDF-` header followed by a version digit anywhere in the bytes.
    static func isPDF(_ data: Data, ext: String) -> Bool {
        if ext.lowercased() == "pdf" { return true }
        var from = data.startIndex
        while from < data.endIndex, let r = data.range(of: pdfMagic, in: from..<data.endIndex) {
            if r.upperBound < data.endIndex, (0x30...0x39).contains(data[r.upperBound]) { return true }
            from = r.lowerBound + 1
        }
        return false
    }

    /// The PDF's parts from the reader's helper, all spent from the budget (bytes; every stream an entry), each scanned, each
    /// stream checked again.
    static func pdfFindings(_ data: Data, archives: any ArchiveReader, expanded: [(name: String, value: String)],
                            budget: ArchiveScanBudget, level: Int, chunk: Int) throws -> [ScanFinding] {
        try budget.ensure(budget.bytes > 0)
        try budget.launch()
        guard let left = budget.remaining else { throw ArchiveMemberScan.outOfTime }
        let parts = try archives.pdfParts(of: data, maxBytes: budget.bytes, timeout: left)
        var total = 0, streams = 0
        for part in parts {
            total += part.data.count
            if part.kind.isStream { streams += 1 }
        }
        budget.bytes -= total
        budget.entries -= streams
        try budget.ensure(budget.bytes >= 0 && budget.entries >= 0)
        var found: [ScanFinding] = []
        for part in parts {
            if part.kind.isStream {
                found += try inner(part.data, ext: "", container: "PDF", archives: archives, expanded: expanded, budget: budget,
                                   level: level, chunk: chunk)
            } else {
                found += try ArchiveMemberScan.scanBytes(part.data, expanded: expanded, chunk: chunk)
            }
        }
        return found
    }

    // MARK: PNG (R2-5)

    static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func isPNG(_ data: Data) -> Bool { [UInt8](data.prefix(8)) == pngMagic }

    /// The chunk types a PNG may hold besides the text chunks decoded here: the critical ones and the registered ancillary
    /// ones that hold no compressed data (their bytes are scanned with the file's own). Anything else is refused.
    static let plainChunks: Set<String> = [
        "IHDR", "PLTE", "IDAT", "tRNS", "cHRM", "gAMA", "sBIT", "sRGB", "cICP", "mDCV", "cLLI", "tEXt", "bKGD", "hIST", "pHYs",
        "sPLT", "eXIf", "tIME", "acTL", "fcTL", "fdAT", "oFFs", "pCAL", "sCAL", "sTER", "gIFg", "iDOT",
    ]

    /// The inflated text of every `zTXt`, `iCCP` and compressed `iTXt` chunk. Strict (anything else refuses, `badPNG`):
    /// the signature; `IHDR` first; every chunk's length within the file and at most 2^31 - 1, its type four ASCII letters,
    /// its CRC right; a keyword of 1–79 bytes; an `iTXt` compression flag of 0 or 1 and method 0; only known chunk types;
    /// `IEND`, empty, as the last bytes of the file. A text chunk that does not inflate refuses (`badInflate`).
    static func pngTexts(_ data: Data, budget: ArchiveScanBudget) throws -> [Data] {
        let b = [UInt8](data)
        guard b.count >= 8, Array(b[0..<8]) == pngMagic else { throw badPNG }
        var out: [Data] = []
        var i = 8
        var first = true
        while true {
            guard b.count - i >= 12 else { throw badPNG }
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length <= 0x7FFF_FFFF, length <= b.count - i - 12 else { throw badPNG }
            let typeBytes = b[(i + 4)..<(i + 8)]
            guard typeBytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) else { throw badPNG }
            let type = String(decoding: typeBytes, as: UTF8.self)
            let end = i + 8 + length
            let stored = UInt32(b[end]) << 24 | UInt32(b[end + 1]) << 16 | UInt32(b[end + 2]) << 8 | UInt32(b[end + 3])
            guard crc32(b[(i + 4)..<end]) == stored else { throw badPNG }
            let body = Array(b[(i + 8)..<end])
            i = end + 4
            try budget.ensure(true)
            if first {
                guard type == "IHDR" else { throw badPNG }
                first = false
            }
            switch type {
            case "IEND":
                guard length == 0, i == b.count else { throw badPNG }
                return out
            case "zTXt", "iCCP":
                guard let nul = body.firstIndex(of: 0), nul >= 1, nul <= 79, body.count - nul >= 2, body[nul + 1] == 0 else { throw badPNG }
                out.append(try inflateChunk(Data(body[(nul + 2)...]), budget: budget))
            case "iTXt":
                guard let nul = body.firstIndex(of: 0), nul >= 1, nul <= 79, body.count - nul >= 3 else { throw badPNG }
                let flag = body[nul + 1], method = body[nul + 2]
                guard flag == 0 || flag == 1, method == 0 else { throw badPNG }
                var j = nul + 3
                for _ in 0..<2 {   // the language tag, the translated keyword
                    guard j <= body.count, let z = body[j...].firstIndex(of: 0) else { throw badPNG }
                    j = z + 1
                }
                if flag == 1 { out.append(try inflateChunk(Data(body[j...]), budget: budget)) }
            default:
                guard plainChunks.contains(type) else { throw badPNG }
            }
        }
    }

    static func inflateChunk(_ data: Data, budget: ArchiveScanBudget) throws -> Data {
        let out = try inflateZlib(data, cap: outputCap(input: data.count, budget: budget), failure: badInflate)
        budget.bytes -= out.count
        try budget.ensure(budget.bytes >= 0)
        return out
    }

    /// At most what the budget has left, and at most `ArchiveLimits.maxRatio` × the input (at least `minOutput`).
    static func outputCap(input: Int, budget: ArchiveScanBudget) -> Int {
        let (ratio, overflow) = input.multipliedReportingOverflow(by: Int(ArchiveLimits.maxRatio))
        return max(0, min(budget.bytes, max(minOutput, overflow ? Int.max : ratio)))
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (ISO 3309, as PNG and zip use it).
    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: Inflate

    /// zlib (RFC 1950) data inflated to at most `cap` bytes (`ArchiveMemberScan.overBudget` past it); `failure` when it is
    /// not zlib, does not decode, or ends before its last block.
    static func inflateZlib(_ data: Data, cap: Int, failure: ArchiveReadError) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 2, b[0] & 0x0F == 8, (Int(b[0]) << 8 | Int(b[1])) % 31 == 0, b[1] & 0x20 == 0 else { throw failure }
        return try inflateRaw(Data(b[2...]), cap: cap, failure: failure)
    }

    /// Raw DEFLATE through Apple's bounded `Compression` stream; where there is none (Linux), nothing compressed is decoded
    /// and it refuses.
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
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { throw failure }
            stream.src_ptr = base
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                guard produced >= 0, produced <= cap - out.count else { throw ArchiveMemberScan.overBudget }
                out.append(dst, count: produced)
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK:
                    // No progress with all input given: it ended before its last block.
                    if produced == 0 && stream.src_size == 0 { throw failure }
                default: throw failure
                }
            }
        }
        #else
        throw failure
        #endif
    }
}
