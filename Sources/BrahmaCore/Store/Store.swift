import Foundation
import GRDB

public enum StoreError: Error, Equatable {
    case duplicateName
    case notFound
    /// Channel or agent name is reserved or not in the allowed alphabet.
    case invalidName
    /// The workspace could not be made a git repository. The message is shown as `git is required: <stderr>`.
    case gitRequired(String)
}

extension StoreError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateName: "duplicate name"
        case .notFound: "not found"
        case .invalidName: "invalid name"
        case .gitRequired(let stderr): "git is required: \(stderr)"
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
    /// How much output a plan-turn barrier git call may produce before the barrier fails closed (tests shrink it).
    let planBarrierOutputLimit = GitOutputLimit()
    /// Called inside the kill transaction of every agent (Plan 5-lite revokes grants, Plan 7 reassigns threads).
    let lifecycleObservers: [any AgentLifecycleObserver]

    public init(path: String, catalog: PackCatalog = .builtin, lifecycleObservers: [any AgentLifecycleObserver] = []) throws {
        self.catalog = catalog
        self.lifecycleObservers = lifecycleObservers
        dataHome = URL(fileURLWithPath: path).deletingLastPathComponent()
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        writer = try DatabasePool(path: path, configuration: config)
        try Migrations.migrator().migrate(writer)
    }

    private init(queue: DatabaseQueue, catalog: PackCatalog, lifecycleObservers: [any AgentLifecycleObserver]) throws {
        self.catalog = catalog
        self.lifecycleObservers = lifecycleObservers
        dataHome = nil
        writer = queue
        try Migrations.migrator().migrate(writer)
    }

    public static func inMemory(catalog: PackCatalog = .builtin, lifecycleObservers: [any AgentLifecycleObserver] = []) throws -> Store {
        try Store(queue: DatabaseQueue(), catalog: catalog, lifecycleObservers: lifecycleObservers)
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

    /// The git workspace of a company, with its per-item lock files under the data home (`<home>/run/locks/<companyId>`),
    /// never in the workspace where an agent could hold a lock forever.
    func gitWorkspace(root: URL, companyId: String) -> GitWorkspace {
        let locks = (dataHome?.appending(path: "run/locks", directoryHint: .isDirectory)
            ?? FileManager.default.temporaryDirectory.appending(path: "brahma-locks", directoryHint: .isDirectory))
            .appending(path: companyId, directoryHint: .isDirectory)
        var git = GitWorkspace(root: root, lockDirectory: locks)
        git.lockTimeout = gitLockTimeout.seconds
        git.planBarrierOutputLimit = planBarrierOutputLimit.bytes
        git.onWorktreeTamper = { [self] key, detail in
            let name = (try? company(id: companyId))?.name ?? companyId
            try? EngineAlerts.raise(
                store: self, text: "The worktree of \(key) in \(name) was repointed (\(detail)). Brahma refused to commit, merge or reset "
                + "there and put it back from its own records. An agent probably rewrote it; look at what \(key) is doing.",
                now: Store.now(), reason: "worktree:\(companyId):\(key)")
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
            try company.insert(db)
            // Directory is created only after the row is in; a failure here rolls the insert back.
            let existed = FileManager.default.fileExists(atPath: dir.path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                let git = GitWorkspace(root: dir)
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

    /// Whole-row update of the owner-editable fields. `mainCommit` belongs to the engine and is never overwritten from a copy.
    public func updateCompany(_ c: Company) throws {
        try writer.write { db in
            var kept = c
            kept.mainCommit = try String.fetchOne(db, sql: "SELECT mainCommit FROM company WHERE id = ?", arguments: [c.id])
            try kept.update(db)
        }
    }

    // MARK: Agents

    public func hire(companyId: String, name: String, role: String, model: String,
                     managerId: String? = nil, team: String? = nil) throws -> Agent {
        do {
            return try writer.write { db in
                try Store.hire(db: db, companyId: companyId, name: name, role: role, model: model,
                               managerId: managerId, team: team, now: Store.now())
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw StoreError.duplicateName
        }
    }

    /// `reserved` lets `applyOrg` and `fillVacancy` hire into a handle an open vacancy holds; everyone else is refused.
    static func hire(db: Database, companyId: String, name: String, role: String, model: String, managerId: String?,
                     team: String?, now: Date, honoringVacancy: Bool = false) throws -> Agent {
        let handle = name.lowercased()
        guard handle != "owner", handle != "system", handle != "here", handle != "team",
              handle.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
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

final class GitLockTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 10
    var seconds: TimeInterval { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
