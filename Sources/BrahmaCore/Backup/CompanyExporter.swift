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
    /// Archive databases left out because they could not be copied consistently or failed their integrity check, each
    /// `<path in the export>: <why>`. The rest of the export is complete.
    public var skipped: [String] = []
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

    /// Trees copied from the company's data directory (`<home>/companies/<companyId>/`). The company's transcripts
    /// (`<home>/transcripts/<companyId>/`) and archive (`<home>/archive/<slug>/`) are copied beside them, under the same names.
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

        // Files, roles, manifest. Every source is read by descriptor from the resolved data home (`HomeFiles`): a link anywhere
        // on the way, or inside a tree, is never followed.
        var copied: [String] = []
        var skipped: [String] = []
        let home = try HomeFiles.root(paths.home, create: false)
        func source(_ parts: [String]) -> HomeFiles.Directory? { try? HomeFiles.walk(home, parts, create: false) }
        for tree in copiedTrees {
            guard let dir = source(["companies", company.id, tree]) else { continue }
            try copyTree(from: dir, to: staging.appending(path: tree, directoryHint: .isDirectory), relative: tree,
                         sqlite: false, tmpDir: paths.tmpDir, skipped: &skipped)
            copied.append(tree)
        }
        // Task 13a: the captured work record (already redacted when captured) and the company archive. The archive holds live
        // SQLite files (Memory-lite writes them, in WAL mode): each is exported from a private, descriptor-made copy as one
        // consistent `VACUUM INTO` that passes `integrity_check` (`HomeSnapshot.sqliteCopy`); one that cannot be is skipped and
        // named in `skipped`, and the export goes on.
        let homeTrees: [(name: String, parts: [String])] = [
            ("transcripts", ["transcripts", company.id]),
            ("archive", ["archive", company.slug]),
        ]
        for tree in homeTrees {
            guard let dir = source(tree.parts) else { continue }
            let to = tree.parts.joined(separator: "/")
            try copyTree(from: dir, to: staging.appending(path: to, directoryHint: .isDirectory), relative: to,
                         sqlite: tree.name == "archive", tmpDir: paths.tmpDir, skipped: &skipped)
            copied.append(tree.name)
        }
        // Plan ML: the handbook as Markdown (the owner's view, redacted). Secrets that cannot be loaded leave it out, named in
        // `skipped`; the rest of the export goes on.
        do {
            try HandbookExporter.export(store: store, companyId: company.id, to: staging.appending(path: "handbook", directoryHint: .isDirectory),
                                        force: true)
            copied.append("handbook")
        } catch {
            // A partial `handbook/` never travels: when it cannot be removed, the export fails.
            do {
                let partial = staging.appending(path: "handbook", directoryHint: .isDirectory)
                if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            } catch let cleanup {
                throw ExportError.failed("the handbook export failed (\(error)) and its partial folder could not be removed: \(cleanup)")
            }
            skipped.append("handbook: \(error)")
        }
        // Plan ML Task 6c: the company's resources.
        if try exportResources(store: store, paths: paths, company: company,
                               to: staging.appending(path: "resources", directoryHint: .isDirectory), skipped: &skipped) {
            copied.append("resources")
        }
        let manifest = staging.appending(path: "MANIFEST.json")
        if let companyDir = source(["companies", company.id]), HomeFiles.status(companyDir, "MANIFEST.json").map({ $0.st_mode & S_IFMT == S_IFREG }) == true {
            let input = try HomeFiles.openRead(companyDir, "MANIFEST.json", copySource: true)
            defer { close(input) }
            try HomeSnapshot.copyFile(from: input, to: manifest)
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
                                bundle: bundleName.map { destination.appending(path: $0) }, copied: copied, skipped: skipped)
        }
        return ExportResult(directory: destination, database: destination.appending(path: "brahma.sqlite"),
                            bundle: bundleName.map { destination.appending(path: $0) }, copied: copied, skipped: skipped)
    }

    /// `resources/`: every live file's vault bytes as `F-<n>.<ext>` (read through `ContentVault.read`, so verified against the
    /// hash recorded when it was added; one that fails is left out and named in `skipped`), and `resources.json` with every
    /// row's metadata, purged rows as tombstones (no file). Files and the JSON are 0600. False when the company has no
    /// resources (nothing is written).
    static func exportResources(store: Store, paths: BrahmaPaths, company: Company, to dir: URL,
                                skipped: inout [String]) throws -> Bool {
        let rows = try store.resources(companyId: company.id, reader: .owner, includePurged: true)
        guard !rows.isEmpty else { return false }
        try BrahmaPaths.ensurePrivateDirectory(dir)
        let vault = ContentVault(paths: paths)
        let refs = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.ref) })
        let iso = ISO8601DateFormatter()
        func write(_ data: Data, _ name: String) throws {
            guard FileManager.default.createFile(atPath: dir.appending(path: name).path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw ExportError.failed("could not write resources/\(name) in the export")
            }
        }
        var entries: [[String: Any]] = []
        for r in rows {
            var e: [String: Any] = [
                "ref": r.ref, "number": r.number, "kind": r.kind.rawValue, "name": r.displayName, "bytes": r.bytes,
                "scope": r.scopeId.map { "\(r.scopeKind):\($0)" } ?? r.scopeKind, "futureHolders": r.futureHolders,
                "provenance": r.provenance, "tainted": r.tainted, "secretScan": r.secretScan.rawValue, "addedVia": r.addedVia,
                "createdAt": iso.string(from: r.createdAt),
            ]
            if let parent = r.parentId { e["parent"] = refs[parent] ?? parent }
            if let ext = r.ext { e["ext"] = ext }
            if let kind = r.fileKind { e["fileKind"] = kind }
            if let sha = r.sha256 { e["sha256"] = sha }
            if let url = r.url { e["url"] = url }
            if let readers = r.readerSet { e["readerSet"] = readers.sorted() }
            if let reason = r.taintReason { e["taintReason"] = reason }
            if let vouched = r.vouchedAt { e["vouchedAt"] = iso.string(from: vouched) }
            if let purged = r.purgedAt { e["purgedAt"] = iso.string(from: purged) }
            if let report = r.purgeReport {
                // As stored when it does not parse (the engine writes it; the text is kept either way).
                e["purgeReport"] = (try? JSONSerialization.jsonObject(with: Data(report.utf8))) ?? report
            }
            if r.kind == .file, r.purgedAt == nil, let path = r.vaultPath, let sha = r.sha256 {
                let name = (path as NSString).lastPathComponent
                do {
                    let data = try vault.read(companyId: company.id, relativePath: path, expectedSHA256: sha, maxBytes: r.bytes)
                    try write(data, name)
                    e["file"] = "resources/\(name)"
                } catch let error as ResourceError {
                    skipped.append("resources/\(name): \(error.message); left out")
                }
            }
            entries.append(e)
        }
        try write(try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]), "resources.json")
        return true
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

    /// SQLite sidecars: their content is inside the copy of the database they belong to.
    static let sqliteSidecarSuffixes = [".sqlite-wal", ".sqlite-shm", ".sqlite-journal"]

    /// Copies the regular files and directories of a tree held open by a descriptor walk: subdirectories are opened with
    /// `O_NOFOLLOW` (`child`), files read with `HomeFiles.openRead(copySource:)`; links, worktrees and caches are left out,
    /// and a file with another hard link or of another user is left out and named in `skipped` (S7). With `sqlite`, a
    /// `*.sqlite` file goes through `HomeSnapshot.sqliteCopy` (a private copy, then `VACUUM INTO` and `integrity_check`; one
    /// that fails is listed in `skipped` and left out) and its sidecars are not copied.
    static func copyTree(from source: HomeFiles.Directory, to destination: URL, relative: String, sqlite: Bool, tmpDir: URL,
                         skipped: inout [String], depth: Int = 0) throws {
        try BrahmaPaths.ensurePrivateDirectory(destination)
        guard depth < HomeSnapshot.maxDepth else { return }
        for name in try source.names().sorted() where !skippedNames.contains(name) {
            guard let st = HomeFiles.status(source, name) else { continue }
            let to = destination.appending(path: name), path = relative + "/" + name
            let folded = HomeSnapshot.fold(name)
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                guard let child = try? source.child(name) else { continue }
                try copyTree(from: child, to: to, relative: path, sqlite: sqlite, tmpDir: tmpDir, skipped: &skipped, depth: depth + 1)
            case S_IFREG where sqlite && sqliteSidecarSuffixes.contains(where: { folded.hasSuffix($0) }):
                continue
            case S_IFREG where EngineFiles.copyProblem(st) != nil:
                // S7: another hard link (perhaps an owner file linked in) or another user's file is never copied out.
                skipped.append("\(path): \(EngineFiles.copyProblem(st) ?? ""); left out")
            case S_IFREG where sqlite && folded.hasSuffix(".sqlite"):
                do { try HomeSnapshot.sqliteCopy(in: source, name, relative: path, expected: st, tmpDir: tmpDir, to: to) } catch {
                    unlink(to.path)
                    skipped.append("\(path): \(error)")
                }
            case S_IFREG:
                let input = try HomeFiles.openRead(source, name, copySource: true)
                defer { close(input) }
                try HomeSnapshot.copyFile(from: input, to: to)
            default:
                continue
            }
        }
    }
}
