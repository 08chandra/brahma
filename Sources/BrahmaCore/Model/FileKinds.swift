import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The kinds of file Brahma knows: what an owner can drop as a resource (ML) and what can be published as an artifact (4a).
/// ML owns this table; 4a consumes it unchanged. Anything not in it (a `.zip` included: archives are handled by the caller)
/// is not a known kind.
public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case html, markdown, pdf, image, video, table, spreadsheet, document, model3d, cad, text, code

    /// Streaming playlists: refused, since the media they name lives elsewhere (artifacts: "publish the video file";
    /// resources: "add the video file").
    public static let playlistExtensions = ["m3u8", "m3u", "mpd", "pls"]

    /// The kind of a file name, by its lowercased extension (`ext(of:)`); nil for anything not in the table.
    public static func from(fileName: String) -> ArtifactKind? { from(ext: ext(of: fileName)) }

    /// The kind of a lowercased extension; nil for anything not in the table.
    public static func from(ext: String) -> ArtifactKind? { extensionTable[ext.lowercased()]?.kind }

    /// The lowercased extension of a file name: what follows the last dot. A dotfile with no other dot is its own extension
    /// (`.env` → `env`); a name without a dot, or ending in one, has none (`""`).
    public static func ext(of fileName: String) -> String {
        let name = fileName.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? fileName
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Whether files of this kind are text as a whole kind. Some extensions of other kinds are text too (svg, and the text 3D
    /// formats): `isText(ext:)` answers per file.
    public var isText: Bool {
        switch self {
        case .html, .markdown, .table, .text, .code: true
        case .pdf, .image, .video, .spreadsheet, .document, .model3d, .cad: false
        }
    }

    /// Whether a file with this extension is text (scanned for secret patterns, indexed as text): the text kinds, plus `svg`
    /// and the text 3D formats (`gltf`, `usda`, `obj`, `dae`). False for anything not in the table.
    public static func isText(ext: String) -> Bool { extensionTable[ext.lowercased()]?.isText ?? false }

    /// Whether files with this extension are zip containers (docx, xlsx, pptx, key, pages, numbers, usdz). Their archive
    /// gets every check a dropped `.zip` gets, so a renamed bomb is still a bomb.
    public static func isZipContainer(ext: String) -> Bool { extensionTable[ext.lowercased()]?.sniff == .zip }

    /// How the first bytes of a file are checked against its extension (`ArtifactSniffer`).
    enum Sniff: Sendable {
        case text, svg, pdf, png, jpeg, gif, webp, heic, tiff, mp4, mov, zip, cfb, rtf, glb, usdc, extensionOnly
    }

    static let extensionTable: [String: (kind: ArtifactKind, sniff: Sniff, isText: Bool)] = {
        var t: [String: (kind: ArtifactKind, sniff: Sniff, isText: Bool)] = [:]
        func add(_ kind: ArtifactKind, _ sniff: Sniff, _ isText: Bool, _ exts: String...) {
            for e in exts { t[e] = (kind, sniff, isText) }
        }
        add(.html, .text, true, "html", "htm")
        add(.markdown, .text, true, "md", "markdown")
        add(.pdf, .pdf, false, "pdf")
        add(.image, .png, false, "png")
        add(.image, .jpeg, false, "jpg", "jpeg")
        add(.image, .gif, false, "gif")
        add(.image, .webp, false, "webp")
        add(.image, .heic, false, "heic")
        add(.image, .tiff, false, "tiff", "tif")
        add(.image, .svg, true, "svg")
        add(.video, .mp4, false, "mp4", "m4v")
        add(.video, .mov, false, "mov")
        add(.table, .text, true, "csv", "tsv")
        add(.spreadsheet, .zip, false, "xlsx", "numbers")
        add(.spreadsheet, .cfb, false, "xls")
        add(.document, .zip, false, "docx", "pptx", "key", "pages")
        add(.document, .cfb, false, "doc", "ppt", "msg")
        add(.document, .rtf, false, "rtf")
        add(.model3d, .text, true, "gltf", "usda", "obj", "dae")
        add(.model3d, .glb, false, "glb")
        add(.model3d, .usdc, false, "usdc")
        add(.model3d, .zip, false, "usdz")
        add(.model3d, .extensionOnly, false, "stl", "usd")
        add(.cad, .text, false, "step", "stp", "iges", "igs")
        add(.text, .text, true, "txt", "json", "yaml", "yml", "log", "eml")
        add(.code, .text, true, "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "c", "h",
            "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "zsh", "bash", "sql", "toml", "ini", "xml", "css", "scss", "env",
            "cfg", "conf")
        return t
    }()
}

/// Whether a file's first bytes match its extension. A mismatch is refused: `"the file's content doesn't match .<ext>"`.
public enum ArtifactSniffer {
    /// How many leading bytes the rules look at.
    public static let headBytes = 64

    public static func mismatch(ext: String) -> String { "the file's content doesn't match .\(ext)" }

    /// True when `head` (the first up-to-64 bytes) fits the rule for `ext` and `ext` is of `kind`. Unknown extensions never
    /// match.
    public static func matches(kind: ArtifactKind, ext: String, head: Data) -> Bool {
        guard let row = ArtifactKind.extensionTable[ext.lowercased()], row.kind == kind else { return false }
        return matches(row.sniff, Array(head.prefix(headBytes)))
    }

    /// A zip archive's first bytes: a local file header, or the end record of an empty archive.
    public static func isZip(_ head: Data) -> Bool {
        let h = Array(head.prefix(4))
        return h == [0x50, 0x4B, 0x03, 0x04] || h == [0x50, 0x4B, 0x05, 0x06]
    }

    /// The text rule: valid UTF-8 with no NUL byte. A multi-byte sequence cut off at the end is allowed only when `head` is
    /// the full 64 bytes (the cut is ours, not the file's).
    public static func isText(_ head: Data) -> Bool { isText(Array(head.prefix(headBytes))) }

    static func isText(_ b: [UInt8]) -> Bool {
        let truncatedOK = b.count >= headBytes
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0 { return false }
            if c < 0x80 { i += 1; continue }
            var len = 0, lo: UInt8 = 0x80, hi: UInt8 = 0xBF
            switch c {
            case 0xC2...0xDF: len = 2
            case 0xE0: len = 3; lo = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: len = 3
            case 0xED: len = 3; hi = 0x9F
            case 0xF0: len = 4; lo = 0x90
            case 0xF1...0xF3: len = 4
            case 0xF4: len = 4; hi = 0x8F
            default: return false
            }
            for k in 1..<len {
                guard i + k < b.count else { return truncatedOK }
                let n = b[i + k]
                let (l, h) = k == 1 ? (lo, hi) : (UInt8(0x80), UInt8(0xBF))
                if n < l || n > h { return false }
            }
            i += len
        }
        return true
    }

    private static func at(_ b: [UInt8], _ offset: Int, _ bytes: [UInt8]) -> Bool {
        b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
    }

    private static func at(_ b: [UInt8], _ offset: Int, _ ascii: String) -> Bool { at(b, offset, Array(ascii.utf8)) }

    private static let cfb: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    static func matches(_ sniff: ArtifactKind.Sniff, _ b: [UInt8]) -> Bool {
        switch sniff {
        case .text: return isText(b)
        case .svg:
            guard isText(b) else { return false }
            var rest = b[...]
            if at(b, 0, [0xEF, 0xBB, 0xBF]) { rest = rest.dropFirst(3) }
            let trimmed = Array(rest.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
            return at(trimmed, 0, "<svg") || at(trimmed, 0, "<?xml")
        case .pdf: return at(b, 0, "%PDF-")
        case .png: return at(b, 0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case .jpeg: return at(b, 0, [0xFF, 0xD8, 0xFF])
        case .gif: return at(b, 0, "GIF87a") || at(b, 0, "GIF89a")
        case .webp: return at(b, 0, "RIFF") && at(b, 8, "WEBP")
        case .heic: return at(b, 4, "ftyp") && ["heic", "heix", "mif1", "msf1"].contains { at(b, 8, $0) }
        case .tiff: return at(b, 0, [0x49, 0x49, 0x2A, 0x00]) || at(b, 0, [0x4D, 0x4D, 0x00, 0x2A])
        case .mp4: return at(b, 4, "ftyp")
        case .mov: return ["ftyp", "moov", "wide", "mdat", "free"].contains { at(b, 4, $0) }
        case .zip: return at(b, 0, [0x50, 0x4B, 0x03, 0x04])
        case .cfb: return at(b, 0, cfb)
        case .rtf: return at(b, 0, #"{\rtf"#)
        case .glb: return at(b, 0, "glTF")
        case .usdc: return at(b, 0, "PXR-USDC")
        case .extensionOnly: return true
        }
    }
}

/// Caps for what can be published or dropped.
public enum ArtifactPolicy {
    public static let maxFileBytes = 52_428_800
    public static let maxVideoBytes = 524_288_000
    public static let maxFolderBytes = 209_715_200
    public static let maxFiles = 500
    public static let titleMax = 120
    public static let companyQuotaBytes: Int64 = 2_147_483_648
    public static let publishesPerHour = 20
}

/// What a zip archive's central directory says about it (`ArchiveRatio.stats`). Nothing is inflated.
public struct ArchiveStats: Equatable, Sendable {
    /// Total uncompressed bytes over the archive's size on disk.
    public var ratio: Double
    public var uncompressedBytes: Int64
    /// The entry count the archive declares (only the first `ResourcePolicy.maxArchiveEntries` records are read).
    public var entries: Int
    /// An entry whose external attributes carry the `S_IFLNK` file type.
    public var hasSymlink: Bool
    /// An entry name with a `..` component, a leading `/` or `\`, or a NUL byte.
    public var hasUnsafeName: Bool

    public init(ratio: Double, uncompressedBytes: Int64, entries: Int, hasSymlink: Bool, hasUnsafeName: Bool) {
        self.ratio = ratio; self.uncompressedBytes = uncompressedBytes; self.entries = entries
        self.hasSymlink = hasSymlink; self.hasUnsafeName = hasUnsafeName
    }
}

/// Why an archive is refused. `message` is the text the owner sees.
public enum ArchiveError: Error, Equatable, Sendable, CustomStringConvertible {
    /// More than 10 000 entries, a ratio over 100, or more than 200 MB uncompressed.
    case expandsTooMuch
    /// A symlink entry or an unsafe name.
    case unsafePaths
    /// No end-of-central-directory record, or records that do not fit the file or each other.
    case unreadable

    public var message: String {
        switch self {
        case .expandsTooMuch: "this archive expands too much"
        case .unsafePaths: "this archive contains unsafe paths"
        case .unreadable: "this archive can't be read"
        }
    }

    public var description: String { message }
}

/// Zip checks that read only the end-of-central-directory record (ZIP64 included), the central-directory records and each
/// entry's local header, never the entries' data, and stop after `ResourcePolicy.maxArchiveEntries` records.
public enum ArchiveRatio {
    /// The ratio, when the archive passes every limit; else throws `ArchiveError`.
    @discardableResult
    public static func check(url: URL) throws -> Double {
        let s = try stats(url: url)
        if let refusal = refusal(s) { throw refusal }
        return s.ratio
    }

    public static func stats(url: URL) throws -> ArchiveStats {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveError.unreadable }
        defer { close(fd) }
        return try stats(fd: fd)
    }

    /// What `stats` means under `ResourcePolicy`: nil when the archive may be added.
    public static func refusal(_ s: ArchiveStats) -> ArchiveError? {
        if s.entries > ResourcePolicy.maxArchiveEntries || s.ratio > Double(ResourcePolicy.maxArchiveRatio)
            || s.uncompressedBytes > Int64(ResourcePolicy.maxArchiveUncompressed) {
            return .expandsTooMuch
        }
        if s.hasSymlink || s.hasUnsafeName { return .unsafePaths }
        return nil
    }

    /// The stats of the zip open at `fd` (read with `pread`; the descriptor's offset is untouched). Throws
    /// `ArchiveError.unreadable` for an archive whose records do not agree with each other, and `.unsafePaths` when a
    /// central record names a different file than its local header.
    /// - The end record is the last signature whose comment ends exactly at the end of the file.
    /// - The central directory is walked record by record to exactly its declared end, and must hold exactly the declared
    ///   number of records. Past `ResourcePolicy.maxArchiveEntries` records the walk stops and the stats report more entries
    ///   than the cap (refused as too many).
    /// - Every record's local header must carry the same name and the same sizes (a data-descriptor entry, bit 3 set in both,
    ///   may leave its local sizes zero), its data must end before the central directory, and no two entries' data may
    ///   overlap. Nothing is inflated.
    public static func stats(fd: Int32) throws -> ArchiveStats {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.unreadable }
        let size = Int64(st.st_size)
        guard size >= 22 else { throw ArchiveError.unreadable }

        let tailLength = Int(min(size, 22 + 65_535))
        let tailStart = size - Int64(tailLength)
        let tail = try readExactly(fd, at: tailStart, count: tailLength)
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06,
               i + 22 + Int(u16(tail, i + 20)) == tail.count {
                eocd = i; break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.unreadable }
        var entries = UInt64(u16(tail, eocd + 10))
        var cdSize = UInt64(u32(tail, eocd + 12))
        var cdOffset = UInt64(u32(tail, eocd + 16))
        if entries == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64: the locator sits right before the end record and points at the ZIP64 end record.
            let locatorAt = tailStart + Int64(eocd) - 20
            guard locatorAt >= 0 else { throw ArchiveError.unreadable }
            let locator = try readExactly(fd, at: locatorAt, count: 20)
            guard u32(locator, 0) == 0x0706_4b50 else { throw ArchiveError.unreadable }
            let z64At = u64(locator, 8)
            guard size >= 56, z64At <= UInt64(size - 56) else { throw ArchiveError.unreadable }
            let z64 = try readExactly(fd, at: Int64(z64At), count: 56)
            guard u32(z64, 0) == 0x0606_4b50 else { throw ArchiveError.unreadable }
            entries = u64(z64, 32); cdSize = u64(z64, 40); cdOffset = u64(z64, 48)
        }
        guard cdOffset <= UInt64(size), cdSize <= UInt64(size) - cdOffset else { throw ArchiveError.unreadable }

        let declared = entries > UInt64(Int.max) ? Int.max : Int(entries)
        var uncompressed: Int64 = 0
        var hasSymlink = false, hasUnsafe = false
        var spans: [(start: UInt64, end: UInt64)] = []
        var records = 0
        var at = Int64(cdOffset)
        let cdEnd = Int64(cdOffset + cdSize)
        func result(entries: Int) -> ArchiveStats {
            ArchiveStats(ratio: Double(uncompressed) / Double(max(size, 1)), uncompressedBytes: uncompressed, entries: entries,
                         hasSymlink: hasSymlink, hasUnsafeName: hasUnsafe)
        }
        while at < cdEnd {
            if records == ResourcePolicy.maxArchiveEntries { return result(entries: max(declared, records + 1)) }
            records += 1
            guard at + 46 <= cdEnd else { throw ArchiveError.unreadable }
            let h = try readExactly(fd, at: at, count: 46)
            guard u32(h, 0) == 0x0201_4b50 else { throw ArchiveError.unreadable }
            let flags = u16(h, 8)
            let nameLength = Int(u16(h, 28)), extraLength = Int(u16(h, 30)), commentLength = Int(u16(h, 32))
            let variable = nameLength + extraLength
            guard at + 46 + Int64(variable + commentLength) <= cdEnd else { throw ArchiveError.unreadable }
            let v = try readExactly(fd, at: at + 46, count: variable)
            let name = Array(v[0..<nameLength])
            var usize = UInt64(u32(h, 24)), csize = UInt64(u32(h, 20)), local = UInt64(u32(h, 42))
            let wanted = [usize == 0xFFFF_FFFF, csize == 0xFFFF_FFFF, local == 0xFFFF_FFFF]
            if wanted.contains(true) {
                var values = try zip64(Array(v[nameLength...]), count: wanted.filter { $0 }.count)[...]
                if wanted[0] { usize = values.removeFirst() }
                if wanted[1] { csize = values.removeFirst() }
                if wanted[2] { local = values.removeFirst() }
            }
            let dataEnd = try localDataEnd(fd, at: local, name: name, flags: flags, compressed: csize, uncompressed: usize,
                                           before: cdOffset)
            spans.append((local, dataEnd))
            let (sum, overflow) = uncompressed.addingReportingOverflow(Int64(clamping: usize))
            uncompressed = overflow ? .max : sum
            let mode = (u32(h, 38) >> 16) & 0o170000
            if mode == 0o120000 { hasSymlink = true }
            if unsafe(name) { hasUnsafe = true }
            at += 46 + Int64(variable + commentLength)
        }
        guard at == cdEnd, records == declared else { throw ArchiveError.unreadable }
        spans.sort { $0.start < $1.start }
        for (a, b) in zip(spans, spans.dropFirst()) where a.end > b.start { throw ArchiveError.unreadable }
        return result(entries: declared)
    }

    /// Checks the local header at `offset` against its central record and returns where the entry's data ends, which must
    /// be at or before `limit` (the central directory's start).
    private static func localDataEnd(_ fd: Int32, at offset: UInt64, name: [UInt8], flags: UInt16, compressed: UInt64,
                                     uncompressed: UInt64, before limit: UInt64) throws -> UInt64 {
        guard offset <= limit, limit - offset >= 30 else { throw ArchiveError.unreadable }
        let h = try readExactly(fd, at: Int64(offset), count: 30)
        guard u32(h, 0) == 0x0403_4b50 else { throw ArchiveError.unreadable }
        let localFlags = u16(h, 6)
        guard localFlags & 0x0008 == flags & 0x0008 else { throw ArchiveError.unreadable }
        let nameLength = Int(u16(h, 26)), extraLength = Int(u16(h, 28))
        let variableEnd = offset + 30 + UInt64(nameLength + extraLength)
        guard variableEnd <= limit else { throw ArchiveError.unreadable }
        let v = try readExactly(fd, at: Int64(offset) + 30, count: nameLength + extraLength)
        guard Array(v[0..<nameLength]) == name else { throw ArchiveError.unsafePaths }
        var localU = UInt64(u32(h, 22)), localC = UInt64(u32(h, 18))
        if localU == 0xFFFF_FFFF || localC == 0xFFFF_FFFF {
            // A local ZIP64 field carries both sizes.
            let values = try zip64(Array(v[nameLength...]), count: 2)
            localU = values[0]; localC = values[1]
        }
        if localFlags & 0x0008 != 0 {
            guard (localU == 0 && localC == 0) || (localU == uncompressed && localC == compressed) else {
                throw ArchiveError.unreadable
            }
        } else {
            guard localU == uncompressed, localC == compressed else { throw ArchiveError.unreadable }
        }
        guard compressed <= limit - variableEnd else { throw ArchiveError.unreadable }
        return variableEnd + compressed
    }

    /// The first `count` 64-bit values of the ZIP64 extended-information extra field (id 0x0001): the uncompressed size,
    /// compressed size and local-header offset, each present only when its 32-bit field is 0xFFFFFFFF, in that order.
    private static func zip64(_ extra: [UInt8], count: Int) throws -> [UInt64] {
        var i = 0
        while i + 4 <= extra.count {
            let id = u16(extra, i), length = Int(u16(extra, i + 2))
            guard i + 4 + length <= extra.count else { break }
            if id == 0x0001 {
                guard length >= count * 8 else { throw ArchiveError.unreadable }
                return (0..<count).map { u64(extra, i + 4 + $0 * 8) }
            }
            i += 4 + length
        }
        throw ArchiveError.unreadable
    }

    /// `..` as a path component, a leading `/` or `\`, or a NUL byte.
    static func unsafe(_ name: [UInt8]) -> Bool {
        if name.contains(0) { return true }
        if let first = name.first, first == UInt8(ascii: "/") || first == UInt8(ascii: "\\") { return true }
        let parts = name.split(omittingEmptySubsequences: false) { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "\\") }
        return parts.contains { Array($0) == [UInt8(ascii: "."), UInt8(ascii: ".")] }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }

    private static func readExactly(_ fd: Int32, at offset: Int64, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, count - got, off_t(offset) + off_t(got)) }
            if n < 0 { if errno == EINTR { continue }; throw ArchiveError.unreadable }
            if n == 0 { throw ArchiveError.unreadable }
            got += n
        }
        return buffer
    }
}
