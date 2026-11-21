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

/// Reads members of a zip archive the engine holds in memory (a vault resource, a git blob).
public protocol ArchiveReader: Sendable {
    /// The members of the zip `data` whose names `wanted` accepts, in archive order, each at most `limits.bytes` and all of
    /// them together too. Throws `ArchiveReadError`.
    func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)]
}

/// Where no sandbox exists: nothing is unpacked.
public struct UnavailableArchiveReader: ArchiveReader {
    public init() {}

    public func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
        throw ArchiveReadError.unavailable
    }
}

/// `/usr/bin/unzip -p` under the engine's sandbox (`SandboxedRunner`): no network, read access to one private copy of the
/// archive in a vault temp directory (`scratch`), write access to one output directory, each member's output cut by `head -c`.
/// Before anything runs, ML's `ArchiveRatio.stats` reads the central directory (nothing inflated): a ratio, size or entry count
/// over the limits, a symlink entry or an unsafe name refuses the read, as 4a's publish does. Only members whose names are
/// plain (`[A-Za-z0-9._/-]`, no `..`) are asked for, so `unzip` sees no pattern characters. The temp directory is removed
/// whatever happens.
public struct SandboxedUnzipReader: ArchiveReader {
    public static let unzip = "/usr/bin/unzip"
    public static let timeout: Duration = .seconds(60)

    let runner: any SandboxedRunner
    let scratch: @Sendable () throws -> URL

    /// `scratch` makes a fresh private directory for one read (`Vault.makeTempDir`).
    public init(runner: any SandboxedRunner, scratch: @escaping @Sendable () throws -> URL) {
        self.runner = runner; self.scratch = scratch
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
        let names = entries.filter { !$0.isDirectory && !$0.isSymlink && Self.isPlain($0.name) && wanted($0.name) }
            .prefix(ArchiveLimits.maxMembers).map(\.name)
        guard !names.isEmpty else { return [] }

        let q = ExtensionValidator.shellQuote
        let (heldDir, outDir) = (held.resolvedForSandbox, out.resolvedForSandbox)
        let copy = heldDir.appending(path: "archive.zip").path
        let command = names.enumerated().map { i, name in
            "\(q(Self.unzip)) -p \(q(copy)) \(q(name)) 2>/dev/null | /usr/bin/head -c \(limits.bytes + 1) > \(q(outDir.appending(path: "m\(i)").path))"
        }.joined(separator: " && ")
        let policy = SandboxPolicy(writable: [outDir], readable: [heldDir], network: .none, toolchain: false)
        let environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        let outcome = Self.wait {
            await runner.run(command: command, cwd: outDir, environment: environment, timeout: Self.timeout,
                             outputURL: dir.appending(path: "unzip.log"), policy: policy)
        }
        guard outcome?.exitCode == 0 else { throw ArchiveReadError.unreadable }
        var result: [(name: String, data: Data)] = []
        var total = 0
        for (i, name) in names.enumerated() {
            guard let bytes = EngineFiles.readNoFollow(outDir.appending(path: "m\(i)"), under: outDir, limit: limits.bytes + 1) else {
                throw ArchiveReadError.unreadable
            }
            total += bytes.count
            guard bytes.count <= limits.bytes, total <= limits.bytes else { throw ArchiveReadError.expands }
            result.append((name, bytes))
        }
        return result
    }

    /// A member name `unzip` reads literally: `[A-Za-z0-9._/-]` only, no empty, `.` or `..` component, not absolute.
    static func isPlain(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 512, !name.hasPrefix("/"), !name.hasPrefix("-"),
              name.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || [0x2E, 0x2D, 0x5F, 0x2F].contains($0) })
        else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Runs the sandboxed command to completion from synchronous code (the store's callers are synchronous): the runner's own
    /// timeout ends it; nil only if it never reported back.
    static func wait(_ body: @escaping @Sendable () async -> CheckOutcome) -> CheckOutcome? {
        final class Box: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            var value: CheckOutcome?
        }
        let box = Box()
        Task.detached {
            box.value = await body()
            box.done.signal()
        }
        guard box.done.wait(timeout: .now() + SafeGit.seconds(timeout) + 30) == .success else { return nil }
        return box.value
    }
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
