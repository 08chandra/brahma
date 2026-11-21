import Foundation
import GRDB

// Plan C Task C2b (design §4.5): the one secret gate every byte C shares, snapshots, opens, copies or renders goes through.
// The streaming scan is ML's `ContentScan` (chunked, with an overlap of at least the longest needle; findings never carry
// the matched text). C adds only the forms ML does not scan: encoded copies of each stored value (`EncodedForms`), the
// members of zip-based archives (`ArchiveMemberScan`), and what PDFs and PNGs hold decoded (`EmbeddedContent`; a PDF only
// through the sandboxed `brahma-pdf` helper, never parsed in the engine).

/// The encoded forms of stored secret values a file may hold instead of the value itself.
public enum EncodedForms {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `values` as given, plus for each value of at least `Redactor.minLength` characters: percent-encoded (upper- and
    /// lowercase escapes, and the form encoding with `+` for a space), lowercase and uppercase hex of its UTF-8 bytes, and
    /// base64 at byte offsets 0, 1 and 2 (the characters of each alignment that depend on the value alone, so the value is
    /// found inside a longer base64 text; standard and URL-safe alphabets). Every form keeps the original `<NAME>`, so a
    /// finding names the secret and never the form. The list goes straight into `ContentScan.scan(…knownValues:)`, which
    /// matches ML's own forms (raw, percent, JSON) of each entry too.
    public static func expand(_ values: [(name: String, value: String)]) -> [(name: String, value: String)] {
        var out: [(name: String, value: String)] = []
        var seen = Set<String>()
        func add(_ name: String, _ form: String, always: Bool = false) {
            guard always || form.count >= Redactor.minLength else { return }
            if seen.insert("\(name)\u{0}\(form)").inserted { out.append((name, form)) }
        }
        for (name, value) in values { add(name, value, always: true) }
        for (name, value) in values where value.count >= Redactor.minLength {
            if let percent = value.addingPercentEncoding(withAllowedCharacters: unreserved) {
                add(name, percent)
                add(name, lowercaseEscapes(percent))
                add(name, percent.replacingOccurrences(of: "%20", with: "+"))
            }
            let bytes = Array(value.utf8)
            add(name, bytes.map { hexDigit($0 >> 4, upper: false) + hexDigit($0 & 0xF, upper: false) }.joined())
            add(name, bytes.map { hexDigit($0 >> 4, upper: true) + hexDigit($0 & 0xF, upper: true) }.joined())
            for offset in 0...2 {
                guard let interior = base64Interior(bytes, offset: offset) else { continue }
                add(name, interior)
                add(name, interior.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"))
            }
        }
        return out
    }

    /// The base64 characters of `bytes` placed at `offset` (0, 1 or 2) bytes into a 3-byte group that depend on those bytes
    /// only: character `i` covers bits `6i..<6i+6` of the padded input, so it is stable from `ceil(8·offset/6)` up to
    /// `floor(8·(offset+n)/6)`.
    static func base64Interior(_ bytes: [UInt8], offset: Int) -> String? {
        let encoded = Array(Data([UInt8](repeating: 0, count: offset) + bytes).base64EncodedString())
        let start = (8 * offset + 5) / 6, end = (8 * (offset + bytes.count)) / 6
        guard end > start, end <= encoded.count else { return nil }
        return String(encoded[start..<end])
    }

    static func hexDigit(_ v: UInt8, upper: Bool) -> String {
        String(UnicodeScalar((v < 10 ? 0x30 : (upper ? 0x37 : 0x57)) + v))
    }

    /// `%2F` → `%2f` (the escapes only; the rest is unchanged).
    static func lowercaseEscapes(_ s: String) -> String {
        var out = ""
        var pending = 0
        for c in s {
            if c == "%" { pending = 2; out.append(c); continue }
            if pending > 0 { pending -= 1; out += c.lowercased() } else { out.append(c) }
        }
        return out
    }
}

/// The members of a zip-based archive (zip, docx, xlsx, pptx and the like), read through the engine's `ArchiveReader` and
/// scanned one by one. Fail closed (C2b fix round 1, rulings 29 and 30):
/// - an archive is any bytes with an end record near the end, or a plausible zip local header anywhere (C2b fix round 2,
///   ruling 32: a polyglot or a renamed zip), and its central directory must be self-consistent and tile from byte 0 (ML's
///   `ZipInventory`), so prepended data refuses;
/// - an entry is a directory only when its name ends in `/` and both its sizes are 0; every other entry (whatever its
///   directory flags) is a file the reader must return, exactly once, with exactly the length the directory declares;
/// - only stored (0) and deflate (8) members, never an encrypted one, and a local header whose encryption bit differs from
///   the central directory's refuses (fix round 2, m-1); a link entry refuses;
/// - nested archives are opened with ONE budget (`ArchiveScanBudget`: decompressed bytes, entries, depth and time) for all
///   levels together;
/// - a member compressed in a format the engine can't open (`unscannableFormat`) refuses; a member that is itself an
///   archive, a PDF or a PNG is opened in turn (`EmbeddedContent`).
public enum ArchiveMemberScan {
    public static let maxDepth = 3
    /// Extensions read as archives even when their bytes do not look like one (they then fail to read, and are refused).
    public static let archiveExts: Set<String> = ["zip", "docx", "xlsx", "pptx"]
    static let zipMagic = Data([0x50, 0x4B, 0x03, 0x04])
    static let endMagic = Data([0x50, 0x4B, 0x05, 0x06])

    static let incomplete = ArchiveReadError.refused("this archive can't be scanned for secrets")
    static let tooMany = ArchiveReadError.refused("this archive has too many files to scan for secrets")
    static let overBudget = ArchiveReadError.refused("this archive expands too much to scan for secrets")
    /// Round 3 (m-A): more sandboxed reads than one check may launch (`ArchiveScanBudget.maxLaunches`).
    static let tooManyLaunches = ArchiveReadError.refused("this content holds too many nested archives or PDFs to scan for secrets")
    /// The check's time ran out (not cached: it may pass on another try).
    static let outOfTime = ArchiveReadError.refused("this content took too long to scan for secrets")
    static let unscannableMethod = ArchiveReadError.refused("this archive uses compression or encryption that can't be scanned for secrets")

    /// Bytes that hold a zip: an end record within the last 64 KB + 22 bytes (where every zip reader looks), a plausible
    /// local header anywhere (`plausibleLocalHeader`), or a name that says zip. Four bytes `PK\x03\x04` followed by anything
    /// else are not a zip (ruling 32). Round 4 (R4-2, ruling 34): the deflate probes of one call share one `ProbeBudget`,
    /// bounded in headers, bytes and (with `deadline`, the check's) time; a spent budget means an archive (fail closed).
    public static func isArchive(_ data: Data, ext: String, deadline: TimeInterval? = nil) -> Bool {
        if archiveExts.contains(ext.lowercased()) { return true }
        let tail = max(data.startIndex, data.endIndex - (65_535 + 22))
        if data.range(of: endMagic, in: tail..<data.endIndex) != nil { return true }
        var budget = ProbeBudget(deadline: deadline)
        var from = data.startIndex
        while from < data.endIndex, let r = data.range(of: zipMagic, in: from..<data.endIndex) {
            if plausibleLocalHeader(data, at: r.lowerBound, budget: &budget) { return true }
            from = r.lowerBound + 1
        }
        return false
    }

    /// What one `isArchive` call may spend on deflate probes (R4-2): at most `maxHeaders` headers probed, `maxBytes` input
    /// bytes read in all (each probe at most `sliceBytes`), and nothing past `deadline`. Spent → an archive.
    struct ProbeBudget {
        static let maxHeaders = 64
        /// Round 4 (R4-7): the probe feeds one byte per decoder call, so its slice and total are kept small.
        static let maxBytes = 1 << 18
        static let sliceBytes = 1 << 14
        var headers = 0
        var bytes = 0
        let deadline: TimeInterval?

        /// Takes one probe of up to `size` input bytes; false when the budget can't pay for it.
        mutating func take(_ size: Int) -> Bool {
            if let deadline, AwakeTime.uptime() > deadline { return false }
            guard headers < Self.maxHeaders, size <= Self.maxBytes - bytes else { return false }
            headers += 1
            bytes += size
            return true
        }
    }

    /// The compression methods APPNOTE names (stored, shrunk, reduced, imploded, deflate, deflate64, bzip2, LZMA, zstd, xz,
    /// JPEG, WavPack, PPMd, AES and the rest).
    static let knownMethods: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 12, 14, 16, 18, 19, 20, 93, 94, 95, 96, 97, 98, 99]

    /// Whether a zip local header parses at `offset` (an index of `data`), as amended ruling 32 has it: a method a zip may
    /// use, the name and extra field inside the bytes, and data that stays inside them: a compressed size that fits in what
    /// is left (or zip64's marker, or 0 with a data descriptor), or, deflated, data that is not a deflate error. Round 4
    /// (R4-3, the controller's ruling on truncated deflate; R4-7, ruling 36): only a deflate DATA ERROR before any output
    /// means "no archive"; data that produces any output (whatever follows it), ends, or runs out before its stream ends
    /// or past the probe's slice is an archive. The probe reads at most
    /// `ProbeBudget.sliceBytes` of the bytes in place (no copy) and is paid for from `budget`; a spent budget is an archive.
    /// The version and the name's length play no part (they only limit what a reader accepts). Every read is bounds-checked
    /// first.
    static func plausibleLocalHeader(_ data: Data, at offset: Data.Index, budget: inout ProbeBudget) -> Bool {
        guard offset >= data.startIndex, data.endIndex - offset >= 30 else { return false }
        func u16(_ k: Int) -> Int { Int(data[offset + k]) | Int(data[offset + k + 1]) << 8 }
        func u32(_ k: Int) -> Int { u16(k) | u16(k + 2) << 16 }
        let flags = u16(6), method = u16(8)
        let compressed = u32(18), nameLength = u16(26), extraLength = u16(28)
        guard knownMethods.contains(method) else { return false }
        let left = data.endIndex - offset - 30 - nameLength - extraLength
        guard left >= 0 else { return false }
        if compressed == 0xFFFF_FFFF || (compressed == 0 && flags & 0x08 != 0) || compressed <= left { return true }
        // A deflated entry whose declared size runs past the bytes still counts unless its data is a deflate error (a
        // reader may go by the stream, not the size, and prints what a cut stream holds).
        guard method == 8 else { return false }
        let start = offset + 30 + nameLength + extraLength
        let slice = min(left, ProbeBudget.sliceBytes)
        guard budget.take(slice) else { return true }
        return EmbeddedContent.deflateProbe(data[start..<(start + slice)]) != .dataError
    }

    /// The compressed format whose magic `data` starts with, among those the engine can't open: gzip, bzip2, xz, zstd, 7z,
    /// rar (ruling 29), and Unix compress (`.Z`), lz4, lzip, lzma-alone, cab and xar (fix round 2).
    public static func unscannableFormat(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(8))
        func starts(_ m: [UInt8]) -> Bool { b.count >= m.count && Array(b[0..<m.count]) == m }
        if starts([0x1F, 0x8B]) { return "gzip" }
        if starts([0x42, 0x5A, 0x68]), b.count > 3, (0x31...0x39).contains(b[3]) { return "bzip2" }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "xz" }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return "zstd" }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "7z" }
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return "rar" }
        if starts([0x1F, 0x9D]) { return "compress" }
        if starts([0x04, 0x22, 0x4D, 0x18]) || starts([0x02, 0x21, 0x4C, 0x18]) { return "lz4" }
        if starts(Array("LZIP".utf8)) { return "lzip" }
        if starts([0x5D, 0x00, 0x00]) { return "lzma" }
        if starts(Array("MSCF".utf8) + [0, 0, 0, 0]) { return "cab" }
        if starts(Array("xar!".utf8)) { return "xar" }
        return nil
    }

    /// A real directory entry: the name ends in `/` and it holds nothing (ruling 30). Anything else is a file.
    static func isDirectoryEntry(_ e: ZipInventory.Entry) -> Bool {
        e.name.hasSuffix("/") && e.compressedSize == 0 && e.uncompressedSize == 0
    }

    /// Every finding in the members of the archive `data` (ML's `ContentScan` with `EncodedForms.expand(knownValues)`, and
    /// the secret patterns). Findings have line 0: a member's lines are not the archive's. Throws `ArchiveReadError`.
    public static func scan(_ data: Data, archives: any ArchiveReader,
                            knownValues: [(name: String, value: String)]) throws -> [ScanFinding] {
        try scan(data, archives: archives, knownValues: knownValues, budget: ArchiveScanBudget())
    }

    static func scan(_ data: Data, archives: any ArchiveReader, knownValues: [(name: String, value: String)],
                     budget: ArchiveScanBudget) throws -> [ScanFinding] {
        try scan(data, archives: archives, expanded: EncodedForms.expand(knownValues), budget: budget, level: 0,
                 chunk: ContentScan.chunkBytes)
    }

    static func scan(_ data: Data, archives: any ArchiveReader, expanded: [(name: String, value: String)],
                     budget: ArchiveScanBudget, level: Int, chunk: Int) throws -> [ScanFinding] {
        try budget.ensure(level < budget.depth)
        let entries: [ZipInventory.Entry]
        do { entries = try ZipInventory.entries(of: data) } catch { throw ArchiveReadError.unreadable }
        var files = entries.filter { !isDirectoryEntry($0) }
        if files.contains(where: \.isSymlink) { throw ArchiveReadError.unsafe }
        guard files.count <= ArchiveLimits.maxMembers else { throw tooMany }
        // m-1: the local header's encryption bit must agree with the central directory's.
        func unscannable(_ e: ZipInventory.Entry) -> Bool {
            (e.method != 0 && e.method != 8) || e.flags & 0x1 != 0 || e.localFlags & 0x1 != e.flags & 0x1
        }
        if files.contains(where: unscannable) {
            // Round 5 (ruling 38): in a file the owner vouched for, the members that can be read still are (and scanned);
            // only those that can't are left out.
            guard budget.vouched else { throw unscannableMethod }
            files = files.filter { !unscannable($0) }
        }
        budget.entries -= files.count
        guard budget.entries >= 0, files.reduce(0, { $0 + $1.uncompressedSize }) <= budget.bytes else { throw overBudget }
        guard !files.isEmpty else { return [] }
        try budget.launch()
        // (A vouched archive with members left out asks only for the rest.)
        let wanted = Set(files.map(\.name)), every = !budget.vouched
        let members = try archives.members(of: data, wanted: { every || wanted.contains($0) },
                                           limits: ArchiveLimits(bytes: budget.bytes, ratio: ArchiveLimits.maxRatio))
        // Every file entry exactly once, each with the length the directory declares: nothing the reader skipped or could
        // not decode goes unscanned (a failed inflate is short, never empty-and-clean).
        let got = members.map { "\($0.name)\u{0}\($0.data.count)" }.sorted()
        let want = files.map { "\($0.name)\u{0}\($0.uncompressedSize)" }.sorted()
        guard got == want else { throw incomplete }
        budget.bytes -= members.reduce(0) { $0 + $1.data.count }
        try budget.ensure(budget.bytes >= 0)
        var found: [ScanFinding] = []
        for member in members {
            // Refused when compressed in a format the engine can't open; scanned; opened again when it is an archive, a PDF
            // or a PNG itself (one level down, on the same budget).
            var hits = try EmbeddedContent.inner(member.data, ext: (member.name as NSString).pathExtension, container: "archive",
                                                 archives: archives, expanded: expanded, budget: budget, level: level, chunk: chunk)
            // Office text split across runs (`<w:t>sk_</w:t><w:t>…</w:t>`): the member's text between its tags, joined.
            if member.name.lowercased().hasSuffix(".xml") || member.name.lowercased().hasSuffix(".rels") {
                let text = TextExtract.stripTags(String(decoding: member.data, as: UTF8.self), lineBreaks: [])
                hits += try ContentScan.scan(data: Data(text.utf8), isText: true, knownValues: expanded, chunk: chunk)
            }
            found += hits.map { ScanFinding(label: $0.label, line: 0, isKnownValue: $0.isKnownValue) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert("\($0.label)\n\($0.isKnownValue)").inserted }
    }

    /// ML's `ContentScan` over bytes: text (no NUL in the first 8 KB) gets the patterns and every form of the values; a
    /// binary gets the values' bytes, and the patterns over its bytes read as text.
    static func scanBytes(_ data: Data, expanded: [(name: String, value: String)], chunk: Int) throws -> [ScanFinding] {
        let isText = !data.prefix(OpenRefLimits.binarySniffBytes).contains(0)
        var findings = try ContentScan.scan(data: data, isText: isText, knownValues: expanded, chunk: chunk)
        if !isText {
            findings += try ContentScan.scan(data: data, isText: true, knownValues: [], chunk: chunk).filter { !$0.isKnownValue }
        }
        return findings
    }
}

/// What one check may spend on everything decoded from its bytes, across every nesting level together (C2b fix rounds 1
/// and 2): decompressed bytes (`ArchiveLimits.maxBytes`), entries (`maxEntries`: every archive member and every decoded PDF
/// stream; one archive still holds at most `ArchiveLimits.maxMembers`), levels (`ArchiveMemberScan.maxDepth`) and awake
/// time (`seconds`, the PDF helper's time limit included), and (round 3, m-A) sandboxed reads launched (`maxLaunches`: each
/// archive opened, each PDF read). Shared by reference: an inner level spends what the outer left.
final class ArchiveScanBudget {
    static let maxEntries = 10_000
    static let maxLaunches = 200

    var bytes: Int
    var entries: Int
    var launches: Int
    let depth: Int
    let deadline: TimeInterval
    /// Round 5 (ruling 38): the owner vouched for the exact bytes being checked: their structure refusals (a PDF whose
    /// structure couldn't be verified, a part in a format the engine can't open, archive members it can't decode) give way
    /// to scanning everything that can be read, at every level.
    let vouched: Bool

    init(bytes: Int = ArchiveLimits.maxBytes, entries: Int = ArchiveScanBudget.maxEntries, depth: Int = ArchiveMemberScan.maxDepth,
         seconds: TimeInterval = 120, launches: Int = ArchiveScanBudget.maxLaunches, vouched: Bool = false) {
        self.bytes = bytes; self.entries = entries; self.launches = launches; self.depth = depth; self.vouched = vouched
        deadline = AwakeTime.uptime() + seconds
    }

    var expired: Bool { AwakeTime.uptime() > deadline }

    /// Throws when the time is spent (`ArchiveMemberScan.outOfTime`), else when `ok` is false (`overBudget`).
    func ensure(_ ok: Bool) throws {
        if expired { throw ArchiveMemberScan.outOfTime }
        if !ok { throw ArchiveMemberScan.overBudget }
    }

    /// Spends one sandboxed read; past the cap, `tooManyLaunches`.
    func launch() throws {
        try ensure(true)
        launches -= 1
        guard launches >= 0 else { throw ArchiveMemberScan.tooManyLaunches }
    }

    /// The time left, or nil once it is spent.
    var remaining: Duration? {
        let left = deadline - AwakeTime.uptime()
        return left > 0 ? .milliseconds(Int((left * 1000).rounded(.down))) : nil
    }
}

/// What the gate found in some bytes: nothing, a stored secret's value (the first, by line; never the value itself), or a
/// secret pattern (the first: its rule's label and line).
public enum ScanVerdict: Equatable, Sendable {
    case clean
    case knownValue(ScanFinding)
    case pattern(label: String, line: Int)
}

/// Verdicts by the bytes' SHA-256 and a version that names everything else the verdict depends on (the company, the
/// extension, the secrets version and the known values), so a secret stored later is caught on the next read of old bytes.
/// In memory only, at most `maxEntries` (then emptied). A lock, not an actor: every caller is synchronous store code.
public final class ScanCache: @unchecked Sendable {
    public static let shared = ScanCache()
    public static let maxEntries = 4096

    private let lock = NSLock()
    private var entries: [String: ScanVerdict] = [:]
    private var refusals: [String: String] = [:]

    public init() {}

    public func result(sha256: String, version: String) -> ScanVerdict? {
        lock.withLock { entries["\(version)\n\(sha256)"] }
    }

    public func store(sha256: String, version: String, verdict: ScanVerdict) {
        lock.withLock {
            if entries.count >= Self.maxEntries { entries.removeAll(keepingCapacity: true) }
            entries["\(version)\n\(sha256)"] = verdict
        }
    }

    /// A refusal's message for these bytes (the ref's name as `SecretGate.refToken`), when one is cached.
    func refusal(sha256: String, version: String) -> String? {
        lock.withLock { refusals["\(version)\n\(sha256)"] }
    }

    func storeRefusal(sha256: String, version: String, message: String) {
        lock.withLock {
            if refusals.count >= Self.maxEntries { refusals.removeAll(keepingCapacity: true) }
            refusals["\(version)\n\(sha256)"] = message
        }
    }
}

/// The one gate (design §4.5). Order: the stored values first (ML's `ContentScan` over `EncodedForms.expand(knownValues)`
/// for the whole bytes, then the members of an archive or Office file through `ArchiveMemberScan`), then the secret
/// patterns. `knownValues` come from `Store.knownSecretValues(companyId:vault:)` with the caller's injected vault.
public enum SecretGate {
    /// The verdict for `data`, refusing a stored secret's value: `WorkError.invalid("<canonical> contains a stored secret
    /// (line <n>); remove it before sharing")` (no line for a binary or an archive member) and an engine alert; the value is
    /// never echoed. An archive or PDF that can't be read refuses too: `"archives can't be scanned on this machine"` (no
    /// reader), `"PDFs can't be scanned on this machine"` (no PDF helper), or the reader's reason (`"this archive expands
    /// too much to preview safely"`, `"this PDF is encrypted, …"`, …), and so do bytes compressed in a format the engine
    /// can't open (`"<canonical> is compressed as gzip, which can't be scanned for secrets; share the files inside
    /// instead"`; `unscannableFormat`). A secret pattern found only inside decoded content refuses (`decodedRefusal`: no
    /// redaction of the raw bytes would remove it); one in the raw bytes is returned for the caller to redact (text, through
    /// `redactedCopy`) or refuse (binary or a container). `canonical` names the bytes in every message and alert only after the stored values (and their encoded
    /// forms) and the secret patterns are redacted from it (`shown`).
    public static func check(_ data: Data, ext: String, canonical: String, archives: any ArchiveReader,
                             knownValues: [(name: String, value: String)], store: Store, companyId: String,
                             chunk: Int = ContentScan.chunkBytes) throws -> ScanVerdict {
        let v = try verdict(data, ext: ext, canonical: canonical, archives: archives, knownValues: knownValues, store: store,
                            companyId: companyId, chunk: chunk)
        if case .knownValue(let finding) = v { throw refusal(canonical, finding, knownValues: knownValues) }
        return v
    }

    /// `check` without the throw for a stored value (the app's render point blanks instead); the alert is raised the same.
    /// Round 5 (ruling 38): a STRUCTURE refusal (`StructureRefusal`: a PDF whose structure couldn't be verified, bytes or a
    /// part compressed in a format the engine can't open, archive members it can't decode) names the exact command by which
    /// the owner can vouch for the file (`vouchHint`), records the refused bytes and alerts the owner
    /// (`Store.recordStructureRefusal`); once the owner vouched for these exact bytes under this name in this company
    /// (`Store.isFileVouched`), those refusals give way and everything readable is scanned as usual.
    static func verdict(_ data: Data, ext: String, canonical: String, archives: any ArchiveReader,
                        knownValues: [(name: String, value: String)], store: Store, companyId: String,
                        chunk: Int = ContentScan.chunkBytes) throws -> ScanVerdict {
        let sha = SHA256.hex(data)
        let vouched = store.isFileVouched(companyId: companyId, canonical: canonical, sha256: sha)
        // A vouched file's verdict is its own: the same bytes under another name, or in another company, are not vouched.
        let version = chunk == ContentScan.chunkBytes
            ? cacheVersion(store: store, companyId: companyId, ext: ext, knownValues: knownValues).map { vouched ? $0 + "|vouched" : $0 } : nil
        let result: ScanVerdict
        let name = shown(canonical, knownValues: knownValues)
        func structural(_ reason: String) -> WorkError {
            store.recordStructureRefusal(companyId: companyId, canonical: canonical, shown: name, sha256: sha, reason: reason, now: Store.now())
            return WorkError.invalid(reason + vouchHint(store: store, companyId: companyId, shown: name))
        }
        if let version, let refused = ScanCache.shared.refusal(sha256: sha, version: version) {
            if refused.hasPrefix(structureMark) {
                throw structural(String(refused.dropFirst(structureMark.count)).replacingOccurrences(of: refToken, with: name))
            }
            throw WorkError.invalid(refused.replacingOccurrences(of: refToken, with: name))
        }
        if let version, let cached = ScanCache.shared.result(sha256: sha, version: version) {
            result = cached
        } else {
            // Round 3 (m-A): a refusal is cached like a verdict, its ref's name left out (a token stands for it), unless it
            // may pass on another try (no reader, a reader that could not run or ran out of time).
            do {
                result = try compute(data, ext: ext, archives: archives, knownValues: knownValues, chunk: chunk, shown: refToken,
                                     vouched: vouched)
            } catch let refusal as StructureRefusal {
                if let version { ScanCache.shared.storeRefusal(sha256: sha, version: version, message: structureMark + refusal.message) }
                throw structural(refusal.message.replacingOccurrences(of: refToken, with: name))
            } catch let error as WorkError {
                if let version, case .invalid(let message) = error, !transientRefusals.contains(message) {
                    ScanCache.shared.storeRefusal(sha256: sha, version: version, message: message)
                }
                if case .invalid(let message) = error { throw WorkError.invalid(message.replacingOccurrences(of: refToken, with: name)) }
                throw error
            }
            if let version { ScanCache.shared.store(sha256: sha, version: version, verdict: result) }
        }
        if case .knownValue(let finding) = result {
            store.alertStoredSecret(companyId: companyId, canonical: canonical, shown: shown(canonical, knownValues: knownValues),
                                    label: finding.label, now: Store.now())
        }
        return result
    }

    /// Round 5 (ruling 38): a refusal of the bytes' STRUCTURE, not of anything found in them; the owner may vouch for the
    /// exact file. `message` names the ref as `refToken`, if at all.
    struct StructureRefusal: Error {
        let message: String
    }

    /// What marks a cached structure refusal.
    static let structureMark = "\u{2}structure\u{2}"

    /// The refusals of the reader that are about structure (`StructureRefusal`).
    static func isStructural(_ e: ArchiveReadError) -> Bool {
        e == SandboxedPDFReader.unaccounted || e == ArchiveMemberScan.unscannableMethod || EmbeddedContent.isFormatRefusal(e.message)
    }

    /// The end of a structure refusal: the exact command by which the owner can vouch for the file (`brahma vouch file
    /// <company slug> <name as shown>`, the name quoted for the shell when it needs it); the Inbox when the name is withheld.
    static func vouchHint(store: Store, companyId: String, shown: String) -> String {
        guard shown != withheldName, let company = try? store.company(id: companyId) else {
            return " — the owner can vouch for this exact file from the Inbox"
        }
        return " — the owner can vouch for this exact file: brahma vouch file \(company.slug) \(shellQuoted(shown))"
    }

    /// `text` as one shell word for the vouch command's last argument: as is when it holds only characters no shell treats
    /// specially, else in single quotes; after `--` when it starts with `-` (so it is never read as an option).
    static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@_+:,./-")
        let word = !text.isEmpty && text.unicodeScalars.allSatisfy({ plain.contains($0) })
            ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return text.hasPrefix("-") ? "-- " + word : word
    }

    /// What stands for the ref's name in a cached refusal.
    static let refToken = "\u{1}ref\u{1}"

    /// Refusals that may not hold on another try, so never cached.
    static let transientRefusals: Set<String> = [
        "archives can't be scanned on this machine", SandboxedPDFReader.unavailable.message, SandboxedPDFReader.couldNotRun.message,
        SandboxedPDFReader.tooLong.message, SandboxedUnzipReader.couldNotRun.message, SandboxedUnzipReader.tooLong.message,
        ArchiveMemberScan.outOfTime.message,
    ]

    /// The cache version for bytes of `ext` in `companyId` checked against `knownValues`: nil when the secrets version
    /// can't be read (nothing is cached or reused then).
    public static func cacheVersion(store: Store, companyId: String, ext: String,
                                    knownValues: [(name: String, value: String)]) -> String? {
        guard let secrets = try? store.secretsVersion() else { return nil }
        let values = StableHash.fnv1a64(knownValues.map { "\($0.name)\u{0}\($0.value)" }.sorted().joined(separator: "\u{1}"))
        return "\(companyId)|\(ext.lowercased())|\(secrets)|\(values)"
    }

    static func compute(_ data: Data, ext: String, archives: any ArchiveReader, knownValues: [(name: String, value: String)],
                        chunk: Int, shown: String, vouched: Bool = false) throws -> ScanVerdict {
        let expanded = EncodedForms.expand(knownValues)
        let raw = try ArchiveMemberScan.scanBytes(data, expanded: expanded, chunk: chunk)
        if let known = raw.first(where: \.isKnownValue) { return .knownValue(known) }
        // Ruling 29: compressed data the engine can't open is never passed as clean (round 5, ruling 38: unless the owner
        // vouched for these exact bytes; their own bytes were scanned just above).
        if let format = ArchiveMemberScan.unscannableFormat(data), !vouched {
            throw StructureRefusal(message: "\(shown) is compressed as \(format), which can't be scanned for secrets; share the files inside instead")
        }
        // One budget for everything decoded from these bytes: archive members, PDF parts and PNG text at every level
        // (R1-6, ruling 33).
        let decoded: [ScanFinding]
        do {
            decoded = try EmbeddedContent.scan(data, ext: ext, archives: archives, expanded: expanded,
                                               budget: ArchiveScanBudget(vouched: vouched), level: 0, chunk: chunk)
        } catch let e as ArchiveReadError {
            if isStructural(e) { throw StructureRefusal(message: e.message) }
            throw WorkError.invalid(e == .unavailable ? "archives can't be scanned on this machine" : e.message)
        }
        if let known = decoded.first(where: \.isKnownValue) { return .knownValue(known) }
        // R2-3 (N-1): a pattern found only in decoded content is not in the bytes a redaction would change: refused, never
        // a "redacted" copy that still holds it.
        if let pattern = decoded.first { throw decodedRefusal(shown, label: pattern.label) }
        if let pattern = raw.first { return .pattern(label: pattern.label, line: pattern.line) }
        return .clean
    }

    /// The refusal of a secret pattern found inside decoded content (an archive member, a PDF part, a PNG text chunk).
    static func decodedRefusal(_ shown: String, label: String) -> WorkError {
        WorkError.invalid("\(shown) looks like it contains a secret (\(label)) inside compressed or embedded content, which can't be "
                          + "redacted, so it can't be shared, copied or shown")
    }

    /// A name withheld whole: what `shown` says for a ref whose name holds a secret split by white space or invisible
    /// characters.
    static let withheldName = "[a name that holds a secret]"

    /// `canonical` as a message may show it: flattened onto one line first, then every secret pattern and every form of
    /// every stored value redacted (a ref named after a secret never echoes it), at most 200 characters. Fix round 2 (m-2):
    /// characters a flattening or a display drops or turns into a space (line and paragraph separators, zero-width and
    /// direction marks, controls, white space) can split a value in a name and put it back together later; when the name
    /// without them still holds a secret after the redaction, the whole name is withheld (`withheldName`).
    static func shown(_ canonical: String, knownValues: [(name: String, value: String)]) -> String {
        let expanded = EncodedForms.expand(knownValues)
        let redacted = ContentScan.redact(text: Store.flat(canonical, max: Int.max), findings: [], knownValues: expanded)
        let skeleton = String(String.UnicodeScalarView(redacted.unicodeScalars.filter { !isInvisible($0) }))
        if ContentScan.redact(text: skeleton, findings: [], knownValues: expanded) != skeleton { return withheldName }
        return Store.flat(redacted, max: 200)
    }

    /// White space, controls, and the format characters `Store.clean` removes or a renderer may not show.
    static func isInvisible(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(s) || CharacterSet.controlCharacters.contains(s)
            || s.properties.generalCategory == .format || s.value == 0x2028 || s.value == 0x2029
    }

    static func refusal(_ canonical: String, _ finding: ScanFinding, knownValues: [(name: String, value: String)]) -> WorkError {
        WorkError.invalid("\(shown(canonical, knownValues: knownValues)) contains a stored secret"
                          + "\(finding.line > 0 ? " (line \(finding.line))" : ""); remove it before sharing")
    }

    /// The refusal of a pattern in bytes that can't be redacted (a binary, an archive).
    static func binaryRefusal(_ canonical: String, label: String, what: String, knownValues: [(name: String, value: String)]) -> WorkError {
        WorkError.invalid("\(shown(canonical, knownValues: knownValues)) looks like it contains a secret (\(label)); a binary file "
                          + "can't be redacted, so it isn't \(what)")
    }

    /// Whether `data` is text as the gate reads it (no NUL in the first 8 KB) and no container: not an archive, a PDF or a
    /// PNG (a redaction of their raw text would not reach what they hold decoded).
    static func isRedactable(_ data: Data, ext: String) -> Bool {
        !data.prefix(OpenRefLimits.binarySniffBytes).contains(0) && !ArchiveMemberScan.isArchive(data, ext: ext)
            && !EmbeddedContent.isPDF(data, ext: ext) && !EmbeddedContent.isPNG(data)
    }

    /// R2-3: the redacted copy of `data` (`RedactedCopy.make`), checked again through the whole gate: refused unless the copy
    /// itself is clean, so no copy ever holds what the redaction missed.
    static func redactedCopy(_ data: Data, ext: String, canonical: String, archives: any ArchiveReader,
                             knownValues: [(name: String, value: String)], store: Store) throws -> Data {
        let copy = store.refHooks.redactedCopy?(data) ?? RedactedCopy.make(data, findings: [], knownValues: knownValues)
        let label = shown(canonical, knownValues: knownValues)
        let again: ScanVerdict
        do {
            again = try compute(copy, ext: ext, archives: archives, knownValues: knownValues, chunk: ContentScan.chunkBytes, shown: label)
        } catch let error as WorkError {
            // Round 3 (m-D): a secret found in the copy says so; a re-check that could not be made says why.
            if case .invalid(let message) = error, message.contains(" inside compressed or embedded content") {
                throw WorkError.invalid("\(label) still looks like it holds a secret after redaction, so no copy of it is made")
            }
            throw WorkError.invalid("no redacted copy of \(label) is made: the copy couldn't be checked again (\(error.message))")
        } catch let refusal as StructureRefusal {
            throw WorkError.invalid("no redacted copy of \(label) is made: the copy couldn't be checked again (\(refusal.message))")
        }
        guard again == .clean else {
            throw WorkError.invalid("\(label) still looks like it holds a secret after redaction, so no copy of it is made")
        }
        return copy
    }
}

/// A shareable copy of text with a secret pattern: decoded as UTF-8 (invalid bytes become U+FFFD), every pattern match and
/// every form of every stored value replaced with `[redacted <label>]` (ML's `ContentScan.redact`), encoded again. Binary
/// input is refused by the caller (`SecretGate.isRedactable`).
public enum RedactedCopy {
    public static func make(_ data: Data, findings: [ScanFinding], knownValues: [(name: String, value: String)]) -> Data {
        Data(ContentScan.redact(text: String(decoding: data, as: UTF8.self), findings: findings,
                                knownValues: EncodedForms.expand(knownValues)).utf8)
    }
}

extension Store {
    /// The app's render point (C6's `RefBodies`): the gate's verdict for bytes about to be drawn, cached by `sha256` (which
    /// must be the bytes' hash) and the secrets version. A stored value is `.knownValue` (the app blanks it) and alerts the
    /// owner; nothing here throws for it. A secret pattern inside decoded content (an archive member, a PDF, a PNG text
    /// chunk) can't be blanked in a rendering and is refused (thrown). `archives` reads Office members and PDFs (none: they
    /// refuse).
    public func scanForRender(companyId: String, sha256: String, data: Data, ext: String,
                              knownValues: [(name: String, value: String)], archives: (any ArchiveReader)? = nil) throws -> ScanVerdict {
        guard SHA256.hex(data) == sha256.lowercased() else { throw WorkError.invalid("the bytes to render don't match their hash") }
        return try SecretGate.verdict(data, ext: ext, canonical: "a file shown in the app (sha256 \(sha256.prefix(12)))",
                                      archives: archives ?? UnavailableArchiveReader(), knownValues: knownValues, store: self,
                                      companyId: companyId)
    }

    /// The owner's "View original" (design §4.5): the bytes of `ref` as they are, unredacted (a pattern hit is what the
    /// owner checks here), with a `refRead(via: viewOriginal)` row and an `.access` activity line. For a redacted share copy
    /// (`F-<n>` with `addedVia = "share"` and `secretScan = redacted`) the original is its source, which the engine recorded
    /// (`sourceDetail`): for a worktree file the worktree file itself. A stored secret's value is still never shown (the
    /// gate refuses it), and a purged ref has no original. Owner only: nothing in `CompanyTools` reaches it.
    public func viewOriginal(companyId: String, ref: WorkRef, knownValues: [(name: String, value: String)], paths: BrahmaPaths,
                             now: Date = Store.now(), archives: (any ArchiveReader)? = nil) throws -> Data {
        guard let company = try company(id: companyId) else { throw WorkError.notFound(Self.refUnavailable) }
        var target = ref
        if ref.kind == .resource, let n = Int(ref.id), let row = try resource(companyId: companyId, number: n), row.purgedAt == nil,
           row.addedVia == "share", row.secretScan == .redacted {
            let context = RefContext(companyId: companyId, keyPrefixes: [Store.keyPrefix(slug: company.slug)])
            guard let source = row.sourceDetail, let parsed = WorkRef.parse(source, context: context), parsed.kind == .file else {
                throw WorkError.notFound("the original of \(SecretGate.shown(row.ref, knownValues: knownValues)) is no longer available")
            }
            target = parsed
        }
        let r = try resolveDetailed(target, reader: .owner, companyId: companyId, messageRefId: nil)
        guard r.resolved.visibility == .full, let subject = r.subject, let found = r.company else {
            throw WorkError.notFound(target == ref ? Self.refUnavailable
                                     : "the original of \(SecretGate.shown(ref.canonical, knownValues: knownValues)) is no longer available")
        }
        guard r.resolved.state != .purged else { throw WorkError.invalid(Self.purgedText) }
        let content: Content
        do {
            content = try readContent(r, subject: subject, company: found, paths: paths, whole: true, knownValues: knownValues)
        } catch let e as WorkError {
            throw e
        } catch {
            throw WorkError.notFound(target == ref ? Self.refUnavailable
                                     : "the original of \(SecretGate.shown(ref.canonical, knownValues: knownValues)) is no longer available")
        }
        let data = content.data
        _ = try SecretGate.check(data, ext: content.ext, canonical: ref.canonical, archives: archives ?? UnavailableArchiveReader(),
                                 knownValues: knownValues, store: self, companyId: companyId)
        try writer.write { db in
            try Self.recordRefRead(db: db, companyId: companyId, reader: .owner, canonical: ref.canonical, rev: content.rev,
                                   bytes: data.count, tainted: r.resolved.tainted, via: "viewOriginal", turnId: nil, now: now)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .access,
                              text: try redact("You viewed the original of \(Store.flat(ref.canonical, max: 200))"), createdAt: now).insert(db)
        }
        return data
    }

    /// The reason that keys the engine alert about `canonical` holding a stored secret's value.
    static func storedSecretAlertReason(_ canonical: String) -> String { "stored-secret:\(StableHash.fnv1a64(canonical))" }

    /// Tells the owner (once while the alert is open) that `canonical` holds the value of a stored secret: its ref and the
    /// secret's name, never the value. Best effort: the refusal stands whether or not the alert could be written.
    func alertStoredSecret(companyId: String, canonical: String, shown: String, label: String, now: Date) {
        let name = label.hasPrefix("stored secret ") ? String(label.dropFirst("stored secret ".count)) : label
        let reason = Self.storedSecretAlertReason(canonical)
        let text = "\(shown) holds the value of stored secret \(name); it was refused and not shown. "
            + "Remove the value from it, and rotate the secret if it was shared."
        do {
            try writer.write { db in
                let open = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.engineAlert
                                          && Column("status") == AskStatus.pendingOwner.rawValue
                                          && Column("subjectId") == Store.engineAlertKey(reason)).fetchCount(db)
                guard open == 0 else { return }
                try EngineAlerts.raise(store: self, db: db, text: text, now: now, reason: reason, companyId: companyId)
            }
        } catch {
            FileHandle.standardError.write(Data("brahma: could not alert the owner that a ref holds a stored secret: \(error)\n".utf8))
        }
    }
}
