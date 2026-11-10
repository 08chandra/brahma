import Foundation
import GRDB

public enum StoreError: Error, Equatable {
    case duplicateName
    case notFound
    /// Channel or agent name is reserved or not in the allowed alphabet.
    case invalidName
    /// The workspace could not be made a git repository. The message is shown as `git is required: <stderr>`.
    case gitRequired(String)
    /// A migration failed. The database was backed up first (`backup` names the snapshot) and is left as it was.
    case migrationFailed(backup: String, detail: String)
    /// Migrations were pending and the pre-migration snapshot could not be made, so nothing was migrated.
    case preMigrationBackupFailed(String)
}

extension StoreError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateName: "duplicate name"
        case .notFound: "not found"
        case .invalidName: "invalid name"
        case .gitRequired(let stderr): "git is required: \(stderr)"
        case .migrationFailed(let backup, let detail): "the database migration failed (\(detail)); your data was backed up first: \(backup)"
        case .preMigrationBackupFailed(let detail): "the database needs a migration and Brahma could not back it up first (\(detail)); nothing was changed"
        }
    }
    public var errorDescription: String? { description }
}

public final class Store: Sendable {
    public let writer: any DatabaseWriter
    /// The industry packs this store knows. Every pack lookup goes through here.
    public let catalog: PackCatalog
    /// The directory holding the database (nil for an in-memory store): where the engine keeps its own locks.
    let dataHome: URL?
    /// How long engine git waits for an item's lock before skipping the item (tests shorten it).
    let gitLockTimeout = GitLockTimeout()
    let mergeRefProbe = MergeRefProbe()
    /// How much output a plan-turn barrier git call may produce before the barrier fails closed (tests shrink it).
    let planBarrierOutputLimit = GitOutputLimit()
    /// Called inside the kill transaction of every agent (Plan 5-lite revokes grants, Plan 7 reassigns threads).
    let lifecycleObservers: [any AgentLifecycleObserver]
    /// Called inside the transaction that completes an item (`completeItem`). The outcome-facts observer is always first.
    let observers: [any WorkItemObserver]
    /// Secret values the engine knows, redacted from any agent- or tool-produced text before it is stored. Reloaded by
    /// `reloadRedactorIfNeeded(vault:)`; until its first complete load (when the database had secrets at open) every
    /// redacting write throws (`secretsHeld`, `SecretError.secretsNotLoaded`).
    public let redactor = Redactor()

    /// How long a write waits for another connection's write lock (the engine, every agent's `brahma mcp`, the CLI and the app
    /// share one database) before it fails with "database is locked". SQLite's busy handler is not first-come-first-served:
    /// under heavy machine load one writer can lose many rounds in a row, and 5 s ran out (`concurrentWritersDoNotLock`, at a
    /// load average of ~88, where 400 writes took 62 s). WAL readers never wait on it.
    public static let busyTimeout: TimeInterval = 30

    public init(path: String, catalog: PackCatalog = .builtin, lifecycleObservers: [any AgentLifecycleObserver] = [],
                observers: [any WorkItemObserver] = [], backupsDir: URL? = nil) throws {
        self.catalog = catalog
        self.lifecycleObservers = lifecycleObservers
        self.observers = [OutcomeFactsObserver(catalog: catalog)] + observers
        dataHome = URL(fileURLWithPath: path).deletingLastPathComponent()
        var config = Configuration()
        config.busyMode = .timeout(Self.busyTimeout)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = \(Int(Self.busyTimeout * 1000))")
        }
        let pool = try DatabasePool(path: path, configuration: config)
        writer = pool
        let migrator = Migrations.migrator()
        // Pending migrations on a database that already holds data: snapshot it first (verified), so a failed or regretted
        // migration can be undone with `brahma restore`. A brand-new database has nothing to protect.
        var backup: URL?
        if let backupsDir {
            let completed = try pool.read { db in try migrator.completedMigrations(db) }
            if !completed.isEmpty, migrator.migrations.contains(where: { !completed.contains($0) }) {
                let service = BackupService(database: URL(fileURLWithPath: path), backupsDir: backupsDir, writer: pool)
                do { backup = try service.snapshot(reason: .preMigration) } catch {
                    throw StoreError.preMigrationBackupFailed("\(error)")
                }
            }
        }
        do {
            try migrator.migrate(pool)
        } catch {
            if let backup { throw StoreError.migrationFailed(backup: backup.path, detail: "\(error)") }
            throw error
        }
        try initializeRedactor()
    }

    /// Closes the database connections. Every later use of this store fails; open a new `Store` instead (the app does this
    /// around a restore).
    public func close() throws {
        if let pool = writer as? DatabasePool { try pool.close() } else if let queue = writer as? DatabaseQueue { try queue.close() }
    }

    private init(queue: DatabaseQueue, catalog: PackCatalog, lifecycleObservers: [any AgentLifecycleObserver],
                 observers: [any WorkItemObserver]) throws {
        self.catalog = catalog
        self.lifecycleObservers = lifecycleObservers
        self.observers = [OutcomeFactsObserver(catalog: catalog)] + observers
        dataHome = nil
        writer = queue
        try Migrations.migrator().migrate(writer)
        try initializeRedactor()
    }

    public static func inMemory(catalog: PackCatalog = .builtin, lifecycleObservers: [any AgentLifecycleObserver] = [],
                                observers: [any WorkItemObserver] = []) throws -> Store {
        try Store(queue: DatabaseQueue(), catalog: catalog, lifecycleObservers: lifecycleObservers, observers: observers)
    }

    /// Test helper: current value of a PRAGMA as text.
    func pragma(_ name: String) throws -> String {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "PRAGMA \(name)") else { return "" }
            let value: DatabaseValue = row[0]
            switch value.storage {
            case .string(let s): return s
            case .int64(let i): return String(i)
            case .double(let d): return String(d)
            default: return ""
            }
        }
    }

    /// The git workspace of a company, with its per-item lock files (`<home>/run/locks/<companyId>`) and the engine's merge
    /// checkout (`<home>/run/merge/<companyId>`) under the data home, never in the workspace, where an agent could hold a
    /// lock forever or tamper with the checkout a merge runs in.
    func gitWorkspace(root: URL, companyId: String) -> GitWorkspace {
        func engineDir(_ name: String, fallback: String) -> URL {
            (dataHome?.appending(path: "run/\(name)", directoryHint: .isDirectory)
                ?? FileManager.default.temporaryDirectory.appending(path: fallback, directoryHint: .isDirectory))
                .appending(path: companyId, directoryHint: .isDirectory)
        }
        // Merge-check exports go under the data home (`<home>/run/exports/<runId>`); an in-memory store uses a per-company
        // stand-in under the temporary directory.
        let exportHome = dataHome ?? FileManager.default.temporaryDirectory
            .appending(path: "brahma-exports/\(companyId)", directoryHint: .isDirectory)
        var git = GitWorkspace(root: root, lockDirectory: engineDir("locks", fallback: "brahma-locks"),
                               mergeDirectory: engineDir("merge", fallback: "brahma-merge"), exportHome: exportHome)
        git.lockTimeout = gitLockTimeout.seconds
        git.planBarrierOutputLimit = planBarrierOutputLimit.bytes
        git.hasLease = { [self] key in try lease(companyId: companyId, key: key) != nil }
        git.onWorktreeTamper = { [self] key, detail in
            let name = (try? company(id: companyId))?.name ?? companyId
            try? EngineAlerts.raise(
                store: self, text: "The worktree of \(key) in \(name) was repointed (\(detail)). Brahma refused to commit, merge or reset "
                + "there and put it back from its own records. An agent probably rewrote it; look at what \(key) is doing.",
                now: Store.now(), reason: "worktree:\(companyId):\(key)")
        }
        git.onUnsafeEngineFile = { [self] problem in alertEngineFile(problem, companyId: companyId) }
        git.onUnsafeRepository = { [self] detail in
            let name = (try? company(id: companyId))?.name ?? companyId
            let reason = "gitconfig:\(companyId)"
            let text = "The git repository of \(name) has settings Brahma does not run git with: \(detail). Brahma runs no git there "
                + "(no claims, commits, checks or reviews) until that is removed, for example with `git config --unset` or "
                + "`git config --remove-section`. An agent may have written it; look at who did."
            // One alert while it stays open: every refused call reports again, and each raise would DM the owner.
            try? writer.write { db in
                let open = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.engineAlert
                                          && Column("status") == AskStatus.pendingOwner.rawValue
                                          && Column("subjectId") == Store.engineAlertKey(reason)).fetchCount(db)
                guard open == 0 else { return }
                try EngineAlerts.raise(store: self, db: db, text: text, now: Store.now(), reason: reason)
            }
        }
        return git
    }

    // MARK: Companies

    /// Dates are stored with millisecond precision, so round at creation to keep records Equatable after reload.
    public static func now() -> Date {
        let now = Date()
        return Date.fromDatabaseValue(now.databaseValue) ?? now
    }

    static func slug(for name: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        return out
    }

    public func createCompany(name: String, goal: String, workspacesRoot: URL, packId: String = "software",
                              packVersion: Int? = nil) throws -> Company {
        guard let pack = catalog.pack(packId) else { throw OrgError.unknownPack }
        let base = Store.slug(for: name).isEmpty ? "company" : Store.slug(for: name)
        let createdAt = Store.now()
        return try writer.write { db in
            var slug = base
            var n = 2
            while try Company.filter(Column("slug") == slug).fetchCount(db) > 0 {
                slug = "\(base)-\(n)"
                n += 1
            }
            let dir = workspacesRoot.appending(path: slug, directoryHint: .isDirectory)
            var company = Company(
                id: UUID().uuidString, name: name, slug: slug, goal: goal, workspacePath: dir.path,
                status: .running, usageMode: .balanced, priorityWeight: 1, createdAt: createdAt,
                packId: packId, packVersion: packVersion ?? pack.version)
            company.cadence = CadenceKind(rawValue: pack.defaultCadence) ?? .sprint
            try company.insert(db)
            // Directory is created only after the row is in; a failure here rolls the insert back.
            let existed = FileManager.default.fileExists(atPath: dir.path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                // The engine's git output for this init goes under the data home (A-I1b), never the shared per-user temp dir.
                let git = GitWorkspace(root: dir, exportHome: dataHome)
                try git.ensureRepo()
                // The head the engine expects `main` to have; every claim checks it is still an ancestor of the real one.
                if let head = try git.head(of: GitWorkspace.mainRef) {
                    try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [head, company.id])
                    company.mainCommit = head
                }
            } catch {
                if !existed { try? FileManager.default.removeItem(at: dir) }
                let detail: String
                if case GitError.failed(_, _, let stderr) = error { detail = stderr } else { detail = "\(error)" }
                throw StoreError.gitRequired(detail)
            }
            try Store.insertChannel(db, companyId: company.id, name: "general", kind: .channel, members: ["owner"], now: createdAt)
            return company
        }
    }

    public func companies() throws -> [Company] {
        try writer.read { db in try Company.order(Column("createdAt"), Column.rowID).fetchAll(db) }
    }

    public func company(id: String) throws -> Company? {
        try writer.read { db in try Company.fetchOne(db, key: id) }
    }

    /// Whole-row update of the owner-editable fields. `mainCommit`, `pendingMainCommit` and `autoMergeCount` belong to the
    /// engine and are never overwritten from a copy; `autoMergeSmall` changes only through `setAutoMergeSmall` (which takes
    /// back pending auto-approvals).
    public func updateCompany(_ c: Company) throws {
        try writer.write { db in
            var kept = c
            let row = try Row.fetchOne(db, sql: """
                SELECT mainCommit, pendingMainCommit, autoMergeCount, autoMergeSmall FROM company WHERE id = ?
                """, arguments: [c.id])
            kept.mainCommit = row?["mainCommit"]
            kept.pendingMainCommit = row?["pendingMainCommit"]
            kept.autoMergeCount = row?["autoMergeCount"] ?? 0
            kept.autoMergeSmall = row?["autoMergeSmall"] ?? false
            // The sandbox settings change only through `updateSandbox` (validated); a copy never overwrites them.
            if let stored = try Company.fetchOne(db, key: c.id) {
                kept.permissionProfile = stored.permissionProfile
                kept.roleProfiles = stored.roleProfiles
                kept.allowedDomains = stored.allowedDomains
                kept.webDomains = stored.webDomains
                kept.allowLocalBinding = stored.allowLocalBinding
                kept.toolchainReadPaths = stored.toolchainReadPaths
                kept.ultraShare = stored.ultraShare
            }
            try kept.update(db)
        }
    }

    // MARK: Agents

    public func hire(companyId: String, name: String, role: String, model: String,
                     managerId: String? = nil, team: String? = nil) throws -> Agent {
        try retirePreexistingLab(companyId: companyId, handle: name)
        do {
            return try writer.write { db in
                try Store.hire(db: db, companyId: companyId, name: name, role: role, model: model,
                               managerId: managerId, team: team, now: Store.now())
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw StoreError.duplicateName
        }
    }

    /// Task 10b (round 2c): a hire never adopts a per-agent place that is already there. Without a sandbox (Workspace, Full)
    /// any agent can create another handle's places before that handle is hired. Each one found (`.brahma/labs/<h>`,
    /// `.brahma/home/<h>`, `.brahma/notes/agents/<h>.md`, `.brahma/bin/shell-<h>.sh`) is moved, unread and without following a
    /// link, into `.brahma/trash/<h>/<stamp>-<id>-<kind>`; one owner alert lists what was moved; the lab, home and notes file
    /// are created fresh and empty (the shell prefix is written at the agent's first sandboxed turn). Only for a valid handle
    /// no agent of the company holds yet: an existing agent's places are never touched. A place that cannot be moved aside
    /// refuses the hire. Blocking (file moves); call it outside a write transaction.
    func retirePreexistingLab(companyId: String, handle raw: String, now: Date = Store.now()) throws {
        let handle = raw.lowercased()
        guard handle.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
              let company = try company(id: companyId), try agent(companyId: companyId, name: handle) == nil else { return }
        let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true).resolvedForSandbox
        let places: [(kind: String, relative: String)] = [
            ("lab", ".brahma/labs/\(handle)"), ("home", ".brahma/home/\(handle)"),
            ("notes", ".brahma/notes/agents/\(handle).md"), ("bin", ".brahma/bin/shell-\(handle).sh"),
        ]
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let batch = String(UUID().uuidString.prefix(8))
        var moved: [String] = []
        var failed: String?
        for place in places {
            let url = ws.appending(path: place.relative)
            guard SandboxPath.kind(url.path) != .missing else { continue }
            let name = "\(stamp)-\(batch)-\(place.kind)"
            if case .removed? = try? EngineFiles.moveNoFollow(url, under: ws, toDirectory: ".brahma/trash/\(handle)", name: name) {
                moved.append("\(place.relative) → .brahma/trash/\(handle)/\(name)")
            } else {
                failed = place.relative
                break
            }
        }
        if !moved.isEmpty || failed != nil {
            let what = moved.isEmpty ? "" : " Brahma moved, unread: " + moved.joined(separator: "; ") + "."
            let refusal = failed.map { " \($0) could not be moved aside, so @\(handle) was not hired." } ?? " The new agent gets fresh, empty places."
            try? EngineAlerts.raise(store: self, text: "Before @\(handle) was hired in \(company.name), something had already created its "
                                    + "places.\(what)\(refusal) Check what put them there: on the Workspace and Full profiles any agent can "
                                    + "write another's places.", now: now, reason: "pre-hire-places:\(company.id):\(handle):\(batch)",
                                    companyId: company.id)
        }
        if let failed { throw WorkError.conflict("\(failed) already exists and could not be moved aside; nothing was hired") }
        guard !moved.isEmpty else { return }
        _ = try EngineFiles.directory(workspace: ws, ".brahma/labs/\(handle)", mode: 0o700)
        _ = try EngineFiles.directory(workspace: ws, ".brahma/home/\(handle)", mode: 0o700)
        if case .missing = try EngineFiles.entry(workspace: ws, dir: ".brahma/notes/agents", name: "\(handle).md") {
            _ = try EngineFiles.create(Data(), workspace: ws, dir: ".brahma/notes/agents", name: "\(handle).md", mode: 0o600)
        }
    }

    /// `reserved` lets `applyOrg` and `fillVacancy` hire into a handle an open vacancy holds; everyone else is refused.
    static func hire(db: Database, companyId: String, name: String, role: String, model: String, managerId: String?,
                     team: String?, now: Date, honoringVacancy: Bool = false) throws -> Agent {
        let handle = name.lowercased()
        guard handle != "owner", handle != "system", handle != "here", handle != "team",
              handle.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
              // `try-` names the owner's extension trials (10b, S29), never a team member.
              !ExtensionTry.isReservedHandle(name)
        else { throw StoreError.invalidName }
        if !honoringVacancy,
           try OrgVacancy.filter(Column("companyId") == companyId && Column("handle") == handle && Column("filledAt") == nil)
            .fetchCount(db) > 0 {
            throw StoreError.duplicateName
        }
        let agent = Agent(
            id: UUID().uuidString, companyId: companyId, name: handle, role: role, model: model,
            sessionId: UUID().uuidString, sessionStarted: false, state: .sleeping,
            blocker: nil, requestedBlocker: nil, paused: false, readySince: nil, createdAt: now,
            managerId: managerId, team: team)
        try agent.insert(db)
        if let general = try Channel.filter(Column("companyId") == companyId && Column("name") == "general").fetchOne(db) {
            try ChannelMember(channelId: general.id, member: agent.id).insert(db, onConflict: .ignore)
        }
        return agent
    }

    public func agent(id: String) throws -> Agent? {
        try writer.read { db in try Agent.fetchOne(db, key: id) }
    }

    public func agent(companyId: String, name: String) throws -> Agent? {
        try writer.read { db in
            try Agent.filter(Column("companyId") == companyId && Column("name") == name.lowercased()).fetchOne(db)
        }
    }

    public func agents(companyId: String? = nil, states: Set<AgentState>? = nil) throws -> [Agent] {
        try writer.read { db in
            var request = Agent.order(Column("createdAt"), Column.rowID)
            if let companyId { request = request.filter(Column("companyId") == companyId) }
            if let states { request = request.filter(states.map(\.rawValue).contains(Column("state"))) }
            return try request.fetchAll(db)
        }
    }

    /// Whole-row upsert, for tests only: production code must write single columns or go through `transition`,
    /// because MCP server processes update agent rows concurrently.
    func save(_ agent: Agent) throws {
        try writer.write { db in try agent.save(db) }
    }
}

/// A settable timeout shared by a store's git workspaces.
final class GitOutputLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 32 * 1024 * 1024
    var bytes: Int { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

/// Tests only: called by a merge with each ref's name right before its stop check (`Store.performMerge`; "" for the check
/// before anything is done), so a test can raise the owner's stop at exactly that seam.
final class MergeRefProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (@Sendable (String) -> Void)?
    func set(_ new: (@Sendable (String) -> Void)?) { lock.withLock { body = new } }
    func call(_ ref: String) { lock.withLock { body }?(ref) }
}

final class GitLockTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 10
    var seconds: TimeInterval { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

/// The C `close(2)`, for code inside `Store` where `Store.close()` (the database) shadows it.
func closeDescriptor(_ fd: Int32) { _ = close(fd) }
