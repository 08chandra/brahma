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

/// How an approved `grant` ask becomes a grant: the validated value, and the scope and duration the owner (or a preset the
/// owner turned on) chose. Never the agent's proposal.
struct GrantApproval: Sendable {
    var kind: GrantKind
    var value: String
    var scope: GrantScope
    var duration: GrantDuration
    var approvedBy: String
}

extension Store {
    // MARK: Requests

    /// An agent's access request (`request_access`). In order:
    /// 1. the requester must be an active agent of the company, and the item (if any) the company's (`.forbidden("not in
    ///    your company")`);
    /// 2. `AskQuota` (checked again in the write that files the ask), then the refusal budget (`AccessRefusals`);
    /// 3. the value must be grantable (`Grants.validate`). A refusal is recorded with its reason for the owner and counts
    ///    against the agent's refusal budget; a read path is refused with the one generic `Grants.pathRefusal`;
    /// 4. an open request for the same kind and value anywhere in the company is returned instead (`deduped`);
    /// 5. an enabled access preset may decide it at once: the ask is filed without the "approval needed" line and DM, approved
    ///    through `ownerDecide` (owner-delegated, `decidedBy` `preset:<id>`) and the owner gets an FYI notice;
    /// 6. otherwise the `grant` ask (category `tooling`, risk `kind.risk`) goes straight to the owner.
    @discardableResult
    public func requestAccess(companyId: String, agentId: String, kind: GrantKind, value: String, reason: String,
                              itemId: String? = nil, scope: GrantScope? = nil, duration: GrantDuration? = nil,
                              environment: SandboxEnvironment = .owner, now: Date = Store.now()) throws -> AccessRequest {
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
        // 2. The quota, then the refusal budget, before anything else is looked at.
        try AskQuota.check(store: self, agentId: agentId)
        try writer.read { db in
            let since = try Store.activeNow(db: db, companyId: companyId) - AccessRefusals.window
            let refused = try AccessRefusal.filter(Column("agentId") == agentId && Column("createdActive") > since).fetchCount(db)
            if refused >= AccessRefusals.perActiveDay { throw WorkError.invalid(AccessRefusals.message) }
        }
        // 3. The value (reads the file system for a path: outside any transaction).
        let normalized: String
        do {
            if scope == .item, itemId == nil { throw WorkError.invalid("scope item needs an item") }
            let context = try grantCheckContext(companyId: companyId)
            normalized = try Grants.validate(kind: kind, value: value, company: context.company, paths: context.paths,
                                             environment: environment, otherWorkspaces: context.others, backupTargets: context.backups,
                                             installedExtensions: try grantableExtensions(companyId: companyId))
        } catch {
            let detail = (error as? WorkError)?.message ?? "\(error)"
            // Agent-supplied text, kept in a database that is backed up, exported and shipped: redacted like every other
            // agent text (final review M3); withheld when the redactor cannot run.
            let withheld = "(withheld: secrets are not loaded)"
            try writer.write { db in
                var row = AccessRefusal(companyId: companyId, agentId: agentId, kind: kind.rawValue,
                                        value: Store.flat((try? redact(value)) ?? withheld, max: 500),
                                        detail: Store.flat((try? redact(detail)) ?? withheld, max: 1000),
                                        createdActive: try Store.activeNow(db: db, companyId: companyId), createdAt: now)
                try row.insert(db)
            }
            switch kind {
            case .readPath: throw WorkError.invalid(Grants.pathRefusal)
            case .extension: throw WorkError.invalid(Grants.noExtension(value))
            case .networkDomain, .webDomain: throw WorkError.invalid(detail)
            }
        }
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
            // 5. The presets decide before the ask is routed, so an ask they resolve never reaches the owner as "approval needed".
            let company = try requireCompany(db, companyId)
            guard let requester = try Agent.fetchOne(db, key: agentId) else { throw WorkError.forbidden("not in your company") }
            let decision = AccessPresets.autoDecision(kind: kind, value: normalized, risk: kind.risk, requesterRole: requester.role,
                                                      company: company, enabled: try Store.enabledPresets(db, companyId: companyId),
                                                      pack: catalog.pack(company.packId))
            // 6. The ask: no approver decides a grant; it goes to the owner.
            var ask = try propose(db: db, companyId: companyId, by: .agent(agentId), kind: .grant, risk: kind.risk,
                                  category: AccessPresets.category, title: "\(kind.rawValue) \(normalized)", summary: reason,
                                  payload: AskPayload(details: Grants.details(requested)), document: nil, itemId: itemId,
                                  subjectId: nil, supersedes: nil, requestId: nil, decisionClass: .taste, viaOwner: true,
                                  announce: decision == nil, now: now)
            ask.proposedGrant = ProposedGrant(scope: (scope ?? .agent).rawValue, durationSeconds: nil)
            try ask.update(db, columns: ["proposedGrant"])
            guard let decision else { return AccessRequest(ask: ask, deduped: false, grant: nil) }
            let approval = GrantApproval(kind: kind, value: normalized, scope: decision.scope, duration: decision.duration,
                                         approvedBy: decision.approvedBy)
            // The one engine-internal caller of `ownerDecide`: the owner turned this preset on, so the decision is theirs.
            let decided = try ownerDecide(db: db, askId: ask.id, approve: true, note: "auto: \(ask.title)", acknowledgeChange: false,
                                          currentHash: nil, grant: approval, decidedBy: decision.approvedBy, now: now)
            let grant = try Grant.filter(Column("askId") == ask.id).fetchOne(db)
            try notifyOwner(db: db, companyId: companyId, kind: .system, urgency: .normal,
                            title: "Access approved by preset \(decision.preset.rawValue)",
                            body: "\(decided.ref) \(ask.title) for @\(requester.name): \(grant?.ref ?? "?") (\(decision.scope.rawValue), "
                                + "\(decision.duration.rawValue)). Revoke with brahma grants revoke \(company.slug) \(grant?.ref ?? "").",
                            now: now)
            return AccessRequest(ask: decided, deduped: false, grant: grant)
        }
    }

    /// The refused access requests of a company, newest first (the owner's view of why).
    public func accessRefusals(companyId: String, limit: Int = 50) throws -> [AccessRefusal] {
        try writer.read { db in
            try AccessRefusal.filter(Column("companyId") == companyId).order(Column("id").desc).limit(limit).fetchAll(db)
        }
    }

    /// The company and what a grant value is checked against: the data home (a stand-in for an in-memory store), every other
    /// company's workspace and the owner's backup folders.
    /// `<publisher>/<id>` of every installed, enabled extension of the company: what an `extension` grant may name (Task 5a).
    func grantableExtensions(companyId: String) throws -> Set<String> {
        // The publisher is the company's own (set at approve), never the shared package row's (B-I1).
        Set(try installedExtensions(companyId: companyId).filter { $0.enabled && !$0.publisher.isEmpty }
                .map { ExtensionRef(publisher: $0.publisher, id: $0.id).key })
    }

    func grantCheckContext(companyId: String) throws -> (company: Company, paths: BrahmaPaths, others: [URL], backups: [URL]) {
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

    /// The owner approves an access ask with the scope and duration they chose (the agent's proposal is only shown). The value is
    /// validated again (a read path must still be the very directory that was asked for), then the ask is approved through
    /// `ownerDecide` and the grant written in the same transaction.
    @discardableResult
    public func approveAccess(askId: String, scope: GrantScope, duration: GrantDuration, note: String = "",
                              environment: SandboxEnvironment = .owner, now: Date = Store.now()) throws -> Grant {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        let approval = try grantApproval(askId: askId, scope: scope, duration: duration, approvedBy: "owner", environment: environment)
        return try writer.write { db in
            let ask = try ownerDecide(db: db, askId: askId, approve: true, note: note, acknowledgeChange: false, currentHash: nil,
                                      grant: approval, now: now)
            guard let grant = try Grant.filter(Column("askId") == ask.id).fetchOne(db) else { throw WorkError.conflict("no grant was written") }
            return grant
        }
    }

    /// What approving a `grant` ask grants; reads the file system for a path (call it outside a write transaction).
    func grantApproval(askId: String, scope: GrantScope, duration: GrantDuration, approvedBy: String,
                       environment: SandboxEnvironment) throws -> GrantApproval {
        guard let ask = try ask(id: askId) else { throw WorkError.notFound("no such ask") }
        guard ask.kind == .grant, let requested = Grants.requested(ask) else { throw WorkError.invalid("\(ask.ref) is not an access request") }
        guard ask.status.isPending else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
        let context = try grantCheckContext(companyId: ask.companyId)
        let value = try Grants.validate(kind: requested.kind, value: requested.value, company: context.company, paths: context.paths,
                                        environment: environment, otherWorkspaces: context.others, backupTargets: context.backups,
                                        installedExtensions: try grantableExtensions(companyId: ask.companyId))
        // A read path is pinned at request: if it now resolves elsewhere (a link was put in its place), it is not what was asked.
        if requested.kind == .readPath, !Grants.isPinned(requested.value) || SandboxPath.key(value) != SandboxPath.key(requested.value) {
            throw WorkError.invalid("\(requested.value) is no longer the directory that was requested (a symbolic link replaced it "
                                    + "or a part of it); reject \(ask.ref)")
        }
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
        let scope = approval.scope, duration = approval.duration
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
        let number = try Store.nextRefNumber(db: db, companyId: ask.companyId, kind: .grant, floor: try Int.fetchOne(db, sql:
            #"SELECT COALESCE(MAX(number), 0) FROM "grant" WHERE companyId = ?"#, arguments: [ask.companyId]) ?? 0)
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
        let own = try Grant.filter(Column("companyId") == agent.companyId && Column("revokedAt") == nil
                                   && ((Column("scope") == GrantScope.agent.rawValue && Column("scopeRef") == agent.id)
                                       || (Column("scope") == GrantScope.once.rawValue && Column("requesterId") == agent.id)))
            .fetchAll(db)
        try revoke(db, own, by: "kill", why: "@\(agent.name) was removed", now: now)
    }

    /// A rescinded access ask takes its grant with it.
    func revokeGrants(_ db: Database, askId: String, now: Date) throws {
        let grants = try Grant.filter(Column("askId") == askId && Column("revokedAt") == nil).fetchAll(db)
        try Store.revoke(db, grants, by: "owner", why: "its ask was rescinded", now: now)
    }

    /// Revokes each grant with a ledger line.
    static func revoke(_ db: Database, _ grants: [Grant], by: String, why: String, now: Date) throws {
        for var g in grants {
            g.revokedAt = now
            g.revokedBy = by
            try g.update(db)
            try ActivityEvent(companyId: g.companyId, agentId: nil, turnId: nil, kind: .approval,
                              text: "\(g.ref) revoked by \(by) (\(why)): \(g.kind.rawValue) \(g.value)", createdAt: now).insert(db)
        }
    }

    /// A read-path grant whose directory was replaced (a link, an alias or a file where it or a part of it was) is revoked by
    /// the engine and the owner is told; it never reaches a turn. A missing or newly overlapping path is only left out of a turn.
    func revokeChangedPathGrant(_ grant: Grant, now: Date) throws {
        try writer.write { db in
            guard let current = try Grant.fetchOne(db, key: grant.id), current.revokedAt == nil else { return }
            try Store.revoke(db, [current], by: "engine", why: "the path changed", now: now)
            try notifyOwner(db: db, companyId: grant.companyId, kind: .system, urgency: .normal,
                            title: "Read grant \(grant.ref) revoked",
                            body: "\(grant.ref) read_path \(grant.value) no longer is the directory you approved: a symbolic link, "
                                + "an alias or a file is where it (or a part of it) was. Brahma revoked it; check what changed it "
                                + "before granting it again.", now: now)
        }
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

    /// The grants a turn of `agent` of `kind` gets now (working `itemId`, if any; see `GrantResolver.active`).
    public func activeGrants(agent: Agent, itemId: String?, kind: TurnKind = .work) throws -> [Grant] {
        try writer.read { db in
            guard let current = try Agent.fetchOne(db, key: agent.id), current.state != .killed,
                  let company = try Company.fetchOne(db, key: current.companyId) else { return [] }
            var roles: Set<String> = [current.role]
            if let template = catalog.pack(company.packId)?.role(current.role) { roles.formUnion(template.covers) }
            let all = try Grant.filter(Column("companyId") == company.id && Column("revokedAt") == nil).order(Column("number")).fetchAll(db)
            let sprints = try Store.activeSprintIds(db, companyId: company.id)
            return GrantResolver.active(all, agent: current, roles: roles, itemId: itemId, kind: kind,
                                        activeNow: try Store.activeNow(db: db, companyId: company.id), sprintActive: sprints.contains)
        }
    }

    /// Counts one use of each grant a launching turn starts with, all or nothing: when any of them was revoked, used up or removed
    /// meanwhile, nothing is written and those ids are returned (the caller rebuilds the scope without them and tries again).
    /// A grant with uses left loses one; only those uses are logged (unlimited ones keep `useCount`/`lastUsedAt`).
    @discardableResult
    public func consumeGrants(ids: [String], turnId: String, now: Date) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try writer.write { db in
            var grants: [Grant] = []
            var lost: Set<String> = []
            for id in ids {
                guard let g = try Grant.fetchOne(db, key: id), g.revokedAt == nil, (g.usesLeft ?? 1) > 0 else { lost.insert(id); continue }
                grants.append(g)
            }
            guard lost.isEmpty else { return lost }
            var oneUse: [String] = []
            for var g in grants {
                g.useCount += 1
                g.lastUsedAt = now
                if let uses = g.usesLeft { g.usesLeft = uses - 1; oneUse.append(g.ref) }
                try g.update(db)
            }
            if let companyId = grants.first?.companyId, !oneUse.isEmpty {
                let agentId = try String.fetchOne(db, sql: "SELECT agentId FROM turn WHERE id = ?", arguments: [turnId])
                try ActivityEvent(companyId: companyId, agentId: agentId, turnId: turnId, kind: .work,
                                  text: "turn uses \(oneUse.joined(separator: ", ")) (one use)", createdAt: now).insert(db)
            }
            return []
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
