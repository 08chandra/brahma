import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The fixed rules for what an owner can drop as a resource (file caps live in `ArtifactPolicy`).
public enum ResourcePolicy {
    /// Extensions refused as executables (or installers, scripts that run on open, and code bundles).
    public static let refusedExt: Set<String> = [
        "app", "pkg", "dmg", "exe", "msi", "dylib", "so", "bundle", "kext", "command", "tool", "workflow", "scpt",
        "applescript", "jar", "apk", "ipa", "deb", "rpm",
    ]
    /// Executable magic in a file's first bytes: Mach-O (both widths, both byte orders), fat Mach-O, ELF and PE.
    public static let executableMagic: [[UInt8]] = [
        [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],
        [0xCA, 0xFE, 0xBA, 0xBE], [0x7F, 0x45, 0x4C, 0x46], [0x4D, 0x5A],
    ]
    /// Archives other than zip: refused ("only .zip archives can be added").
    public static let otherArchives: Set<String> = ["tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]

    public static let maxArchiveUncompressed = 209_715_200
    public static let maxArchiveRatio = 100
    public static let maxArchiveEntries = 10_000
    /// How many directory levels below a dropped folder are walked.
    public static let maxDepth = 12

    /// md, txt and csv files over this size are treated as untrusted (`DropTrust`).
    public static let largeTextBytes = 65_536
    /// Text kinds up to this size are indexed (the first 200 000 chars).
    public static let indexBytes = 2_097_152
    /// The one text file that can be stored as a secret instead of a resource.
    public static let secretFileBytes = 65_536
    /// The longest link that can be added.
    public static let maxURL = 2048

    /// Extensions whose drops default to EXTERNAL (document types that commonly carry outside text).
    public static let docTypeTainted: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "html", "htm", "svg", "eml", "msg", "rtf",
        "zip",
    ]

    /// Whether the first bytes of a file are executable magic.
    public static func isExecutable(head: Data) -> Bool {
        let h = Array(head.prefix(4))
        return executableMagic.contains { h.count >= $0.count && Array(h[0..<$0.count]) == $0 }
    }
}

/// Why a resource operation was refused. `message` is the text the owner sees.
public enum ResourceError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)
    case forbidden(String)
    case conflict(String)
    case notFound(String)
    /// The file on disk is not the one that was inspected.
    case changed(String)
    /// The vault copy no longer matches its recorded hash.
    case integrity(String)

    public var message: String {
        switch self {
        case .invalid(let m), .forbidden(let m), .conflict(let m), .notFound(let m), .changed(let m), .integrity(let m): m
        }
    }

    public var description: String { message }
}

/// Which file an inspected drop was: device, inode, size and modification time, read from the open descriptor. 6b's vault
/// copy requires the same identity before it copies a byte (the drop TOCTOU).
public struct FileIdentity: Equatable, Sendable {
    public var dev: UInt64
    public var ino: UInt64
    public var size: Int64
    public var mtimeNs: Int64

    public init(dev: UInt64, ino: UInt64, size: Int64, mtimeNs: Int64) {
        self.dev = dev; self.ino = ino; self.size = size; self.mtimeNs = mtimeNs
    }

    public init(_ st: stat) {
        dev = UInt64(truncatingIfNeeded: st.st_dev)
        ino = UInt64(truncatingIfNeeded: st.st_ino)
        size = Int64(st.st_size)
        #if canImport(Darwin)
        mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        #else
        mtimeNs = Int64(st.st_mtim.tv_sec) * 1_000_000_000 + Int64(st.st_mtim.tv_nsec)
        #endif
    }

    /// The same file (device and inode), whatever its size or time.
    func sameFile(_ st: stat) -> Bool {
        dev == UInt64(truncatingIfNeeded: st.st_dev) && ino == UInt64(truncatingIfNeeded: st.st_ino)
    }
}

/// One file of a drop that passed every check, ready for 6b to copy into the vault.
public struct DropItem: Equatable, Sendable {
    /// The directory the dropped path sits in, and its identity when the drop was inspected.
    public var root: URL
    public var rootIdentity: FileIdentity
    /// The path from `root` as it is on disk (raw names, `/`-separated): the dropped name, plus the path inside a folder.
    public var relativePath: String
    public var identity: FileIdentity
    /// The file's own name, sanitized (`ResourceIntake.sanitizeName`).
    public var displayName: String
    /// The lowercased extension (`ArtifactKind.ext(of:)`).
    public var ext: String
    /// An `ArtifactKind` raw value, or `"archive"` for a zip.
    public var fileKind: String
    public var bytes: Int64
    public var isText: Bool
    public var provenance: Provenance
    public var tainted: Bool
    public var taintReason: String?
    public var quarantined: Bool
    public var findings: [ScanFinding]

    public init(root: URL, rootIdentity: FileIdentity, relativePath: String, identity: FileIdentity, displayName: String,
                ext: String, fileKind: String, bytes: Int64, isText: Bool, provenance: Provenance, tainted: Bool,
                taintReason: String?, quarantined: Bool, findings: [ScanFinding]) {
        self.root = root; self.rootIdentity = rootIdentity; self.relativePath = relativePath; self.identity = identity
        self.displayName = displayName; self.ext = ext; self.fileKind = fileKind; self.bytes = bytes; self.isText = isText
        self.provenance = provenance; self.tainted = tainted; self.taintReason = taintReason; self.quarantined = quarantined
        self.findings = findings
    }
}

/// What a drop would add: the files that passed, what was refused (with the owner-facing reason) and what was skipped.
public struct DropPlan: Equatable, Sendable {
    public var items: [DropItem]
    /// The sanitized folder name when the drop is exactly one folder.
    public var folderName: String?
    /// The refused paths (sanitized, relative to the drop) and why.
    public var refusals: [(name: String, reason: String)]
    /// Paths left out without a refusal: links inside a folder, `.git`, directories deeper than `ResourcePolicy.maxDepth`,
    /// and anything that is not a file or directory. `.DS_Store` is left out silently.
    public var skipped: [String]
    public var totalBytes: Int64
    public var hasKnownValueFinding: Bool
    public var hasPatternFinding: Bool

    public init(items: [DropItem] = [], folderName: String? = nil, refusals: [(name: String, reason: String)] = [],
                skipped: [String] = [], totalBytes: Int64 = 0, hasKnownValueFinding: Bool = false, hasPatternFinding: Bool = false) {
        self.items = items; self.folderName = folderName; self.refusals = refusals; self.skipped = skipped
        self.totalBytes = totalBytes; self.hasKnownValueFinding = hasKnownValueFinding; self.hasPatternFinding = hasPatternFinding
    }

    public static func == (a: DropPlan, b: DropPlan) -> Bool {
        a.items == b.items && a.folderName == b.folderName && a.skipped == b.skipped && a.totalBytes == b.totalBytes
            && a.hasKnownValueFinding == b.hasKnownValueFinding && a.hasPatternFinding == b.hasPatternFinding
            && a.refusals.count == b.refusals.count
            && zip(a.refusals, b.refusals).allSatisfy { $0.name == $1.name && $0.reason == $1.reason }
    }
}

// MARK: Resources (Task 6b)

/// What a `resource` row is: a vault-stored file, a dropped folder (its files are its `parentId` children) or a link (never
/// fetched).
public enum ResourceKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case file, folder, link
}

/// What the drop's secret scan came to: nothing found (`none`), a redacted copy was stored (`redacted`), or the owner chose to
/// upload a file with secret findings as is (`flagged`: never indexed, mirrored or read by agents).
public enum SecretScanState: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case none, redacted, flagged
}

/// One owner resource, shown as `F-<number>`. A folder row owns its children's scope, reader set, future holders, trust and
/// purge: every mutation applies to the folder and its `parentId` children in one transaction. Every query is bound to one
/// company (`companyId = ?`).
public struct Resource: Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "resource"

    public var id: String
    public var companyId: String
    /// Per company, from 1.
    public var number: Int
    public var kind: ResourceKind
    /// The folder a dropped folder's file belongs to.
    public var parentId: String?
    /// Sanitized (`ResourceIntake.sanitizeName`); never used as a file name.
    public var displayName: String
    public var ext: String?
    /// An `ArtifactKind` raw value or `"archive"`; nil for folders and links.
    public var fileKind: String?
    public var bytes: Int64
    /// Of the stored bytes (the redacted copy when `secretScan == .redacted`), verified on every read.
    public var sha256: String?
    /// Relative to `<home>/vault/<companyId>`: `resources/F-<n>.<ext>`.
    public var vaultPath: String?
    /// Relative to the workspace: `.brahma/resources/company/F-<n>.<ext>`, when mirrored.
    public var mirrorPath: String?
    public var mirrorSha256: String?
    public var url: String?
    public var scopeKind: String
    public var scopeId: String?
    /// A fixed set of agent ids that may read it; nil follows the scope (team and company).
    public var readerSet: Set<String>?
    /// With an item scope: whoever owns or leases the item later may read it too.
    public var futureHolders: Bool
    /// `Provenance.raw`.
    public var provenance: String
    /// The sanitized original file name only, never a path.
    public var sourceDetail: String?
    public var tainted: Bool
    public var taintReason: String?
    public var quarantined: Bool
    public var secretScan: SecretScanState
    public var vouchedAt: Date?
    /// The drop context: `library`, `dm`, `channel`, `inbox`, `item`, `cli` or (Plan C) `thread`.
    public var addedVia: String
    public var channelId: String?
    public var messageId: String?
    public var askId: String?
    public var itemId: String?
    /// Its text is in the memory index (a text kind up to `ResourcePolicy.indexBytes`, not flagged).
    public var textIndexed: Bool
    public var purgedAt: Date?
    /// JSON `{backups:[], transcripts:[]}` (Task 6c).
    public var purgeReport: String?
    public var removedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, companyId: String, number: Int, kind: ResourceKind, parentId: String? = nil,
                displayName: String, ext: String? = nil, fileKind: String? = nil, bytes: Int64 = 0, sha256: String? = nil,
                vaultPath: String? = nil, mirrorPath: String? = nil, mirrorSha256: String? = nil, url: String? = nil,
                scopeKind: String, scopeId: String?, readerSet: Set<String>?, futureHolders: Bool = false, provenance: String,
                sourceDetail: String? = nil, tainted: Bool, taintReason: String? = nil, quarantined: Bool = false,
                secretScan: SecretScanState = .none, vouchedAt: Date? = nil, addedVia: String, channelId: String? = nil,
                messageId: String? = nil, askId: String? = nil, itemId: String? = nil, textIndexed: Bool = false,
                purgedAt: Date? = nil, purgeReport: String? = nil, removedAt: Date? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id; self.companyId = companyId; self.number = number; self.kind = kind; self.parentId = parentId
        self.displayName = displayName; self.ext = ext; self.fileKind = fileKind; self.bytes = bytes; self.sha256 = sha256
        self.vaultPath = vaultPath; self.mirrorPath = mirrorPath; self.mirrorSha256 = mirrorSha256; self.url = url
        self.scopeKind = scopeKind; self.scopeId = scopeId; self.readerSet = readerSet; self.futureHolders = futureHolders
        self.provenance = provenance; self.sourceDetail = sourceDetail; self.tainted = tainted; self.taintReason = taintReason
        self.quarantined = quarantined; self.secretScan = secretScan; self.vouchedAt = vouchedAt; self.addedVia = addedVia
        self.channelId = channelId; self.messageId = messageId; self.askId = askId; self.itemId = itemId
        self.textIndexed = textIndexed; self.purgedAt = purgedAt; self.purgeReport = purgeReport; self.removedAt = removedAt
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public var ref: String { "F-\(number)" }

    /// The access class; a stored scope that does not parse is owner-only (fail closed: no agent reads it).
    public var scope: AccessClass { AccessClass(kind: scopeKind, id: scopeId) ?? .ownerOnly }

    public init(row: Row) throws {
        id = row["id"]; companyId = row["companyId"]; number = row["number"]
        guard let kind = ResourceKind(rawValue: row["kind"]) else {
            throw ResourceError.invalid("resource \(row["id"] as String? ?? "?") has an unknown kind")
        }
        self.kind = kind
        parentId = row["parentId"]; displayName = row["displayName"]; ext = row["ext"]; fileKind = row["fileKind"]
        bytes = row["bytes"]; sha256 = row["sha256"]; vaultPath = row["vaultPath"]; mirrorPath = row["mirrorPath"]
        mirrorSha256 = row["mirrorSha256"]; url = row["url"]; scopeKind = row["scopeKind"]; scopeId = row["scopeId"]
        if let raw: String = row["readerSet"] {
            // A reader set that does not parse reads as empty: nobody (fail closed).
            readerSet = Set((try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? [])
        } else {
            readerSet = nil
        }
        futureHolders = row["futureHolders"]; provenance = row["provenance"]; sourceDetail = row["sourceDetail"]
        tainted = row["tainted"]; taintReason = row["taintReason"]; quarantined = row["quarantined"]
        // An unknown scan state reads as flagged: never shown to agents.
        secretScan = SecretScanState(rawValue: row["secretScan"]) ?? .flagged
        vouchedAt = row["vouchedAt"]; addedVia = row["addedVia"]; channelId = row["channelId"]; messageId = row["messageId"]
        askId = row["askId"]; itemId = row["itemId"]; textIndexed = row["textIndexed"]; purgedAt = row["purgedAt"]
        purgeReport = row["purgeReport"]; removedAt = row["removedAt"]; createdAt = row["createdAt"]; updatedAt = row["updatedAt"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id; container["companyId"] = companyId; container["number"] = number; container["kind"] = kind
        container["parentId"] = parentId; container["displayName"] = displayName; container["ext"] = ext
        container["fileKind"] = fileKind; container["bytes"] = bytes; container["sha256"] = sha256
        container["vaultPath"] = vaultPath; container["mirrorPath"] = mirrorPath; container["mirrorSha256"] = mirrorSha256
        container["url"] = url; container["scopeKind"] = scopeKind; container["scopeId"] = scopeId
        container["readerSet"] = try readerSet.map { set in
            String(decoding: try JSONEncoder().encode(set.sorted()), as: UTF8.self)
        }
        container["futureHolders"] = futureHolders; container["provenance"] = provenance; container["sourceDetail"] = sourceDetail
        container["tainted"] = tainted; container["taintReason"] = taintReason; container["quarantined"] = quarantined
        container["secretScan"] = secretScan; container["vouchedAt"] = vouchedAt; container["addedVia"] = addedVia
        container["channelId"] = channelId; container["messageId"] = messageId; container["askId"] = askId
        container["itemId"] = itemId; container["textIndexed"] = textIndexed; container["purgedAt"] = purgedAt
        container["purgeReport"] = purgeReport; container["removedAt"] = removedAt; container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }
}

/// What a purge could not reach (Task 6c, ML-7): the DB and data-home snapshots taken since the resource was added (by name),
/// and the turns whose captured transcripts recorded reading it (by turn id). Stored on the tombstone as `purgeReport`.
public struct PurgeReport: Codable, Equatable, Sendable {
    public var backups: [String]
    /// Turn ids.
    public var transcripts: [String]

    public init(backups: [String] = [], transcripts: [String] = []) { self.backups = backups; self.transcripts = transcripts }
}

/// Where the owner dropped: the Resources library, a DM with an agent (by handle), a channel (by name), an agent's question in
/// the Inbox, an item card, or the CLI. Collab adds `.thread(rootId:)`.
public enum DropContext: Equatable, Sendable {
    case library
    case dm(handle: String)
    case channel(name: String)
    case inbox(askId: String)
    case item(id: String)
    case cli
    /// Plan C Task C5: a reply in the thread of `rootId` (`msg:<id>` or the bare id; a reply's id joins its root), in a channel
    /// or in the owner's DM with an agent. Its default scope is that conversation's agent members at drop time, like
    /// `.channel` (a DM: `.dm(handle:)`'s), and its announcement is posted as a reply in that thread.
    case thread(rootId: String)

    /// The stored `resource.addedVia`.
    public var via: String {
        switch self {
        case .library: "library"
        case .dm: "dm"
        case .channel: "channel"
        case .inbox: "inbox"
        case .item: "item"
        case .cli: "cli"
        case .thread: "thread"
        }
    }
}

/// The trust chip: the detected default (`DropTrust`), marked untrusted, or vouched for by the owner.
public enum TrustChoice: Equatable, Sendable {
    case asDetected, untrusted, vouched
}

/// What the owner chose on the secret sheet. `.none` is only allowed for a drop without findings.
public enum SecretChoice: Equatable, Sendable {
    case none
    case uploadRedacted
    case uploadAnyway
    case storeAsSecret(name: String)
}

/// The owner's choices for one drop (`Store.addResources`, `Store.addLink`).
public struct ResourceDrop: Equatable, Sendable {
    public var context: DropContext
    public var scope: AccessClass
    /// The fixed reader set (`Store.defaultScope`); agent and item scopes get theirs from `Store.readerSet(for:)` when nil.
    public var readerSet: Set<String>?
    public var futureHolders: Bool
    public var trust: TrustChoice
    public var secretChoice: SecretChoice
    /// The owner's own words, sent above the engine's announcement lines.
    public var message: String?

    public init(context: DropContext = .library, scope: AccessClass = .company, readerSet: Set<String>? = nil,
                futureHolders: Bool = false, trust: TrustChoice = .asDetected, secretChoice: SecretChoice = .none,
                message: String? = nil) {
        self.context = context; self.scope = scope; self.readerSet = readerSet; self.futureHolders = futureHolders
        self.trust = trust; self.secretChoice = secretChoice; self.message = message
    }
}
