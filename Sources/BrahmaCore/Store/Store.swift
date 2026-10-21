import Foundation
import GRDB

public enum StoreError: Error, Equatable {
    case duplicateName
    case notFound
    /// Channel or agent name is reserved or not in the allowed alphabet.
    case invalidName
}

public final class Store: Sendable {
    public let writer: any DatabaseWriter
    /// The industry packs this store knows. Every pack lookup goes through here.
    public let catalog: PackCatalog

    public init(path: String, catalog: PackCatalog = .builtin) throws {
        self.catalog = catalog
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        writer = try DatabasePool(path: path, configuration: config)
        try Migrations.migrator().migrate(writer)
    }

    private init(queue: DatabaseQueue, catalog: PackCatalog) throws {
        self.catalog = catalog
        writer = queue
        try Migrations.migrator().migrate(writer)
    }

    public static func inMemory(catalog: PackCatalog = .builtin) throws -> Store {
        try Store(queue: DatabaseQueue(), catalog: catalog)
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
            let company = Company(
                id: UUID().uuidString, name: name, slug: slug, goal: goal, workspacePath: dir.path,
                status: .running, usageMode: .balanced, priorityWeight: 1, createdAt: createdAt,
                packId: packId, packVersion: packVersion ?? pack.version)
            try company.insert(db)
            // Directory is created only after the row is in; a failure here rolls the insert back.
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    public func updateCompany(_ c: Company) throws {
        try writer.write { db in try c.update(db) }
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
