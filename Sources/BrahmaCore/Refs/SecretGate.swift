import Foundation
import GRDB

// Plan C Task C2b (design §4.5): the one secret gate every byte C shares, snapshots, opens, copies or renders goes through.
// The streaming scan is ML's `ContentScan` (chunked, with an overlap of at least the longest needle; findings never carry
// the matched text). C adds only the forms ML does not scan: encoded copies of each stored value (`EncodedForms`) and the
// members of zip-based archives (`ArchiveMemberScan`).

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
/// - an archive is any bytes with a zip local header anywhere or an end record near the end (a polyglot or a renamed zip),
///   and its central directory must be self-consistent and tile from byte 0 (ML's `ZipInventory`), so prepended data refuses;
/// - an entry is a directory only when its name ends in `/` and both its sizes are 0; every other entry (whatever its
///   directory flags) is a file the reader must return, exactly once, with exactly the length the directory declares;
/// - only stored (0) and deflate (8) members, never an encrypted one; a link entry refuses;
/// - nested archives are opened with ONE budget (`ArchiveScanBudget`: decompressed bytes, entries, depth and time) for all
///   levels together;
/// - a member that is gzip, bzip2, xz, zstd, 7z or rar data can't be scanned and refuses.
public enum ArchiveMemberScan {
    public static let maxDepth = 3
    /// Extensions read as archives even when their bytes do not look like one (they then fail to read, and are refused).
    public static let archiveExts: Set<String> = ["zip", "docx", "xlsx", "pptx"]
    static let zipMagic = Data([0x50, 0x4B, 0x03, 0x04])
    static let endMagic = Data([0x50, 0x4B, 0x05, 0x06])

    static let incomplete = ArchiveReadError.refused("this archive can't be scanned for secrets")
    static let tooMany = ArchiveReadError.refused("this archive has too many files to scan for secrets")
    static let overBudget = ArchiveReadError.refused("this archive expands too much to scan for secrets")
    static let unscannableMethod = ArchiveReadError.refused("this archive uses compression or encryption that can't be scanned for secrets")

    /// Bytes that hold a zip: a local header anywhere, or an end record within the last 64 KB + 22 bytes (where every zip
    /// reader looks), or a name that says zip.
    public static func isArchive(_ data: Data, ext: String) -> Bool {
        if archiveExts.contains(ext.lowercased()) { return true }
        if data.range(of: zipMagic) != nil { return true }
        let tail = max(data.startIndex, data.endIndex - (65_535 + 22))
        return data.range(of: endMagic, in: tail..<data.endIndex) != nil
    }

    /// The compressed format whose magic `data` starts with, among those the engine can't open: gzip, bzip2, xz, zstd, 7z, rar.
    public static func unscannableFormat(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(8))
        func starts(_ m: [UInt8]) -> Bool { b.count >= m.count && Array(b[0..<m.count]) == m }
        if starts([0x1F, 0x8B]) { return "gzip" }
        if starts([0x42, 0x5A, 0x68]), b.count > 3, (0x31...0x39).contains(b[3]) { return "bzip2" }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "xz" }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return "zstd" }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "7z" }
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return "rar" }
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
        guard level < budget.depth, !budget.expired else { throw overBudget }
        let entries: [ZipInventory.Entry]
        do { entries = try ZipInventory.entries(of: data) } catch { throw ArchiveReadError.unreadable }
        let files = entries.filter { !isDirectoryEntry($0) }
        if files.contains(where: \.isSymlink) { throw ArchiveReadError.unsafe }
        guard files.count <= ArchiveLimits.maxMembers else { throw tooMany }
        if files.contains(where: { ($0.method != 0 && $0.method != 8) || $0.flags & 0x1 != 0 }) { throw unscannableMethod }
        budget.entries -= files.count
        guard budget.entries >= 0, files.reduce(0, { $0 + $1.uncompressedSize }) <= budget.bytes else { throw overBudget }
        guard !files.isEmpty else { return [] }
        let members = try archives.members(of: data, wanted: { _ in true },
                                           limits: ArchiveLimits(bytes: budget.bytes, ratio: ArchiveLimits.maxRatio))
        // Every file entry exactly once, each with the length the directory declares: nothing the reader skipped or could
        // not decode goes unscanned (a failed inflate is short, never empty-and-clean).
        let got = members.map { "\($0.name)\u{0}\($0.data.count)" }.sorted()
        let want = files.map { "\($0.name)\u{0}\($0.uncompressedSize)" }.sorted()
        guard got == want else { throw incomplete }
        budget.bytes -= members.reduce(0) { $0 + $1.data.count }
        guard budget.bytes >= 0, !budget.expired else { throw overBudget }
        var found: [ScanFinding] = []
        for member in members {
            if let format = unscannableFormat(member.data) {
                throw ArchiveReadError.refused("this archive holds \(format) data, which can't be scanned for secrets")
            }
            var hits = try scanBytes(member.data, expanded: expanded, chunk: chunk)
            // Office text split across runs (`<w:t>sk_</w:t><w:t>…</w:t>`): the member's text between its tags, joined.
            if member.name.lowercased().hasSuffix(".xml") || member.name.lowercased().hasSuffix(".rels") {
                let text = TextExtract.stripTags(String(decoding: member.data, as: UTF8.self), lineBreaks: [])
                hits += try ContentScan.scan(data: Data(text.utf8), isText: true, knownValues: expanded, chunk: chunk)
            }
            let ext = (member.name as NSString).pathExtension
            if isArchive(member.data, ext: ext) {
                hits += try scan(member.data, archives: archives, expanded: expanded, budget: budget, level: level + 1, chunk: chunk)
            }
            // R1-9: a PDF's or PNG's compressed streams, on the same budget.
            hits += try EmbeddedStreams.scan(member.data, ext: ext, expanded: expanded, budget: budget, chunk: chunk)
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

/// What one archive scan may spend across every nesting level together (C2b fix round 1): decompressed bytes
/// (`ArchiveLimits.maxBytes`), file entries (`ArchiveLimits.maxMembers`), levels (`ArchiveMemberScan.maxDepth`) and awake
/// time (`seconds`). Shared by reference: an inner archive spends what the outer one left.
final class ArchiveScanBudget {
    var bytes: Int
    var entries: Int
    let depth: Int
    let deadline: TimeInterval

    init(bytes: Int = ArchiveLimits.maxBytes, entries: Int = ArchiveLimits.maxMembers, depth: Int = ArchiveMemberScan.maxDepth,
         seconds: TimeInterval = 120) {
        self.bytes = bytes; self.entries = entries; self.depth = depth; deadline = AwakeTime.uptime() + seconds
    }

    var expired: Bool { AwakeTime.uptime() > deadline }
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
}

/// The one gate (design §4.5). Order: the stored values first (ML's `ContentScan` over `EncodedForms.expand(knownValues)`
/// for the whole bytes, then the members of an archive or Office file through `ArchiveMemberScan`), then the secret
/// patterns. `knownValues` come from `Store.knownSecretValues(companyId:vault:)` with the caller's injected vault.
public enum SecretGate {
    /// The verdict for `data`, refusing a stored secret's value: `WorkError.invalid("<canonical> contains a stored secret
    /// (line <n>); remove it before sharing")` (no line for a binary or an archive member) and an engine alert; the value is
    /// never echoed. An archive that can't be read refuses too: `"archives can't be scanned on this machine"` (no reader),
    /// or the reader's reason (`"this archive expands too much to preview safely"`, …), and so do bytes compressed in a
    /// format the engine can't open (`"<canonical> is compressed as gzip, which can't be scanned for secrets; share the files
    /// inside instead"`; also bzip2, xz, zstd, 7z, rar). A pattern is returned for the caller to redact (text) or refuse
    /// (binary). `canonical` names the bytes in every message and alert only after the stored values (and their encoded
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
    static func verdict(_ data: Data, ext: String, canonical: String, archives: any ArchiveReader,
                        knownValues: [(name: String, value: String)], store: Store, companyId: String,
                        chunk: Int = ContentScan.chunkBytes) throws -> ScanVerdict {
        let sha = SHA256.hex(data)
        let version = chunk == ContentScan.chunkBytes
            ? cacheVersion(store: store, companyId: companyId, ext: ext, knownValues: knownValues) : nil
        let result: ScanVerdict
        if let version, let cached = ScanCache.shared.result(sha256: sha, version: version) {
            result = cached
        } else {
            result = try compute(data, ext: ext, archives: archives, knownValues: knownValues, chunk: chunk,
                                 shown: shown(canonical, knownValues: knownValues))
            if let version { ScanCache.shared.store(sha256: sha, version: version, verdict: result) }
        }
        if case .knownValue(let finding) = result {
            store.alertStoredSecret(companyId: companyId, canonical: canonical, shown: shown(canonical, knownValues: knownValues),
                                    label: finding.label, now: Store.now())
        }
        return result
    }

    /// The cache version for bytes of `ext` in `companyId` checked against `knownValues`: nil when the secrets version
    /// can't be read (nothing is cached or reused then).
    public static func cacheVersion(store: Store, companyId: String, ext: String,
                                    knownValues: [(name: String, value: String)]) -> String? {
        guard let secrets = try? store.secretsVersion() else { return nil }
        let values = StableHash.fnv1a64(knownValues.map { "\($0.name)\u{0}\($0.value)" }.sorted().joined(separator: "\u{1}"))
        return "\(companyId)|\(ext.lowercased())|\(secrets)|\(values)"
    }

    static func compute(_ data: Data, ext: String, archives: any ArchiveReader, knownValues: [(name: String, value: String)],
                        chunk: Int, shown: String) throws -> ScanVerdict {
        let expanded = EncodedForms.expand(knownValues)
        var findings = try ArchiveMemberScan.scanBytes(data, expanded: expanded, chunk: chunk)
        if let known = findings.first(where: \.isKnownValue) { return .knownValue(known) }
        // Ruling 29: compressed data the engine can't open is never passed as clean.
        if let format = ArchiveMemberScan.unscannableFormat(data) {
            throw WorkError.invalid("\(shown) is compressed as \(format), which can't be scanned for secrets; share the files inside instead")
        }
        // One budget for everything decoded from these bytes: archive members at every level, PDF and PNG streams (R1-6, R1-9).
        let budget = ArchiveScanBudget()
        do {
            if ArchiveMemberScan.isArchive(data, ext: ext) {
                findings += try ArchiveMemberScan.scan(data, archives: archives, expanded: expanded, budget: budget, level: 0, chunk: chunk)
            }
            findings += try EmbeddedStreams.scan(data, ext: ext, expanded: expanded, budget: budget, chunk: chunk)
        } catch let e as ArchiveReadError {
            throw WorkError.invalid(e == .unavailable ? "archives can't be scanned on this machine" : e.message)
        }
        if let known = findings.first(where: \.isKnownValue) { return .knownValue(known) }
        if let pattern = findings.first { return .pattern(label: pattern.label, line: pattern.line) }
        return .clean
    }

    /// `canonical` as a message may show it: every secret pattern and every form of every stored value redacted (a ref named
    /// after a secret never echoes it), on one line, at most 200 characters.
    static func shown(_ canonical: String, knownValues: [(name: String, value: String)]) -> String {
        Store.flat(ContentScan.redact(text: canonical, findings: [], knownValues: EncodedForms.expand(knownValues)), max: 200)
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

    /// Whether `data` is text as the gate reads it (no NUL in the first 8 KB) and not an archive.
    static func isRedactable(_ data: Data, ext: String) -> Bool {
        !data.prefix(OpenRefLimits.binarySniffBytes).contains(0) && !ArchiveMemberScan.isArchive(data, ext: ext)
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
    /// owner; nothing here throws for it. `archives` reads Office members (none: archives refuse).
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
                throw WorkError.notFound("the original of \(row.ref) is no longer available")
            }
            target = parsed
        }
        let r = try resolveDetailed(target, reader: .owner, companyId: companyId, messageRefId: nil)
        guard r.resolved.visibility == .full, let subject = r.subject, let found = r.company else {
            throw WorkError.notFound(target == ref ? Self.refUnavailable : "the original of \(ref.canonical) is no longer available")
        }
        guard r.resolved.state != .purged else { throw WorkError.invalid(Self.purgedText) }
        let content: Content
        do {
            content = try readContent(r, subject: subject, company: found, paths: paths, whole: true, knownValues: knownValues)
        } catch let e as WorkError {
            throw e
        } catch {
            throw WorkError.notFound(target == ref ? Self.refUnavailable : "the original of \(ref.canonical) is no longer available")
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
