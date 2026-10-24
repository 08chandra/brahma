import Foundation
import GRDB

public enum BackupReason: String, Sendable, CaseIterable, Hashable {
    case hourly
    case preMigration = "pre-migration"
    case manual
    case preRestore = "pre-restore"
}

public enum BackupError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case noDatabase
    /// The snapshot failed `PRAGMA integrity_check`; it was deleted and nothing was pruned.
    case snapshotFailedCheck([String])
    case io(String)

    public var description: String {
        switch self {
        case .noDatabase: "no database to back up"
        case .snapshotFailedCheck(let rows): "the snapshot failed its integrity check (\(rows.prefix(3).joined(separator: "; "))) and was discarded"
        case .io(let text): text
        }
    }
    public var errorDescription: String? { description }
}

/// One DB snapshot on disk.
public struct BackupInfo: Equatable, Sendable {
    public let url: URL
    public let reason: BackupReason
    public let date: Date
    public var name: String { url.lastPathComponent }
}

/// Verified `VACUUM INTO` snapshots of the database, and per-company git bundles.
///
/// Every temporary file lives under `<home>/tmp` (0700 directory, 0600 files), never the system temp directory.
public struct BackupService: Sendable {
    /// Snapshots kept per reason: hourly / pre-migration / manual / pre-restore.
    public static let keep: [BackupReason: Int] = [.hourly: 48, .preMigration: 10, .manual: 20, .preRestore: 5]
    /// Repo bundles kept per company.
    public static let keepBundles = 14

    public let database: URL
    public let home: URL
    public let dbBackups: URL
    public let repoBackups: URL
    public let tmpDir: URL
    var writer: (any DatabaseWriter)?
    /// Test seams.
    var now: @Sendable () -> Date = { Date() }
    var integrityCheck: @Sendable (URL) -> [String] = { BackupService.integrity(of: $0) }
    /// The restore's search-index rebuild and check (step 7 of `restore`).
    var searchRebuild: @Sendable (Database) throws -> Void = { db in try BackupService.rebuildSearchIndexes(db, check: true) }

    public init(paths: BrahmaPaths, writer: (any DatabaseWriter)? = nil) {
        database = paths.database; home = paths.home
        dbBackups = paths.dbBackups; repoBackups = paths.repoBackups; tmpDir = paths.tmpDir
        self.writer = writer
    }

    /// For a store that has only its database path and a backups directory (the pre-migration snapshot).
    init(database: URL, backupsDir: URL, writer: (any DatabaseWriter)?) {
        self.database = database
        home = database.deletingLastPathComponent()
        dbBackups = backupsDir.appending(path: "db", directoryHint: .isDirectory)
        repoBackups = backupsDir.appending(path: "repos", directoryHint: .isDirectory)
        tmpDir = home.appending(path: "tmp", directoryHint: .isDirectory)
        self.writer = writer
    }

    // MARK: Integrity

    /// A connection that cannot write. Not `SQLITE_OPEN_READONLY`: that cannot open a WAL-mode database whose `-wal`/`-shm`
    /// are gone (any cleanly closed live database), which would read as damage. A missing file is an error, never created.
    static func openForReading(_ url: URL) throws -> DatabaseQueue {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.io("\(url.lastPathComponent) does not exist")
        }
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = ON") }
        return try DatabaseQueue(path: url.path, configuration: config)
    }

    /// `PRAGMA integrity_check` on a read-only connection: `["ok"]`, or the problems found (an unreadable file is one row).
    public static func integrity(of url: URL) -> [String] {
        do {
            let queue = try openForReading(url)
            defer { try? queue.close() }
            let rows = try queue.read { db in try String.fetchAll(db, sql: "PRAGMA integrity_check") }
            return rows.isEmpty ? ["no result"] : rows
        } catch {
            return ["\(error)"]
        }
    }

    // MARK: Snapshots

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return f.string(from: date)
    }

    static func parse(name: String) -> (date: Date, reason: BackupReason)? {
        guard name.hasPrefix("brahma-"), name.hasSuffix(".sqlite") else { return nil }
        let core = name.dropFirst("brahma-".count).dropLast(".sqlite".count)
        // <stamp>-<reason>: the stamp has no dash.
        guard let dash = core.firstIndex(of: "-") else { return nil }
        let stamp = String(core[core.startIndex..<dash]), reasonText = String(core[core.index(after: dash)...])
        guard let reason = BackupReason(rawValue: reasonText) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        guard let date = f.date(from: stamp) else { return nil }
        return (date, reason)
    }

    /// Every snapshot, newest first.
    public func list() -> [BackupInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dbBackups.path)) ?? []
        return names.compactMap { name -> BackupInfo? in
            guard let parsed = Self.parse(name: name) else { return nil }
            return BackupInfo(url: dbBackups.appending(path: name), reason: parsed.reason, date: parsed.date)
        }
        .sorted { ($0.date, $0.name) > ($1.date, $1.name) }
    }

    /// 1. `VACUUM INTO` a staging file under `<home>/tmp`; 2. it must pass `integrity(of:)` (a bad one is deleted, nothing is
    /// pruned); 3. it is renamed into `dbBackups`; 4. snapshots of that reason beyond `keep` are pruned.
    @discardableResult
    public func snapshot(reason: BackupReason) throws -> URL {
        guard let writer else { throw BackupError.noDatabase }
        try BrahmaPaths.ensurePrivateDirectory(tmpDir)
        try BrahmaPaths.ensurePrivateDirectory(dbBackups)
        let staging = tmpDir.appending(path: "snapshot-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [staging.path])
        }
        chmod(staging.path, 0o600)
        let problems = integrityCheck(staging)
        guard problems == ["ok"] else { throw BackupError.snapshotFailedCheck(problems) }
        try Self.syncFile(staging)
        let destination = dbBackups.appending(path: "brahma-\(Self.stamp(now()))-\(reason.rawValue).sqlite")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BackupError.io("\(destination.lastPathComponent) already exists")
        }
        guard rename(staging.path, destination.path) == 0 else {
            throw BackupError.io("could not move the snapshot into \(dbBackups.path) (errno \(errno))")
        }
        prune(reason)
        return destination
    }

    func prune(_ reason: BackupReason) {
        let keep = Self.keep[reason] ?? 10
        let mine = list().filter { $0.reason == reason }
        for old in mine.dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
    }

    static func syncFile(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    // MARK: Repo bundles

    public struct BundleResult: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable { case created(URL), unchanged, empty, failed(String) }
        public let companyId: String
        public let outcome: Outcome
    }

    /// For each company: `git bundle create --all` into `repoBackups/<companyId>/<yyyyMMdd>.bundle`, skipped when the
    /// StableHash of the `for-each-ref` output is unchanged since the last bundle; then `bundle verify` (a bundle that does not
    /// verify is deleted and not counted), then prune to `keepBundles`. All of it is `GitCommand` (hardened git), so blocking:
    /// the caller runs it inside a `Blocking` body.
    public func bundleRepos(companies: [Company], workspace: (Company) -> GitWorkspace) -> [BundleResult] {
        companies.map { BundleResult(companyId: $0.id, outcome: bundle(company: $0, git: workspace($0))) }
    }

    private func bundle(company: Company, git: GitWorkspace) -> BundleResult.Outcome {
        do {
            let dir = repoBackups.appending(path: company.id, directoryHint: .isDirectory)
            let digestFile = dir.appending(path: ".refs")
            let digest = StableHash.fnv1a64(try git.refListing())
            let existing = bundles(in: dir)
            if let last = existing.last, !digest.isEmpty,
               (try? String(contentsOf: digestFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == digest,
               FileManager.default.fileExists(atPath: last.path) {
                return .unchanged
            }
            try BrahmaPaths.ensurePrivateDirectory(tmpDir)
            try BrahmaPaths.ensurePrivateDirectory(dir)
            let staging = tmpDir.appending(path: "bundle-\(UUID().uuidString).bundle")
            defer { try? FileManager.default.removeItem(at: staging) }
            guard try git.createBundle(at: staging) else { return .empty }
            chmod(staging.path, 0o600)
            try git.verifyBundle(at: staging)
            try Self.syncFile(staging)
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = TimeZone(identifier: "UTC")
            day.dateFormat = "yyyyMMdd"
            let destination = dir.appending(path: "\(day.string(from: now())).bundle")
            guard rename(staging.path, destination.path) == 0 else {
                throw BackupError.io("could not move the bundle into \(dir.path) (errno \(errno))")
            }
            try Data(digest.utf8).write(to: digestFile, options: .atomic)
            chmod(digestFile.path, 0o600)
            for old in bundles(in: dir).dropLast(Self.keepBundles) { try? FileManager.default.removeItem(at: old) }
            return .created(destination)
        } catch {
            return .failed("\(error)")
        }
    }

    /// The bundles of a company directory, oldest first.
    func bundles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".bundle") }.sorted().map { dir.appending(path: $0) }
    }
}
