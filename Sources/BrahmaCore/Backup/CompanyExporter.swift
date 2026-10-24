import Foundation
import GRDB

public enum ExportError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case destinationExists(String)
    case failed(String)
    public var description: String {
        switch self {
        case .destinationExists(let path): "\(path) already exists; export into a new directory"
        case .failed(let text): text
        }
    }
    public var errorDescription: String? { description }
}

public struct ExportResult: Equatable, Sendable {
    public let directory: URL
    public let database: URL
    public let bundle: URL?
    public let copied: [String]
}

/// A self-contained copy of one company: its rows only, its repository as a bundle, and its files and roles.
public enum CompanyExporter {
    /// Tables that do not belong to one company and are emptied in an export. Later tasks append their tables here (the export
    /// skips a name that does not exist yet): `sandboxCanary` (Task 1b), `engineStop` (7c), `pushLog` (7b).
    /// `rateLimit` is `usageState` in 3a's schema. `turnCredential` holds the hashed MCP tokens of turns, which are meaningless
    /// outside this machine and must not travel. `restoreEvent` (and, by cascade, `restoreMain`) is this machine's restore record.
    nonisolated(unsafe) public static var globalTables = [
        "rateLimit", "usageState", "engineProbe", "engineHold", "turnCredential",
        "sandboxCanary", "engineStop", "pushLog", "restoreEvent",
    ]

    /// Trees copied from the company's data directory (`<home>/companies/<companyId>/`). Task 13a appends the transcript and
    /// archive trees.
    nonisolated(unsafe) public static var copiedTrees = ["files", "roles"]

    /// Directory names never copied: worktrees, build output and caches.
    static let skippedNames: Set<String> = [".brahma", ".git", "wt", "worktrees", ".cache", "cache", "node_modules", ".build",
                                            "check-output", "__pycache__", ".DS_Store"]

    /// Builds the export in a staging directory under `<home>/tmp`, then moves it to `destination` (which must not exist).
    /// `bundle` produces the company's `repo.bundle`; it runs git, so the caller runs this inside a `Blocking` body.
    public static func export(store: Store, paths: BrahmaPaths, company: Company, to destination: URL,
                              includeWorkspace: Bool = true, now: Date = Date()) throws -> ExportResult {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw ExportError.destinationExists(destination.path) }
        try paths.ensureTmpDir()
        let staging = paths.tmpDir.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try BrahmaPaths.ensurePrivateDirectory(staging)
        defer { try? fm.removeItem(at: staging) }

        // Database subset.
        let dbFile = staging.appending(path: "brahma.sqlite")
        try store.writer.writeWithoutTransaction { db in try db.execute(sql: "VACUUM INTO ?", arguments: [dbFile.path]) }
        chmod(dbFile.path, 0o600)
        try subset(dbFile, companyId: company.id)

        // Repository.
        var bundleName: String?
        if includeWorkspace {
            let git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
            let bundle = staging.appending(path: "repo.bundle")
            if try git.createBundle(at: bundle) {
                chmod(bundle.path, 0o600)
                try git.verifyBundle(at: bundle)
                bundleName = "repo.bundle"
            }
        }

        // Files, roles, manifest.
        let companyDir = paths.companyDir(company.id)
        var copied: [String] = []
        for tree in copiedTrees {
            let source = companyDir.appending(path: tree, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue,
                  !isLink(source) else { continue }
            try copyTree(from: source, to: staging.appending(path: tree, directoryHint: .isDirectory))
            copied.append(tree)
        }
        let manifest = staging.appending(path: "MANIFEST.json")
        let sourceManifest = companyDir.appending(path: "MANIFEST.json")
        if fm.fileExists(atPath: sourceManifest.path), !isLink(sourceManifest) {
            try fm.copyItem(at: sourceManifest, to: manifest)
        } else {
            var body: [String: Any] = [
                "format": 1,
                "company": ["id": company.id, "name": company.name, "slug": company.slug],
                "exportedAt": ISO8601DateFormatter().string(from: now),
                "database": "brahma.sqlite", "trees": copied,
            ]
            if let bundleName { body["repo"] = bundleName }
            try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
        }
        chmod(manifest.path, 0o600)

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard rename(staging.path, destination.path) == 0 else {
            // Another volume: copy, then the staging directory is removed by the deferred cleanup.
            try fm.copyItem(at: staging, to: destination)
            return ExportResult(directory: destination, database: destination.appending(path: "brahma.sqlite"),
                                bundle: bundleName.map { destination.appending(path: $0) }, copied: copied)
        }
        return ExportResult(directory: destination, database: destination.appending(path: "brahma.sqlite"),
                            bundle: bundleName.map { destination.appending(path: $0) }, copied: copied)
    }

    /// Reduces a copy of the database to one company.
    static func subset(_ file: URL, companyId: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(path: file.path, configuration: config)
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: "DELETE FROM company WHERE id <> ?", arguments: [companyId])
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            for table in tables where table != "company" {
                let hasCompany = try Int.fetchOne(db, sql: "SELECT count(*) FROM pragma_table_info(?) WHERE name = 'companyId'",
                                                  arguments: [table]) ?? 0
                guard hasCompany > 0 else { continue }
                try db.execute(sql: "DELETE FROM \(quote(table)) WHERE companyId IS NULL OR companyId <> ?", arguments: [companyId])
            }
            for table in globalTables where tables.contains(table) {
                try db.execute(sql: "DELETE FROM \(quote(table))")
            }
        }
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try BackupService.rebuildSearchIndexes(db, check: true)
        }
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    private static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private static func isLink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
    }

    /// Copies regular files and directories; links, worktrees and caches are left out.
    static func copyTree(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try BrahmaPaths.ensurePrivateDirectory(destination)
        for name in try fm.contentsOfDirectory(atPath: source.path).sorted() where !skippedNames.contains(name) {
            let from = source.appending(path: name), to = destination.appending(path: name)
            var st = stat()
            guard lstat(from.path, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: try copyTree(from: from, to: to)
            case S_IFREG:
                try fm.copyItem(at: from, to: to)
                chmod(to.path, 0o600)
            default: continue
            }
        }
    }
}
