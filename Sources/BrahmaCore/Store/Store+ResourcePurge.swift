import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What `Store.syncResourceMirror` did, by file name in `.brahma/resources/company`.
public struct ResourceMirrorResult: Equatable, Sendable {
    /// Files mirrored that were not mirrored before (after a vouch, a scope change to the company, a wipe).
    public var written: [String] = []
    /// Mirrored files found changed or missing, put back from the vault.
    public var repaired: [String] = []
    /// Entries removed: files of resources no longer mirrored (rescoped, tainted, purged) and files nothing mirrored there.
    public var removed: [String] = []
    /// A link or odd entry found in the mirror: each is alerted, and the whole mirror is wiped.
    public var unsafe: [UnsafeEngineFile] = []

    public init() {}
}

/// Owner resources (Plan ML Task 6c): vouch, scope changes and purge (each covers a folder and its files, in one transaction;
/// a folder's file is refused on its own), the secure purge of memory docs (ML-7), and the repair sweep of the
/// `.brahma/resources` mirror. Owner callers only (the CLI and the app); nothing here is reachable from `CompanyTools`.
extension Store {
    /// The `memoryCursor.source` holding the mirror's verified files: `{name: "<dev:ino:size:mtime:ctime:mode>|<sha256>"}`.
    static let resourceMirrorCursor = "resource-mirror"
    /// The `memoryCursor.source` holding the resource mirror alerts raised since its last clean sweep (one key per line).
    static let resourceMirrorAlertCursor = "resource-mirror-alerts"
    /// The reason that keys the alert about a resource mirror that could not be cleared.
    public static let resourceMirrorAlertReason = "resource-mirror"

    // MARK: Vouch

    /// The owner vouches for `F-<number>` and, for a folder, every file in it: provenance `.owner`, `tainted = false`,
    /// `vouchedAt = now`, and each doc re-indexed untainted (its text kept). A company-scope file is then mirrored
    /// (`syncResourceMirror`). A folder's file → `.invalid("F-<n> is part of folder F-<m>; change the folder")`; a purged one →
    /// `.invalid("F-<n> was purged")`. Returns the folder (or file) first, then its files.
    @discardableResult
    public func vouchResource(companyId: String, number: Int, contentVault: ContentVault, paths: BrahmaPaths,
                              now: Date = Store.now()) throws -> [Resource] {
        guard contentVault.paths == paths else { throw ResourceError.invalid("the vault belongs to another data home") }
        let ids = try writer.write { db -> [String] in
            var rows = try Self.ownerTarget(db: db, companyId: companyId, number: number, allowPurged: false)
            for i in rows.indices {
                rows[i].provenance = Provenance.owner.raw
                rows[i].tainted = false
                rows[i].taintReason = nil
                rows[i].vouchedAt = now
                rows[i].updatedAt = now
                try rows[i].update(db)
            }
            try reindexResources(db: db, rows, now: now)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .resource,
                              text: try redact("You vouched for \(Self.named(rows))"), createdAt: now).insert(db)
            return rows.map(\.id)
        }
        syncResourceMirror(companyId: companyId, contentVault: contentVault, now: now)
        return try resources(companyId: companyId, ids: ids)
    }

    // MARK: Scope

    /// The owner changes who reads `F-<number>` (a folder and every file in it). The reader set follows 6b's rules
    /// (`resolveDrop`, `Store.readerSet(for:)`): agent → exactly that agent; item → its people now (and later holders with
    /// `futureHolders`); a channel or DM → its members now; team, role and company stay dynamic. Every doc's access is
    /// re-indexed, the change is logged, and the mirror follows (`syncResourceMirror`: added for a company scope, removed
    /// otherwise). A folder's file and a purged resource are refused as in `vouchResource`.
    @discardableResult
    public func setResourceScope(companyId: String, number: Int, scope: AccessClass, futureHolders: Bool,
                                 contentVault: ContentVault, paths: BrahmaPaths, now: Date = Store.now()) throws -> [Resource] {
        guard contentVault.paths == paths else { throw ResourceError.invalid("the vault belongs to another data home") }
        let ids = try writer.write { db -> [String] in
            var rows = try Self.ownerTarget(db: db, companyId: companyId, number: number, allowPurged: false)
            let resolved = try resolveDrop(db: db, companyId: companyId,
                                           drop: ResourceDrop(context: .library, scope: scope, futureHolders: futureHolders))
            let from = try Self.scopeLabel(db: db, rows[0].scope, companyId: companyId)
            for i in rows.indices {
                rows[i].scopeKind = resolved.scope.kind
                rows[i].scopeId = resolved.scope.id
                rows[i].readerSet = resolved.readerSet
                rows[i].futureHolders = resolved.futureHolders
                rows[i].updatedAt = now
                try rows[i].update(db)
            }
            try reindexResources(db: db, rows, now: now)
            let to = try Self.scopeLabel(db: db, resolved.scope, companyId: companyId)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .resource,
                              text: try redact("You changed the scope of \(Self.named(rows)) from \(from) to \(to)"),
                              createdAt: now).insert(db)
            return rows.map(\.id)
        }
        syncResourceMirror(companyId: companyId, contentVault: contentVault, now: now)
        return try resources(companyId: companyId, ids: ids)
    }

    /// How a scope reads to the owner (`company`, `team payments`, `agent @eng-1`, `item ENG-4`, `channel #design` …).
    public func resourceScopeLabel(_ scope: AccessClass, companyId: String) throws -> String {
        try writer.read { db in try Self.scopeLabel(db: db, scope, companyId: companyId) }
    }

    // MARK: Purge

    /// The secure purge of memory docs (ML-7), used by resource purge and by the owner's memory delete:
    /// 1. `PRAGMA secure_delete = ON` for the connection (freed pages and cells are zeroed);
    /// 2. in one transaction, every doc's title becomes `"[purged]"`, its body `""`, and `removedAt` is set (the FTS
    ///    trigger removes its terms);
    /// 3. `INSERT INTO memoryFts(memoryFts) VALUES('optimize')`: the segments are merged, dropping the deleted terms;
    /// 4. `PRAGMA wal_checkpoint(TRUNCATE)`: the WAL frames holding the old pages go;
    /// 5. `secure_delete` is restored.
    public func purgeMemoryDocs(companyId: String, source: MemorySource, sourceIds: [String], now: Date) throws {
        try purgeMemoryDocs(companyId: companyId, source: source, sourceIds: sourceIds, now: now) { _ in }
    }

    /// `purgeMemoryDocs`, with `body` run first inside its transaction (under `secure_delete`): the caller's own row changes
    /// (a memory entry's fact, a resource's tombstone) are cleared from the file the same way.
    @discardableResult
    func purgeMemoryDocs<T>(companyId: String, source: MemorySource, sourceIds: [String], now: Date,
                            alsoInTransaction body: (Database) throws -> T) throws -> T {
        let (result, checkpoint) = try writer.writeWithoutTransaction { db -> (T, Row?) in
            let before = try Int.fetchOne(db, sql: "PRAGMA secure_delete") ?? 0
            try db.execute(sql: "PRAGMA secure_delete = ON")
            defer {
                // 2 is FAST (Apple's default build), which only the keyword sets back; any other value is a boolean.
                let restore = before == 2 ? "FAST" : before == 0 ? "OFF" : "ON"
                do { try db.execute(sql: "PRAGMA secure_delete = \(restore)") } catch {
                    FileHandle.standardError.write(Data("brahma: could not restore secure_delete after a purge: \(error)\n".utf8))
                }
            }
            var result: T?
            try db.inTransaction {
                result = try body(db)
                for chunk in stride(from: 0, to: sourceIds.count, by: 500).map({ Array(sourceIds[$0..<min($0 + 500, sourceIds.count)]) }) {
                    var arguments: StatementArguments = [now, now, companyId, source.rawValue]
                    arguments += StatementArguments(chunk)
                    try db.execute(sql: """
                        UPDATE memoryDoc SET title = '[purged]', body = '', removedAt = COALESCE(removedAt, ?), updatedAt = ?
                        WHERE companyId = ? AND source = ? AND sourceId IN (\(chunk.map { _ in "?" }.joined(separator: ", ")))
                        """, arguments: arguments)
                }
                return .commit
            }
            try db.execute(sql: "INSERT INTO memoryFts(memoryFts) VALUES('optimize')")
            let checkpoint = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            guard let result else { throw ResourceError.invalid("the purge did not run") }
            return (result, checkpoint)
        }
        // A reader kept the WAL from being emptied: the old pages stay there until a later checkpoint overwrites them.
        if let busy: Int = checkpoint?[0], busy != 0 {
            resourceTrace(companyId: companyId, "A purge could not empty the database's write-ahead log yet (a reader was using it); "
                          + "purged text may stay in brahma.sqlite-wal until the next checkpoint", now: now)
        }
        return result
    }

    /// The owner purges `F-<number>` and, for a folder, every file in it (ML-7). Its docs go through the secure purge, its
    /// vault bytes and mirror files are removed (`ContentVault.remove`, `EngineFiles.remove`), and the row stays as a
    /// tombstone (`purgedAt`, `purgeReport`; its name stays in old messages: metadata). Nothing brings it back: ingest and the
    /// mirror sweep skip purged rows. Returns what still holds it:
    /// - `backups`: the names in `backups` (DB and data-home snapshots) taken in `[createdAt, now]`;
    /// - `transcripts`, conservatively (over-listing is safe, under-listing is not): the distinct captured turns that read one
    ///   of its docs through Brahma's tools (`memoryRead.turnId`), plus every captured turn of an agent in its reader set
    ///   (any agent the access engine lets read it at all, now) that ran while it existed (`[createdAt, now]`). A turn still
    ///   running at the purge is listed by id too: its transcript is captured when it ends, and is flagged from then on.
    ///   Reads of the mirror or the vault through an agent's shell or the Read tool leave no record, so those transcripts
    ///   *may* contain it.
    ///
    /// Activity: `Purged F-<n> (<k> backups and <t> transcripts made since it was added may still contain it; reads through
    /// an agent's shell or the mirror are not tracked one by one)`. A purge can be run again (it finishes what a failed one
    /// left, and recomputes the report).
    ///
    /// Purge is the owner's remedy for a leak, so one file of a folder can be purged on its own: it becomes a tombstone with
    /// its own report, and the folder's size counts only its live files. A later purge of the folder keeps that report. A
    /// purged link keeps only its ref and kind: its URL (its content), the host and the name shown are blanked.
    public func purgeResource(companyId: String, number: Int, backups: [(name: String, takenAt: Date)],
                              contentVault: ContentVault, paths: BrahmaPaths, now: Date = Store.now()) throws -> PurgeReport {
        guard contentVault.paths == paths else { throw ResourceError.invalid("the vault belongs to another data home") }
        guard let company = try company(id: companyId) else { throw ResourceError.notFound("no such company") }
        let (rows, transcripts) = try writer.read { db -> ([Resource], [String]) in
            let rows = try Self.ownerTarget(db: db, companyId: companyId, number: number, allowPurged: true, allowChild: true)
            let ids = rows.map(\.id)
            let turns = try String.fetchAll(db, sql: """
                SELECT DISTINCT r.turnId FROM memoryRead r
                JOIN memoryDoc d ON d.id = r.docId AND d.companyId = r.companyId
                JOIN turn tn ON tn.id = r.turnId AND tn.companyId = r.companyId
                LEFT JOIN turnTranscript t ON t.turnId = r.turnId AND t.companyId = r.companyId
                WHERE r.companyId = ? AND r.turnId IS NOT NULL AND d.source = ?
                  AND (t.turnId IS NOT NULL OR tn.endedAt IS NULL)
                  AND d.sourceId IN (\(ids.map { _ in "?" }.joined(separator: ", ")))
                ORDER BY r.turnId
                """, arguments: StatementArguments([companyId, MemorySource.resource.rawValue]) + StatementArguments(ids))
            // Untracked reads (the mirror or the vault through a shell): every captured turn of a reader while it existed.
            // In both lists a turn still running now is kept by id although its transcript is captured only when it ends:
            // the notice is keyed by turn id, so it shows over that transcript once it is captured.
            let readers = try Self.purgeReaders(db: db, catalog: catalog, companyId: companyId, rows: rows)
            let windowed = readers.isEmpty ? [] : try String.fetchAll(db, sql: """
                SELECT DISTINCT t.id FROM turn t
                LEFT JOIN turnTranscript tt ON tt.turnId = t.id AND tt.companyId = t.companyId
                WHERE t.companyId = ? AND t.startedAt <= ? AND (t.endedAt IS NULL OR t.endedAt >= ?)
                  AND (tt.turnId IS NOT NULL OR t.endedAt IS NULL)
                  AND t.agentId IN (\(readers.map { _ in "?" }.joined(separator: ", ")))
                """, arguments: [companyId, now, rows[0].createdAt] + StatementArguments(readers))
            var seen = Set<String>()
            return (rows, (turns + windowed.sorted()).filter { seen.insert($0).inserted })
        }
        let top = rows[0]
        var seen = Set<String>()
        let flagged = backups.filter { $0.takenAt >= top.createdAt && $0.takenAt <= now }
            .sorted { ($0.takenAt, $0.name) < ($1.takenAt, $1.name) }
            .compactMap { seen.insert($0.name).inserted ? $0.name : nil }
        let report = PurgeReport(backups: flagged, transcripts: transcripts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let reportText = String(decoding: try encoder.encode(report), as: UTF8.self)

        // 1. The tombstones and the docs, under the secure purge.
        try purgeMemoryDocs(companyId: companyId, source: .resource, sourceIds: rows.map(\.id), now: now) { db in
            // Its shown name leaves the engine-built text that carries it (a folder's files are never named there).
            if top.parentId == nil { try scrubShownName(db: db, top) }
            for r in rows {
                // A file purged on its own before keeps its own report. A link's URL, host and shown name are its content.
                try db.execute(sql: """
                    UPDATE resource SET purgedAt = COALESCE(purgedAt, ?),
                      purgeReport = CASE WHEN purgedAt IS NULL OR id = ? THEN ? ELSE purgeReport END,
                      mirrorPath = NULL, mirrorSha256 = NULL, textIndexed = 0, url = NULL,
                      displayName = CASE WHEN kind = 'link' THEN '[purged]' ELSE displayName END,
                      sourceDetail = CASE WHEN kind = 'link' THEN NULL ELSE sourceDetail END,
                      updatedAt = ?
                    WHERE companyId = ? AND id = ?
                    """, arguments: [now, top.id, reportText, now, companyId, r.id])
            }
            // A folder's size counts its live files only.
            if let folderId = top.parentId {
                try db.execute(sql: """
                    UPDATE resource SET bytes = (SELECT COALESCE(SUM(bytes), 0) FROM resource
                                                 WHERE companyId = ? AND parentId = ? AND purgedAt IS NULL AND removedAt IS NULL),
                      updatedAt = ?
                    WHERE companyId = ? AND id = ?
                    """, arguments: [companyId, folderId, now, companyId, folderId])
            }
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .resource,
                              text: "Purged \(top.ref) (\(Self.purgeHolders(report)))",
                              createdAt: now).insert(db)
        }

        // 2. The mirror files and the vault bytes.
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        var problems: [String] = []
        for r in rows where r.kind == .file {
            if r.mirrorPath != nil, let ext = r.ext {
                do {
                    try EngineFiles.remove(workspace: workspace, dir: Self.resourceMirrorDir, name: "\(r.ref).\(ext)")
                } catch let problem as UnsafeEngineFile {
                    alertResourceMirror(problem, companyId: companyId, now: now)       // the sweep below wipes the mirror
                } catch {
                    problems.append("its mirror \(r.ref).\(ext): \(error)")
                }
            }
            if let path = r.vaultPath {
                do { try contentVault.remove(companyId: companyId, relativePath: path) } catch {
                    problems.append("\(r.ref)'s vault copy: \(error)")
                }
            }
        }
        syncResourceMirror(companyId: companyId, contentVault: contentVault, now: now)
        guard problems.isEmpty else {
            let text = "\(top.ref) was purged from search, but \(problems.joined(separator: "; ")) could not be removed; purge it again"
            resourceTrace(companyId: companyId, text, now: now)
            throw ResourceError.conflict(text)
        }
        return report
    }

    /// `<k> backups and <t> transcripts made since it was added may still contain it; reads through an agent's shell or the
    /// mirror are not tracked one by one`: the purge's activity line, the CLI and the app say the same.
    public static func purgeHolders(_ report: PurgeReport) -> String {
        "\(report.backups.count) backups and \(report.transcripts.count) transcripts made since it was added may still contain it; "
            + untrackedReads
    }

    /// Why a purge's transcript list is a "may contain" list.
    public static let untrackedReads = "reads through an agent's shell or the mirror are not tracked one by one"

    /// The agents of the company the access engine lets read any of `rows` at all (full or summary), now. A killed agent's
    /// old turns count too; an agent whose context can't be loaded is kept (fail toward listing).
    static func purgeReaders(db: Database, catalog: PackCatalog, companyId: String, rows: [Resource]) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM agent WHERE companyId = ? ORDER BY id", arguments: [companyId]).filter { id in
            guard let ctx = try? ReaderContext.load(db: db, catalog: catalog, companyId: companyId, reader: .agent(id)) else {
                return true
            }
            return rows.contains { level(ctx, $0) != .none }
        }
    }

    // MARK: The mirror sweep

    /// Brings `.brahma/resources/company` in line with the vault: exactly the company-scope, untainted, unflagged, live files
    /// (`Store.mirrors`), each holding its vault bytes, read-only. Run with the handbook refresh (`HandbookRefresh.run`) and
    /// after every vouch, scope change and purge. Never throws: a failure is traced (an `error` activity line).
    ///
    /// - Entries no resource is mirrored at are removed (a file of a resource rescoped or purged quietly; anything else with
    ///   an activity line), and so is anything under `.brahma/resources` beside `company/`.
    /// - Each mirrored file is compared with its recorded vault hash. It is hashed through one open descriptor, and the
    ///   descriptor's fingerprint (inode, size, times, mode) is cached as verified only when it matched the hash and was the
    ///   same before and after the read. A file whose fingerprint equals a cached one is not read again (a rewrite always
    ///   changes its ctime, which no user can set). A file the sweep has just written is never cached: the next sweep hashes
    ///   it. A changed or missing file is put back from the vault (`ContentVault.read`, verified) with an activity line.
    /// - It fails closed. A link or any entry that is not a single-link regular file of this user (`UnsafeEngineFile`), at
    ///   any name or in the way of a write, raises 3a's engine-file alert (once per distinct problem until a clean sweep)
    ///   and wipes the whole `.brahma/resources` mirror (by descriptor; a link is unlinked, never followed); the next sweep
    ///   rebuilds it. A file whose vault copy fails its hash is not mirrored.
    @discardableResult
    public func syncResourceMirror(companyId: String, contentVault: ContentVault, now: Date = Store.now()) -> ResourceMirrorResult {
        syncResourceMirror(companyId: companyId, contentVault: contentVault, now: now, afterWrite: nil, beforeHash: nil)
    }

    /// Tests only: `afterWrite` is called with a file's name right after the sweep wrote it (where an agent's write may
    /// land); `beforeHash` as a mirror file is about to be hashed (what it throws counts as a read failure of that file).
    @discardableResult
    func syncResourceMirror(companyId: String, contentVault: ContentVault, now: Date,
                            afterWrite: ((String) throws -> Void)?, beforeHash: ((String) throws -> Void)? = nil) -> ResourceMirrorResult {
        var result = ResourceMirrorResult()
        do {
            try syncResourceMirror(companyId: companyId, contentVault: contentVault, now: now, afterWrite: afterWrite,
                                   beforeHash: beforeHash, into: &result)
        } catch {
            resourceTrace(companyId: companyId, "Could not refresh the resource mirror \(Self.resourceMirrorDir): \(error)", now: now)
        }
        return result
    }

    private func syncResourceMirror(companyId: String, contentVault: ContentVault, now: Date,
                                    afterWrite: ((String) throws -> Void)?, beforeHash: ((String) throws -> Void)?,
                                    into result: inout ResourceMirrorResult) throws {
        guard let company = try company(id: companyId) else { return }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let dirName = Self.resourceMirrorDir
        let (rows, stored) = try writer.read { db in
            (try Resource.fetchAll(db, sql: "SELECT * FROM resource WHERE companyId = ? AND kind = 'file' ORDER BY number",
                                   arguments: [companyId]),
             try Self.memoryCursorPosition(db: db, companyId: companyId, source: Self.resourceMirrorCursor))
        }
        var expected: [(name: String, row: Resource)] = []
        for r in rows where r.purgedAt == nil && r.removedAt == nil && Self.mirrors(r) {
            guard let ext = r.ext, ContentVault.validExt(ext), r.vaultPath != nil, r.sha256 != nil else { continue }
            expected.append(("\(r.ref).\(ext)", r))
        }
        let wasMirrored = Set(rows.compactMap { $0.mirrorPath.map { ($0 as NSString).lastPathComponent } })
        let verified = (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
        var prints: [String: String] = [:]
        var mirrored: [String: String] = [:]          // row id → the sha256 its mirror file holds
        var notes: [String] = []

        // Nothing to mirror and no mirror on disk: nothing to do (no empty directory is made).
        var top = stat()
        let absent = lstat(workspace.appending(path: ".brahma/resources").path, &top) != 0 && errno == ENOENT
        if !(expected.isEmpty && absent) {
            do {
                // Beside `company/`, nothing belongs under `.brahma/resources`: a planted file or directory goes (a directory
                // by descriptor, its links unlinked, never followed); a link or odd file there is planted.
                let parent = try EngineFiles.openWalked(workspace: workspace, ".brahma/resources")
                let parentShown = workspace.appending(path: ".brahma/resources").path
                for name in try parent.names().sorted() where name != "company" {
                    var st = stat()
                    guard fstatat(parent.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                        if errno == ENOENT { continue }
                        throw UnsafeEngineFile(path: "\(parentShown)/\(name)", problem: "cannot be inspected")
                    }
                    if st.st_mode & S_IFMT == S_IFLNK {
                        throw UnsafeEngineFile(path: "\(parentShown)/\(name)", problem: "is a symbolic link")
                    }
                    if st.st_mode & S_IFMT != S_IFDIR, let problem = EngineFiles.copyProblem(st) {
                        throw UnsafeEngineFile(path: "\(parentShown)/\(name)", problem: problem)
                    }
                    try parent.remove(name)
                    result.removed.append(name)
                    notes.append("Removed .brahma/resources/\(Store.flat(name, max: 120)) from the resource mirror: nothing is mirrored there")
                }
                let dir = try EngineFiles.openWalked(workspace: workspace, dirName)
                let shown = workspace.appending(path: dirName).path
                let names = Set(expected.map(\.name))
                var present: [String: String] = [:]    // name → fingerprint when listed
                // Sweep: anything unsafe is planted; anything no resource is mirrored at goes.
                for name in try dir.names().sorted() {
                    var st = stat()
                    guard fstatat(dir.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                        if errno == ENOENT { continue }
                        throw UnsafeEngineFile(path: "\(shown)/\(name)", problem: "cannot be inspected")
                    }
                    if st.st_mode & S_IFMT == S_IFLNK { throw UnsafeEngineFile(path: "\(shown)/\(name)", problem: "is a symbolic link") }
                    if let problem = EngineFiles.copyProblem(st) { throw UnsafeEngineFile(path: "\(shown)/\(name)", problem: problem) }
                    if names.contains(name) { present[name] = Self.mirrorFingerprint(st); continue }
                    try dir.remove(name)
                    result.removed.append(name)
                    if !wasMirrored.contains(name) {
                        notes.append("Removed \(dirName)/\(Store.flat(name, max: 120)) from the resource mirror: no resource is mirrored there")
                    }
                }
                // Each mirrored file: verified (by fingerprint, else by hash), else put back from the vault.
                for (name, r) in expected {
                    guard let sha = r.sha256, let path = r.vaultPath else { continue }
                    if let print = present[name] {
                        if verified[name] == "\(print)|\(sha)" {
                            prints[name] = verified[name]; mirrored[r.id] = sha
                            continue
                        }
                        // Hashed through one descriptor; its fingerprint is cached only when it is the same before and after.
                        let read: (sha256: String, fingerprint: String?)?
                        do {
                            try beforeHash?(name)
                            read = try MirrorFile.hash(dir: dir, name: name, shown: "\(shown)/\(name)", limit: r.bytes)
                        } catch let problem as UnsafeEngineFile {
                            throw problem
                        } catch {
                            // Content that can't be read can't be verified: fail closed, like a planted file.
                            throw UnsafeEngineFile(path: "\(shown)/\(name)", problem: "cannot be read (\(error))")
                        }
                        if let read, read.sha256 == sha {
                            if let stable = read.fingerprint { prints[name] = "\(stable)|\(sha)" }
                            mirrored[r.id] = sha
                            continue
                        }
                    }
                    let bytes: Data
                    do {
                        bytes = try readResourceBytes(r, contentVault: contentVault, now: now, expected: (path, sha))
                    } catch {
                        // The vault copy can't be trusted (an integrity failure is already traced): no mirror for it.
                        if case ResourceError.integrity = error {} else {
                            resourceTrace(companyId: companyId, "Could not mirror \(r.ref) into \(dirName): \(error)", now: now)
                        }
                        if present[name] != nil { try dir.remove(name); result.removed.append(name) }
                        continue
                    }
                    do {
                        if let replaced = try EngineFiles.replace(bytes, workspace: workspace, dir: dirName, name: name, mode: 0o444) {
                            throw replaced   // planted between the sweep and the write: replaced, never followed; still planted
                        }
                    } catch let problem as UnsafeEngineFile where !HandbookExporter.isPlanted(problem) {
                        // The engine's own write failed (a full disk; a concurrent sweep took its temporary file): no stale
                        // copy stays under the name, and the next sweep tries again.
                        resourceTrace(companyId: companyId, "Could not mirror \(r.ref) into \(dirName): \(problem)", now: now)
                        try dir.remove(name)
                        if present[name] != nil { result.removed.append(name) }
                        continue
                    }
                    // No fingerprint is cached for a file written now: what is at the name after the rename may already be
                    // someone else's. The next sweep hashes it once.
                    try afterWrite?(name)
                    mirrored[r.id] = sha
                    if present[name] != nil || r.mirrorPath != nil {
                        result.repaired.append(name)
                        notes.append("Repaired the resource mirror file \(dirName)/\(name) (it was \(present[name] != nil ? "changed" : "missing")); "
                                     + "its vault copy was put back")
                    } else {
                        result.written.append(name)
                    }
                }
            } catch let problem as UnsafeEngineFile {
                result.unsafe.append(problem)
                wipeResourceMirror(problem, companyId: companyId, workspace: workspace, now: now)
                mirrored = [:]; prints = [:]; notes = []
            }
        }

        // The rows say what is mirrored now; the verified fingerprints are kept for the next sweep.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let printsText = prints.isEmpty ? "" : String(decoding: try encoder.encode(prints), as: UTF8.self)
        try writer.write { db in
            for r in rows {
                let sha = mirrored[r.id]
                let path = sha != nil ? r.ext.map { "\(dirName)/\(r.ref).\($0)" } : nil
                guard r.mirrorPath != path || r.mirrorSha256 != sha else { continue }
                // Never marks a row mirrored that a purge or removal reached meanwhile.
                try db.execute(sql: """
                    UPDATE resource SET mirrorPath = ?, mirrorSha256 = ?, updatedAt = ?
                    WHERE companyId = ? AND id = ? AND (? IS NULL OR (purgedAt IS NULL AND removedAt IS NULL))
                    """, arguments: [path, sha, now, companyId, r.id, path])
            }
            for text in notes {
                try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .resource, text: try redact(text), createdAt: now)
                    .insert(db)
            }
            try Self.setMemoryCursorPosition(db: db, companyId: companyId, source: Self.resourceMirrorCursor, printsText)
            if result.unsafe.isEmpty {
                try Self.setMemoryCursorPosition(db: db, companyId: companyId, source: Self.resourceMirrorAlertCursor, "")
            }
        }
    }

    /// Something planted in the mirror: 3a's engine-file alert (once per distinct problem until a clean sweep), and the whole
    /// `.brahma/resources` removed by descriptor (`EngineFiles.clear`); what could not be cleared is alerted too.
    private func wipeResourceMirror(_ problem: UnsafeEngineFile, companyId: String, workspace: URL, now: Date) {
        HandbookExporter.alertOnce(store: self, companyId: companyId, key: "planted \(problem.description)",
                                   cursor: Self.resourceMirrorAlertCursor, what: "resource mirror") { db in
            try alertEngineFile(db: db, problem, companyId: companyId, now: now)
        }
        var outcome: EngineFiles.Clearance
        do { outcome = try EngineFiles.clear(workspace: workspace, dir: ".brahma", name: "resources") } catch {
            outcome = .failed("\(error)")
        }
        guard outcome != .removed else { return }
        let left: String
        switch outcome {
        case .removed: return
        case .emptied: left = "its files could not all be removed, so their contents were emptied"
        case .failed(let why): left = "its files could not be removed (\(Store.flat(why, max: 300))): check .brahma/resources in the workspace"
        }
        let text = "The resource mirror in .brahma/resources met \(Store.flat(problem.description, max: 300)); \(left)."
        HandbookExporter.alertOnce(store: self, companyId: companyId, key: "cleared \(problem.description) \(outcome)",
                                   cursor: Self.resourceMirrorAlertCursor, what: "resource mirror") { db in
            try EngineAlerts.raise(store: self, db: db, text: text, now: now, reason: Self.resourceMirrorAlertReason, companyId: companyId)
        }
    }

    /// What identifies a file's content without reading it: a rewrite in place changes its ctime (which no user can set), a
    /// swap its inode.
    static func mirrorFingerprint(_ st: stat) -> String {
        #if canImport(Darwin)
        let m = st.st_mtimespec, c = st.st_ctimespec
        #else
        let m = st.st_mtim, c = st.st_ctim
        #endif
        return "\(st.st_dev):\(st.st_ino):\(st.st_size):\(m.tv_sec).\(m.tv_nsec):\(c.tv_sec).\(c.tv_nsec):\(st.st_mode)"
    }

    // MARK: Helpers

    /// A purge's rewrite of the resource's shown name, in the purge's secure transaction, wherever engine-built text carries
    /// it: the activity line `F-<n> "<name>"` and the announcement fragment `F-<n> · "<name>"` (for an old link announcement,
    /// `F-<n> · <host/path>`) become `F-<n> [purged F-<n>]` / `F-<n> · [purged F-<n>]`. Matched as those exact ref-tagged
    /// strings (as written and as redacted), never fuzzily, in the activity feed, messages (with `messageFts` kept in step and
    /// optimized), item events, question answers and memory docs (title and body). The owner's own words are not matched.
    private func scrubShownName(db: Database, _ r: Resource) throws {
        let tag = "[purged \(r.ref)]"
        var raw: [(String, String)] = [
            ("\(r.ref) \"\(Store.flat(r.displayName, max: 120))\"", "\(r.ref) \(tag)"),
            ("\(r.ref) · \"\(Self.announcedName(r.displayName, max: 120))\"", "\(r.ref) · \(tag)"),
        ]
        if r.kind == .link, let url = r.url {
            raw.append(("\(r.ref) · \(Self.announcedName(Self.cut(Self.linkShown(url), 60), max: 200))", "\(r.ref) · \(tag)"))
        }
        var pairs: [(old: String, new: String)] = []
        for (old, new) in raw {
            for variant in [old, try redact(old)] where !pairs.contains(where: { $0.old == variant }) { pairs.append((variant, new)) }
        }
        let columns = [("activityEvent", "text"), ("workItemEvent", "text"), ("ask", "ownerAnswer"), ("memoryDoc", "title"),
                       ("memoryDoc", "body")]
        for (old, new) in pairs {
            for (table, column) in columns {
                try db.execute(sql: """
                    UPDATE \(table) SET \(column) = replace(\(column), ?, ?) WHERE companyId = ? AND instr(\(column), ?) > 0
                    """, arguments: [old, new, r.companyId, old])
            }
        }
        // Messages: `messageFts` indexes them as external content with an insert trigger only, so each rewrite takes the old
        // text out of the index and puts the new one in; the segments are then merged so the old terms go.
        var rewritten = false
        for (old, _) in pairs {
            for row in try Row.fetchAll(db, sql: "SELECT rowid, text FROM message WHERE companyId = ? AND instr(text, ?) > 0",
                                        arguments: [r.companyId, old]) {
                let rowid: Int64 = row[0], before: String = row[1]
                let after = pairs.reduce(before) { $0.replacingOccurrences(of: $1.old, with: $1.new) }
                guard after != before else { continue }
                try db.execute(sql: "INSERT INTO messageFts(messageFts, rowid, text) VALUES('delete', ?, ?)", arguments: [rowid, before])
                try db.execute(sql: "UPDATE message SET text = ? WHERE rowid = ?", arguments: [after, rowid])
                try db.execute(sql: "INSERT INTO messageFts(rowid, text) VALUES(?, ?)", arguments: [rowid, after])
                rewritten = true
            }
        }
        if rewritten { try db.execute(sql: "INSERT INTO messageFts(messageFts) VALUES('optimize')") }
    }

    /// The rows an owner action on `F-<number>` covers: the resource, then (for a folder) its files by number (purged ones
    /// only with `allowPurged`). Missing or removed → `.notFound("no resource F-<n>")`; a folder's file (unless `allowChild`:
    /// it is then the only row) → `.invalid("F-<n> is part of folder F-<m>; change the folder")`; purged (unless
    /// `allowPurged`) → `.invalid("F-<n> was purged")`.
    static func ownerTarget(db: Database, companyId: String, number: Int, allowPurged: Bool,
                            allowChild: Bool = false) throws -> [Resource] {
        guard let r = try resource(db: db, companyId: companyId, number: number), r.removedAt == nil else {
            throw ResourceError.notFound("no resource F-\(number)")
        }
        if let parentId = r.parentId, !allowChild {
            let parent = try Int.fetchOne(db, sql: "SELECT number FROM resource WHERE companyId = ? AND id = ?",
                                          arguments: [companyId, parentId])
            throw ResourceError.invalid("\(r.ref) is part of folder \(parent.map { "F-\($0)" } ?? "?"); change the folder")
        }
        guard allowPurged || r.purgedAt == nil else { throw ResourceError.invalid("\(r.ref) was purged") }
        guard r.parentId == nil else { return [r] }
        let children = try Resource.fetchAll(db, sql: """
            SELECT * FROM resource WHERE companyId = ? AND parentId = ? AND removedAt IS NULL AND (? OR purgedAt IS NULL)
            ORDER BY number
            """, arguments: [companyId, r.id, allowPurged])
        return [r] + children
    }

    /// Re-indexes each row's doc from the row as stored now, keeping the text it was indexed with.
    private func reindexResources(db: Database, _ rows: [Resource], now: Date) throws {
        for r in rows {
            let body = try String.fetchOne(db, sql: "SELECT body FROM memoryDoc WHERE companyId = ? AND source = ? AND sourceId = ?",
                                           arguments: [r.companyId, MemorySource.resource.rawValue, r.id])
            try ingestResource(db: db, r, text: body, now: now)
        }
    }

    /// `F-<n> "<name>"`, and ` and its <k> files` for a folder; a link is `[link F-<n>]` (owner-facing activity text).
    private static func named(_ rows: [Resource]) -> String {
        let top = rows[0]
        if top.kind == .link { return linkTag(top.ref) }       // a link's address is its content
        var text = "\(top.ref) \"\(Store.flat(top.displayName, max: 120))\""
        if top.kind == .folder { text += " and its \(rows.count - 1) files" }
        return text
    }

    private func resources(companyId: String, ids: [String]) throws -> [Resource] {
        try writer.read { db in
            try Resource.fetchAll(db, sql: """
                SELECT * FROM resource WHERE companyId = ? AND id IN (\(ids.map { _ in "?" }.joined(separator: ", "))) ORDER BY number
                """, arguments: StatementArguments([companyId]) + StatementArguments(ids))
        }
    }
}

/// Reading a mirror file outside `Store` (whose `close()` would shadow the descriptor call).
private enum MirrorFile {
    /// The SHA-256 of mirror file `name`, read through one descriptor (`O_NOFOLLOW`, `copyProblem` on it), and that
    /// descriptor's fingerprint when it was the same before and after the read (nil when the file changed meanwhile). Nil
    /// when the name is missing; a file over `limit` bytes hashes to "" (a mismatch). A link or odd file → `UnsafeEngineFile`.
    static func hash(dir: EngineFiles.OpenDirectory, name: String, shown: String,
                               limit: Int64) throws -> (sha256: String, fingerprint: String?)? {
        let fd = openat(dir.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let err = errno
            if err == ENOENT { return nil }
            throw UnsafeEngineFile(path: shown, problem: err == ELOOP ? "is a symbolic link" : "cannot be opened (\(String(cString: strerror(err))))")
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw UnsafeEngineFile(path: shown, problem: "cannot be inspected") }
        if let problem = EngineFiles.copyProblem(before) { throw UnsafeEngineFile(path: shown, problem: problem) }
        guard Int64(before.st_size) <= limit else { return ("", nil) }
        var hasher = SHA256.Hasher()
        var offset: off_t = 0
        while true {
            let piece = try ContentScan.read(fd, at: offset, count: ContentScan.chunkBytes)
            if piece.isEmpty { break }
            offset += off_t(piece.count)
            guard Int64(offset) <= limit else { return ("", nil) }
            piece.withUnsafeBytes { hasher.update($0) }
        }
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw UnsafeEngineFile(path: shown, problem: "cannot be inspected") }
        let print = Store.mirrorFingerprint(before)
        return (SHA256.hex(digest: hasher.finalize()), print == Store.mirrorFingerprint(after) ? print : nil)
    }
}
