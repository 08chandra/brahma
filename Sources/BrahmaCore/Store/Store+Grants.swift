import Foundation
import GRDB

/// The outcome of `request_access`.
public struct AccessRequest: Equatable, Sendable {
    public var ask: Ask
    /// An open request for the same kind and value already existed (`ask` is that one); nothing was filed.
    public var deduped: Bool
    /// The grant an enabled access preset approved at once, if any.
    public var grant: Grant?
}

/// How an approved `grant` ask becomes a grant: the validated value, and the owner's (or a preset's) scope and duration (nil:
/// what the agent asked for).
struct GrantApproval: Sendable {
    var kind: GrantKind
    var value: String
    var scope: GrantScope?
    var duration: GrantDuration?
    var approvedBy: String
}

extension Store {
    // MARK: Requests

    /// An agent's access request (`request_access`). In order:
    /// 1. the requester must be an active agent of the company, and the item (if any) the company's (`.forbidden("not in
    ///    your company")`);
    /// 2. `AskQuota` (checked again in the write that files the ask);
    /// 3. the value must be grantable (`Grants.validate`; read paths against the owner's `userHome`);
    /// 4. an open request for the same kind and value anywhere in the company is returned instead (`deduped`);
    /// 5. a `grant` ask (category `tooling`, risk `kind.risk`) goes straight to the owner;
    /// 6. an enabled access preset may approve it at once, through `ownerDecide` (owner-delegated), with an FYI notice.
    @discardableResult
    public func requestAccess(companyId: String, agentId: String, kind: GrantKind, value: String, reason: String,
                              itemId: String? = nil, scope: GrantScope? = nil, duration: GrantDuration? = nil,
                              userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                              now: Date = Store.now()) throws -> AccessRequest {
        // 1. Cross-company ids first.
        try writer.read { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard agent.state != .killed else { throw WorkError.forbidden("this agent is not active in the company") }
            if let itemId {
                guard let item = try WorkItem.fetchOne(db, key: itemId), item.companyId == companyId else {
                    throw WorkError.forbidden("not in your company")
                }
            }
        }
        // 2. The quota, before anything else is looked at.
        try AskQuota.check(store: self, agentId: agentId)
        // 3. The value (reads the file system for a path: outside any transaction).
        let context = try grantCheckContext(companyId: companyId, userHome: userHome)
        let normalized = try Grants.validate(kind: kind, value: value, company: context.company, paths: context.paths,
                                             userHome: userHome, otherWorkspaces: context.others, backupTargets: context.backups)
        if scope == .item, itemId == nil { throw WorkError.invalid("scope item needs an item") }
        let requested = RequestedGrant(kind: kind, value: normalized, duration: duration ?? .sprint)

        return try writer.write { db in
            try AskQuota.check(db: db, agentId: agentId)
            // 4. Deduped company-wide.
            let open = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.grant
                                      && [AskStatus.pendingInternal.rawValue, AskStatus.pendingOwner.rawValue].contains(Column("status")))
                .order(Column("number")).fetchAll(db)
            if let same = open.first(where: { Grants.requested($0).map { $0.kind == kind && $0.value == normalized } ?? false }) {
                return AccessRequest(ask: same, deduped: true, grant: nil)
            }
            // 5. The ask: no approver decides a grant; it goes to the owner.
            var ask = try propose(db: db, companyId: companyId, by: .agent(agentId), kind: .grant, risk: kind.risk,
                                  category: AccessPresets.category, title: "\(kind.rawValue) \(normalized)", summary: reason,
                                  payload: AskPayload(details: Grants.details(requested)), document: nil, itemId: itemId,
                                  subjectId: nil, supersedes: nil, requestId: nil, decisionClass: .taste, viaOwner: true, now: now)
            ask.proposedGrant = ProposedGrant(scope: (scope ?? .agent).rawValue, durationSeconds: nil)
            try ask.update(db, columns: ["proposedGrant"])
            // 6. The presets.
            let company = try requireCompany(db, companyId)
            guard let requester = try Agent.fetchOne(db, key: agentId),
                  let decision = AccessPresets.autoDecision(kind: kind, value: normalized, risk: ask.risk, requesterRole: requester.role,
                                                            company: company, enabled: try Store.enabledPresets(db, companyId: companyId),
                                                            pack: catalog.pack(company.packId))
            else { return AccessRequest(ask: ask, deduped: false, grant: nil) }
            let approval = GrantApproval(kind: kind, value: normalized, scope: decision.scope, duration: decision.duration,
                                         approvedBy: decision.approvedBy)
            // The one engine-internal caller of `ownerDecide`: the owner turned this preset on, so the decision is theirs.
            let decided = try ownerDecide(db: db, askId: ask.id, approve: true, note: "auto: \(ask.title)", acknowledgeChange: false,
                                          currentHash: nil, grant: approval, now: now)
            let grant = try Grant.filter(Column("askId") == ask.id).fetchOne(db)
            try notifyOwner(db: db, companyId: companyId, kind: .system, urgency: .normal,
                            title: "Access approved by preset \(decision.preset.rawValue)",
                            body: "\(decided.ref) \(ask.title) for @\(requester.name): \(grant?.ref ?? "?") (\(decision.scope.rawValue), "
                                + "\(decision.duration.rawValue)). Revoke with brahma grants revoke \(company.slug) \(grant?.ref ?? "").",
                            now: now)
            return AccessRequest(ask: decided, deduped: false, grant: grant)
        }
    }

    /// The company and what a grant value is checked against: the data home (a stand-in for an in-memory store), every other
    /// company's workspace and the owner's backup folders.
    func grantCheckContext(companyId: String, userHome: URL) throws -> (company: Company, paths: BrahmaPaths, others: [URL], backups: [URL]) {
        let (fetched, others) = try writer.read { db in
            (try Company.fetchOne(db, key: companyId),
             try Company.filter(Column("id") != companyId).fetchAll(db).map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false) })
        }
        guard let company = fetched else { throw WorkError.notFound("no such company") }
        let workspaces = URL(fileURLWithPath: company.workspacePath, isDirectory: false).deletingLastPathComponent()
        let paths = BrahmaPaths(home: dataHome ?? FileManager.default.temporaryDirectory.appending(path: "brahma-home-\(companyId)"),
                                workspaces: workspaces)
        return (company, paths, others, BackupTargets.protectedFolders(store: self))
    }

    // MARK: Owner

    /// The owner approves an access ask with a scope and duration (nil: what the agent asked for). The value is validated again
    /// (a path may have changed), then the ask is approved through `ownerDecide` and the grant written in the same transaction.
    @discardableResult
    public func approveAccess(askId: String, scope: GrantScope? = nil, duration: GrantDuration? = nil, note: String = "",
                              userHome: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Store.now()) throws -> Grant {
        let approval = try grantApproval(askId: askId, scope: scope, duration: duration, approvedBy: "owner", userHome: userHome)
        return try writer.write { db in
            let ask = try ownerDecide(db: db, askId: askId, approve: true, note: note, acknowledgeChange: false, currentHash: nil,
                                      grant: approval, now: now)
            guard let grant = try Grant.filter(Column("askId") == ask.id).fetchOne(db) else { throw WorkError.conflict("no grant was written") }
            return grant
        }
    }

    /// What approving a `grant` ask grants; reads the file system for a path (call it outside a write transaction).
    func grantApproval(askId: String, scope: GrantScope?, duration: GrantDuration?, approvedBy: String,
                       userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> GrantApproval {
        guard let ask = try ask(id: askId) else { throw WorkError.notFound("no such ask") }
        guard ask.kind == .grant, let requested = Grants.requested(ask) else { throw WorkError.invalid("\(ask.ref) is not an access request") }
        guard ask.status.isPending else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
        let context = try grantCheckContext(companyId: ask.companyId, userHome: userHome)
        let value = try Grants.validate(kind: requested.kind, value: requested.value, company: context.company, paths: context.paths,
                                        userHome: userHome, otherWorkspaces: context.others, backupTargets: context.backups)
        return GrantApproval(kind: requested.kind, value: value, scope: scope, duration: duration, approvedBy: approvedBy)
    }

    /// Writes the grant an approved `grant` ask gives (inside `ownerDecide`'s transaction).
    @discardableResult
    func createGrant(_ db: Database, ask: Ask, approval: GrantApproval, now: Date) throws -> Grant {
        guard let requested = Grants.requested(ask), requested.kind == approval.kind else {
            throw WorkError.invalid("\(ask.ref) is not an access request")
        }
        guard let requester = try Agent.fetchOne(db, key: ask.requesterId), requester.companyId == ask.companyId else {
            throw WorkError.forbidden("not in your company")
        }
        let scope = approval.scope ?? ask.proposedGrant.flatMap { GrantScope(rawValue: $0.scope) } ?? .agent
        let duration = approval.duration ?? requested.duration
        let scopeRef: String?
        switch scope {
        case .once, .agent:
            guard requester.state != .killed else { throw WorkError.invalid("@\(requester.name) has left the company; choose role or company scope") }
            scopeRef = scope == .agent ? requester.id : nil
        case .item:
            guard let itemId = ask.itemId else { throw WorkError.invalid("\(ask.ref) names no item; choose another scope") }
            scopeRef = itemId
        case .role: scopeRef = requester.role
        case .company: scopeRef = nil
        }
        let active = try Store.activeNow(db: db, companyId: ask.companyId)
        var sprintId: String?
        var expires: Double?
        if duration == .sprint {
            let open = Column("companyId") == ask.companyId && Column("status") == SprintStatus.active.rawValue
            var sprint: Sprint?
            if let team = requester.team { sprint = try Sprint.filter(open && Column("team") == team).order(Column("number").desc).fetchOne(db) }
            if sprint == nil { sprint = try Sprint.filter(open && Column("team") == nil).order(Column("number").desc).fetchOne(db) }
            if let sprint { sprintId = sprint.id } else { expires = active + GrantResolver.noSprintTTL }
        }
        let number = try Int.fetchOne(db, sql: #"SELECT COALESCE(MAX(number), 0) + 1 FROM "grant" WHERE companyId = ?"#,
                                      arguments: [ask.companyId]) ?? 1
        let grant = Grant(id: UUID().uuidString, companyId: ask.companyId, number: number, askId: ask.id, kind: approval.kind,
                          value: approval.value, scope: scope, scopeRef: scopeRef, requesterId: requester.id, duration: duration,
                          sprintId: sprintId, expiresActive: expires, usesLeft: scope == .once || duration == .turn ? 1 : nil,
                          approvedBy: approval.approvedBy, createdAt: now)
        try grant.insert(db)
        try ActivityEvent(companyId: ask.companyId, agentId: requester.id, turnId: nil, kind: .approval,
                          text: "\(grant.ref) granted (\(ask.ref)): \(grant.kind.rawValue) \(grant.value) for "
                              + "\(Store.describeScope(grant, requester: requester.name)), \(duration.rawValue), by \(approval.approvedBy)",
                          createdAt: now).insert(db)
        return grant
    }

    static func describeScope(_ grant: Grant, requester: String) -> String {
        switch grant.scope {
        case .once: "@\(requester)'s next turn"
        case .agent: "@\(requester)"
        case .item: "the item"
        case .role: "role \(grant.scopeRef ?? "?")"
        case .company: "the company"
        }
    }

    /// The owner (or a kill, `by: "kill"`) revokes a grant; it is gone from the next turn.
    @discardableResult
    public func revokeGrant(companyId: String, number: Int, by: String = "owner", now: Date = Store.now()) throws -> Grant {
        try writer.write { db in
            guard var grant = try Grant.filter(Column("companyId") == companyId && Column("number") == number).fetchOne(db) else {
                throw WorkError.notFound("no grant G-\(number)")
            }
            guard grant.revokedAt == nil else { throw WorkError.conflict("\(grant.ref) is already revoked") }
            grant.revokedAt = now
            grant.revokedBy = by
            try grant.update(db)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .approval,
                              text: "\(grant.ref) revoked by \(by): \(grant.kind.rawValue) \(grant.value)", createdAt: now).insert(db)
            return grant
        }
    }

    /// A killed agent's own grants (`agent` scope naming it, and its `once` grants) are revoked in the kill's transaction.
    static func revokeGrantsOfKilled(db: Database, agent: Agent, now: Date) throws {
        try db.execute(sql: #"""
            UPDATE "grant" SET revokedAt = ?, revokedBy = 'kill'
            WHERE companyId = ? AND revokedAt IS NULL
              AND ((scope = 'agent' AND scopeRef = ?) OR (scope = 'once' AND requesterId = ?))
            """#, arguments: [now, agent.companyId, agent.id, agent.id])
    }

    /// A rescinded access ask takes its grant with it.
    func revokeGrants(_ db: Database, askId: String, now: Date) throws {
        try db.execute(sql: #"UPDATE "grant" SET revokedAt = ?, revokedBy = 'owner' WHERE askId = ? AND revokedAt IS NULL"#,
                       arguments: [now, askId])
    }

    // MARK: Ledger

    /// The company's grants, newest last: the live ones, or (`includeInactive`) every grant ever written.
    public func grants(companyId: String, includeInactive: Bool = false) throws -> [Grant] {
        try writer.read { db in
            let all = try Grant.filter(Column("companyId") == companyId).order(Column("number")).fetchAll(db)
            guard !includeInactive else { return all }
            let active = try Store.activeNow(db: db, companyId: companyId)
            let sprints = try Store.activeSprintIds(db, companyId: companyId)
            return all.filter { GrantResolver.isLive($0, activeNow: active, sprintActive: sprints.contains) }
        }
    }

    static func activeSprintIds(_ db: Database, companyId: String) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT id FROM sprint WHERE companyId = ? AND status = ?",
                                arguments: [companyId, SprintStatus.active.rawValue]))
    }

    /// The grants a turn of `agent` gets now (working `itemId`, if any).
    public func activeGrants(agent: Agent, itemId: String?) throws -> [Grant] {
        try writer.read { db in
            guard let current = try Agent.fetchOne(db, key: agent.id), current.state != .killed,
                  let company = try Company.fetchOne(db, key: current.companyId) else { return [] }
            var roles: Set<String> = [current.role]
            if let template = catalog.pack(company.packId)?.role(current.role) { roles.formUnion(template.covers) }
            let all = try Grant.filter(Column("companyId") == company.id && Column("revokedAt") == nil).order(Column("number")).fetchAll(db)
            let sprints = try Store.activeSprintIds(db, companyId: company.id)
            return GrantResolver.active(all, agent: current, roles: roles, itemId: itemId,
                                        activeNow: try Store.activeNow(db: db, companyId: company.id), sprintActive: sprints.contains)
        }
    }

    /// Counts one use of each grant a turn starts with; a grant with uses left loses one. Returns the ids actually consumed: a
    /// grant revoked or used up meanwhile is not.
    @discardableResult
    public func consumeGrants(ids: [String], turnId: String, now: Date) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try writer.write { db in
            var used: Set<String> = []
            var refs: [String] = []
            var companyId: String?
            for id in ids {
                try db.execute(sql: #"""
                    UPDATE "grant" SET useCount = useCount + 1, lastUsedAt = ?,
                        usesLeft = CASE WHEN usesLeft IS NULL THEN NULL ELSE usesLeft - 1 END
                    WHERE id = ? AND revokedAt IS NULL AND (usesLeft IS NULL OR usesLeft > 0)
                    """#, arguments: [now, id])
                guard db.changesCount > 0, let g = try Grant.fetchOne(db, key: id) else { continue }
                used.insert(id)
                refs.append(g.ref)
                companyId = g.companyId
            }
            if let companyId, !refs.isEmpty {
                let agentId = try String.fetchOne(db, sql: "SELECT agentId FROM turn WHERE id = ?", arguments: [turnId])
                try ActivityEvent(companyId: companyId, agentId: agentId, turnId: turnId, kind: .work,
                                  text: "turn uses \(refs.joined(separator: ", "))", createdAt: now).insert(db)
            }
            return used
        }
    }

    // MARK: Presets

    public func setPreset(companyId: String, _ preset: AccessPreset, enabled: Bool) throws {
        try writer.write { db in
            _ = try requireCompany(db, companyId)
            try db.execute(sql: """
                INSERT INTO accessPreset(companyId, presetId, enabled) VALUES (?, ?, ?)
                ON CONFLICT(companyId, presetId) DO UPDATE SET enabled = excluded.enabled
                """, arguments: [companyId, preset.rawValue, enabled])
        }
    }

    /// The presets the owner turned on (none by default).
    public func enabledPresets(companyId: String) throws -> Set<AccessPreset> {
        try writer.read { db in try Store.enabledPresets(db, companyId: companyId) }
    }

    static func enabledPresets(_ db: Database, companyId: String) throws -> Set<AccessPreset> {
        Set(try String.fetchAll(db, sql: "SELECT presetId FROM accessPreset WHERE companyId = ? AND enabled = 1", arguments: [companyId])
            .compactMap(AccessPreset.init(rawValue:)))
    }
}
