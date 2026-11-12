import Foundation
import GRDB

public struct OrgVacancy: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "orgVacancy"
    public var id: Int64?
    public var companyId: String
    public var role: String
    public var handle: String
    public var managerHandle: String?
    public var team: String?
    public var createdAt: Date
    public var filledAt: Date?
    /// Owner-only text (Plan 4b): shown by the map, `brahma org vacancies` and the vacancy sheet; never read by agents.
    public var note: String = ""
    /// Set when the owner removed the seat. The row stays: its handle is never handed out again.
    public var removedAt: Date? = nil

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension PackCatalog {
    /// Loads packs from `directory`; a bad pack file is reported through `log` and the built-in catalog is used.
    public static func loadOrBuiltin(directory: URL, log: (String) -> Void) -> PackCatalog {
        do { return try load(directory: directory) } catch {
            log("brahma: ignoring packs in \(directory.path): \(error)")
            return .builtin
        }
    }
}

extension Store {
    private func pack(for company: Company) -> IndustryPack? { catalog.pack(company.packId) }

    // MARK: Handles

    /// `<prefix>-<max n over all agents (killed included) and every vacancy row (filled and removed included) + 1>`.
    public func nextHandle(companyId: String, prefix: String) throws -> String {
        try writer.read { db in try Store.nextHandle(db, companyId: companyId, prefix: prefix) }
    }

    /// The same, inside a caller's transaction: `addVacancy` picks its handle in the write that inserts the row.
    static func nextHandle(_ db: Database, companyId: String, prefix: String) throws -> String {
        let names = try String.fetchAll(db, sql: "SELECT name FROM agent WHERE companyId = ?", arguments: [companyId])
            + String.fetchAll(db, sql: "SELECT handle FROM orgVacancy WHERE companyId = ?", arguments: [companyId])
        let head = prefix + "-"
        let maxN = names.compactMap { $0.hasPrefix(head) ? Int($0.dropFirst(head.count)) : nil }.max() ?? 0
        return "\(head)\(maxN + 1)"
    }

    // MARK: Applying a plan

    /// Validates the whole plan (seated agents plus vacancies, and every existing handle), then in one transaction hires
    /// the seated agents with model `auto`, records the vacancies, and creates the org channels.
    @discardableResult
    public func applyOrg(companyId: String, plan: OrgPlan, pack: IndustryPack, vacancies: [PlannedAgent] = []) throws -> [Agent] {
        let (existing, reserved) = try writer.read { db in
            (try String.fetchAll(db, sql: "SELECT name FROM agent WHERE companyId = ?", arguments: [companyId]),
             try String.fetchAll(db, sql: "SELECT handle FROM orgVacancy WHERE companyId = ? AND filledAt IS NULL", arguments: [companyId]))
        }
        let taken = Set(existing + reserved)
        var issues = OrgPlan(goal: plan.goal, agents: plan.agents + vacancies).validate(pack: pack, external: Set(existing))
        for a in plan.agents + vacancies where taken.contains(a.handle) {
            issues.append(OrgIssue(handle: a.handle, message: "handle already exists"))
        }
        let seatedHandles = Set(plan.agents.map(\.handle))
        for a in plan.agents { if let m = a.managerHandle, !seatedHandles.contains(m), !taken.contains(m) {
            issues.append(OrgIssue(handle: a.handle, message: "manager \(m) is not seated"))
        } }
        guard issues.isEmpty else { throw OrgError.invalidPlan(issues) }

        let now = Store.now()
        for a in plan.agents { try retirePreexistingLab(companyId: companyId, handle: a.handle, now: now) }
        do {
            return try writer.write { db in
                var hired: [String: Agent] = [:]
                var result: [Agent] = []
                for a in plan.agents {
                    let agent = try Store.hire(db: db, companyId: companyId, name: a.handle, role: a.role, model: "auto",
                                               managerId: nil, team: a.team, now: now, honoringVacancy: true)
                    hired[a.handle] = agent
                    result.append(agent)
                }
                for (i, a) in plan.agents.enumerated() {
                    guard let m = a.managerHandle else { continue }
                    let managerId = try hired[m]?.id ?? String.fetchOne(
                        db, sql: "SELECT id FROM agent WHERE companyId = ? AND name = ?", arguments: [companyId, m])
                    try db.execute(sql: "UPDATE agent SET managerId = ? WHERE id = ?", arguments: [managerId, result[i].id])
                    result[i].managerId = managerId
                }
                for a in result {
                    try Store.joinOrgChannels(db, agent: a, template: pack.role(a.role) ?? .generic(a.role), pack: pack, now: now)
                }
                for v in vacancies {
                    var row = OrgVacancy(id: nil, companyId: companyId, role: v.role, handle: v.handle,
                                         managerHandle: v.managerHandle, team: v.team, createdAt: now, filledAt: nil)
                    try row.insert(db)
                }
                return result
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw StoreError.duplicateName
        }
    }

    /// exec (executives + owner), architecture (cto-covering roles, architects, managers, directors), team-<name>.
    static func joinOrgChannels(_ db: Database, agent: Agent, template: RoleTemplate, pack: IndustryPack, now: Date) throws {
        func join(_ name: String, owner: Bool = false) throws {
            guard name.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else { return }
            let channel: Channel
            if let existing = try Channel.filter(Column("companyId") == agent.companyId && Column("name") == name).fetchOne(db) {
                channel = existing
            } else {
                channel = try Store.insertChannel(db, companyId: agent.companyId, name: name, kind: .channel,
                                                  members: owner ? ["owner"] : [], now: now)
            }
            try ChannelMember(channelId: channel.id, member: agent.id).insert(db, onConflict: .ignore)
        }
        if template.kind == .executive { try join("exec", owner: true) }
        if pack.rolesCovering("cto").contains(template.id) || template.kind == .architect || template.kind == .manager {
            try join("architecture")
        }
        if let team = agent.team { try join("team-\(team)") }
    }

    // MARK: Vacancies

    /// Open seats (neither filled nor removed), oldest first.
    public func vacancies(companyId: String) throws -> [OrgVacancy] {
        try writer.read { db in
            try OrgVacancy.filter(Column("companyId") == companyId && Column("filledAt") == nil && Column("removedAt") == nil)
                .order(Column("id")).fetchAll(db)
        }
    }

    /// Hires the vacancy (model `auto`). The manager is resolved by handle, else the nearest existing ancestor.
    @discardableResult
    public func fillVacancy(companyId: String, handle: String) throws -> Agent {
        let now = Store.now()
        let key = handle.lowercased()
        guard let company = try company(id: companyId) else { throw StoreError.notFound }
        let pack = pack(for: company)
        try retirePreexistingLab(companyId: companyId, handle: key, now: now)
        do {
            return try writer.write { db in
                guard var v = try OrgVacancy.filter(Column("companyId") == companyId && Column("handle") == key
                                                    && Column("filledAt") == nil && Column("removedAt") == nil).fetchOne(db)
                else { throw StoreError.notFound }
                var managerId: String?
                var cursor = v.managerHandle
                var steps = 0
                while let c = cursor, steps < 1000 {
                    if let m = try Agent.filter(Column("companyId") == companyId && Column("name") == c
                                                && Column("state") != AgentState.killed.rawValue).fetchOne(db) {
                        managerId = m.id; break
                    }
                    cursor = try OrgVacancy.filter(Column("companyId") == companyId && Column("handle") == c)
                        .fetchOne(db)?.managerHandle
                    steps += 1
                }
                let agent = try Store.hire(db: db, companyId: companyId, name: v.handle, role: v.role, model: "auto",
                                           managerId: managerId, team: v.team, now: now, honoringVacancy: true)
                v.filledAt = now
                try v.update(db)
                let template = pack?.role(v.role) ?? .generic(v.role)
                if let pack { try Store.joinOrgChannels(db, agent: agent, template: template, pack: pack, now: now) }
                return agent
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw StoreError.duplicateName
        }
    }

    // MARK: Reporting lines

    /// Owner or manager edit. Throws `.cycle`, `.tooManyReports` or `.managerKilled`.
    public func setManager(agentId: String, managerId: String?) throws {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            if let managerId {
                guard let manager = try Agent.fetchOne(db, key: managerId), manager.companyId == agent.companyId
                else { throw StoreError.notFound }
                if manager.state == .killed { throw OrgError.managerKilled }
                var cursor: String? = managerId
                var steps = 0
                while let c = cursor, steps < 100_000 {
                    if c == agentId { throw OrgError.cycle }
                    cursor = try String.fetchOne(db, sql: "SELECT managerId FROM agent WHERE id = ?", arguments: [c])
                    steps += 1
                }
                let others = try Agent.filter(Column("managerId") == managerId && Column("id") != agentId
                                              && Column("state") != AgentState.killed.rawValue).fetchCount(db)
                if others + 1 > OrgGenerator.maxReports { throw OrgError.tooManyReports(manager: manager.name, count: others + 1) }
            }
            try db.execute(sql: "UPDATE agent SET managerId = ? WHERE id = ?", arguments: [managerId, agentId])
        }
    }

    public func setTeam(agentId: String, team: String?) throws {
        try writer.write { db in
            guard try Agent.fetchOne(db, key: agentId) != nil else { throw StoreError.notFound }
            try db.execute(sql: "UPDATE agent SET team = ? WHERE id = ?", arguments: [team, agentId])
        }
    }

    public func reports(agentId: String) throws -> [Agent] {
        try writer.read { db in
            try Agent.filter(Column("managerId") == agentId && Column("state") != AgentState.killed.rawValue)
                .order(Column("createdAt"), Column.rowID).fetchAll(db)
        }
    }

    /// The live org as indented lines: `handle (Title)`, children in hire order.
    public func orgTreeLines(companyId: String) throws -> [String] {
        let live = try agents(companyId: companyId).filter { $0.state != .killed }
        let pack = try company(id: companyId).flatMap { catalog.pack($0.packId) }
        let ids = Set(live.map(\.id))
        var children: [String: [Agent]] = [:]
        var roots: [Agent] = []
        for a in live {
            if let m = a.managerId, ids.contains(m) { children[m, default: []].append(a) } else { roots.append(a) }
        }
        var lines: [String] = []
        var seen = Set<String>()
        func walk(_ a: Agent, _ depth: Int) {
            guard seen.insert(a.id).inserted else { return }
            let title = (pack?.role(a.role) ?? RoleTemplate.generic(a.role)).title
            lines.append(String(repeating: "  ", count: depth) + "\(a.name) (\(title))")
            for c in children[a.id] ?? [] { walk(c, depth + 1) }
        }
        for r in roots { walk(r, 0) }
        return lines
    }
}
