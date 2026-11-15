import Foundation
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
