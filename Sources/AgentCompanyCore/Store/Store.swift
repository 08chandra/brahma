import Foundation
import GRDB

public enum StoreError: Error, Equatable {
    case duplicateName
}

public final class Store: Sendable {
    public let writer: any DatabaseWriter

    public init(path: String) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        writer = try DatabasePool(path: path, configuration: config)
        try Migrations.migrator().migrate(writer)
    }

    private init(queue: DatabaseQueue) throws {
        writer = queue
        try Migrations.migrator().migrate(writer)
    }

    public static func inMemory() throws -> Store {
        try Store(queue: DatabaseQueue())
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
    static func now() -> Date {
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

    public func createCompany(name: String, goal: String, workspacesRoot: URL) throws -> Company {
        let slug = Store.slug(for: name)
        let dir = workspacesRoot.appending(path: slug, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let company = Company(
            id: UUID().uuidString, name: name, slug: slug, goal: goal, workspacePath: dir.path,
            status: .running, usageMode: .low, priorityWeight: 1, createdAt: Store.now())
        try writer.write { db in try company.insert(db) }
        return company
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

    public func hire(companyId: String, name: String, role: String, model: String) throws -> Agent {
        let agent = Agent(
            id: UUID().uuidString, companyId: companyId, name: name.lowercased(), role: role, model: model,
            sessionId: UUID().uuidString, sessionStarted: false, state: .sleeping,
            blocker: nil, requestedBlocker: nil, paused: false, readySince: nil, createdAt: Store.now())
        do {
            try writer.write { db in try agent.insert(db) }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw StoreError.duplicateName
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

    public func save(_ agent: Agent) throws {
        try writer.write { db in try agent.save(db) }
    }
}
