import Foundation
import GRDB

/// One company's storage, measured (Plan ML Task 9). `total` is the company's own: database estimate, workspace, resources,
/// transcripts and archive. `backupBytes` is the whole backups directory, shared by every company.
public struct StorageReport: Equatable, Sendable {
    public var dbBytes: Int64
    public var workspaceBytes: Int64
    public var vaultBytes: Int64
    public var transcriptBytes: Int64
    public var archiveBytes: Int64
    public var backupBytes: Int64
    public var freeBytes: Int64
    public var measuredAt: Date
    /// db + workspace + vault + transcripts + archive.
    public var total: Int64

    public init(dbBytes: Int64, workspaceBytes: Int64, vaultBytes: Int64, transcriptBytes: Int64, archiveBytes: Int64,
                backupBytes: Int64, freeBytes: Int64, measuredAt: Date) {
        self.dbBytes = dbBytes; self.workspaceBytes = workspaceBytes; self.vaultBytes = vaultBytes
        self.transcriptBytes = transcriptBytes; self.archiveBytes = archiveBytes; self.backupBytes = backupBytes
        self.freeBytes = freeBytes; self.measuredAt = measuredAt
        total = dbBytes + workspaceBytes + vaultBytes + transcriptBytes + archiveBytes
    }
}

/// How the meter sizes the disk. Sizes only: an implementation never opens a file.
public protocol FileSizing: Sendable {
    /// The allocated bytes of the tree at `url` (0 when it does not exist). Links are never followed.
    func allocatedSize(of url: URL) throws -> Int64
    /// The free bytes of the volume holding `url`.
    func freeBytes(at url: URL) throws -> Int64
}

/// `FileManager` sizes: `.totalFileAllocatedSizeKey` of every regular file under the root. A symbolic link (the root
/// itself or anything below it) counts nothing and is never descended into, so a link out of a workspace measures nothing
/// of where it points.
public struct LiveFileSizing: FileSizing {
    public init() {}

    public func allocatedSize(of url: URL) throws -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        // The root: a link or a missing path is nothing; a file is its own size.
        guard let attrs = try? fm.attributesOfItem(atPath: url.path), let type = attrs[.type] as? FileAttributeType else { return 0 }
        if type == .typeSymbolicLink { return 0 }
        if type == .typeRegular { return Self.size(try url.resourceValues(forKeys: Set(keys))) }
        guard type == .typeDirectory else { return 0 }
        // A walk of our own, not `FileManager.enumerator`: a link is never descended into, and nothing after it is skipped.
        var total: Int64 = 0
        var pending = [url]
        while let dir = pending.popLast() {
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { continue }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isRegularFile == true {
                    total += Self.size(values)
                } else if values.isDirectory == true {
                    pending.append(child)
                }
            }
        }
        return total
    }

    public func freeBytes(at url: URL) throws -> Int64 {
        // The nearest existing ancestor: a company directory may not exist yet.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: probe.path)
        return (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    private static func size(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}

/// The per-company storage meter (Budget › STORAGE). Plain code, no LLM turn; reads sizes, never contents.
public enum StorageMeter {
    /// The app re-measures a company at most once per this many company-active seconds (Refresh always measures).
    public static let minInterval: TimeInterval = 600

    /// The company's text columns whose bytes estimate its share of the database.
    static let textColumns: [(table: String, column: String)] = [
        ("message", "text"), ("memoryDoc", "title"), ("memoryDoc", "body"), ("kbRevision", "body"), ("workItemEvent", "text"),
        ("turn", "summary"), ("activityEvent", "text"), ("ask", "summary"), ("ask", "payload"),
        // C4a fix round 4: memory's vault-blanked shadow (`MemoryShadow`).
        ("memoryShadow", "title"), ("memoryShadow", "body"),
    ]

    /// Blocking (a walk of the company's directories): call it off the main actor.
    public static func measure(store: Store, paths: BrahmaPaths, company: Company, sizing: any FileSizing, now: Date) throws -> StorageReport {
        let db = try dbBytes(store: store, companyId: company.id)
        let workspace = try sizing.allocatedSize(of: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        let vault = try sizing.allocatedSize(of: paths.vaultDir(companyId: company.id))
        let transcripts = try sizing.allocatedSize(of: paths.transcriptsDir.appending(path: company.id, directoryHint: .isDirectory))
        let archive = try sizing.allocatedSize(of: paths.archiveDir.appending(path: company.slug, directoryHint: .isDirectory))
        let backups = try sizing.allocatedSize(of: paths.backupsDir)
        let free = try sizing.freeBytes(at: paths.home)
        return StorageReport(dbBytes: db, workspaceBytes: workspace, vaultBytes: vault, transcriptBytes: transcripts, archiveBytes: archive,
                             backupBytes: backups, freeBytes: free, measuredAt: now)
    }

    /// Σ `length(CAST(col AS BLOB))` over the company's rows of `textColumns`.
    static func dbBytes(store: Store, companyId: String) throws -> Int64 {
        try store.writer.read { db in
            var total: Int64 = 0
            for (table, column) in textColumns {
                total += try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(CAST(\(column) AS BLOB))), 0) FROM \(table) WHERE companyId = ?",
                                            arguments: [companyId]) ?? 0
            }
            return total
        }
    }
}
