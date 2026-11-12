import Foundation
import GRDB

/// What a memory doc was indexed from. Later plans add their own (4a `artifact`, M `analytics`, 7 `mail`) without changing ML.
public struct MemorySource: RawRepresentable, Hashable, Codable, Sendable, DatabaseValueConvertible, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let message = MemorySource(rawValue: "message")
    public static let item = MemorySource(rawValue: "item")
    public static let ask = MemorySource(rawValue: "ask")
    public static let decision = MemorySource(rawValue: "decision")
    public static let handoff = MemorySource(rawValue: "handoff")
    public static let retro = MemorySource(rawValue: "retro")
    public static let kb = MemorySource(rawValue: "kb")
    public static let resource = MemorySource(rawValue: "resource")
    public static let memory = MemorySource(rawValue: "memory")
}

/// One doc to index (`Store.ingest`). `(companyId, source, sourceId)` identifies it; `ref` is its canonical citation form.
public struct MemoryIngestDoc: Sendable {
    public var companyId: String
    public var source: MemorySource
    public var sourceId: String
    public var ref: String
    public var title: String
    public var body: String
    public var access: AccessClass
    /// A fixed set of agent ids that may read it (e.g. a channel's members when a file was dropped); nil follows `access`.
    public var readerSet: Set<String>?
    /// With an `item` access and a reader set: whoever owns or leases the item later may read it too.
    public var futureHolders: Bool
    public var sensitivity: Sensitivity
    public var restrictions: [Restriction]
    public var provenance: Provenance
    public var tainted: Bool
    public var taintReason: String?
    public var weight: Double
    public var authorId: String?
    public var itemId: String?
    public var createdAt: Date
    /// Company-active seconds after which the doc is no longer returned.
    public var expiresActive: Double?

    public init(companyId: String, source: MemorySource, sourceId: String, ref: String, title: String, body: String,
                access: AccessClass, readerSet: Set<String>? = nil, futureHolders: Bool = false, sensitivity: Sensitivity = .normal,
                restrictions: [Restriction] = [], provenance: Provenance, tainted: Bool = false, taintReason: String? = nil,
                weight: Double = 1, authorId: String? = nil, itemId: String? = nil, createdAt: Date, expiresActive: Double? = nil) {
        self.companyId = companyId; self.source = source; self.sourceId = sourceId; self.ref = ref; self.title = title
        self.body = body; self.access = access; self.readerSet = readerSet; self.futureHolders = futureHolders
        self.sensitivity = sensitivity; self.restrictions = restrictions; self.provenance = provenance; self.tainted = tainted
        self.taintReason = taintReason; self.weight = weight; self.authorId = authorId; self.itemId = itemId
        self.createdAt = createdAt; self.expiresActive = expiresActive
    }
}

/// One search result, already filtered by the access engine. `summary` hits carry no snippet; tainted hits carry neither
/// a snippet nor their own title (`"<ref> (untrusted)"`).
public struct MemoryHit: Equatable, Sendable {
    public var docId: Int64
    public var ref: String
    public var source: MemorySource
    public var title: String
    public var snippet: String?
    public var level: AccessLevel
    public var tainted: Bool
    public var taintReason: String?
    public var authorId: String?
    public var itemId: String?
    public var updatedAt: Date
    public var score: Double
}

/// A doc read by ref (`MemoryIndex.document`): its full text bounded to `MemoryPolicy.readLines`/`readBytes`, or its title
/// only at `summary`.
public struct MemoryDocument: Sendable {
    public var hit: MemoryHit
    public var text: String
    public var truncated: Bool
}

/// How a doc was read, recorded in `memoryRead` (purge reports who read what).
public enum MemoryReadVia: String, Codable, Sendable {
    case search, recall
    case kbRead = "kb_read"
}

/// Ref forms and the source each implies.
enum MemoryRefs {
    /// 4a's source; ML only names it so `AR-<n>` resolves to artifacts once 4a indexes them.
    static let artifactSource = MemorySource(rawValue: "artifact")

    /// Canonicalizes `ref` and names the source its form implies (nil: no known form):
    /// `ask:<n>`/`A-<n>` → ask `A-<n>`; `AR-<n>` → artifact; `F-<n>` → resource; `mem:<n>` → memory; `kb:` → kb;
    /// `msg:` → message; `handoff:` → handoff; `sprint:` → retro; `decision:` → decision; `item:<KEY>` and any other
    /// `<KEY>-<n>` → item. An item whose key prefix is `A`, `AR` or `F` is cited and recalled as `item:<KEY>`.
    static func implied(_ ref: String) -> (source: MemorySource?, canonical: String) {
        let raw = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        func rest(_ prefix: String) -> String { String(raw.dropFirst(prefix.count)) }
        if lower.hasPrefix("ask:") {
            let n = rest("ask:")
            return (.ask, isNumber(n) ? "A-\(n)" : raw)
        }
        if lower.hasPrefix("mem:") { return (.memory, "mem:" + rest("mem:")) }
        if lower.hasPrefix("kb:") { return (.kb, "kb:" + rest("kb:")) }
        if lower.hasPrefix("msg:") { return (.message, "msg:" + rest("msg:")) }
        if lower.hasPrefix("handoff:") { return (.handoff, "handoff:" + rest("handoff:")) }
        if lower.hasPrefix("sprint:") { return (.retro, "sprint:" + rest("sprint:")) }
        if lower.hasPrefix("decision:") { return (.decision, "decision:" + rest("decision:")) }
        if lower.hasPrefix("item:") {
            let key = rest("item:")
            return (.item, itemKey(key) ?? key.uppercased())
        }
        if let key = itemKey(raw) {
            let prefix = key.prefix { $0 != "-" }
            switch prefix {
            case "A": return (.ask, key)
            case "AR": return (artifactSource, key)
            case "F": return (.resource, key)
            default: return (.item, key)
            }
        }
        return (nil, raw)
    }

    /// `<KEY>-<n>` uppercased, or nil.
    private static func itemKey(_ s: String) -> String? {
        guard let dash = s.lastIndex(of: "-") else { return nil }
        let prefix = s[..<dash], number = s[s.index(after: dash)...]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), isNumber(number) else { return nil }
        return s.uppercased()
    }

    private static func isNumber<S: StringProtocol>(_ s: S) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
}
