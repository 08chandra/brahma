import Foundation

/// How much an archive (a zip, or an Office file, which is one) may expand when the engine reads its members: ML's resource
/// caps, which 4a's publish uses too (≤ 200 MB decompressed, ratio ≤ 100). Tests lower the instance values.
public struct ArchiveLimits: Equatable, Sendable {
    public static let maxBytes = ResourcePolicy.maxArchiveUncompressed
    public static let maxRatio = Double(ResourcePolicy.maxArchiveRatio)
    /// The most members one read takes out.
    public static let maxMembers = 200
    public static let standard = ArchiveLimits(bytes: maxBytes, ratio: maxRatio)

    public var bytes: Int
    public var ratio: Double

    public init(bytes: Int, ratio: Double) { self.bytes = bytes; self.ratio = ratio }
}

/// Why an archive's members were not read. `message` is the text a reader sees.
public enum ArchiveReadError: Error, Equatable, Sendable, CustomStringConvertible {
    case refused(String)

    public var message: String { if case .refused(let m) = self { return m }; return "" }
    public var description: String { message }

    static let expands = ArchiveReadError.refused("this archive expands too much to preview safely")
    static let unsafe = ArchiveReadError.refused("this archive contains unsafe paths")
    static let unreadable = ArchiveReadError.refused("this archive can't be read")
    static let unavailable = ArchiveReadError.refused("archives can't be read on this machine")
}

/// Reads the insides of containers the engine holds in memory (a vault resource, a git blob) outside the engine: the
/// members of a zip, and (C2b fix round 2) the decoded parts of a PDF.
public protocol ArchiveReader: Sendable {
    /// The members of the zip `data` whose names `wanted` accepts, in archive order, each at most `limits.bytes` and all of
    /// them together too. Throws `ArchiveReadError`.
    func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)]
    /// Every decoded part of the PDF `data` (`SandboxedPDFReader`), at most `maxBytes` in all, within `timeout`. Throws
    /// `ArchiveReadError`; a reader without the PDF helper refuses (`"PDFs can't be scanned on this machine"`).
    func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart]
    /// C2b-carry (c), Ruling 42: the flattened copy of the PDF `data` (`SandboxedPDFReader.flatten`: the visible pages
    /// re-rendered, nothing else), at most `maxBytes`, within `timeout`. Throws `ArchiveReadError`; a reader without the PDF
    /// helper refuses (`"PDFs can't be scanned on this machine"`).
    func flattenPDF(of data: Data, maxBytes: Int, timeout: Duration) throws -> Data
}

extension ArchiveReader {
    public func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] { throw SandboxedPDFReader.unavailable }
    public func flattenPDF(of data: Data, maxBytes: Int, timeout: Duration) throws -> Data { throw SandboxedPDFReader.unavailable }
}

/// Where no sandbox exists: nothing is unpacked.
public struct UnavailableArchiveReader: ArchiveReader {
    public init() {}

    public func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
        throw ArchiveReadError.unavailable
    }
}

/// `/usr/bin/unzip -p` under the engine's sandbox (`SandboxedRunner`), read access to one private copy of the archive in a
/// vault temp directory (`scratch`). C2b fix round 4 (R4-6, ruling 35): it runs as the PDF helper does (`policy`): unzip
/// itself, no shell and no `head`, the leader of its own session, under the same deny-default profile (it may run nothing
/// else and fork nothing, read only the system and that copy, write nothing, reach no network), with a memory watchdog on
/// its own pid (`memoryLimit`) and its standard output read by the engine up to the byte cap (one byte more kills it).
/// Before anything runs, ML's `ArchiveRatio.stats` reads the central directory (nothing inflated): a ratio, size or entry
/// count over the limits, a symlink entry or an unsafe name refuses the read, as 4a's publish does. Only members whose
/// names are plain (`[A-Za-z0-9._/-]` plus `[` and `]`, no `..`) are asked for; a `[` is passed as `[[]`, so `unzip`'s
/// wildcard matching takes every name literally (Office's `[Content_Types].xml` included). All of them come out of one
/// run, in archive order (`unzip -p` follows the central directory): the output is split by the sizes the central
/// directory declares, and must be exactly their sum, each piece matching its entry's CRC-32; an unzip that did not exit
/// 0, or anything else, refuses the read. The temp directory is removed whatever happens. With `pdfHelper` (the
/// `brahma-pdf` binary, `SandboxedPDFReader.locate`) it reads PDFs too, through the same runner; without it a PDF is
/// refused.
public struct SandboxedUnzipReader: ArchiveReader {
    public static let unzip = "/usr/bin/unzip"
    public static let timeout: Duration = .seconds(60)
    /// The most memory one read may use (the runner's watchdog: unzip's own pid and its group).
    public static let memoryLimit = 1 << 30
    static let tooLong = ArchiveReadError.refused("this archive took too long to scan for secrets")
    static let couldNotRun = ArchiveReadError.refused("the archive reader could not run, so this archive can't be scanned for secrets")
    static let membersName = "members"

    let runner: any SandboxedRunner
    let scratch: @Sendable () throws -> URL
    let pdfHelper: URL?

    /// `scratch` makes a fresh private directory for one read (`Vault.makeTempDir`).
    public init(runner: any SandboxedRunner, scratch: @escaping @Sendable () throws -> URL, pdfHelper: URL? = nil) {
        self.runner = runner; self.scratch = scratch; self.pdfHelper = pdfHelper
    }

    /// The sandbox of one read (round 4): `held` (the copy) the only tree it reads besides the system; `unzip` the only
    /// program (nothing else runs, nothing forks); no file it may write (`out` is the runner's own; the engine writes the
    /// output there); no network; the memory limit.
    static func policy(unzip: URL, held: URL, out: URL) -> SandboxPolicy {
        var policy = SandboxPolicy(writable: [out], readable: [held], network: .none, toolchain: false)
        policy.confined = SandboxConfinement(executables: [unzip], readableFiles: [], listableDirectories: [], writableFiles: [])
        policy.memoryLimit = memoryLimit
        return policy
    }

    public func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] {
        guard let pdfHelper else { throw SandboxedPDFReader.unavailable }
        return try SandboxedPDFReader(runner: runner, helper: pdfHelper, scratch: scratch).parts(of: data, maxBytes: maxBytes, timeout: timeout)
    }

    public func flattenPDF(of data: Data, maxBytes: Int, timeout: Duration) throws -> Data {
        guard let pdfHelper else { throw SandboxedPDFReader.unavailable }
        return try SandboxedPDFReader(runner: runner, helper: pdfHelper, scratch: scratch).flatten(of: data, maxBytes: maxBytes, timeout: timeout)
    }

    public func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = dir.appending(path: "held", directoryHint: .isDirectory)
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        for d in [held, out] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let archive = held.appending(path: "archive.zip")
        guard FileManager.default.createFile(atPath: archive.path, contents: data, attributes: [.posixPermissions: 0o400]) else {
            throw ArchiveReadError.unreadable
        }
        // The central directory first: nothing runs for an archive that would expand too much or names unsafe paths.
        let stats: ArchiveStats
        do { stats = try ArchiveRatio.stats(url: archive) } catch let e as ArchiveError {
            throw e == .unsafePaths ? ArchiveReadError.unsafe : e == .expandsTooMuch ? ArchiveReadError.expands : ArchiveReadError.unreadable
        }
        if stats.entries > ResourcePolicy.maxArchiveEntries || stats.ratio > limits.ratio || stats.uncompressedBytes > Int64(limits.bytes) {
            throw ArchiveReadError.expands
        }
        if stats.hasSymlink || stats.hasUnsafeName { throw ArchiveReadError.unsafe }
        let entries: [ZipInventory.Entry]
        do { entries = try ZipInventory.entries(of: data) } catch { throw ArchiveReadError.unreadable }
        // C2b fix round 1 (ruling 30): a directory is a `/`-named entry holding nothing; any other entry is a file.
        let chosen = Array(entries.filter { !ArchiveMemberScan.isDirectoryEntry($0) && !$0.isSymlink && Self.isPlain($0.name) && wanted($0.name) }
            .prefix(ArchiveLimits.maxMembers))
        guard !chosen.isEmpty else { return [] }
        let expected = chosen.reduce(0) { $0 + $1.uncompressedSize }
        guard expected <= limits.bytes else { throw ArchiveReadError.expands }

        let (heldDir, outDir) = (held.resolvedForSandbox, out.resolvedForSandbox)
        let program = URL(fileURLWithPath: Self.unzip)
        let policy = Self.policy(unzip: program, held: heldDir, out: outDir)
        let environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        // One run, unzip itself, on this thread (`runProgramBlocking`: never a wait on the cooperative pool); the engine reads
        // its output up to the cap.
        let outcome = runner.runProgramBlocking(arguments: [program.path, "-p", heldDir.appending(path: "archive.zip").path]
                                                    + chosen.map { Self.literal($0.name) },
                                                cwd: outDir, environment: environment, timeout: Self.timeout,
                                                outputURL: dir.appending(path: "unzip.log"), stdoutURL: outDir.appending(path: Self.membersName),
                                                stdoutCap: limits.bytes, policy: policy)
        if outcome.tail.hasSuffix(GroupRun.outputExceeded) || outcome.tail.hasSuffix(GroupRun.memoryExceeded) { throw ArchiveReadError.expands }
        // Round 3: a run that ran out of time or never ran says so (the gate does not cache those).
        if outcome.timedOut { throw Self.tooLong }
        guard let exit = outcome.exitCode else { throw Self.couldNotRun }
        guard exit == 0, let output = EngineFiles.readNoFollow(outDir.appending(path: Self.membersName), under: outDir, limit: limits.bytes + 1)
        else { throw ArchiveReadError.unreadable }
        guard output.count <= limits.bytes else { throw ArchiveReadError.expands }
        // Exactly what the central directory declares, member by member: a member unzip could not fully decode, or bytes
        // that belong to another member, never pass (sizes, then each piece's CRC-32).
        guard output.count == expected else { throw ArchiveReadError.unreadable }
        var result: [(name: String, data: Data)] = []
        var at = output.startIndex
        for entry in chosen {
            let piece = output[at..<(at + entry.uncompressedSize)]
            guard EmbeddedContent.crc32(ArraySlice(piece)) == entry.crc else { throw ArchiveReadError.unreadable }
            result.append((entry.name, Data(piece)))
            at += entry.uncompressedSize
        }
        return result
    }

    /// A member name `unzip` can be asked for literally: `[A-Za-z0-9._/-[]]` only, no empty, `.` or `..` component, not
    /// absolute (`literal` escapes its `[`).
    static func isPlain(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 512, !name.hasPrefix("/"), !name.hasPrefix("-"),
              name.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || [0x2E, 0x2D, 0x5F, 0x2F, 0x5B, 0x5D].contains($0) })
        else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// `name` as an `unzip` pattern that matches only itself: each `[` becomes the class `[[]` (a lone `]` is literal).
    static func literal(_ name: String) -> String { name.replacingOccurrences(of: "[", with: "[[]") }
}

/// The text `open_ref` shows for bytes that are not plain text (design §4.6: nothing untrusted is parsed in process beyond
/// headers and a linear tag strip).
public enum TextExtract {
    /// - every `ArtifactKind.isText` kind (text, code, table, markdown, html): UTF-8, invalid sequences as U+FFFD;
    /// - docx `word/document.xml`, xlsx `xl/sharedStrings.xml` + `xl/worksheets/sheet*.xml`, pptx `ppt/slides/slide*.xml`
    ///   (in slide order), read through `archives` and a linear tag stripper (no XML parser, no entity expansion beyond the
    ///   five predefined entities, once);
    /// - images: `image · <w>×<h> · <format>` from the header (PNG IHDR, JPEG SOF0/SOF2, GIF, WebP VP8/VP8L/VP8X);
    /// - anything else: `<kind> · <bytes> bytes; open_ref can't read its text — use copy: true and your own tools`.
    /// Throws `ArchiveReadError` when an Office file's members can't be read.
    public static func extract(kind: ArtifactKind?, ext: String, data: Data, archives: any ArchiveReader) throws -> String {
        let ext = ext.lowercased()
        if let kind, kind.isText { return String(decoding: data, as: UTF8.self) }
        switch ext {
        case "docx":
            let parts = try archives.members(of: data, wanted: { $0 == "word/document.xml" }, limits: .standard)
            return parts.map { stripTags(String(decoding: $0.data, as: UTF8.self), lineBreaks: ["w:p", "w:br"], tabs: ["w:tab"]) }
                .joined(separator: "\n")
        case "xlsx":
            let parts = try archives.members(of: data, wanted: { $0 == "xl/sharedStrings.xml" || isNumbered($0, "xl/worksheets/sheet") },
                                             limits: .standard)
            return ordered(parts, prefix: "xl/worksheets/sheet").map { part in
                let text = stripTags(String(decoding: part.data, as: UTF8.self), lineBreaks: ["si", "row"], tabs: ["c"])
                return part.name == "xl/sharedStrings.xml" ? text : "Sheet \(number(part.name, "xl/worksheets/sheet") ?? 0)\n" + text
            }.joined(separator: "\n\n")
        case "pptx":
            let parts = try archives.members(of: data, wanted: { isNumbered($0, "ppt/slides/slide") }, limits: .standard)
            return ordered(parts, prefix: "ppt/slides/slide").map { part in
                "Slide \(number(part.name, "ppt/slides/slide") ?? 0)\n" + stripTags(String(decoding: part.data, as: UTF8.self), lineBreaks: ["a:p"])
            }.joined(separator: "\n\n")
        default:
            break
        }
        if kind == .image, let size = imageSize(data) { return "image · \(size.width)×\(size.height) · \(size.format)" }
        return metadata(kind: kind, bytes: data.count)
    }

    /// The sentence for bytes `open_ref` can't show as text.
    public static func metadata(kind: ArtifactKind?, bytes: Int) -> String {
        "\(kind?.rawValue ?? "file") · \(bytes) bytes; open_ref can't read its text — use copy: true and your own tools"
    }

    // MARK: Tags

    /// The text between tags, in one pass: the closing tag of a name in `lineBreaks` (or such an empty element) ends a line,
    /// one in `tabs` adds a tab; every other tag is dropped. `&amp; &lt; &gt; &quot; &apos;` are decoded once; nothing else is
    /// expanded. Trailing line ends are trimmed.
    public static func stripTags(_ xml: String, lineBreaks: Set<String>, tabs: Set<String> = []) -> String {
        var out = ""
        var text = ""
        var i = xml.startIndex
        func flush() { out += decodeEntities(text); text = "" }
        while i < xml.endIndex {
            let c = xml[i]
            guard c == "<" else { text.append(c); i = xml.index(after: i); continue }
            guard let close = xml[i...].firstIndex(of: ">") else { break }
            flush()
            var tag = xml[xml.index(after: i)..<close]
            let closing = tag.hasPrefix("/"), empty = tag.hasSuffix("/")
            if closing { tag = tag.dropFirst() }
            if empty { tag = tag.dropLast() }
            let name = String(tag.prefix { !$0.isWhitespace })
            if closing || empty {
                if lineBreaks.contains(name) { out += "\n" } else if tabs.contains(name) { out += "\t" }
            }
            i = xml.index(after: close)
        }
        flush()
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        let entities: [(String, String)] = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'")]
        while i < s.endIndex {
            if s[i] == "&", let hit = entities.first(where: { s[i...].hasPrefix($0.0) }) {
                out += hit.1
                i = s.index(i, offsetBy: hit.0.count)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    static func isNumbered(_ name: String, _ prefix: String) -> Bool { number(name, prefix) != nil }

    /// `<prefix><n>.xml` → n.
    static func number(_ name: String, _ prefix: String) -> Int? {
        guard name.hasPrefix(prefix), name.hasSuffix(".xml") else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(4)
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// Unnumbered parts first (shared strings), then numbered ones in number order.
    static func ordered(_ parts: [(name: String, data: Data)], prefix: String) -> [(name: String, data: Data)] {
        parts.sorted { (number($0.name, prefix) ?? -1, $0.name) < (number($1.name, prefix) ?? -1, $1.name) }
    }

    // MARK: Images

    /// Width, height and format from the first bytes of a PNG, JPEG, GIF or WebP; nil for anything else.
    static func imageSize(_ data: Data) -> (width: Int, height: Int, format: String)? {
        let b = [UInt8](data.prefix(65_536))
        func be16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func le16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func be32(_ i: Int) -> Int { be16(i) << 16 | be16(i + 2) }
        func le24(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 }
        func at(_ i: Int, _ s: String) -> Bool { b.count >= i + s.utf8.count && Array(b[i..<i + s.utf8.count]) == Array(s.utf8) }
        if b.count >= 24, b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), at(12, "IHDR") {
            return (be32(16), be32(20), "PNG")
        }
        if b.count >= 10, at(0, "GIF87a") || at(0, "GIF89a") { return (le16(6), le16(8), "GIF") }
        if b.count >= 16, at(0, "RIFF"), at(8, "WEBP") {
            if at(12, "VP8 "), b.count >= 30, b[23] == 0x9D, b[24] == 0x01, b[25] == 0x2A {
                return (le16(26) & 0x3FFF, le16(28) & 0x3FFF, "WebP")
            }
            if at(12, "VP8L"), b.count >= 25, b[20] == 0x2F {
                let bits = UInt32(b[21]) | UInt32(b[22]) << 8 | UInt32(b[23]) << 16 | UInt32(b[24]) << 24
                return (Int(bits & 0x3FFF) + 1, Int((bits >> 14) & 0x3FFF) + 1, "WebP")
            }
            if at(12, "VP8X"), b.count >= 30 { return (le24(24) + 1, le24(27) + 1, "WebP") }
            return nil
        }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 {
            var i = 2
            while i + 9 < b.count {
                guard b[i] == 0xFF else { return nil }
                let marker = b[i + 1]
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
                if marker == 0xFF { i += 1; continue }
                if marker == 0xDA || marker == 0xD9 { return nil }
                let length = be16(i + 2)
                if marker == 0xC0 || marker == 0xC2 { return (be16(i + 7), be16(i + 5), "JPEG") }
                guard length >= 2 else { return nil }
                i += 2 + length
            }
        }
        return nil
    }
}
