import Foundation

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
